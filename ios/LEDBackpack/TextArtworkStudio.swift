import SwiftUI
import BackpackProtocol

@MainActor
struct TextArtworkStudio: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @State private var text = "HELLO"
    @State private var name = "My text"
    @State private var category = ""
    @State private var font = ArtworkFont.pixel
    @State private var alignment = ArtworkAlignment.center
    @State private var ink: Color = .cyan
    @State private var scrolling = false
    @State private var pixelScale = 0
    @State private var delay = 0.08
    @State private var preview: UIImage?
    @State private var animation: Data?
    @State private var failure: String?
    @State private var status: String?
    @State private var saving = false
    @State private var dimensions = ""
    private var size: PanelSize { panel.size ?? PanelSize(width: 64, height: 64) }
    private struct PreviewKey: Equatable {
        let text: String
        let font: ArtworkFont
        let alignment: ArtworkAlignment
        let ink: Color
        let scrolling: Bool
        let size: PanelSize
        let pixelScale: Int?
    }
    private var previewKey: PreviewKey {
        PreviewKey(text: text, font: font, alignment: alignment, ink: ink, scrolling: scrolling, size: size,
            pixelScale: pixelScale == 0 ? nil : pixelScale)
    }

    var body: some View {
        Section("Text to GIF") {
            TextField("Message", text: $text, axis: .vertical).lineLimit(1...4)
            Text("\(text.count)/80 characters").font(.caption).foregroundStyle(.secondary)
            typography
            artworkPreview
            saveControls
        }
        .task(id: previewKey) {
            let key = previewKey
            do {
                try await Task.sleep(for: .milliseconds(150))
                let frame = key.scrolling
                    ? try TextArtwork.scrollingFrame(key.text, size: key.size, font: key.font, color: UIColor(key.ink), phase: 0.5,
                        pixelScale: key.pixelScale)
                    : try TextArtwork.render(key.text, size: key.size, font: key.font, alignment: key.alignment, color: UIColor(key.ink),
                        pixelScale: key.pixelScale)
                preview = try frame.image()
                if key.font == .pixel {
                    let scale = key.scrolling ? key.pixelScale ?? max(1, min(3, (key.size.height - 4) / 7))
                        : try TextArtwork.pixelLayout(key.text, size: key.size, scale: key.pixelScale).scale
                    dimensions = "\(scale * 5) x \(scale * 7) LEDs per glyph / \(scale)-LED spacing"
                } else { dimensions = "Measured system-font layout" }
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                preview = nil
                failure = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { animation != nil }, set: { if !$0 { animation = nil } })) {
            NavigationStack {
                if let animation {
                    AnimatedPreview(data: animation).navigationTitle("Text animation")
                        .toolbar { Button("Done") { self.animation = nil } }
                }
            }
        }
    }

    private var typography: some View {
        Group {
            Picker("Typeface", selection: $font) {
                ForEach(ArtworkFont.allCases) { Text($0.rawValue).tag($0) }
            }
            if font == .pixel {
                Picker("Letter size", selection: $pixelScale) {
                    Text("Auto fit whole words").tag(0)
                    ForEach(1...TextArtwork.maximumPixelScale(size), id: \.self) { scale in
                        Text("\(scale * 5) x \(scale * 7) LEDs").tag(scale)
                    }
                }
                NavigationLink("Inspect every letter and size") { LEDAlphabetView() }
            }
            if !scrolling {
                Picker("Alignment", selection: $alignment) {
                    ForEach(ArtworkAlignment.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            ColorPicker("Text color", selection: $ink, supportsOpacity: false)
            Toggle("Scrolling animation", isOn: $scrolling)
            if scrolling {
                Slider(value: $delay, in: 0.03...0.3, step: 0.01) { Text("Frame duration") }
                Text("\(Int((delay * 1000).rounded())) ms per frame").font(.caption).foregroundStyle(.secondary)
            }
            Text(font == .pixel
                ? "Pixel type uses crisp whole-pixel A-Z, a-z, digits and punctuation. Auto fit keeps words intact when possible; fixed sizes never silently shrink."
                : "System fonts support other scripts. Their measured layout wraps and fits the actual canvas.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var artworkPreview: some View {
        Group {
            if let preview {
                Image(uiImage: preview).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220).background(.black)
                Text("\(size.width) x \(size.height) / \(scrolling ? "mid-scroll sample" : "auto-fit preview")")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(dimensions).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var saveControls: some View {
        Group {
            TextField("Saved name", text: $name)
            TextField("Category (optional)", text: $category)
            if scrolling {
                Button("Play animation preview") { generate(save: false) }.disabled(saving || preview == nil || failure != nil)
            }
            Button("Save text as GIF") { generate(save: true) }
                .buttonStyle(.borderedProminent).disabled(saving || preview == nil || failure != nil)
            if saving { ProgressView("Creating GIF...") }
        }
    }

    private func generate(save: Bool) {
        guard !saving else { return }
        let key = previewKey
        let savedName = name, savedCategory = category, frameDelay = delay
        app.run {
            guard !saving else { throw BackpackError.invalid("Wait for the current text generation to finish.") }
            saving = true
            defer { saving = false }
            await Task.yield()
            let frames = key.scrolling
                ? try TextArtwork.animation(key.text, size: key.size, font: key.font, color: UIColor(key.ink), pixelScale: key.pixelScale)
                : [try TextArtwork.render(key.text, size: key.size, font: key.font, alignment: key.alignment,
                    color: UIColor(key.ink), pixelScale: key.pixelScale)]
            let bytes = try MediaCodec.encode(frames, delays: Array(repeating: key.scrolling ? frameDelay : 1, count: frames.count))
            if save {
                try library.add(name: savedName, data: bytes, category: savedCategory)
                status = "Saved to Library."
            } else { animation = bytes }
        }
    }
}
