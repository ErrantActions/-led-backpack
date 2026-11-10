import SwiftUI

@MainActor
struct BackpackDirectSendView: View {
    let request: BackpackSendRequest
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var vault: CloudVaultStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = BackpackDirectSendStore()
    @State private var options = BackpackSendOptions()
    var body: some View {
        NavigationStack {
            Form {
                Section("\(request.sources.count) GIF(s)") {
                    Text("Uses empty slots only. Your originals stay unchanged.").font(.caption)
                    if request.usesVault {
                        Text("Private artwork is sent only to your backpack, not published.").font(.caption)
                    }
                    if !panel.link.connected { Text("Connect your backpack, then retry.").foregroundStyle(.orange) }
                    DisclosureGroup("Timing options") {
                    GIFTimingControls(timing: $options.timing).disabled(store.busy)
                    Picker("Play each GIF for", selection: $options.limit) {
                        Text("Time").tag(BackpackPresentationLimit.time)
                        Text("GIF loops").tag(BackpackPresentationLimit.loops)
                    }.disabled(store.busy)
                    if options.limit == .time { Stepper("\(options.programSeconds) seconds", value: $options.programSeconds, in: 1...600).disabled(store.busy) }
                    else {
                        Stepper("\(options.totalLoops) total loops per GIF", value: $options.totalLoops, in: 1...100).disabled(store.busy)
                        Text("Backpack loop timing is approximate.").font(.caption).foregroundStyle(.secondary)
                    }
                    }
                    if store.plan == nil {
                        Button("Review copies") { store.prepare(request, options: options, community: community, panel: panel, library: library, vault: vault) }
                            .buttonStyle(AuroraPrimaryButton())
                            .disabled(store.busy || !panel.link.connected || panel.hasDisplayOwner)
                            .accessibilityLabel("Prepare / update send copies")
                    }
                    if store.busy { ProgressView() }
                    FeatureDetails("Preparation details") { Text(store.status) }
                    if let failure = store.failure { Text(failure).foregroundStyle(.orange) }
                }
                if store.preview != nil {
                    DirectSendPreview(preview: store.preview).id(store.preview.map { ObjectIdentifier($0) })
                }
                ForEach(Array(store.warnings.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.orange) }
                if store.plan != nil && !store.playbackConfirmed {
                    Text("Send the reviewed copies to the empty slots shown above.").font(.caption)
                }
                if store.playbackConfirmed { Label("Backpack playback loop reported", systemImage: "checkmark.circle").foregroundStyle(.green) }
                if store.sending { Button("Stop transfer", role: .destructive) { store.stop() } }
                FeatureDetails("Playback & transfer limits") {
                    Text("Empty ordinary slots 2–54 only. Copies are fitted to your panel and played in an ordered loop; no occupied slot is overwritten.")
                    Text("Loop count is converted to approximate program time. Physical frame/repeat counting is not verified.")
                    Text("A failed transfer may leave its slot partly written. Inspect storage before retrying. Power/brightness are not forced.")
                }
            }.navigationTitle("Send & Play").buttonStyle(.borderless)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if store.plan != nil && !store.playbackConfirmed {
                            Button("Send & Play") { store.send(options: options, confirmed: true, community: community, panel: panel, vault: vault) }
                                .buttonStyle(AuroraPrimaryButton()).disabled(store.busy)
                                .accessibilityLabel("Send & Play on backpack")
                        }
                        Button(store.busy ? "Stop & close" : "Done") {
                            if store.busy { store.stop() }
                            dismiss()
                        }.frame(minHeight: 44).accessibilityIdentifier("backpack-send-done")
                    }.padding(.horizontal, 20).padding(.vertical, 8).background(Aurora.surface)
                }
                .interactiveDismissDisabled(store.sending)
                .task { store.prepare(request, options: options, community: community, panel: panel, library: library, vault: vault) }
                .onChange(of: options) { _, _ in store.invalidate() }
                .onChange(of: phase) { _, value in if value != .active { store.stop() } }
                .onChange(of: community.accountRevision) { _, _ in store.stop() }
                .onChange(of: community.avatarPolicyRevision) { _, _ in store.stop() }
                .onChange(of: panel.link.connected) { _, connected in if !connected { store.stop() } }
                .onChange(of: vault.syncing) { _, syncing in if request.usesVault && !syncing { store.stop() } }
                .onChange(of: vault.locked) { _, locked in if request.usesVault && locked { store.stop() } }
                .onChange(of: vault.state?.keyId) { _, _ in if request.usesVault { store.stop() } }
                .onChange(of: vault.state?.generation) { _, _ in if request.usesVault { store.stop() } }
                .onChange(of: vault.state?.mode) { _, _ in if request.usesVault { store.stop() } }
                .onChange(of: vault.state?.deleting) { _, deleting in if request.usesVault && deleting == true { store.stop() } }
                .onChange(of: vault.available) { _, available in if request.usesVault && !available { store.stop() } }
                .onDisappear { if store.busy { store.stop() } }
        }
    }
}
@MainActor
private struct DirectSendPreview: View {
    let preview: GIFPreview?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var phase
    @State private var playing = false
    @State private var clock = PhonePlaybackClock()
    @State private var failure: String?
    var body: some View {
        Group {
        if let preview {
            TimelineView(.animation(paused: !playing)) { _ in
                let elapsed = clock.elapsed(), finished = preview.duration > 0 && preview.cycles.map { elapsed >= preview.duration * Double($0) } == true
                Image(uiImage: preview.frames[finished ? preview.frames.count - 1 : preview.frameIndex(at: elapsed)])
                    .resizable().interpolation(.none).scaledToFit().frame(height: 160)
                    .onChange(of: finished) { _, done in if done { playing = false; clock.pause() } }
            }
            Button(playing ? "Pause first-GIF preview" : "Play first-GIF timing preview") {
                if playing { clock.pause(); playing = false }
                else {
                    do {
                        if preview.duration > 0, let cycles = preview.cycles, clock.elapsed() >= preview.duration * Double(cycles) { try clock.reset() }
                        clock.start(); playing = true
                    } catch { failure = error.localizedDescription }
                }
            }.disabled(reducedMotion || preview.duration == 0 || phase != .active)
            if let failure { Text(failure).foregroundStyle(.orange) }
        }
        }
        .onChange(of: phase) { _, value in if value != .active { playing = false; clock.pause() } }
        .onChange(of: reducedMotion) { _, value in if value { playing = false; clock.pause() } }
        .onDisappear { playing = false; clock.pause() }
    }
}
