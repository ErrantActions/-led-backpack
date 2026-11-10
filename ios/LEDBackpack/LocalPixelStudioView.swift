import SwiftUI
import UniformTypeIdentifiers
import BackpackProtocol

@MainActor
struct LocalPixelStudioView: View {
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @StateObject private var store = LocalPixelStore()
    @AppStorage("localPixelDataSaving") private var dataSaving = false
    @State private var name = "My local pixels"
    @State private var ink: Color = .cyan
    @State private var tool = "Brush"
    @State private var radius = 0
    @State private var xText = "0"
    @State private var yText = "0"
    @State private var widthText = "64"
    @State private var heightText = "64"
    @State private var delayText = "10"
    @State private var repeatsText = "1"
    @State private var text = "HELLO"
    @State private var grid = true
    @State private var brightness = 1.0
    @State private var blackFloor = 0.0
    @State private var dimAmount = 0.5
    @State private var importing = false
    @State private var importSprite = false
    @State private var importPoint = LocalPixelPoint(x: 0, y: 0)
    @State private var previewStart = Date()
    @State private var pending: Action?
    @State private var sourceSave: Task<Void, Never>?
    private enum Action {
        case new(Int, Int), importDocument, open(LocalPixelProjectEntry), remove(LocalPixelProjectEntry), library(PhoneArtwork)
    }
    private var art: LocalPixelArtwork { store.document.artwork }
    private var animationBlocked: Bool { reducedMotion || dataSaving || phone.dataSaving || !phone.animationsEnabled || phase != .active }

    var body: some View {
        Form {
            intro
            canvasSection
            tools
            Section("Save") {
                Button("Save editable project") { store.saveProject(name: name) }
                    .buttonStyle(AuroraPrimaryButton())
                    .disabled(store.busy || store.playing || originals.busy)
                Text("Save before leaving to keep this draft. Export creates a separate phone-library copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            previewControls
            timeline
            importExport
            projects
            newCanvas
        }
        .modernScene().navigationTitle("Offline pixel studio").buttonStyle(.borderless)
        .task {
            store.setForeground(phase == .active)
            await store.loadProjects(); await originals.load()
        }
        .onChange(of: phase) { _, value in store.setForeground(value == .active); if value != .active { sourceSave?.cancel() } }
        .onChange(of: animationBlocked) { _, blocked in if blocked { store.pause() } }
        .onChange(of: community.avatarPolicyRevision) { _, _ in store.pause() }
        .onChange(of: tool) { _, _ in store.endStroke(); store.cancel() }
        .onChange(of: xText) { _, _ in store.cancel() }
        .onChange(of: yText) { _, _ in store.cancel() }
        .onChange(of: store.document.current.centiseconds) { _, value in delayText = String(value) }
        .onChange(of: store.document.current.id) { _, _ in delayText = String(store.document.current.centiseconds) }
        .onDisappear { store.cancel(); sourceSave?.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .webP, .gif]) { result in
            do { store.importFile(try result.get(), sprite: importSprite, at: importPoint) }
            catch { store.failure = error.localizedDescription }
        }
        .confirmationDialog("Confirm local studio action", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let action = pending {
                    Button(confirmLabel(action), role: .destructive) { perform(action); pending = nil }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text("Save the editable project before replacing this draft. Delete affects only the selected local project, not sources, hardware or cloud.")
            }
    }
    private var intro: some View {
        Section {
            Text("\(art.width) × \(art.height) local pixels").font(.headline)
            Text("New copies only. Your originals and display are unchanged.").font(.caption)
            FeatureDetails("Draft replacement & deletion") {
                Text("New/import/open replaces this unsaved editing session only after a supported result is ready. Save an editable project first to retain it. Delete removes only the chosen local project. Phone display, original sources, hardware and cloud are unchanged.")
            }
            if let error = store.failure { Text(error).foregroundStyle(.orange).accessibilityLabel("Studio error: \(error)") }
            if let notice = store.notice { Text(notice).foregroundStyle(.secondary).accessibilityLabel(notice) }
            if store.busy {
                ProgressView("Processing local copy")
                Button("Cancel pending work") { store.cancel() }
            }
        }
    }
    private var canvasSection: some View {
        Section("Canvas — frame \(store.document.selected + 1) of \(art.frames.count)") {
            TimelineView(.animation(minimumInterval: 0.03, paused: !store.playing)) { context in
                let position = LocalPixelPlayback.position(art, elapsed: context.date.timeIntervalSince(previewStart))
                let index = store.playing ? position.index : store.document.selected
                LocalPixelCanvas(frame: art.frames[index], width: art.width, height: art.height,
                    brightness: brightness, blackFloor: blackFloor, grid: grid, revision: store.generation,
                    paint: paint, end: store.endStroke)
                    .allowsHitTesting(!store.playing && !store.busy)
                    .onChange(of: position.finished) { _, finished in
                        if finished && store.playing {
                            store.change { try $0.select(art.frames.count - 1) }
                        }
                    }
            }
            HStack {
                Button("Undo") { store.change { try $0.undo() } }.disabled(!store.document.canUndo)
                Button("Redo") { store.change { try $0.redo() } }.disabled(!store.document.canRedo)
            }.disabled(store.busy)
            FeatureDetails("Canvas & undo") {
                Text("Drag inside the exact canvas. Edges outside it do not paint. Brush sets RGBA; erase restores transparency. Sprite/text use source-over and explicitly clip at edges.")
                Text("Undo/redo: at most 30 transactions / 24 MB of logical RGBA snapshots, including a live stroke. Oldest history is evicted, never artwork.")
            }
        }
    }
    private var tools: some View {
        Section("Tools") {
            Picker("Tool", selection: $tool) {
                ForEach(["Brush", "Erase", "Fill", "Sample"], id: \.self) { Text($0) }
            }
            ColorPicker("Ink color & opacity", selection: $ink, supportsOpacity: true)
            palette
            Stepper("Brush diameter \(radius * 2 + 1) pixels", value: $radius, in: 0...4)
            DisclosureGroup("Coordinate editing & text") {
                HStack {
                    TextField("Column X (zero based)", text: $xText).keyboardType(.numbersAndPunctuation)
                        .accessibilityLabel("Column X, zero through \(art.width - 1)")
                    TextField("Row Y (zero based)", text: $yText).keyboardType(.numbersAndPunctuation)
                        .accessibilityLabel("Row Y, zero through \(art.height - 1)")
                }
                Button("Apply tool at X / Y") {
                    do { paint(try coordinate()); store.endStroke() } catch { store.failure = error.localizedDescription }
                }
                TextField("Pixel text (up to 21 characters)", text: $text)
                Button("Stamp text at X / Y") { stampText() }
                Text("Text uses the 5×7 font. Stamping is one undoable edit and clips at canvas edges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Color replacement & dimming") {
                Text("Uses X / Y from Coordinate editing. Changes the current frame; Undo can restore it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Replace sampled color with ink") {
                    do {
                        let old = try store.document.sample(coordinate()), new = try color()
                        store.change { try $0.replacePaletteColor(old, with: new) }
                    } catch { store.failure = error.localizedDescription }
                }
                Slider(value: $dimAmount, in: 0...1, step: 0.05) { Text("Authored brightness") }
                Button("Apply \(Int(dimAmount * 100))% RGB brightness") {
                    store.change { try $0.dim(dimAmount) }
                }
            }
        }.disabled(store.busy || store.playing)
    }
    private var palette: some View {
        let colors: [(String, Color)] = [
            ("Transparent", .clear), ("Black", .black), ("White", .white), ("Red", .red),
            ("Yellow", .yellow), ("Green", .green), ("Cyan", .cyan), ("Blue", .blue), ("Purple", .purple)
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 46))]) {
            ForEach(colors, id: \.0) { label, color in
                Button { ink = color } label: {
                    RoundedRectangle(cornerRadius: 6).fill(color)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
                        .overlay { if label == "Transparent" { Image(systemName: "circle.slash") } }
                        .frame(width: 36, height: 36).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("\(label) palette ink")
            }
        }
    }
    private var timeline: some View {
        DisclosureGroup("Frames & timing") {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(art.frames.enumerated()), id: \.element.id) { index, frame in
                        Button("Frame \(index + 1)\n\(frame.centiseconds) cs") { store.change { try $0.select(index) } }
                            .buttonStyle(.bordered)
                            .accessibilityAddTraits(index == store.document.selected ? .isSelected : [])
                    }
                }
            }
            HStack {
                Button("Add blank") { store.change { try $0.addFrame(copy: false) } }
                Button("Duplicate") { store.change { try $0.addFrame(copy: true) } }
            }.disabled(art.frames.count == 120)
            HStack {
                Button("Earlier") { store.change { try $0.moveFrame(-1) } }.disabled(store.document.selected == 0)
                Button("Later") { store.change { try $0.moveFrame(1) } }.disabled(store.document.selected == art.frames.count - 1)
                Button("Remove", role: .destructive) { store.change { try $0.removeFrame() } }.disabled(art.frames.count == 1)
            }
            TextField("Delay in whole centiseconds (1…65535)", text: $delayText).keyboardType(.numberPad)
            Button("Apply frame delay") {
                guard let delay = Int(delayText) else { store.failure = "Enter a whole number of centiseconds."; return }
                store.change { try $0.setTiming(delay) }
            }
            InteractionExplanation("Delay uses centiseconds: 100 = 1 second. Source timing is preserved; zero-delay preview uses a 1 cs display interval.",
                details: "Current delay \(store.document.current.centiseconds) cs. 100 cs = 1 second. Source timing is never capped at ten seconds. Source zero delay stays zero in export; preview uses a 1 cs display interval.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Loop behavior", selection: Binding(get: {
                art.repeats == nil ? 0 : (art.repeats == 0 ? 1 : 2)
            }, set: { choice in
                if choice == 0 { store.change { try $0.setRepeats(nil) } }
                else if choice == 1 { store.change { try $0.setRepeats(0) } }
                else { applyRepeats() }
            })) {
                Text("Once (no repeat extension)").tag(0)
                Text("Forever").tag(1)
                Text("Finite repeats").tag(2)
            }
            TextField("Additional repeats (1…65535)", text: $repeatsText).keyboardType(.numberPad)
            Button("Apply finite repeats") { applyRepeats() }
            if let repeats = art.repeats { Text(repeats == 0 ? "Repeats forever" : "\(repeats) additional repeats (\(repeats + 1) total passes)") }
        }.disabled(store.busy || store.playing)
    }
    private var previewControls: some View {
        Section("Preview") {
            Button(store.playing ? "Pause preview" : "Play preview") {
                if store.playing { store.pause() }
                else { previewStart = Date(); store.play(reducedMotion: reducedMotion, dataSaving: animationBlocked) }
            }.disabled(store.busy || (animationBlocked && !store.playing) || art.frames.count == 1)
            DisclosureGroup("Preview appearance") {
                Toggle("Local data-saving / still preview", isOn: $dataSaving)
                Toggle("Pixel grid", isOn: $grid)
                Slider(value: $brightness, in: 0...1) { Text("Preview RGB brightness") }
                Slider(value: $blackFloor, in: 0...0.2) { Text("Preview black floor") }
                Button("Reset preview appearance") { brightness = 1; blackFloor = 0; grid = true }
                Text("Preview only. Motion/data-saving settings apply; no display or original pixels change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var importExport: some View {
        DisclosureGroup("Import & export") {
            Text("Importing or opening an original replaces the draft after confirmation. Save an editable project first.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Import artwork…") { pending = .importDocument }
            Button("Stamp image at X / Y…") {
                do { importPoint = try coordinate(); importSprite = true; importing = true }
                catch { store.failure = error.localizedDescription }
            }
            FeatureDetails("Supported imports") {
                Text("Up to 5 MB, 128×128 and 120 GIF frames. Stills: PNG/JPEG/WebP. Unsupported formats fail without changing the draft.")
            }
            DisclosureGroup("Edit an existing original") {
                ForEach(originals.items) { item in
                    Button("Edit local original") { pending = .library(item) }
                        .accessibilityLabel("Edit local original: \(item.name)")
                }
            }
            if store.retainedImport != nil {
                Text("Most recently read import bytes retained in this session, even if pixel decoding failed.")
                    .font(.caption)
                Button("Save imported ORIGINAL bytes to Phone originals") { saveOriginal(retained: true) }
            }
            if store.original != nil {
                Button("Save document's retained ORIGINAL bytes to Phone originals") { saveOriginal(retained: false) }
            }
            if let attribution = art.attribution {
                Text("Attribution retained: \(attribution.author) · \(attribution.source) · \(attribution.license) · \(attribution.licenseURL)")
                    .font(.caption).textSelection(.enabled)
            }
            DisclosureGroup("Export a copy") {
                Button("Export current frame as PNG") { store.export(animated: false, name: name, library: originals) }
                Button("Export animation as GIF") { store.export(animated: true, name: name, library: originals) }
                Text("GIF needs binary transparency and at most 256 colors per frame. Unsupported pixels produce an error; PNG and projects retain RGBA.")
                    .font(.caption)
            }
        }.disabled(store.busy || store.playing || originals.busy)
    }
    private var projects: some View {
        DisclosureGroup("Saved projects") {
            if store.projects.isEmpty { Text("No saved studio projects yet. Save explicitly before leaving; unsaved edits are not auto-synced.") }
            ForEach(store.projects) { entry in
                HStack {
                    Button("Open \(entry.name)") { pending = .open(entry) }
                    Spacer()
                    Button("Delete", role: .destructive) { pending = .remove(entry) }
                        .accessibilityLabel("Delete local project \(entry.name)")
                }
            }
            Text("New-copy saves only: 30 projects, 40 MB per encoded project, 100 MB total. Undo history is session-only. Phone-library exports have separate 100-original / 100 MB limits.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(store.busy || store.playing)
    }
    private var newCanvas: some View {
        DisclosureGroup("New canvas") {
            Text("Replaces the unsaved draft after confirmation. Save an editable project first.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach([16, 32, 48, 64], id: \.self) { side in
                Button("New \(side) × \(side)") { pending = .new(side, side) }
            }
            Button("New legacy 96 × 128") { pending = .new(96, 128) }
            TextField("Custom columns (1…128)", text: $widthText).keyboardType(.numberPad)
            TextField("Custom rows (1…128)", text: $heightText).keyboardType(.numberPad)
            Button("New custom rectangle…") {
                guard let width = Int(widthText), let height = Int(heightText),
                      (1...128).contains(width), (1...128).contains(height) else {
                    store.failure = "Enter whole dimensions 1…128 for each side. No values were clamped."; return
                }
                pending = .new(width, height)
            }
        }.disabled(store.busy || store.playing)
    }
    private func coordinate() throws -> LocalPixelPoint {
        guard let x = Int(xText), let y = Int(yText), (-128...127).contains(x), (-128...127).contains(y) else {
            throw BackpackError.invalid("Enter whole X/Y coordinates. Brush/fill/sample must be inside the canvas; sprites/text may clip from −128…127.")
        }
        return LocalPixelPoint(x: x, y: y)
    }
    private func color() throws -> LocalPixelColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(ink).getRed(&r, green: &g, blue: &b, alpha: &a),
              [r, g, b, a].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw BackpackError.invalid("Choose a representable sRGB RGBA ink.")
        }
        return LocalPixelColor(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()),
            b: UInt8((b * 255).rounded()), a: UInt8((a * 255).rounded()))
    }
    private func paint(_ point: LocalPixelPoint) {
        do {
            if tool == "Sample" {
                let value = try store.document.sample(point)
                ink = Color(.sRGB, red: Double(value.r) / 255, green: Double(value.g) / 255,
                    blue: Double(value.b) / 255, opacity: Double(value.a) / 255)
            } else if tool == "Fill" { let ink = try color(); store.change { try $0.fill(point, color: ink) } }
            else { store.stroke(point, color: tool == "Erase" ? .clear : try color(), radius: radius) }
        } catch { store.failure = error.localizedDescription }
    }
    private func stampText() {
        do {
            let point = try coordinate(), stamp = try LocalPixelText.stamp(text, color: color())
            store.change { try $0.stamp(rgba: stamp.rgba, width: stamp.width, height: stamp.height, at: point) }
        } catch { store.failure = error.localizedDescription }
    }
    private func applyRepeats() {
        guard let repeats = Int(repeatsText), (1...65535).contains(repeats) else { store.failure = "Enter 1…65535 additional repeats."; return }
        store.change { try $0.setRepeats(repeats) }
    }
    private func confirmLabel(_ action: Action) -> String {
        switch action {
        case .new: return "Replace session with new blank document"
        case .importDocument: return "Choose document to replace session"
        case .open: return "Open project and replace session"
        case .remove: return "Delete this owned local project"
        case .library: return "Import local original and replace session"
        }
    }
    private func perform(_ action: Action) {
        switch action {
        case let .new(width, height): store.newDocument(width: width, height: height)
        case .importDocument: importSprite = false; importing = true
        case let .open(entry): store.openProject(entry)
        case let .remove(entry): store.removeProject(entry)
        case let .library(item): store.importLibrary(item, library: originals)
        }
    }
    private func saveOriginal(retained: Bool) {
        guard let bytes = retained ? store.retainedImport : store.original else { return }
        let sourceName = (retained ? store.retainedImportName : store.originalName) ?? "Original artwork"
        let attribution = retained ? store.retainedImportAttribution : art.attribution
        let stamp = store.ticket
        sourceSave?.cancel()
        sourceSave = Task {
            do {
                guard store.accepts(stamp) else { return }
                _ = try await originals.saveCreatedCopy(bytes, name: sourceName, attribution: attribution)
                if store.accepts(stamp) { store.notice = "Byte-exact original copied locally. Active phone display unchanged." }
            } catch { if store.accepts(stamp) { store.failure = error.localizedDescription } }
        }
    }
}
