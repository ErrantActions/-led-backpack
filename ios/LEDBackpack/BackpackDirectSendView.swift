import SwiftUI

@MainActor
struct BackpackDirectSendView: View {
    let request: BackpackSendRequest
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = BackpackDirectSendStore()
    @State private var options = BackpackSendOptions()
    var body: some View {
        NavigationStack {
            Form {
                Section("Send & Play \(request.sources.count) GIF(s)") {
                    Text("No mandatory library save or slot-number form. We choose only empty ordinary slots2–54, fit separate copies to the panel and start their ordered loop—even for one GIF. Sources remain unchanged.").font(.caption)
                    if !panel.link.connected { Text("Connect from the Backpack tab, then retry. This screen does not scan or connect automatically.").foregroundStyle(.orange) }
                    GIFTimingControls(timing: $options.timing).disabled(store.busy)
                    Picker("Switch to next GIF after", selection: $options.limit) {
                        Text("Time").tag(BackpackPresentationLimit.time)
                        Text("GIF loops").tag(BackpackPresentationLimit.loops)
                    }.disabled(store.busy)
                    if options.limit == .time { Stepper("Time on screen \(options.programSeconds)s per GIF", value: $options.programSeconds, in: 1...600).disabled(store.busy) }
                    else {
                        Stepper("\(options.totalLoops) total loops per GIF", value: $options.totalLoops, in: 1...100).disabled(store.busy)
                        Text("Loop count is encoded in the send copy; program time is derived from its frame timing and rounded up to whole seconds. Device repeat handling/counting is not verified.").font(.caption)
                    }
                    Button("Prepare / update send copies") { store.prepare(request, options: options, community: community, panel: panel, library: library) }
                        .disabled(store.busy || !panel.link.connected || panel.hasDisplayOwner)
                    if store.busy { ProgressView() }
                    Text(store.status).font(.caption)
                    if let failure = store.failure { Text(failure).foregroundStyle(.orange) }
                }
                if store.preview != nil {
                    DirectSendPreview(preview: store.preview).id(store.preview.map { ObjectIdentifier($0) })
                }
                ForEach(Array(store.warnings.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.orange) }
                if store.plan != nil && !store.playbackConfirmed {
                    Button("Send & Play on backpack") { store.send(options: options, confirmed: true, community: community, panel: panel) }
                        .buttonStyle(.borderedProminent).disabled(store.busy)
                    Text("This button approves the displayed empty destinations and prepared timing. No occupied-slot overwrite is permitted.").font(.caption)
                }
                if store.playbackConfirmed { Label("Backpack playback loop reported", systemImage: "checkmark.circle").foregroundStyle(.green) }
                if store.sending { Button("Stop remaining transfer", role: .destructive) { store.stop() } }
                Text("GIF programs repeat in an ordered loop, not an exactly counted physical-frame receipt. No forced power/maximum brightness. A failed transfer may leave its current slot partially written; inspect storage before retrying. Use the advanced Send queue only when you intentionally want to overwrite occupied slots.").font(.caption)
            }.navigationTitle("Send & Play")
                .toolbar { Button("Done") { if store.sending { store.stop() }; dismiss() } }
                .interactiveDismissDisabled(store.sending)
                .task { store.prepare(request, options: options, community: community, panel: panel, library: library) }
                .onChange(of: options) { _, _ in store.invalidate() }
                .onChange(of: phase) { _, value in if value != .active { store.stop() } }
                .onChange(of: community.accountRevision) { _, _ in store.stop() }
                .onChange(of: community.avatarPolicyRevision) { _, _ in store.stop() }
                .onChange(of: panel.link.connected) { _, connected in if !connected { store.stop() } }
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
