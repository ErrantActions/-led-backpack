import SwiftUI
import BackpackProtocol

@MainActor
struct MediaEditor: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @Environment(\.dismiss) private var dismiss
    let data: Data
    let attribution: Attribution?
    @State private var categoryName: String
    @State private var animation: MediaCodec.Animation?
    @State private var fit = MediaCodec.Fit.fit
    @State private var turns = 0
    @State private var brightness = 1.0
    @State private var start = 0
    @State private var end = 0
    @State private var frameIndex = 0
    @State private var sizeIndex = 1
    @State private var name = "My artwork"
    @State private var preview: UIImage?
    @State private var previewPixels: PixelFrame?
    @State private var previewAnimation: Data?
    @State private var busy = false
    @State private var progress = 0.0
    @State private var processing: Task<Void, Never>?
    @State private var removal = BackgroundRemoval.off
    @State private var keyColor = Color.white
    @State private var tolerance = 0.1
    @State private var halos = false
    @State private var haloThreshold = 30.0
    @State private var isolated = false
    @State private var subject = false
    @State private var subjects: [Int: Data] = [:]
    @State private var speed = 1.0
    @State private var direction = GIFDirection.forward
    @State private var loops = 0
    @State private var overrideDelay = 0.1
    @State private var overrides: [Int: Double] = [:]
    @State private var tool = "Off"
    @State private var brushColor = Color.cyan
    @State private var radius = 0
    @State private var allFrames = false
    @State private var touches: [Int: [Int: RGB8]] = [:]
    @State private var undoTouches: [Int: [Int: RGB8]]?
    @State private var drawing = false
    @State private var resetFrameCanvas = false
    @State private var previewIsOriginal = false
    private let sizes = [PanelSize(width: 16, height: 16), PanelSize(width: 64, height: 64), PanelSize(width: 96, height: 128)]

    init(data: Data, attribution: Attribution?, category: String? = nil, initialName: String = "My artwork") {
        self.data = data
        self.attribution = attribution
        _categoryName = State(initialValue: category ?? "")
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            observedEditor
                .toolbar { Button("Cancel", action: cancelEditing) }
                .sheet(isPresented: Binding(get: { previewAnimation != nil }, set: { if !$0 { previewAnimation = nil } })) {
                    animationPreview
                }
                .task { loadAnimation() }
                .onDisappear { processing?.cancel() }
        }
    }

    private var editorForm: some View {
        Form {
            canvas
            framing
            cleanup
            ghosting
            timing
            manual
            outputActions
        }.modernScene().navigationTitle("GIF Studio").buttonStyle(.borderless)
    }

    private var geometryObservedEditor: some View {
        editorForm
            .onChange(of: sizeIndex) { _, _ in invalidate() }
            .onChange(of: fit) { _, _ in invalidate() }
            .onChange(of: turns) { _, _ in invalidate() }
            .onChange(of: brightness) { _, _ in invalidate() }
            .onChange(of: frameIndex) { _, _ in invalidate() }
    }

    private var observedEditor: some View {
        geometryObservedEditor
            .onChange(of: removal) { _, _ in invalidate() }
            .onChange(of: keyColor) { _, _ in invalidate() }
            .onChange(of: tolerance) { _, _ in invalidate() }
            .onChange(of: halos) { _, _ in invalidate() }
            .onChange(of: haloThreshold) { _, _ in invalidate() }
            .onChange(of: isolated) { _, _ in invalidate() }
            .onChange(of: subject) { _, _ in invalidate() }
            .onChange(of: resetFrameCanvas) { _, _ in
                preview = nil; previewPixels = nil; subjects = [:]
                do {
                    animation = try MediaCodec.decode(data, resetFrameCanvas: resetFrameCanvas)
                    process { try await updatePreview() }
                } catch { animation = nil; panel.report(error) }
            }
    }

    private var outputActions: some View {
        Section {
            Button("Update frame preview") { process { try await updatePreview() } }
            Button("Preview edited animation") {
                process { previewIsOriginal = false; previewAnimation = try await output() }
            }
            Button("Save new GIF to library") {
                process {
                    let bytes = try await output()
                    try Task.checkCancellation()
                    try library.add(name: name, data: bytes, attribution: attribution, category: categoryName)
                    dismiss()
                }
            }.buttonStyle(.borderedProminent)
            if busy { ProgressView("Processing selected frames...", value: progress) }
            Text("Removed areas display as black on the LED panel. Changes apply only to a new saved copy. Original attribution is retained. Automatic masks can vary across GIF frames; inspect the animation before sending.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(animation == nil || busy)
    }

    private var animationPreview: some View {
        NavigationStack {
            if let bytes = previewAnimation {
                AnimatedPreview(data: bytes).navigationTitle(previewIsOriginal ? "Original preview" : "Edited preview")
                    .toolbar { Button("Done") { previewAnimation = nil } }
            }
        }
    }

    private func loadAnimation() {
        do {
            let decoded = try MediaCodec.decode(data)
            animation = decoded
            end = decoded.images.count - 1
            if let size = panel.size, let index = sizes.firstIndex(of: size) { sizeIndex = index }
            process { try await updatePreview() }
        } catch { panel.report(error) }
    }

    private func cancelEditing() {
        processing?.cancel()
        dismiss()
    }

    private var canvas: some View {
        Section {
            if let preview {
                GeometryReader { geometry in
                    Image(uiImage: preview).interpolation(.none).resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged {
                            paint($0.location, in: geometry.size)
                        }.onEnded { _ in drawing = false })
                }.aspectRatio(CGFloat(sizes[sizeIndex].width) / CGFloat(sizes[sizeIndex].height), contentMode: .fit)
            }
            TextField("Artwork name", text: $name)
            TextField("Category (optional)", text: $categoryName)
            if preview == nil { Text("Tap Update frame preview to render the current settings.").font(.caption).foregroundStyle(.secondary) }
            Text("Frame \(frameIndex + 1) / \(animation?.images.count ?? 0)").font(.caption.monospaced())
        }
    }

    private var framing: some View {
        DisclosureGroup("Canvas & framing") {
            Picker("Panel size", selection: $sizeIndex) {
                ForEach(0..<sizes.count, id: \.self) { Text("\(sizes[$0].width) x \(sizes[$0].height)").tag($0) }
            }
            Picker("Framing", selection: $fit) { ForEach(MediaCodec.Fit.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            Stepper("Quarter turns: \(turns)", value: $turns, in: 0...3)
            Slider(value: $brightness, in: 0.1...2) { Text("Artwork brightness") }
            if !touches.isEmpty { Text("Reset manual edits before changing canvas geometry or brightness.").font(.caption) }
        }.disabled(busy || !touches.isEmpty)
    }

    private var cleanup: some View {
        DisclosureGroup("Background cleanup") {
            Picker("Remove background", selection: $removal) {
                ForEach(BackgroundRemoval.allCases) { Text($0.rawValue).tag($0) }
            }

            ColorPicker("Background color", selection: $keyColor, supportsOpacity: false)
            Slider(value: $tolerance, in: 0...1) { Text("Color tolerance") }
            Text("Tolerance \(Int(tolerance * 100))%. Edge-connected removal preserves matching areas enclosed inside the subject.").font(.caption)
            Toggle("Trim dark halos next to black", isOn: $halos)
            if halos { Slider(value: $haloThreshold, in: 0...128, step: 1) { Text("Halo threshold") } }
            Toggle("Remove isolated pixels", isOn: $isolated)
            Toggle("Automatic foreground cutout (Vision)", isOn: $subject)
            Text("Cutout runs on device on supported hardware and may fail for some art. All selected frames are processed individually; no cloud image service is used. Edge cleanup can remove intentional tiny details.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy)
    }

    @ViewBuilder private var ghosting: some View {
        if ["GIF87a", "GIF89a"].contains(String(data: data.prefix(6), encoding: .ascii) ?? "") {
            DisclosureGroup("Ghost trails") {
                Toggle("Reset canvas between GIF frames", isOn: $resetFrameCanvas)
                    .disabled(busy || !touches.isEmpty)
                Text("Repairs trails caused by frames retaining previous pixels. Some GIFs intentionally update only part of the canvas; resetting may remove wanted details. Preview before saving.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Faint outlines already painted into a frame are different: use Trim dark halos, background cleanup or the eraser. Canvas reset cannot reconstruct obscured artwork.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Compare original animation") { previewIsOriginal = true; previewAnimation = data }
                    .disabled(busy)
                if !touches.isEmpty { Text("Reset manual edits before changing frame disposal.").font(.caption) }
            }
        }
    }

    private var timing: some View {
        DisclosureGroup("Timing & loops") {
            if let animation {
                Stepper("First frame \(start + 1)", value: $start, in: 0...(animation.images.count - 1))
                Stepper("Last frame \(end + 1)", value: $end, in: 0...(animation.images.count - 1))
                Stepper("Preview frame \(frameIndex + 1)", value: $frameIndex, in: 0...(animation.images.count - 1))
            }
            Picker("Direction", selection: $direction) { ForEach(GIFDirection.allCases) { Text($0.rawValue).tag($0) } }
            Slider(value: $speed, in: 0.25...4, step: 0.05) { Text("Playback speed") }
            Text("Speed \(speed, specifier: "%.2f")x").font(.caption.monospaced())
            Stepper("Repeat count \(loops) (0 = forever)", value: $loops, in: 0...100)
            Slider(value: $overrideDelay, in: 0.02...2, step: 0.02) { Text("Frame delay") }
            Button("Set frame \(frameIndex + 1) delay to \(overrideDelay, specifier: "%.2f")s") {
                overrides[frameIndex] = overrideDelay
            }
            Button("Use source timing") { overrides = [:]; speed = 1 }
            Text("Per-frame overrides are applied before the global speed multiplier. Ping-pong avoids repeating endpoint frames; output is limited to 120 frames.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy)
    }

    private var manual: some View {
        DisclosureGroup("Brush & eraser") {
            Picker("Tool", selection: $tool) { Text("Off").tag("Off"); Text("Brush").tag("Brush"); Text("Eraser").tag("Eraser") }
            ColorPicker("Brush color", selection: $brushColor, supportsOpacity: false)
            Stepper("Brush radius \(radius) px", value: $radius, in: 0...3)
            Toggle("Apply touches across selected frame range", isOn: $allFrames)
            Button("Undo last stroke") {
                if let undoTouches { touches = undoTouches; self.undoTouches = nil; process { try await updatePreview() } }
            }.disabled(undoTouches == nil)
            Button("Reset manual edits") { touches = [:]; undoTouches = nil; process { try await updatePreview() } }
            Text("Touch the preview after updating it. Edits use panel pixels and are applied after automatic cleanup.").font(.caption)
        }.disabled(busy)
    }

    private func rgb(_ color: Color) throws -> RGB8 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            throw BackpackError.invalid("Could not read the selected color.")
        }
        return RGB8(r: UInt8(max(0, min(255, Int(r * 255)))), g: UInt8(max(0, min(255, Int(g * 255)))),
            b: UInt8(max(0, min(255, Int(b * 255)))))
    }

    private func frame(_ index: Int) async throws -> PixelFrame {
        guard let animation else { throw BackpackError.invalid("No media loaded.") }
        try Task.checkCancellation()
        var image = animation.images[index]
        if subject {
            let bytes: Data
            if let cached = subjects[index] { bytes = cached }
            else {
                guard let input = image.pngData() else { throw BackpackError.invalid("Could not prepare subject frame.") }
                bytes = try await SubjectCutout.png(input)
                try Task.checkCancellation()
                subjects[index] = bytes
            }
            guard let cut = UIImage(data: bytes) else { throw BackpackError.invalid("Could not decode subject mask.") }
            image = cut
        }
        let transformed = try MediaCodec.transform(image, size: sizes[sizeIndex], fit: fit, turns: turns, brightness: brightness)
        return try GIFCleanup.apply(transformed, options: CleanupOptions(removal: removal, key: rgb(keyColor),
            tolerance: tolerance, trimHalos: halos, haloThreshold: Int(haloThreshold), removeIsolated: isolated,
            edgeRegion: MediaCodec.footprint(image, size: sizes[sizeIndex], fit: fit, turns: turns)),
            touches: touches[index] ?? [:])
    }

    private func output() async throws -> Data {
        guard let animation else { throw BackpackError.invalid("No media loaded.") }
        let plan = try GIFCleanup.timing(delays: animation.delays, first: start, last: end,
            speed: speed, overrides: overrides, direction: direction)
        var rendered: [Int: PixelFrame] = [:]
        var frames: [PixelFrame] = []
        for (position, step) in plan.enumerated() {
            try Task.checkCancellation()
            let image: PixelFrame
            if let cached = rendered[step.index] { image = cached }
            else { image = try await frame(step.index); rendered[step.index] = image }
            frames.append(image)
            progress = Double(position + 1) / Double(plan.count)
            await Task.yield()
        }
        return try MediaCodec.encode(frames, delays: plan.map(\.delay), loopCount: loops)
    }

    private func updatePreview() async throws {
        let pixels = try await frame(frameIndex)
        previewPixels = pixels; preview = try pixels.image()
    }

    private func process(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = 0
        processing = Task {
            defer { busy = false; processing = nil }
            do { try await operation() }
            catch { if !Task.isCancelled { panel.report(error) } }
        }

    }

    private func invalidate() { preview = nil; previewPixels = nil }

    private func paint(_ point: CGPoint, in bounds: CGSize) {
        guard tool != "Off", !busy, var pixels = previewPixels, start <= end,
              pixels.size == sizes[sizeIndex], bounds.width > 0, bounds.height > 0 else { return }
        do {
            if !drawing { undoTouches = touches; drawing = true }
            let color = tool == "Eraser" ? RGB8.black : try rgb(brushColor)
            let x = min(pixels.size.width - 1, max(0, Int(point.x / bounds.width * CGFloat(pixels.size.width))))
            let y = min(pixels.size.height - 1, max(0, Int(point.y / bounds.height * CGFloat(pixels.size.height))))
            let indices = allFrames ? Array(start...end) : [frameIndex]
            guard touches.values.reduce(0, { $0 + $1.count }) + indices.count * (radius * 2 + 1) * (radius * 2 + 1) <= 200_000 else {
                throw BackpackError.invalid("Manual edit limit reached. Save and reopen the GIF to continue.")
            }
            for yy in max(0, y - radius)...min(pixels.size.height - 1, y + radius) {
                for xx in max(0, x - radius)...min(pixels.size.width - 1, x + radius) {
                    let pixel = yy * pixels.size.width + xx
                    for index in indices { touches[index, default: [:]][pixel] = color }
                    if indices.contains(frameIndex) {
                        pixels.rgb.replaceSubrange((pixel * 3)..<(pixel * 3 + 3), with: color.bytes)
                    }
                }
            }
            previewPixels = pixels; preview = try pixels.image()
        } catch { panel.report(error) }
    }
}
