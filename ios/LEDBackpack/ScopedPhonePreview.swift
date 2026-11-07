import SwiftUI
import Combine
import UIKit
import BackpackProtocol

enum NativeScopedPhoneSource {
    case playlist(NativePlaylistPreviewRequest)
    case event(NativeEventPlanPreview, sceneID: UUID)

    var id: String {
        switch self {
        case .playlist(let request): return request.id.uuidString
        case .event(let request, let scene): return "\(request.id):\(scene)"
        }
    }
    var accountID: UUID {
        switch self { case .playlist(let r): return r.accountID; case .event(let r, _): return r.accountID }
    }
    var accountEpoch: UUID {
        switch self { case .playlist(let r): return r.accountEpoch; case .event(let r, _): return r.accountEpoch }
    }
    var expired: Bool {
        switch self {
        case .playlist(let request): return request.expired
        case .event(let request, let scene):
            return request.clock.now() >= request.validUntil || !request.currentCues().contains { $0.id == scene }
        }
    }
    var remainingLease: Double {
        switch self {
        case .playlist(let request):
            let elapsed = request.requestStarted.duration(to: ContinuousClock().now).components
            return max(0, 30 - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
        case .event(let request, let scene):
            guard let cue = request.currentCues().first(where: { $0.id == scene }) else { return 0 }
            let anchor: Date
            if let raw = cue.startsAtISO, let date = try? CatalogEventTime.parse(raw) { anchor = date }
            else { anchor = request.clock.serverTime }
            return max(0, min(request.validUntil, anchor.addingTimeInterval(Double(cue.durationSeconds))).timeIntervalSince(request.clock.now()))
        }
    }
    var content: NativePublicPlaylistContent? {
        switch self {
        case .playlist(let r): return r.content
        case .event(let r, let id): return r.snapshot.plan.scenes.first { $0.id == id }?.playlist
        }
    }
    var scene: NativeDisplayScene? {
        guard case .event(let r, let id) = self else { return nil }
        return r.snapshot.plan.scenes.first { $0.id == id }
    }
    func eventElapsed() throws -> Double? {
        guard case .event(let request, let sceneID) = self else { return nil }
        guard let cue = request.currentCues().first(where: { $0.id == sceneID }) else {
            throw BackpackError.invalid("This server-clock cue is no longer active. No preview was renewed.")
        }
        let start = try cue.startsAtISO.map(CatalogEventTime.parse) ?? request.clock.serverTime
        return max(0, request.clock.now().timeIntervalSince(start))
    }
    @MainActor func check(_ client: CommunityFeatureClient) throws {
        try client.check()
        guard accountID == client.accountID, accountEpoch == client.revision, !expired,
              !client.referencePolicyChanging else {
            throw BackpackError.invalid("PHONE preview account, policy, cue or fixed 30-second lease changed.")
        }
    }
}

enum NativeScopedPhoneAlias {
    static func owner(playlistID: UUID, item: NativePlaylistItem, origin: CommunityOrigin) throws -> String {
        try path(item.gifUrl, origin: origin,
            expected: "/api/v1/playlists/\(playlistID.uuidString.lowercased())/items/\(item.id.uuidString.lowercased())/original.gif")
    }
    static func event(eventID: UUID, sceneID: UUID, item: NativePlaylistItem, origin: CommunityOrigin) throws -> String {
        try path(item.gifUrl, origin: origin,
            expected: "/api/v1/events/\(eventID.uuidString.lowercased())/display-plan/items/\(sceneID.uuidString.lowercased())/\(item.id.uuidString.lowercased())/original.gif")
    }
    private static func path(_ url: URL, origin: CommunityOrigin, expected: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (parts.scheme == nil && parts.host == nil && parts.user == nil && parts.password == nil) || origin.contains(url),
              parts.query == nil, parts.fragment == nil, parts.percentEncodedPath == expected else {
            throw BackpackError.invalid("The recorded GIF is not this exact authorized original-media alias.")
        }
        return String(expected.dropFirst("/api/v1/".count))
    }
}

struct NativePhonePlaylistTimeline {
    struct Position: Equatable {
        let index: Int
        let elapsed: Double
        let remaining: Double
    }
    let content: NativePublicPlaylistContent
    let indices: [Int]
    init(_ content: NativePublicPlaylistContent, shuffled: [Int]? = nil) throws {
        try content.validate()
        self.content = content
        if content.order == .shuffle {
            let permutation = shuffled ?? Array(content.entries.indices).shuffled()
            guard permutation.sorted() == Array(content.entries.indices) else { throw BackpackError.invalid("Invalid shuffle permutation.") }
            indices = permutation
        } else { indices = Array(content.entries.indices) }
    }
    var duration: Double { content.entries.reduce(0) { $0 + Double($1.durationMilliseconds) / 1000 } }
    func offset(of index: Int) -> Double? {
        var result = 0.0
        for occurrence in indices {
            if occurrence == index { return result }
            result += Double(content.entries[occurrence].durationMilliseconds) / 1000
        }
        return nil
    }
    func position(at elapsed: Double) -> Position? {
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        var cursor = elapsed
        for index in indices {
            let duration = Double(content.entries[index].durationMilliseconds) / 1000
            if cursor < duration { return .init(index: index, elapsed: cursor, remaining: duration - cursor) }
            cursor -= duration
        }
        return nil
    }
}

enum NativeGentlePhoneFrame {
    struct Frame: Equatable { let hex: String; let opacity: Double }
    static func frame(scene: NativeDisplayScene, elapsed: Double, animated: Bool) -> Frame {
        let colors = scene.colors.isEmpty ? ["#000000"] : scene.colors
        guard animated, elapsed.isFinite, elapsed >= 0 else { return .init(hex: colors[0], opacity: 1) }
        let period = Double(max(2000, scene.periodMilliseconds)) / 1000
        switch scene.pattern {
        case .solid: return .init(hex: colors[0], opacity: 1)
        case .alternate:
            return .init(hex: colors[Int((elapsed / period).truncatingRemainder(dividingBy: Double(colors.count)))], opacity: 1)
        case .gentlePulse:
            let phase = elapsed.truncatingRemainder(dividingBy: period) / period
            return .init(hex: colors[0], opacity: 0.55 + 0.45 * (1 - cos(2 * .pi * phase)) / 2)
        }
    }
    static func components(_ hex: String) -> (Double, Double, Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
    static func still(_ scene: NativeDisplayScene) throws -> Data {
        try GentlePlanPolicy.validate(colors: scene.colors, period: scene.periodMilliseconds)
        let c = components(scene.colors[0])
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BackpackError.invalid("Cannot prepare the isolated scene PHONE still.")
        }
        context.setFillColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage(), let bytes = UIImage(cgImage: image).pngData() else {
            throw BackpackError.invalid("Cannot prepare the isolated scene PHONE pixels.")
        }
        return bytes
    }
}
        struct NativeScopedPhoneOptions: Equatable {
            var animations = true
            var dataSaving = false
            var crisp = true
            var grid = false
            var keepAwake = false
            var brightnessEnabled = false
            var brightness = 0.5
        }

        @MainActor
        final class NativeScopedPhonePreview: ObservableObject {
            @Published private(set) var phone: PhoneDisplayController?
            @Published private(set) var loading = false
            @Published private(set) var playing = false
            @Published private(set) var failure: String?
            @Published private(set) var status = "Paused. No media loaded."
            @Published private(set) var itemTitle: String?
            @Published private(set) var options = NativeScopedPhoneOptions()
            private var source: NativeScopedPhoneSource?
            private var client: CommunityFeatureClient?
            private weak var community: CommunityController?
            private var policy: UUID?
            private var preferences: ViewerMediaPreferences?
            private var reducedMotion = false
            private var foreground = false
            private var visible = false
            private var timeline: NativePhonePlaylistTimeline?
            private var clock = PhonePlaybackClock()
            private var loadedIndex: Int?
            private var capturedPatternElapsed = 0.0
            private var generation = UUID()
            private var work: Task<Void, Never>?
            private var watchdog: Task<Void, Never>?
            private var authority: Task<Void, Never>?
            private var expiration: Task<Void, Never>?

            func bind(source: NativeScopedPhoneSource, client: CommunityFeatureClient, community: CommunityController,
                      reducedMotion: Bool, localOptions: NativeScopedPhoneOptions? = nil) {
                stop()
                self.source = source; self.client = client; self.community = community; self.reducedMotion = reducedMotion
                policy = client.referencePolicyRevision; preferences = community.user?.mediaPreferences
                foreground = true; visible = true; options = localOptions ?? .init(); failure = nil
                status = "Paused. Load or Play explicitly; no global selection is changed."
                do {
                    try check()
                    timeline = try source.content.map { try NativePhonePlaylistTimeline($0) }
                } catch { invalidate(error); return }
                let ticket = generation
                let remaining = source.remainingLease
                expiration = Task {
                    do {
                        try await Task.sleep(for: .seconds(remaining)); try Task.checkCancellation()
                        if self.generation == ticket { self.invalidate(BackpackError.invalid("Fixed PHONE source/cue lease expired. Pixels cleared; no renewal.")) }
                    } catch { }
                }
                watchdog = Task {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                            try self.check(ticket)
                        } catch {
                            if self.generation == ticket && !Task.isCancelled { self.invalidate(error) }
                            return
                        }
                    }
                }
                authority = Task {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(3))
                            try self.check(ticket)
                            if self.phone != nil && !self.loading {
                                _ = try await client.authorizeScopedPhone(source)
                                try self.check(ticket)
                            }
                        } catch {
                            if self.generation == ticket && !Task.isCancelled { self.invalidate(error) }
                            return
                        }
                    }
                }
            }
            func check(_ ticket: UUID? = nil) throws {
                try Task.checkCancellation()
                guard ticket == nil || generation == ticket,
                      foreground, visible, let client, let source, let community,
                      community.accountRevision == source.accountEpoch, community.user?.id == source.accountID,
                      community.origin == client.origin, community.user?.mediaPreferences == preferences,
                      policy == client.referencePolicyRevision, !client.referencePolicyChanging else {
                    throw BackpackError.invalid("PHONE preview visibility, account, media policy or intent changed. Pixels were cleared.")
                }
                try source.check(client)
            }
            func stop(message: String = "Stopped. Pixels cleared; no automatic resume.") {
                generation = UUID(); work?.cancel(); work = nil; watchdog?.cancel(); watchdog = nil; authority?.cancel(); authority = nil
                expiration?.cancel(); expiration = nil
                playing = false; loading = false; itemTitle = nil; loadedIndex = nil; capturedPatternElapsed = 0
                clock = PhonePlaybackClock(); status = message
                if let old = phone {
                    old.pause(); old.setVisible(false); old.dismiss(); old.setKeepAwake(false); old.setBrightnessEnabled(false)
                    phone = nil
                    // Clearing a dismissed, isolated controller cannot restore any global artwork.
                    Task {
                        old.setForeground(true)
                        do {
                            try await old.restore(PhoneDisplaySnapshot(data: nil, mediaID: nil, elapsed: 0,
                                wantsPlayback: false, motionOverride: false, keepAwake: false))
                        } catch { old.report(error) }
                        old.dismiss(); old.setForeground(false)
                    }
                }
            }
            func leave() { visible = false; foreground = false; stop(); source = nil; client = nil; community = nil; timeline = nil }
            func invalidate(_ error: Error) {
                stop(message: "Stopped and cleared. Reload/review explicitly; no retry or lease renewal.")
                failure = error.localizedDescription
            }
            func accessibilityChanged(_ value: Bool) {
                reducedMotion = value
                invalidate(BackpackError.invalid("Reduce Motion changed. PHONE pixels cleared; Play explicitly with the current policy."))
            }
            func setOptions(_ value: NativeScopedPhoneOptions) {
                let changesPlayback = value.animations != options.animations || value.dataSaving != options.dataSaving
                options = value
                if changesPlayback { stop(message: "Local playback policy changed; pixels cleared. Load/Play explicitly.") }
                else { applyOptions() }
            }
            private func applyOptions() {
                guard let phone else { return }
                phone.crispPixels = options.crisp; phone.pixelGrid = options.grid
                phone.setAnimationsEnabled(options.animations); phone.setDataSaving(options.dataSaving)
                phone.setKeepAwake(options.keepAwake); phone.setBrightness(options.brightness); phone.setBrightnessEnabled(options.brightnessEnabled)
                phone.setReducedMotion(reducedMotion)
                phone.setViewerAutomaticPlaybackAllowed(preferences?.permitsAnimation(reducedMotion: reducedMotion, manual: false) ?? !reducedMotion)
            }
            var automaticAllowed: Bool {
                options.animations && !options.dataSaving &&
                    (preferences?.permitsAnimation(reducedMotion: reducedMotion, manual: false) ?? !reducedMotion)
            }
            private func elapsed() throws -> Double {
                try source?.eventElapsed() ?? clock.elapsed()
            }
            func preparePaused(startingAt index: Int? = nil) { launch(play: false, startingAt: index) }
            func play(startingAt index: Int? = nil) { launch(play: true, startingAt: index) }
            private func launch(play: Bool, startingAt index: Int?) {
                guard !loading, let source, let client, let community else { return }
                let localOptions = options
                let capturedTimeline = timeline
                // Stop is terminal for a run, not a way to extend the captured source lease.
                stop(message: "Authorizing this same fixed source lease…")
                bind(source: source, client: client, community: community, reducedMotion: reducedMotion, localOptions: localOptions)
                guard failure == nil else { return }
                timeline = capturedTimeline
                let ticket = generation
                work = Task {
                    do {
                        try self.check(ticket)
                        if let index {
                            guard source.scene == nil, let offset = self.timeline?.offset(of: index) else {
                                throw BackpackError.invalid("Choose a named current owner-playlist occurrence; event cue ordering cannot be overridden.")
                            }
                            try self.clock.reset(to: offset)
                        }
                        let position = try self.timeline?.position(at: self.elapsed())
                        if self.timeline != nil && position == nil { throw BackpackError.invalid("The current scene playlist has finished; no catch-up/replay was inferred.") }
                        try await self.prepare(index: position?.index, ticket: ticket)
                        try self.check(ticket)
                        if play {
                            self.playing = true; self.phone?.play(); self.clock.start()
                            self.status = self.options.animations && !self.options.dataSaving ?
                                "Playing only this isolated PHONE preview; fixed lease, no frame-sync guarantee." :
                                "PHONE sequence running with a still presentation under local controls; no hardware playback."
                            try await self.run(ticket)
                        } else { self.status = "Loaded paused. Press Play deliberately; the original GIF/repeats are unchanged." }
                    } catch {
                        if self.generation == ticket && !Task.isCancelled { self.invalidate(error) }
                    }
                }
            }
        }
                    @MainActor
                    struct NativeScopedPhonePreviewView: View {
                        @EnvironmentObject private var community: CommunityController
                        @EnvironmentObject private var globalPhone: ScopedGlobalPhone
                        @Environment(\.scenePhase) private var phase
                        @Environment(\.accessibilityReduceMotion) private var reducedMotion
                        @StateObject private var runtime = NativeScopedPhonePreview()
                        @State private var startingEntry: Int?
                        let source: NativeScopedPhoneSource
                        let client: CommunityFeatureClient
                        var body: some View {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("ISOLATED PHONE PREVIEW", systemImage: "iphone")
                                ScopedGlobalPhoneConsent(source: source, client: client, beforeStart: { runtime.leave() })
                                Text("No global Phone/Backpack selection, original journal, hardware or library is changed. Foreground only; fixed 30-second source lease, never silently renewed. No physical sync, background execution or safety monitoring.").font(.caption)
                                Text(runtime.status).font(.caption)
                                if let failure = runtime.failure { Text(failure).foregroundStyle(.orange) }
                                if runtime.loading { ProgressView("Authorizing original / decoding local PHONE pixels") }
                                if let phone = runtime.phone, !runtime.loading {
                                    if let title = runtime.itemTitle { Text(title).font(.headline) }
                                    NativeScopedPhoneCanvas(phone: phone, playing: runtime.playing, gentle: runtime.gentleFrame,
                                        authorized: { (try? runtime.check()) != nil })
                                        .frame(height: 240).background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
                                }
                                if case .playlist(let request) = source {
                                    Picker("Explicit named starting occurrence (optional)", selection: $startingEntry) {
                                        Text("Use recorded order / captured shuffle").tag(Optional<Int>.none)
                                        ForEach(Array(request.hydratedEntries.enumerated()), id: \.offset) { index, entry in
                                            Text("\(index + 1). \(entry.item?.title ?? "Unavailable") / \(entry.durationMilliseconds)ms").tag(Optional(index))
                                        }
                                    }
                                }
                                HStack {
                                    Button("Load paused PHONE") { runtime.preparePaused(startingAt: startingEntry) }.disabled(runtime.loading || source.expired)
                                    Button("Play PHONE") { runtime.play(startingAt: startingEntry) }.disabled(runtime.loading || source.expired)
                                    Button("Stop / clear") { runtime.stop() }
                                }
                                Text("Explicit Play may override saved automatic-animation/Reduce Motion policy; local animation and data-saving controls still apply. Automatic next-GIF fetching requires the saved AND local automatic policy. GIF frames/repeats are not rewritten; source entry durations do not prove frame synchronization.").font(.caption)
                                DisclosureGroup("Local PHONE controls (not saved preferences)") {
                                    Toggle("Allow local animations", isOn: option(\.animations))
                                    Toggle("Local data saving / still", isOn: option(\.dataSaving))
                                    Toggle("Crisp nearest-neighbor pixels", isOn: option(\.crisp))
                                    Toggle("Pixel grid where legible", isOn: option(\.grid))
                                    Toggle("Explicit keep-awake opt-in", isOn: option(\.keepAwake))
                                    Toggle("Explicit brightness override opt-in", isOn: option(\.brightnessEnabled))
                                    if runtime.options.brightnessEnabled {
                                        Slider(value: option(\.brightness), in: 0.1...1)
                                    }
                                    Text("Awake/brightness leases are released on Stop, failure, expiry or exit. Saved viewer preferences are never modified.").font(.caption)
                                }
                            }
                            .task(id: "\(source.id):\(client.instanceID)") {
                                guard phase == .active else { runtime.leave(); return }
                                startingEntry = nil
                                runtime.bind(source: source, client: client, community: community, reducedMotion: reducedMotion)
                            }
                            .onChange(of: community.accountRevision) { _, _ in invalidatePolicy() }
                            .onReceive(globalPhone.willStart) { _ in runtime.leave() }
                            .onChange(of: community.avatarPolicyRevision) { _, _ in invalidatePolicy() }
                            .onChange(of: community.avatarPolicyChanging) { _, _ in invalidatePolicy() }
                            .onChange(of: community.user?.mediaPreferences) { _, _ in invalidatePolicy() }
                            .onChange(of: reducedMotion) { _, value in runtime.accessibilityChanged(value) }
                            .onChange(of: startingEntry) { _, _ in runtime.stop(message: "Starting occurrence changed. Pixels cleared; Load/Play explicitly.") }
                            .onChange(of: phase) { _, state in if state != .active { runtime.leave() } }
                            .onDisappear { runtime.leave() }
                        }
                        private func option<T>(_ key: WritableKeyPath<NativeScopedPhoneOptions, T>) -> Binding<T> {
                            Binding(get: { runtime.options[keyPath: key] }, set: {
                                var value = runtime.options; value[keyPath: key] = $0; runtime.setOptions(value)
                            })
                        }
                        private func invalidatePolicy() { runtime.invalidate(BackpackError.invalid("Viewer/account/accessibility policy changed. PHONE pixels cleared; reload the source explicitly.")) }
                    }

                    @MainActor
                    private struct NativeScopedPhoneCanvas: View {
                        @ObservedObject var phone: PhoneDisplayController
                        let playing: Bool
                        let gentle: @MainActor () -> NativeGentlePhoneFrame.Frame?
                        let authorized: @MainActor () -> Bool
                        var body: some View {
                            TimelineView(.animation(paused: !playing && !phone.isPlaying)) { _ in
                                if !authorized() { Color.black.accessibilityLabel("PHONE preview authorization expired or changed") }
                                else if let frame = gentle() {
                                    let components = NativeGentlePhoneFrame.components(frame.hex)
                                    Rectangle().fill(Color(red: components.0, green: components.1, blue: components.2).opacity(frame.opacity))
                                        .accessibilityLabel("Isolated gentle scene color; not synchronized hardware")
                                } else if let preview = phone.preview {
                                    let position = phone.position()
                                    if preview.frames.indices.contains(position.index) {
                                        let image = preview.frames[position.index]
                                        Image(uiImage: image).interpolation(phone.crispPixels ? .none : .high).resizable().scaledToFit()
                                            .overlay {
                                                if phone.pixelGrid {
                                                    GeometryReader { geometry in
                                                        let w = image.cgImage?.width ?? 0, h = image.cgImage?.height ?? 0
                                                        let scale = min(geometry.size.width / CGFloat(max(1, w)), geometry.size.height / CGFloat(max(1, h)))
                                                        if scale >= 6 && w + h <= 512 {
                                                            Canvas { context, canvas in
                                                                let x = (canvas.width - CGFloat(w) * scale) / 2, y = (canvas.height - CGFloat(h) * scale) / 2
                                                                var lines = Path()
                                                                for column in 0...w {
                                                                    lines.move(to: .init(x: x + CGFloat(column) * scale, y: y))
                                                                    lines.addLine(to: .init(x: x + CGFloat(column) * scale, y: y + CGFloat(h) * scale))
                                                                }
                                                                for row in 0...h {
                                                                    lines.move(to: .init(x: x, y: y + CGFloat(row) * scale))
                                                                    lines.addLine(to: .init(x: x + CGFloat(w) * scale, y: y + CGFloat(row) * scale))
                                                                }
                                                                context.stroke(lines, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                                                            }.accessibilityHidden(true)
                                                        }
                                                    }
                                                }
                                            }
                                            .onChange(of: position.finished) { _, finished in if finished { phone.finishIfNeeded() } }
                                            .accessibilityLabel("Isolated authorized PHONE original GIF")
                                    }
                                }
                            }
                        }
                    }

        @MainActor
        extension NativeScopedPhonePreview {
            private func prepare(index: Int?, ticket: UUID) async throws {
                try check(ticket)
                guard let source, let client else { throw CancellationError() }
                loading = true; playing = false; clock.pause()
                let phone: PhoneDisplayController
                if let existing = self.phone { phone = existing }
                else { phone = PhoneDisplayController(); self.phone = phone }
                phone.pause(); phone.setVisible(false); phone.setForeground(true)
                try await phone.restore(PhoneDisplaySnapshot(data: nil, mediaID: nil, elapsed: 0,
                    wantsPlayback: false, motionOverride: false, keepAwake: false))
                try check(ticket)
                let bytes: Data
                if let index {
                    bytes = try await client.scopedPhoneOriginal(source, index: index)
                } else {
                    _ = try await client.authorizeScopedPhone(source)
                    guard let scene = source.scene else { throw BackpackError.invalid("No current scene or public playlist is selected.") }
                    let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try NativeGentlePhoneFrame.still(scene) }
                    bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
                try check(ticket)
                // show() decodes off-main and starts paused. Do not expose decoded pixels before the post-decode authorization.
                try await phone.show(bytes)
                try check(ticket)
                let current = try await client.authorizeScopedPhone(source)
                try check(ticket)
                if let index {
                    guard current.indices.contains(index), let item = current[index].item else { throw BackpackError.invalid("Current original membership disappeared.") }
                    if source.scene != nil, try timeline?.position(at: elapsed())?.index != index {
                        throw BackpackError.invalid("The cue moved to another entry during I/O. Reload/Play explicitly; late GIF bytes were discarded.")
                    }
                    itemTitle = item.title
                } else { itemTitle = source.scene?.name }
                loadedIndex = index; capturedPatternElapsed = try elapsed()
                applyOptions(); phone.open(); phone.setVisible(true); loading = false
            }
            private func run(_ ticket: UUID) async throws {
                while true {
                    try await Task.sleep(for: .milliseconds(100)); try check(ticket)
                    phone?.finishIfNeeded()
                    if let timeline {
                        guard let position = timeline.position(at: try elapsed()) else {
                            stop(message: "Preview sequence finished once; pixels cleared. No loop/background playback was inferred."); return
                        }
                        if position.index != loadedIndex {
                            guard automaticAllowed else {
                                stop(message: "Automatic next-GIF loading is blocked by saved/local viewer policy. Pixels cleared; a new explicit Play is required."); return
                            }
                            try await prepare(index: position.index, ticket: ticket)
                            try check(ticket); playing = true; phone?.play(); clock.start()
                        }
                    }
                }
            }
            func gentleFrame() -> NativeGentlePhoneFrame.Frame? {
                guard let scene = source?.scene, scene.playlist == nil, phone?.hasArtwork == true, !loading else { return nil }
                let time = playing ? ((try? elapsed()) ?? capturedPatternElapsed) : capturedPatternElapsed
                return NativeGentlePhoneFrame.frame(scene: scene, elapsed: time,
                    animated: playing && options.animations && !options.dataSaving)
            }
        }

@MainActor
extension CommunityFeatureClient {
    func authorizeScopedPhone(_ source: NativeScopedPhoneSource) async throws -> [NativeHydratedPlaylistEntry] {
        try source.check(self)
        let policy = referencePolicyRevision
        let entries: [NativeHydratedPlaylistEntry]
        switch source {
        case .playlist(let request):
            let value = try await ownerPlaylist(request.playlistID)
            guard value.revision == request.revision, value.content.publicReferences == request.content,
                  value.hydratedEntries.allSatisfy(\.available) else {
                throw BackpackError.invalid("Private playlist revision or current public artwork changed. Stop and reload explicitly.")
            }
            entries = value.hydratedEntries
        case .event(let request, let sceneID):
            let event = try await currentSocialEvent(request.context, surface: .display)
            let value = try await eventDisplayPlan(event, checkpointID: request.manualCheckpointID)
            try value.plan.validate(event: event)
            guard value.revision == request.planRevision, value.optinRevision == request.optinRevision,
                  value.ownEnabled, value.plan.enabled, value.plan == request.snapshot.plan,
                  value.cues.contains(where: { $0.id == sceneID }), event.moderation?.held != true else {
                throw BackpackError.invalid("Event scene, reviewed participation or current own plan consent changed.")
            }
            if request.snapshot.plan.scenes.first(where: { $0.id == sceneID })?.playlist != nil {
                guard let list = value.scenePlaylists.first(where: { $0.sceneId == sceneID }),
                      list.entries.allSatisfy(\.available) else { throw BackpackError.invalid("Current scene artwork is unavailable.") }
                entries = list.entries
            } else {
                guard value.plan.scenes.contains(where: { $0.id == sceneID }) else { throw BackpackError.invalid("Scene unavailable.") }
                entries = []
            }
        }
        try source.check(self)
        guard referencePolicyRevision == policy else { throw BackpackError.invalid("Viewer/media policy changed during authorization.") }
        return entries
    }
    func scopedPhoneOriginal(_ source: NativeScopedPhoneSource, index: Int) async throws -> Data {
        let policy = referencePolicyRevision
        let before = try await authorizeScopedPhone(source)
        guard before.indices.contains(index), before[index].available, let item = before[index].item else {
            throw BackpackError.invalid("Select a currently authorized recorded public original.")
        }
        let feature: CommunityFeature, path: String
        switch source {
        case .playlist(let request):
            feature = .playlists; path = try NativeScopedPhoneAlias.owner(playlistID: request.playlistID, item: item, origin: origin)
        case .event(let request, let sceneID):
            feature = .events; path = try NativeScopedPhoneAlias.event(eventID: request.context.eventID, sceneID: sceneID, item: item, origin: origin)
        }
        let bytes = try await send(feature, path, maxBytes: 5_000_000)
        try Task.checkCancellation(); try source.check(self)
        guard referencePolicyRevision == policy else { throw BackpackError.invalid("Discarding bytes returned under an older media policy.") }
        let after = try await authorizeScopedPhone(source)
        guard referencePolicyRevision == policy, after.indices.contains(index), after[index].available,
              after[index].item?.id == item.id, after[index].item?.gifUrl == item.gifUrl,
              after[index].durationMilliseconds == before[index].durationMilliseconds,
              !bytes.isEmpty, bytes.count <= 5_000_000 else {
            throw BackpackError.invalid("Discarding original GIF bytes after access, revision, policy or membership changed.")
        }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard GIFStructure.isGIF(bytes) else { throw BackpackError.invalid("The recorded original is not a GIF.") }
            _ = try GIFStructure.inspect(bytes)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); try source.check(self)
        guard referencePolicyRevision == policy else { throw BackpackError.invalid("Policy changed while inspecting GIF bytes.") }
        return bytes
    }
}
