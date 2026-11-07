import Foundation
import UIKit
import Combine
import BackpackProtocol

enum PhoneDisplayFileReader {
    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw BackpackError.invalid("Choose a local image/GIF file.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, (1...5_000_000).contains(size),
              let stream = InputStream(url: url) else {
            throw BackpackError.invalid("Choose a regular local image/GIF file up to 5 MB.")
        }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = stream.read(&buffer, maxLength: 65536)
            guard count >= 0 else { throw stream.streamError ?? BackpackError.invalid("Could not read the local artwork.") }
            if count == 0 { break }
            guard result.count + count <= 5_000_000 else { throw BackpackError.invalid("The image/GIF exceeds 5 MB.") }
            result.append(contentsOf: buffer.prefix(count))
        }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard result.count == size, after.fileSize == size, after.contentModificationDate == values.contentModificationDate else { throw BackpackError.invalid("The file changed while opening. Select it again.") }
        return result
    }
}

struct PhoneDisplaySnapshot: Codable, Sendable {
    let data: Data?
    let mediaID: UUID?
    let elapsed: Double
    let wantsPlayback, motionOverride, keepAwake: Bool
    var brightnessEnabled: Bool? = nil
    var brightnessLevel: Double? = nil
    var animationsEnabled: Bool? = nil
    var dataSaving: Bool? = nil
    var crispPixels: Bool? = nil
    var pixelGrid: Bool? = nil
}
struct PhonePeerHandoff: Equatable {
    let startUptime: Double
    let sender: Bool
    func visible(at uptime: Double) -> Bool {
        guard uptime >= startUptime else { return false }
        let leg = Int((uptime - startUptime) / 2) % 2
        return sender ? leg == 0 : leg == 1
    }
}

struct PhonePlaybackClock {
    private var position = 0.0
    private var anchor: ContinuousClock.Instant?
    func elapsed(at now: ContinuousClock.Instant = ContinuousClock().now) -> Double {
        guard let anchor else { return position }
        let duration = anchor.duration(to: now).components
        return position + max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
    mutating func start(at now: ContinuousClock.Instant = ContinuousClock().now) { if anchor == nil { anchor = now } }
    mutating func pause(at now: ContinuousClock.Instant = ContinuousClock().now) { position = elapsed(at: now); anchor = nil }
    mutating func reset(to elapsed: Double = 0) throws {
        guard elapsed.isFinite, elapsed >= 0 else { throw BackpackError.invalid("Invalid phone playback position.") }
        position = elapsed; anchor = nil
    }
}

@MainActor
protocol PhoneIdleTimer: AnyObject { var disabled: Bool { get set } }

@MainActor
final class SystemPhoneIdleTimer: PhoneIdleTimer {
    var disabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
}

@MainActor
final class PhoneIdleTimerLease {
    private let timer: any PhoneIdleTimer
    private var previous: Bool?
    init(timer: any PhoneIdleTimer) { self.timer = timer }
    func update(requested: Bool) {
        if requested {
            if previous == nil { previous = timer.disabled }
            timer.disabled = true
        } else if let previous {
            timer.disabled = previous
            self.previous = nil
        }
    }
}

@MainActor
protocol PhoneScreenBrightness: AnyObject { var value: Double { get set } }
@MainActor
final class SystemPhoneScreenBrightness: PhoneScreenBrightness {
    var value: Double {
        get { Double(UIScreen.main.brightness) }
        set { UIScreen.main.brightness = CGFloat(newValue) }
    }
}
@MainActor
final class PhoneBrightnessLease {
    private let screen: any PhoneScreenBrightness
    private var original: Double?
    init(_ screen: any PhoneScreenBrightness) { self.screen = screen }
    func update(requested: Bool, level: Double) {
        if requested {
            if original == nil { original = screen.value }
            screen.value = level
        } else if let original {
            screen.value = original; self.original = nil
        }
    }
}

@MainActor
final class PhoneDisplayController: ObservableObject {
    @Published private(set) var presented = false
    @Published private(set) var preview: GIFPreview?
    @Published private(set) var isPlaying = false
    @Published private(set) var keepAwake = false
    @Published private(set) var failure: String?
    @Published private(set) var loading = false
    @Published private(set) var brightnessEnabled = false
    @Published private(set) var brightnessLevel = 0.5
    @Published private(set) var animationsEnabled = true
    @Published private(set) var dataSaving = false
    @Published private(set) var viewerAutomaticPlaybackAllowed = true
    @Published var crispPixels = true
    @Published var pixelGrid = false
    @Published private(set) var artworkRevision = UUID()
    @Published private(set) var playbackPolicyRevision = UUID()
    @Published private(set) var peerHandoff: PhonePeerHandoff?
    private(set) var data: Data?
    private(set) var mediaID: UUID?
    private var clock = PhonePlaybackClock()
    private var wantsPlayback = false
    private var automaticPlayback = false
    private var motionOverride = false
    private var reducedMotion: Bool
    private var peerAwakeSuppressed = false
    private var peerBrightnessSuppressed = false
    private var visible = false
    private var foreground = false
    private let idleLease: PhoneIdleTimerLease
    private let brightnessLease: PhoneBrightnessLease
    private var generation = UUID()
    private var decodeTask: Task<Void, Never>?
    private var preparation: Task<GIFPreview, Error>?

    convenience init() { self.init(idleTimer: SystemPhoneIdleTimer(), reducedMotion: UIAccessibility.isReduceMotionEnabled) }
    init(idleTimer: any PhoneIdleTimer, reducedMotion: Bool = false, brightness: (any PhoneScreenBrightness)? = nil) {
        idleLease = PhoneIdleTimerLease(timer: idleTimer); self.reducedMotion = reducedMotion
        brightnessLease = PhoneBrightnessLease(brightness ?? SystemPhoneScreenBrightness())
    }
    var hasArtwork: Bool { data != nil }
    var canApplyAutomaticPhoneArtwork: Bool { presented && visible && foreground && failure == nil && !loading }
    var manualSelectionWillChange: (() -> Void)?
    var peerPlaybackPolicyChanged: (() -> Void)?
    var manualPresentationWillChange: (() -> Void)?
    var animated: Bool { (preview?.duration ?? 0) > 0 }
    func cancelPendingSelection() { generation = UUID(); decodeTask?.cancel(); preparation?.cancel(); loading = false }
    func showLocalFile(_ url: URL, mediaID: UUID? = nil) async throws {
        guard foreground else { throw BackpackError.invalid("Return to the foreground before choosing phone artwork.") }
        cancelPendingSelection()
        let stamp = generation
        let reader = Task.detached(priority: .userInitiated) { try PhoneDisplayFileReader.read(url) }
        let bytes = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
        try Task.checkCancellation()
        guard generation == stamp, foreground else { throw CancellationError() }
        try await show(bytes, mediaID: mediaID)
    }

    func show(_ bytes: Data, mediaID: UUID? = nil) async throws {
        manualSelectionWillChange?()
        guard foreground else { throw BackpackError.invalid("Return to the foreground before changing phone artwork.") }
        let stamp = UUID(); generation = stamp; decodeTask?.cancel(); loading = true
        defer { if generation == stamp { loading = false } }
        let decoded = try await decode(bytes)
        try Task.checkCancellation()
        guard generation == stamp, foreground else { throw CancellationError() }
        try clock.reset()
        data = bytes; self.mediaID = mediaID; preview = decoded
        peerHandoff = nil
        peerAwakeSuppressed = false; peerBrightnessSuppressed = false
        artworkRevision = UUID()
        wantsPlayback = false; motionOverride = false; automaticPlayback = false
        failure = nil; presented = true; updatePolicy(releaseDecoded: false)
    }
    func open() {
        failure = nil; presented = true
        updatePolicy()
    }
    func dismiss() {
        manualSelectionWillChange?()
        cancelPendingSelection()
        visible = false; presented = false
        updatePolicy()
    }
    func setVisible(_ value: Bool) {
        if !value { manualSelectionWillChange?(); cancelPendingSelection() }
        visible = value; updatePolicy()
    }
    func setForeground(_ value: Bool) {
        if !value { cancelPendingSelection() }
        foreground = value; updatePolicy()
    }
    func setReducedMotion(_ value: Bool) {
        let changed = value != reducedMotion
        if changed { playbackPolicyRevision = UUID() }
        if value != reducedMotion && value { motionOverride = false }
        reducedMotion = value; updatePolicy()
        if changed { peerPlaybackPolicyChanged?() }
    }
    func setKeepAwake(_ value: Bool) { manualPresentationWillChange?(); peerAwakeSuppressed = false; keepAwake = value; updatePolicy() }
    func setBrightnessEnabled(_ value: Bool) { manualPresentationWillChange?(); peerBrightnessSuppressed = false; brightnessEnabled = value; updatePolicy() }
    func setBrightness(_ value: Double) {
        guard value.isFinite, (0.1...1).contains(value) else { report(BackpackError.invalid("Choose a phone brightness between 10% and 100%.")); return }
        manualPresentationWillChange?()
        peerBrightnessSuppressed = false; brightnessLevel = value; updatePolicy()
    }
    func setAnimationsEnabled(_ value: Bool) { playbackPolicyRevision = UUID(); animationsEnabled = value; if !value { wantsPlayback = false }; updatePolicy(); peerPlaybackPolicyChanged?() }
    func applySoloBrightness(_ value: Double, expectedRevision: UUID) throws {
        guard value.isFinite, (0.1...0.6).contains(value), canApplyAutomaticPhoneArtwork,
              artworkRevision == expectedRevision else { throw BackpackError.invalid("Capped SOLO brightness lost PHONE ownership/context; no override applied.") }
        peerBrightnessSuppressed = false; brightnessLevel = value; brightnessEnabled = true; updatePolicy()
    }
    func setDataSaving(_ value: Bool) { playbackPolicyRevision = UUID(); dataSaving = value; if value { wantsPlayback = false }; updatePolicy(); peerPlaybackPolicyChanged?() }
    func setViewerAutomaticPlaybackAllowed(_ value: Bool) {
        guard viewerAutomaticPlaybackAllowed != value else { return }
        viewerAutomaticPlaybackAllowed = value; playbackPolicyRevision = UUID()
        if !value && automaticPlayback { wantsPlayback = false; motionOverride = false; peerHandoff = nil }
        updatePolicy()
        peerPlaybackPolicyChanged?()
    }
    func play() {
        playbackPolicyRevision = UUID()
        peerPlaybackPolicyChanged?()
        guard animated, animationsEnabled, !dataSaving else { return }
        do {
            if position().finished { try clock.reset() }
            peerAwakeSuppressed = false; peerBrightnessSuppressed = false
            wantsPlayback = true; motionOverride = reducedMotion; automaticPlayback = false
            updatePolicy()
        } catch { report(error) }
    }
    func pause() { playbackPolicyRevision = UUID(); wantsPlayback = false; motionOverride = false; updatePolicy(); peerPlaybackPolicyChanged?() }
    func clearPeerHandoff() { peerHandoff = nil }
    func stopPeerPlayback() {
        peerHandoff = nil; wantsPlayback = false; motionOverride = false
        peerAwakeSuppressed = true; peerBrightnessSuppressed = true; updatePolicy()
    }
    func finishIfNeeded() { if position().finished { wantsPlayback = false; updatePolicy() } }
    func position() -> (index: Int, finished: Bool) {
        position(atElapsed: clock.elapsed())
    }
    func position(atElapsed elapsed: Double) -> (index: Int, finished: Bool) {
        guard let preview, preview.duration > 0 else { return (0, false) }
        if let cycles = preview.cycles, elapsed >= preview.duration * Double(cycles) {
            return (preview.frames.count - 1, true)
        }
        return (preview.frameIndex(at: elapsed), false)
    }
    func snapshot() -> PhoneDisplaySnapshot {
        PhoneDisplaySnapshot(data: data, mediaID: mediaID, elapsed: clock.elapsed(), wantsPlayback: wantsPlayback,
            motionOverride: motionOverride, keepAwake: keepAwake, brightnessEnabled: brightnessEnabled,
            brightnessLevel: brightnessLevel, animationsEnabled: animationsEnabled, dataSaving: dataSaving,
            crispPixels: crispPixels, pixelGrid: pixelGrid)
    }
    func restore(_ value: PhoneDisplaySnapshot) async throws {
        guard foreground else { throw BackpackError.invalid("Restore phone artwork only while the app is in the foreground.") }
        guard value.elapsed.isFinite, value.elapsed >= 0, value.data != nil || value.mediaID == nil else {
            throw BackpackError.invalid("Invalid local phone-display snapshot.")
        }
        guard value.data != nil || (value.elapsed == 0 && !value.wantsPlayback && !value.motionOverride) else {
            throw BackpackError.invalid("An empty phone display cannot have an active playhead.")
        }
        if let brightness = value.brightnessLevel {
            guard brightness.isFinite, (0.1...1).contains(brightness) else { throw BackpackError.invalid("Invalid recovered phone brightness.") }
        }
        let decoded: GIFPreview?
        let stamp = UUID(); generation = stamp; decodeTask?.cancel()
        loading = true
        defer { if generation == stamp { loading = false } }
        if let bytes = value.data { decoded = try await decode(bytes) }
        else { decoded = nil }
        try Task.checkCancellation()
        guard stamp == generation, foreground else { throw CancellationError() }
        try clock.reset(to: value.elapsed)
        data = value.data; mediaID = value.mediaID; preview = decoded
        peerHandoff = nil
        peerAwakeSuppressed = false; peerBrightnessSuppressed = false
        artworkRevision = UUID()
        wantsPlayback = value.wantsPlayback; motionOverride = value.motionOverride; keepAwake = value.keepAwake
        automaticPlayback = false
        brightnessEnabled = value.brightnessEnabled ?? false; brightnessLevel = value.brightnessLevel ?? 0.5
        animationsEnabled = value.animationsEnabled ?? true; dataSaving = value.dataSaving ?? false
        crispPixels = value.crispPixels ?? true; pixelGrid = value.pixelGrid ?? false
        failure = nil; updatePolicy(releaseDecoded: false)
    }
    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        failure = error.localizedDescription; wantsPlayback = false; presented = true; updatePolicy(releaseDecoded: false)
    }
    func clearFailure() { failure = nil }
    func applyValidatedGameGIF(_ bytes: Data, expectedRevision: UUID, nextRevision: UUID,
        startAtUptime: Double? = nil, explicitlyArmedPlayback: Bool = false, handoffSender: Bool? = nil,
        reauthorize: @escaping @MainActor () async throws -> Void = {},
        validateContext: @escaping @MainActor () throws -> Void = {}) async throws {
        guard canApplyAutomaticPhoneArtwork, artworkRevision == expectedRevision else { throw BackpackError.invalid("Current phone display/selection is no longer owned by this game.") }
        try validateContext()
        let stamp = generation
        let result = try await decode(bytes)
        try Task.checkCancellation()
        guard generation == stamp, canApplyAutomaticPhoneArtwork, artworkRevision == expectedRevision else { throw CancellationError() }
        try validateContext()
        if let start = startAtUptime {
            let remaining = start - ProcessInfo.processInfo.systemUptime
            guard start.isFinite, remaining >= -0.3, remaining <= 5 else { throw BackpackError.invalid("Best-effort shared start was missed/invalid; no verified synchronization is claimed.") }
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            try validateContext()
            guard generation == stamp, canApplyAutomaticPhoneArtwork, artworkRevision == expectedRevision else { throw CancellationError() }
        }
        try await reauthorize()
        try Task.checkCancellation(); try validateContext()
        guard generation == stamp, canApplyAutomaticPhoneArtwork, artworkRevision == expectedRevision else { throw CancellationError() }
        try clock.reset()
        data = bytes; mediaID = nil; preview = result; artworkRevision = nextRevision
        automaticPlayback = true
        if !viewerAutomaticPlaybackAllowed { wantsPlayback = false; motionOverride = false }
        else if explicitlyArmedPlayback && animationsEnabled && !dataSaving && !reducedMotion { wantsPlayback = true; motionOverride = false }
        if let handoffSender, wantsPlayback && viewerAutomaticPlaybackAllowed && animationsEnabled && !dataSaving && !reducedMotion {
            peerHandoff = PhonePeerHandoff(startUptime: startAtUptime ?? ProcessInfo.processInfo.systemUptime, sender: handoffSender)
        } else { peerHandoff = nil }
        updatePolicy(releaseDecoded: false)
    }
    private func decode(_ bytes: Data) async throws -> GIFPreview {
        preparation?.cancel()
        let worker = Task.detached(priority: .userInitiated) { try GIFPreviewDecoder.phoneDisplay(bytes) }
        preparation = worker
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private func updatePolicy(releaseDecoded: Bool = true) {
        let active = presented && visible && foreground
        if active, failure == nil, preview == nil, let data {
            guard !loading else { return }
            let stamp = UUID(); generation = stamp; loading = true
            decodeTask = Task {
                do {
                    let decoded = try await decode(data)
                    try Task.checkCancellation()
                    guard generation == stamp, presented, visible, foreground else { return }
                    preview = decoded; loading = false; updatePolicy(releaseDecoded: false)
                } catch {
                    guard generation == stamp, !Task.isCancelled else { return }
                    loading = false; report(error)
                }
            }
        }
        if position().finished { wantsPlayback = false }
        let running = active && failure == nil && animated && wantsPlayback && animationsEnabled && !dataSaving &&
            (!automaticPlayback || viewerAutomaticPlaybackAllowed) && (!reducedMotion || motionOverride)
        if running { clock.start() } else { clock.pause() }
        isPlaying = running
        idleLease.update(requested: active && failure == nil && hasArtwork && keepAwake && !peerAwakeSuppressed)
        brightnessLease.update(requested: active && failure == nil && hasArtwork && brightnessEnabled && !peerBrightnessSuppressed, level: brightnessLevel)
        if !active && releaseDecoded { preview = nil }
    }
}
