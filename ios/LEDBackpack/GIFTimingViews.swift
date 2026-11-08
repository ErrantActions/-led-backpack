import SwiftUI
import BackpackProtocol

enum GIFRepeatChoice: String, CaseIterable, Identifiable {
    case source, continuous, count
    var id: String { rawValue }
}
struct GIFTimingControls: View {
    @Binding var timing: GIFTimingAdjustment
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speed · \(timing.speed, specifier: "%.2f")×")
                Spacer()
                Button { timing.speed = 1; timing.uniformCentiseconds = nil } label: {
                    Text("Reset").frame(minHeight: 44)
                }.buttonStyle(.borderless)
            }
            Slider(value: $timing.speed, in: 0.25...4, step: 0.05)
            HStack {
                ForEach([0.25,0.5,1.0,2.0,4.0], id: \.self) { value in
                    Button { timing.speed = value } label: {
                        Text("\(value, specifier: "%g")×").frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.borderless)
                }
            }
            DisclosureGroup("Advanced frame timing") {
                Toggle("Use one frame delay", isOn: Binding(get: { timing.uniformCentiseconds != nil },
                    set: { timing.uniformCentiseconds = $0 ? 10 : nil }))
                if timing.uniformCentiseconds != nil {
                    Slider(value: Binding(get: { Double(timing.uniformCentiseconds ?? 10) / 100 },
                        set: { timing.uniformCentiseconds = Int(($0 * 100).rounded()) }), in: 0.02...2, step: 0.01)
                    Text("Base frame delay \(Double(timing.uniformCentiseconds ?? 10) / 100, specifier: "%.2f")s").font(.caption)
                }
                Text("Speed changes frames, not playlist duration. Only the new copy changes.").font(.caption)
            }.buttonStyle(.borderless)
        }
    }
}
@MainActor
struct GIFTimingEditorView: View {
    let item: SavedMedia
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var timing = GIFTimingAdjustment()
    @State private var limit = GIFRepeatChoice.source
    @State private var loops = 3
    @State private var bytes: Data?
    @State private var preview: GIFPreview?
    @State private var name = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var playing = false
    @State private var clock = PhonePlaybackClock()
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            Form {
                GIFTimingControls(timing: $timing)
                Picker("Repeat", selection: $limit) {
                    Text("Original").tag(GIFRepeatChoice.source)
                    Text("Forever").tag(GIFRepeatChoice.continuous)
                    Text("Loop count").tag(GIFRepeatChoice.count)
                }
                if limit == .count { Stepper("\(loops) total loops", value: $loops, in: 1...100) }
                if let preview {
                    TimelineView(.animation(paused: !playing)) { _ in
                        let t = clock.elapsed(), finished = preview.duration > 0 && preview.cycles.map { t >= preview.duration * Double($0) } == true
                        Image(uiImage: preview.frames[finished ? preview.frames.count - 1 : preview.frameIndex(at: t)])
                            .resizable().interpolation(.none).scaledToFit().frame(height: 180)
                            .onChange(of: finished) { _, value in if value { pause() } }
                    }
                    Button(playing ? "Pause preview" : "Play preview") {
                        if playing { pause() }
                        else {
                            do {
                                if preview.duration > 0, let cycles = preview.cycles, clock.elapsed() >= preview.duration * Double(cycles) { try clock.reset() }
                                clock.start(); playing = true
                            } catch { failure = error.localizedDescription }
                        }
                    }
                        .disabled(reducedMotion || preview.duration == 0 || busy)
                }
                if bytes == nil {
                    Button("Review changes") { update() }.disabled(busy).buttonStyle(AuroraPrimaryButton())
                }
                TextField("New copy name", text: $name)
                if bytes != nil {
                    Button("Save copy") {
                        do {
                            guard let bytes else { throw BackpackError.invalid("Update the current timing preview before saving.") }
                            try library.add(name: name, data: bytes, attribution: item.attribution, category: item.category)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.disabled(busy || bytes == nil).buttonStyle(AuroraPrimaryButton())
                }
                if busy { ProgressView() }
                if let failure { Text(failure).foregroundStyle(.orange) }
                FeatureDetails("Timing details") {
                    Text("Your original is unchanged. This saves a new local copy without uploading or changing backpack playback.")
                    Text("Backpack repeat counting may differ. For individual frame delays, use GIF Studio's Timing tools.")
                }
            }.navigationTitle("GIF timing")
                .toolbar { Button("Done") { work?.cancel(); dismiss() } }
                .onAppear { name = item.name + " timed copy"; update() }
                .onChange(of: timing) { _, _ in invalidate() }
                .onChange(of: limit) { _, _ in invalidate() }
                .onChange(of: loops) { _, _ in invalidate() }
                .onChange(of: phase) { _, value in if value != .active { invalidate() } }
                .onChange(of: reducedMotion) { _, _ in pause() }
                .onDisappear { work?.cancel(); pause() }
        }
    }
    private func pause() { playing = false; clock.pause() }
    private func invalidate() { generation = UUID(); work?.cancel(); work = nil; busy = false; bytes = nil; preview = nil; pause() }
    private func update() {
        invalidate(); let stamp = generation, options = timing, repeatChoice = limit, total = loops
        busy = true; failure = nil
        work = Task {
            defer { if generation == stamp { busy = false } }
            do {
                let url = try library.phoneOriginalURL(item)
                let worker = Task.detached {
                    let original = try PhoneDisplayFileReader.read(url)
                    let timed = try options.applying(to: original)
                    let copy: Data
                    switch repeatChoice {
                    case .source: copy = timed
                    case .continuous: copy = try GIFTimingAdjustment.repeatingCopy(timed, totalLoops: nil)
                    case .count: copy = try GIFTimingAdjustment.repeatingCopy(timed, totalLoops: total)
                    }
                    return (copy, try GIFPreviewDecoder.thumbnail(copy))
                }
                let (copy,image) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard generation == stamp, phase == .active, library.state.media.contains(where: { $0.id == item.id }) else { throw CancellationError() }
                try clock.reset(); bytes = copy; preview = image
            } catch { if generation == stamp && !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
