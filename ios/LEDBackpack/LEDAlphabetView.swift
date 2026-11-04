import SwiftUI
import BackpackProtocol

@MainActor
struct LEDAlphabetView: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @State private var sizeIndex = 1
    @State private var scale = 2
    @State private var letter = "F"
    @State private var preview: UIImage?
    @State private var failure: String?
    @State private var status: String?
    @State private var saving = false
    private var size: PanelSize { MediaCodec.renderSizes[sizeIndex] }
    private var maximum: Int { TextArtwork.maximumPixelScale(size) }
    private var characters: [String] { TextArtwork.supportedCharacters.filter { $0 != " " }.map(String.init) }
    private struct Key: Equatable { let size: Int; let scale: Int; let letter: String }
    private var key: Key { Key(size: sizeIndex, scale: scale, letter: letter) }
    var body: some View {
        Form {
            Section("Exact LED pixels") {
                Picker("Panel", selection: $sizeIndex) {
                    ForEach(MediaCodec.renderSizes.indices, id: \.self) { index in
                        let size = MediaCodec.renderSizes[index]
                        Text("\(size.width) x \(size.height)").tag(index)
                    }
                }
                Picker("Letter", selection: $letter) {
                    ForEach(characters, id: \.self) { Text($0).tag($0) }
                }
                Stepper("\(5 * scale) x \(7 * scale) LEDs / scale \(scale)", value: $scale, in: 1...maximum)
                if let preview {
                    Image(uiImage: preview).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 280).background(.black)
                }
                Text("5x7 is the base glyph cell. Scaling repeats whole LEDs; it never stretches or interpolates. Some glyphs intentionally have empty columns or rows inside their cell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Size and line capacity") {
                ForEach(1...maximum, id: \.self) { value in
                    let padding = max(1, min(size.width, size.height) / 32)
                    let capacity = TextArtwork.lineCapacity(width: size.width - padding * 2, scale: value)
                    LabeledContent("\(5 * value) x \(7 * value) LEDs", value: "\(capacity) characters / line")
                }
            }
            Section("Check the physical backpack") {
                Button("Save all-character test GIF") { saveProof() }.disabled(saving)
                if saving { ProgressView("Building font proof...") }
                Text("Creates a local 94-frame GIF: A-Z, a-z, digits and all printable punctuation in ASCII order at the selected size. Each frame lasts 0.5 seconds. Send it from Library to an expendable slot, or preview it locally first.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Software pixel checks do not certify physical readability. View the actual backpack at your normal distance. Existing saved artwork is not rewritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if let status { Text(status).font(.caption) }
        }
        .modernScene().navigationTitle("LED alphabet")
        .task(id: key) {
            do {
                preview = try TextArtwork.render(letter, size: size, font: .pixel, alignment: .center,
                    color: .white, pixelScale: scale).image()
                failure = nil
            } catch { failure = error.localizedDescription; preview = nil }
        }
        .onChange(of: sizeIndex) { _, _ in scale = min(scale, maximum) }
    }
    private func saveProof() {
        guard !saving else { return }
        let target = size, scale = scale
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                var frames: [PixelFrame] = []
                for letter in characters {
                    frames.append(try TextArtwork.render(letter, size: target, font: .pixel, alignment: .center,
                        color: .white, pixelScale: scale))
                    await Task.yield()
                }
                let data = try MediaCodec.encode(frames, delays: Array(repeating: 0.5, count: frames.count))
                try library.add(name: "Alphabet \(scale * 5)x\(scale * 7) on \(target.width)x\(target.height)",
                    data: data, category: "Font proofs")
                status = "Saved to Library > Font proofs. No backpack storage has been changed."
            } catch { failure = error.localizedDescription }
        }
    }
}
