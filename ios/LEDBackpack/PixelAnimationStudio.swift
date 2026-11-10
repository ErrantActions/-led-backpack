import SwiftUI
import BackpackProtocol

@MainActor
struct PixelAnimationStudio: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var drawing: DrawingLivePreview
    @State private var document = PixelDrawingDocument()
    @State private var ink: Color = .cyan
    @State private var tool = "Brush"
    @State private var radius = 0
    @State private var zoom = 1.0
    @State private var zoomStart = 1.0
    @State private var panning = false
    @State private var name = "Drawing"
    @State private var preview: UIImage?
    @State private var animation: Data?
    @State private var newSize: PanelSize?
    @State private var failure: String?
    @State private var status: String?

    var body: some View {
        Form {
            Section("Pixel canvas") {
                Text("\(document.current.pixels.size.width) x \(document.current.pixels.size.height) / frame \(document.selected + 1) of \(document.frames.count)")
                    .font(.caption)
                canvas
                DisclosureGroup("Zoom & navigation") {
                    Toggle("Move / pinch-zoom canvas", isOn: $panning)
                    Slider(value: $zoom, in: 1...8, step: 0.25) { Text("Canvas zoom") }
                    Text("Zoom \(zoom, specifier: "%.2f")x").font(.caption)
                }
                Picker("Tool", selection: $tool) {
                    Text("Brush").tag("Brush"); Text("Eraser").tag("Eraser"); Text("Eyedropper").tag("Eyedropper")
                }
                ColorPicker("Brush color", selection: $ink, supportsOpacity: false)
                Stepper("Brush size: \(radius * 2 + 1) pixels", value: $radius, in: 0...4)
                HStack {
                    Button("Undo") { change { try document.undo() } }.disabled(!document.canUndo)
                    Button("Redo") { change { try document.redo() } }.disabled(!document.canRedo)
                }
            }
            Section("Save") {
                if let failure { Text(failure).foregroundStyle(.orange) }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Button("Preview animation") {
                    app.run {
                        do { animation = try encoded(); failure = nil }
                        catch { failure = error.localizedDescription; throw error }
                    }
                }
                Button("Save GIF") { save(openLibrary: false) }
                    .buttonStyle(AuroraPrimaryButton())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Saves a new local copy. Sending from Library requires a separate slot / overwrite review.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Save & continue") {
                    Button("Save, then open Library") { save(openLibrary: true) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Single frames stay single frames. Existing GIFs are never replaced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            timeline
            if drawing.running || drawing.failure != nil {
                Section("Backpack preview") {
                    Text(drawing.state.rawValue)
                    if let failure = drawing.failure { Text(failure).foregroundStyle(.orange) }
                    if drawing.running {
                        Button("Stop preview and restore playback") { Task { await drawing.stop() } }
                    }
                }
            }
            DisclosureGroup("Backpack preview") {
                if drawing.running {
                    Text("Preview is active. Stop above to restore stored playback.").font(.caption)
                } else {
                    Button("Preview drawing on backpack") {
                        app.run {
                            do { try drawing.start(document.current.pixels); failure = nil }
                            catch { failure = error.localizedDescription; throw error }
                        }
                    }.disabled(!panel.link.connected || panel.busy || panel.hasDisplayOwner || panel.size != document.current.pixels.size)
                    Text("Requires a connected, idle backpack matching this canvas size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                InteractionExplanation("Preview does not save a slot. Leaving/backgrounding stops preview and attempts to restore stored playback.", details: "Brush updates are coalesced, not queued per touch. Preview stops and attempts to restore stored playback when you leave this editor or background the app. It does not save or overwrite a GIF slot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("New canvas") {
                Text("Replaces the unsaved timeline. Undo is available only while this editor stays open.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(MediaCodec.renderSizes, id: \.width) { size in
                    Button("New \(size.width) x \(size.height) canvas") { newSize = size }
                }
            }
        }
        .modernScene().navigationTitle("Drawing & animation")
        .task { updatePreview() }
        .onChange(of: document.current) { _, value in updatePreview(); drawing.offer(value.pixels) }
        .onDisappear { Task { await drawing.stop() } }
        .onChange(of: tool) { _, _ in document.endStroke() }
        .onChange(of: panning) { _, _ in document.endStroke() }
        .sheet(isPresented: Binding(get: { animation != nil }, set: { if !$0 { animation = nil } })) {
            NavigationStack {
                if let animation {
                    AnimatedPreview(data: animation).navigationTitle("Animation preview")
                        .toolbar { Button("Done") { self.animation = nil } }
                        .safeAreaInset(edge: .bottom) {
                            Button("Back to drawing") { self.animation = nil }
                                .frame(maxWidth: .infinity, minHeight: 44).padding(8).background(.regularMaterial)
                        }
                }
            }
        }
        .confirmationDialog("Start a new canvas?", isPresented: Binding(
            get: { newSize != nil }, set: { if !$0 { newSize = nil } })) {
                if let size = newSize {
                    Button("Start new canvas") { change { try document.resetCanvas(size); zoom = 1 }; newSize = nil }
                }
            } message: { Text("This replaces the unsaved timeline. Undo can restore it while this editor remains open.") }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                if let preview {
                    let width = geometry.size.width * zoom
                    let height = width * CGFloat(document.current.pixels.size.height) / CGFloat(document.current.pixels.size.width)
                    Image(uiImage: preview).interpolation(.none).resizable()
                        .frame(width: width, height: height).contentShape(Rectangle())
                        .highPriorityGesture(DragGesture(minimumDistance: 0)
                            .onChanged { paint($0.location, width: width, height: height) }
                            .onEnded { _ in document.endStroke() }, including: panning ? .none : .all)
                }
            }.scrollDisabled(!panning)
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { if panning { zoom = max(1, min(8, zoomStart * $0)) } }
                    .onEnded { _ in zoomStart = zoom })
        }.frame(height: 340).background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private var timeline: some View {
        DisclosureGroup("Frames & timing") {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(document.frames.enumerated()), id: \.element.id) { index, frame in
                        Button { change { try document.select(index) } } label: {
                            VStack {
                                DrawingFrameThumbnail(frame: frame).frame(width: 60, height: 70)
                                Text("\(index + 1)").font(.caption)
                            }.padding(4).background(document.selected == index ? Aurora.mint.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Stepper("Delay: \(document.current.delay, specifier: "%.2f")s", value: Binding(
                get: { document.current.delay },
                set: { value in change { try document.setDelay(value) } }), in: 0.02...10, step: 0.02)
            Button("Add blank frame") { change { try document.addFrame(copy: false) } }.disabled(document.frames.count >= 120)
            Button("Duplicate selected frame") { change { try document.addFrame(copy: true) } }.disabled(document.frames.count >= 120)
            HStack {
                Button("Move earlier") { change { try document.moveFrame(by: -1) } }.disabled(document.selected == 0)
                Button("Move later") { change { try document.moveFrame(by: 1) } }
                    .disabled(document.selected + 1 == document.frames.count)
            }
            Button("Remove selected frame", role: .destructive) { change { try document.deleteFrame() } }
                .disabled(document.frames.count == 1)
            Text("Remove affects only this draft frame. Undo can restore it while the editor stays open.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func change(_ work: () throws -> Void) {
        do { try work(); updatePreview() } catch { failure = error.localizedDescription; panel.report(error) }
    }
    private func updatePreview() {
        do { preview = try document.current.pixels.image() } catch { failure = error.localizedDescription; panel.report(error) }
    }
    private func paint(_ point: CGPoint, width: CGFloat, height: CGFloat) {
        let size = document.current.pixels.size
        let x = min(size.width - 1, max(0, Int(point.x / width * CGFloat(size.width))))
        let y = min(size.height - 1, max(0, Int(point.y / height * CGFloat(size.height))))
        change {
            if tool == "Eyedropper" {
                let color = try document.sample(x: x, y: y)
                ink = Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
                return
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(ink).getRed(&r, green: &g, blue: &b, alpha: &a) else {
                throw BackpackError.invalid("Could not read the brush color.")
            }
            let color = tool == "Eraser" ? RGB8.black :
                RGB8(r: UInt8(max(0, min(255, Int(r * 255)))), g: UInt8(max(0, min(255, Int(g * 255)))),
                    b: UInt8(max(0, min(255, Int(b * 255)))))
            try document.paint(x: x, y: y, color: color, radius: radius)
        }
    }
    private func encoded() throws -> Data {
        try MediaCodec.encode(document.frames.map(\.pixels), delays: document.frames.map(\.delay))
    }
    private func save(openLibrary: Bool) {
        app.run {
            do {
                try library.add(name: name.trimmingCharacters(in: .whitespacesAndNewlines), data: encoded())
                failure = nil; status = "Saved to Library."
                if openLibrary { app.selectedTab = .library }
            } catch { failure = error.localizedDescription; throw error }
        }
    }
}

@MainActor
private struct DrawingFrameThumbnail: View {
    @EnvironmentObject private var panel: PanelController
    let frame: DrawingFrame
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit() }
            else { ProgressView() }
        }.task(id: frame) {
            do { image = try frame.pixels.image() } catch { panel.report(error) }
        }
    }
}
