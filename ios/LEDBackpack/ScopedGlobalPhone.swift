import SwiftUI
import UIKit
import Combine
import BackpackProtocol

@MainActor
final class ScopedGlobalPhone: ObservableObject {
    @Published private(set) var status = "Scoped global PHONE off"
    @Published private(set) var failure: String?
    @Published private(set) var arming = false
    let session = AutomaticPhoneSession()
    let willStart = PassthroughSubject<Void, Never>()
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private weak var community: CommunityController?
    private var source: NativeScopedPhoneSource?
    func bind(phone: PhoneDisplayController, targets: DisplayTargetSelection, community: CommunityController) {
        session.bind(phone: phone, targets: targets); self.community = community
    }
    func start(_ source: NativeScopedPhoneSource, client: CommunityFeatureClient, consent: Bool) {
        guard consent, !arming, !session.running, !session.busy, let community else { failure = "Explicit source-bound PHONE consent and free target required."; return }
        willStart.send(())
        let stamp = UUID(); epoch = stamp; self.source = source; failure = nil
        let policy = client.referencePolicyRevision, preferences = community.user?.mediaPreferences
        arming = true
        task = Task {
            defer { if self.epoch == stamp { self.arming = false } }
            do {
                try source.check(client)
                _ = try await client.authorizeScopedPhone(source)
                let id: UUID
                switch source { case .playlist(let r): id = r.playlistID; case .event(let r, _): id = r.context.eventID }
                let scope = SwapRecoveryStore.ownerScope(community)
                try await session.begin(id: id, scope: scope, currentScope: { [weak community] in
                    guard let community else { return "unavailable-account" }
                    return SwapRecoveryStore.ownerScope(community)
                }, authorize: {
                    try source.check(client)
                    guard self.epoch == stamp, client.referencePolicyRevision == policy,
                          community.user?.mediaPreferences == preferences else { throw CancellationError() }
                })
                let timeline = try source.content.map { try NativePhonePlaylistTimeline($0) }
                var elapsed = PhonePlaybackClock(); elapsed.start()
                var occurrence: Int?
                var lastAuthorization = ContinuousClock().now
                var gentlePhase: Int?
                while true {
                    try Task.checkCancellation(); try source.check(client); try session.check()
                    guard self.epoch == stamp else { throw CancellationError() }
                    let t = try source.eventElapsed() ?? elapsed.elapsed()
                    if let timeline {
                        guard let position = timeline.position(at: t) else { stop("Scoped playlist completed once; original retained for explicit restore"); return }
                        if occurrence != position.index {
                            guard occurrence == nil || community.user?.mediaPreferences?.permitsAnimation(reducedMotion: UIAccessibility.isReduceMotionEnabled, manual: false) != false else {
                                throw BackpackError.invalid("Automatic next-entry loading is blocked by saved viewer policy. Explicit rearm required.")
                            }
                            if source.scene == nil { elapsed.pause() }
                            let bytes = try await client.scopedPhoneOriginal(source, index: position.index)
                            try await session.apply(bytes, title: "Current scoped playlist on PHONE — no physical sync claim") {
                                _ = try await client.authorizeScopedPhone(source)
                                if source.scene != nil {
                                    guard let time = try source.eventElapsed(), timeline.position(at: time)?.index == position.index else {
                                        throw BackpackError.invalid("Event cue moved to another entry during loading; stale entry discarded.")
                                    }
                                }
                            }
                            if source.scene == nil { elapsed.start() }
                            occurrence = position.index
                        }
                    } else if let scene = source.scene {
                        let allowsMotion = community.user?.mediaPreferences?.permitsAnimation(reducedMotion: UIAccessibility.isReduceMotionEnabled, manual: false) ?? !UIAccessibility.isReduceMotionEnabled
                        if gentlePhase == nil {
                            let initialElapsed = t
                            let worker = Task.detached {
                                let period = Double(max(2000, scene.periodMilliseconds)) / 1000
                                let count = !allowsMotion || scene.pattern == .solid ? 1 : (scene.pattern == .alternate ? scene.colors.count : 32)
                                let delay = scene.pattern == .alternate ? period : period / Double(count)
                                let frames = (0..<count).map { index -> PixelFrame in
                                    let frame = NativeGentlePhoneFrame.frame(scene: scene,
                                        elapsed: initialElapsed + Double(index) * delay, animated: allowsMotion)
                                    let c = NativeGentlePhoneFrame.components(frame.hex)
                                    let color = [c.0,c.1,c.2].map { UInt8(($0 * frame.opacity * 255).rounded()) }
                                    return PixelFrame(size: PanelSize(width: 16, height: 16), rgb: Array(repeating: color, count: 256).flatMap { $0 })
                                }
                                return try MediaCodec.encode(frames, delays: Array(repeating: delay, count: count), loopCount: 0)
                            }
                            let bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                            try await session.apply(bytes, title: "Gentle current event scene on PHONE — foreground only") {
                                _ = try await client.authorizeScopedPhone(source)
                            }
                            gentlePhase = 0
                        }
                    } else { throw BackpackError.invalid("No current scoped playlist/event scene is available.") }
                    if lastAuthorization.duration(to: ContinuousClock().now) >= .seconds(3) {
                        _ = try await client.authorizeScopedPhone(source); lastAuthorization = ContinuousClock().now
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                if self.epoch == stamp { session.fail(error); self.failure = error.localizedDescription; self.status = "Scoped PHONE stopped; explicit recovery retained" }
            }
        }
        status = "Preparing current source and first-original PHONE recovery"
    }
    func stop(_ message: String = "Scoped PHONE stopped — no automatic restart") {
        epoch = UUID(); arming = false; task?.cancel(); task = nil; source = nil; session.stop(message); status = message
    }
    func restore() async { stop(); await session.restore() }
}

@MainActor
struct ScopedGlobalPhoneConsent: View {
    let source: NativeScopedPhoneSource
    let client: CommunityFeatureClient
    var beforeStart: @MainActor () -> Void = {}
    @EnvironmentObject private var global: ScopedGlobalPhone
    @State private var consent = false
    var body: some View {
        VStack(alignment: .leading) {
            Toggle("I explicitly replace the main PHONE display with this current scoped source", isOn: $consent)
            Text("Distinct from isolated preview. Durable initial original and exclusive PHONE ownership required. Runs only until this fixed source/cue lease ends (at most30 seconds); longer playlists require a new explicit source request. No hidden renewal, hardware playback, background execution or guaranteed sync.").font(.caption)
            Button("Play on main PHONE / preserve my original") { beforeStart(); global.start(source, client: client, consent: consent); consent = false }
                .disabled(!consent || source.expired || global.arming || global.session.running || global.session.busy)
            Text(global.status).font(.caption)
            if let error = global.failure { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("Stop global scoped playback") { global.stop() }
            Button("Stop / restore my initial original") { Task { await global.restore() } }
        }.onChange(of: source.id) { _, _ in consent = false }
    }
}
