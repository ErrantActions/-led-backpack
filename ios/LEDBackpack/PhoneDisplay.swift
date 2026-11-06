import Foundation
import UIKit
import Combine
import BackpackProtocol

enum PhoneDisplayFileReader {
    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw BackpackError.invalid("Choose a local image/GIF file.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, (1...5_000_000).contains(size),
              let stream = InputStream(url: url) else {
            throw BackpackError.invalid("Choose a regular local image/GIF file up to 5 MB.")
        }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = stream.read(&buffer, maxLength: 65536)
            guard count >= 0 else { throw stream.streamError ?? BackpackError.invalid("Could not read the local artwork.") }
            if count == 0 { break }
            guard result.count + count <= 5_000_000 else { throw BackpackError.invalid("The image/GIF exceeds 5 MB.") }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == size else { throw BackpackError.invalid("The file changed while opening. Select it again.") }
        return result
    }
}

struct PhoneDisplaySnapshot: Codable {
    let data: Data?
    let mediaID: UUID?
    let elapsed: Double
    let wantsPlayback, motionOverride, keepAwake: Bool
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
final class PhoneDisplayController: ObservableObject {
    @Published private(set) var presented = false
    @Published private(set) var preview: GIFPreview?
    @Published private(set) var isPlaying = false
    @Published private(set) var keepAwake = false
    @Published private(set) var failure: String?
    private(set) var data: Data?
    private(set) var mediaID: UUID?
    private var clock = PhonePlaybackClock()
    private var wantsPlayback = false
    private var motionOverride = false
    private var reducedMotion: Bool
    private var visible = false
    private var foreground = false
    private let idleLease: PhoneIdleTimerLease

    convenience init() { self.init(idleTimer: SystemPhoneIdleTimer(), reducedMotion: UIAccessibility.isReduceMotionEnabled) }
    init(idleTimer: any PhoneIdleTimer, reducedMotion: Bool = false) {
        idleLease = PhoneIdleTimerLease(timer: idleTimer); self.reducedMotion = reducedMotion
    }
    var hasArtwork: Bool { data != nil }
    var animated: Bool { (preview?.duration ?? 0) > 0 }

    func show(_ bytes: Data, mediaID: UUID? = nil) throws {
        guard foreground else { throw BackpackError.invalid("Return to the foreground before changing phone artwork.") }
        let decoded = try GIFPreviewDecoder.phoneDisplay(bytes)
        try clock.reset()
        data = bytes; self.mediaID = mediaID; preview = decoded
        wantsPlayback = decoded.duration > 0 && !reducedMotion; motionOverride = false
        failure = nil; presented = true; updatePolicy(releaseDecoded: false)
    }
    func open() {
        failure = nil; presented = true
        updatePolicy()
    }
    func dismiss() {
        visible = false; presented = false
        updatePolicy()
    }
    func setVisible(_ value: Bool) { visible = value; updatePolicy() }
    func setForeground(_ value: Bool) { foreground = value; updatePolicy() }
    func setReducedMotion(_ value: Bool) {
        if value != reducedMotion && value { motionOverride = false }
        reducedMotion = value; updatePolicy()
    }
    func setKeepAwake(_ value: Bool) { keepAwake = value; updatePolicy() }
    func play() {
        guard animated else { return }
        do {
            if position().finished { try clock.reset() }
            wantsPlayback = true; motionOverride = reducedMotion
            updatePolicy()
        } catch { report(error) }
    }
    func pause() { wantsPlayback = false; motionOverride = false; updatePolicy() }
    func finishIfNeeded() { if position().finished { wantsPlayback = false; updatePolicy() } }
    func position() -> (index: Int, finished: Bool) {
        guard let preview, preview.duration > 0 else { return (0, false) }
        let elapsed = clock.elapsed()
        if let cycles = preview.cycles, elapsed >= preview.duration * Double(cycles) {
            return (preview.frames.count - 1, true)
        }
        return (preview.frameIndex(at: elapsed), false)
    }
    func snapshot() -> PhoneDisplaySnapshot {
        PhoneDisplaySnapshot(data: data, mediaID: mediaID, elapsed: clock.elapsed(), wantsPlayback: wantsPlayback,
            motionOverride: motionOverride, keepAwake: keepAwake)
    }
    func restore(_ value: PhoneDisplaySnapshot) throws {
        guard foreground else { throw BackpackError.invalid("Restore phone artwork only while the app is in the foreground.") }
        guard value.elapsed.isFinite, value.elapsed >= 0, value.data != nil || value.mediaID == nil else {
            throw BackpackError.invalid("Invalid local phone-display snapshot.")
        }
        guard value.data != nil || (value.elapsed == 0 && !value.wantsPlayback && !value.motionOverride) else {
            throw BackpackError.invalid("An empty phone display cannot have an active playhead.")
        }
        let decoded: GIFPreview?
        if let bytes = value.data { decoded = try GIFPreviewDecoder.phoneDisplay(bytes) }
        else { decoded = nil }
        try clock.reset(to: value.elapsed)
        data = value.data; mediaID = value.mediaID; preview = decoded
        wantsPlayback = value.wantsPlayback; motionOverride = value.motionOverride; keepAwake = value.keepAwake
        failure = nil; updatePolicy()
    }
    func report(_ error: Error) { failure = error.localizedDescription; presented = true; updatePolicy(releaseDecoded: false) }
    func clearFailure() { failure = nil }
    private func updatePolicy(releaseDecoded: Bool = true) {
        let active = presented && visible && foreground
        if active, preview == nil, let data {
            do { preview = try GIFPreviewDecoder.phoneDisplay(data) }
            catch { clock.pause(); isPlaying = false; failure = error.localizedDescription; idleLease.update(requested: false); return }
        }
        if position().finished { wantsPlayback = false }
        let running = active && animated && wantsPlayback && (!reducedMotion || motionOverride)
        if running { clock.start() } else { clock.pause() }
        isPlaying = running
        idleLease.update(requested: active && hasArtwork && keepAwake)
        if !active && releaseDecoded { preview = nil }
    }
}
