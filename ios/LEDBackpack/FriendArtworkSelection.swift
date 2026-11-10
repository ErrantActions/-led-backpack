import SwiftUI
import UniformTypeIdentifiers
import BackpackProtocol

struct FriendArtworkChoice {
    let id: UUID
    let name: String
    let data: Data
    let attribution: Attribution?
}

@MainActor
final class FriendArtworkSelection: ObservableObject {
    @Published private(set) var choice: FriendArtworkChoice?
    @Published private(set) var preview: GIFPreview?
    @Published private(set) var reading = false
    @Published private(set) var playing = false
    @Published private(set) var failure: String?
    private var generation = UUID()
    private var worker: Task<GIFPreview, Error>?
    private var clock = PhonePlaybackClock()

    @discardableResult
    func select(name: String, attribution: Attribution?, requiresOutgoingGIF: Bool,
        read: @MainActor () async throws -> Data, context: @MainActor () throws -> Void) async -> Bool {
        cancelPending()
        let stamp = generation
        reading = true; failure = nil; pause()
        defer { if stamp == generation { reading = false; worker = nil } }
        do {
            try context()
            if requiresOutgoingGIF { _ = try PhoneSwapWire.Credit(attribution) }
            let bytes = try await read()
            try Task.checkCancellation(); try context()
            guard stamp == generation else { throw CancellationError() }
            let decode = Task.detached {
                if requiresOutgoingGIF { _ = try PrivateOutgoingGIF.inspectAlreadySanitized(PrivateOutgoingGIF.make(bytes)) }
                return try GIFPreviewDecoder.phoneDisplay(bytes)
            }
            worker = decode
            let decoded = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
            try Task.checkCancellation(); try context()
            guard stamp == generation else { throw CancellationError() }
            try clock.reset()
            choice = FriendArtworkChoice(id: UUID(), name: String(name.prefix(120)), data: bytes, attribution: attribution)
            preview = decoded; worker = nil
            return true
        } catch {
            if stamp == generation, !(error is CancellationError) { failure = error.localizedDescription }
            return false
        }
    }

    func previewPreset(kind: FriendInteractionKind, preset: FriendScenePreset, sender: Bool,
        context: @escaping @MainActor () throws -> Void) async {
        cancelPending()
        let stamp = generation
        reading = true; failure = nil; pause()
        defer { if stamp == generation { reading = false; worker = nil } }
        do {
            guard kind == .palette || kind == .duet else { throw BackpackError.invalid("Choose a local greeting/pass artwork to preview.") }
            try context()
            let render = Task.detached {
                let bytes = try FriendInteractionPixels.render(kind: kind, preset: preset, sender: sender, chosen: Data(), received: nil)
                return try GIFPreviewDecoder.phoneDisplay(bytes)
            }
            worker = render
            let decoded = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
            try Task.checkCancellation(); try context()
            guard stamp == generation else { throw CancellationError() }
            try clock.reset()
            preview = decoded; worker = nil
        } catch {
            if stamp == generation, !(error is CancellationError) { failure = error.localizedDescription }
        }
    }

    func cancelPending() { generation = UUID(); worker?.cancel(); worker = nil; reading = false; pause() }
    func clear() { cancelPending(); choice = nil; preview = nil; failure = nil }
    func pause() { clock.pause(); playing = false }
    func play(allowed: Bool) {
        guard allowed, !reading, let preview, preview.duration > 0 else { pause(); return }
        do {
            if position(at: clock.elapsed()).finished { try clock.reset() }
            clock.start(); playing = true
        } catch { failure = error.localizedDescription; pause() }
    }
    func position(at elapsed: Double? = nil) -> (index: Int, finished: Bool) {
        guard let preview else { return (0, false) }
        let time = elapsed ?? clock.elapsed()
        if preview.duration > 0, let cycles = preview.cycles, time >= preview.duration * Double(cycles) {
            return (preview.frames.count - 1, true)
        }
        return (preview.frameIndex(at: time), false)
    }
}

@MainActor
struct FriendArtworkPreview: View {
    @ObservedObject var selection: FriendArtworkSelection
    @EnvironmentObject private var phone: PhoneDisplayController
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = selection.preview {
                TimelineView(.animation(paused: !selection.playing)) { _ in
                    let position = selection.position()
                    Image(uiImage: preview.frames[position.index]).resizable().interpolation(.none).scaledToFit()
                        .frame(maxWidth: .infinity).frame(height: 180).background(.black)
                        .accessibilityLabel("Isolated local friend artwork preview")
                        .onChange(of: position.finished) { _, finished in if finished { selection.pause() } }
                }
                Button(selection.playing ? "Pause LOCAL preview" : "Play LOCAL preview") {
                    if selection.playing { selection.pause() } else { selection.play(allowed: motionAllowed) }
                }.disabled(preview.duration == 0 || !motionAllowed || selection.reading)
            }
            if selection.reading { ProgressView("Reading / validating local media") }
            if let error = selection.failure { Text(error).font(.caption).foregroundStyle(.orange) }
            InteractionExplanation("Paused local preview only. No device operation, screen lease, service request or verified friend interaction.", details: "Isolated, paused by default; no display target, phone selection, screen lease, service request or Bluetooth operation. Timing/repeats are the source's; preview is not a verified friend interaction.").font(.caption)
        }
        .onChange(of: phase) { _, value in if value != .active { selection.cancelPending() } }
        .onChange(of: reducedMotion) { _, _ in selection.pause() }
        .onChange(of: phone.animationsEnabled) { _, _ in selection.pause() }
        .onChange(of: phone.dataSaving) { _, _ in selection.pause() }
        .onChange(of: phone.viewerAutomaticPlaybackAllowed) { _, _ in selection.pause() }
        .onChange(of: phone.presented) { _, presented in if presented { selection.pause() } }
        .onDisappear { selection.pause() }
    }
    private var motionAllowed: Bool { phase == .active && !reducedMotion && phone.animationsEnabled && !phone.dataSaving }
}

@MainActor
struct FriendArtworkPicker: View {
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var selection: FriendArtworkSelection
    let requiresOutgoingGIF: Bool
    let context: @MainActor () throws -> Void
    @State private var importing = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            List {
                Text(requiresOutgoingGIF ? "Select one GIF ≤128 KiB to share. Original bytes remain unchanged; only the separate outgoing copy is sanitized." :
                    "Select a local greeting still/GIF. These bytes are not sent to your friend.").font(.caption)
                if let failure = selection.failure { Text(failure).foregroundStyle(.orange) }
                if selection.reading { ProgressView() }
                Button("Choose an explicit local file (no library upload)") { importing = true }
                Section("Phone originals") {
                    ForEach(originals.items) { item in
                        Button {
                            choose(name: item.name, attribution: item.attribution) { try await originals.bytes(item) }
                        } label: {
                            GIFThumbnail(key: "friend-original:\(item.id)", cache: false) { try await originals.bytes(item) }
                                .frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityLabel("Choose \(item.name)")
                    }
                }
                Section("Existing local GIFs — first 100") {
                    ForEach(Array(library.state.media.prefix(100))) { item in
                        Button {
                            chooseLocalArtwork(item)
                        } label: {
                            GIFThumbnail(key: item.previewKey) { try library.data(item) }
                                .frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityLabel("Choose \(item.name)")
                    }
                }
                Text("For another saved artwork use the explicit file chooser. Nothing scans cloud, publishes, writes a backpack slot or changes your currently displayed artwork.").font(.caption)
            }.navigationTitle("Choose friend artwork")
                .toolbar { Button("Cancel") { task?.cancel(); selection.cancelPending(); dismiss() } }
                .task { await originals.load() }
                .fileImporter(isPresented: $importing, allowedContentTypes: requiresOutgoingGIF ? [.gif] : [.gif, .png, .jpeg, .webP]) { result in
                    choose(name: "Chosen local file", attribution: nil) {
                        let url = try result.get()
                        return try await Task.detached { try PhoneDisplayFileReader.read(url) }.value
                    }
                }
                .onDisappear { task?.cancel(); selection.cancelPending() }
        }
    }
    private func chooseLocalArtwork(_ item: SavedMedia) {
        choose(name: item.name, attribution: item.attribution) {
            let url = try library.phoneOriginalURL(item)
            return try await Task.detached { try PhoneDisplayFileReader.read(url) }.value
        }
    }

    private func choose(name: String, attribution: Attribution?, read: @escaping @MainActor () async throws -> Data) {
        task?.cancel()
        task = Task {
            let changed = await selection.select(name: name, attribution: attribution, requiresOutgoingGIF: requiresOutgoingGIF,
                read: read, context: context)
            if changed { dismiss() }
        }
    }
}
