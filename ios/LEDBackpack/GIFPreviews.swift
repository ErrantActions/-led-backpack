import SwiftUI
import ImageIO
import BackpackProtocol

final class GIFPreview: NSObject {
    let frames: [UIImage]
    let duration: Double
    let caption: String
    let cost: Int
    init(frames: [UIImage], duration: Double, caption: String, cost: Int) {
        self.frames = frames
        self.duration = duration
        self.caption = caption
        self.cost = cost
    }
}

@MainActor
enum GIFPreviewDecoder {
    static func validateOriginal(_ data: Data) throws {
        guard try originalFrameCount(data) <= 120 else {
            throw BackpackError.invalid("This GIF has too many frames. The editor supports up to 120 frames.")
        }
    }

    static func originalFrameCount(_ data: Data) throws -> Int {
        guard data.count <= 5_000_000,
              ["GIF87a", "GIF89a"].contains(String(data: data.prefix(6), encoding: .ascii) ?? ""),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw BackpackError.invalid("The download is not a supported GIF under 5 MB.")
        }
        let count = CGImageSourceGetCount(source)
        guard (1...1200).contains(count) else {
            throw BackpackError.invalid("The full preview supports 1 to 1200 frames.")
        }
        try checkDimensions(source)
        return count
    }

    private static func checkDimensions(_ source: CGImageSource) throws {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw BackpackError.invalid("Preview dimensions are missing or exceed 4096 pixels.")
        }
    }

    static func thumbnail(_ data: Data) throws -> GIFPreview {
        guard data.count <= 5_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw BackpackError.invalid("This image cannot be previewed.")
        }
        try checkDimensions(source)
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw BackpackError.invalid("The preview contains no frames.") }
        let posterOnly = count > 20
        var frames: [UIImage] = []
        var ticks: [Int] = []
        var cost = 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceShouldCache: false
        ]
        for index in 0..<(posterOnly ? 1 : count) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw BackpackError.invalid("Could not decode the GIF preview.")
            }
            frames.append(UIImage(cgImage: image))
            cost += image.bytesPerRow * image.height
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] ?? [:]
            let delay = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                ?? gif[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.1
            guard delay.isFinite, (0...10).contains(delay) else {
                throw BackpackError.invalid("The preview has unsupported frame timing.")
            }
            ticks.append(max(2, Int((delay * 100).rounded())))
        }
        if posterOnly || frames.count == 1 {
            return GIFPreview(frames: frames, duration: 0, caption: count > 1 ? "Tap to animate" : "Still preview", cost: cost)
        }
        func gcd(_ first: Int, _ second: Int) -> Int {
            var a = first, b = second
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            return a
        }
        let unit = ticks.dropFirst().reduce(ticks[0], gcd)
        let repeats = ticks.map { $0 / unit }
        guard repeats.reduce(0, +) <= 120 else {
            return GIFPreview(frames: [frames[0]], duration: 0, caption: "Tap to animate", cost: cost)
        }
        // Repeated image references preserve variable GIF delays without decoding extra pixels.
        let playback = frames.indices.flatMap { Array(repeating: frames[$0], count: repeats[$0]) }
        return GIFPreview(frames: playback, duration: Double(ticks.reduce(0, +)) / 100,
            caption: "Animated preview", cost: cost)
    }
}

@MainActor
private enum GIFPreviewCache {
    static let images: NSCache<NSString, GIFPreview> = {
        let cache = NSCache<NSString, GIFPreview>()
        cache.totalCostLimit = 24_000_000
        cache.countLimit = 40
        return cache
    }()
}

@MainActor
private struct GIFPreviewImage: UIViewRepresentable {
    let preview: GIFPreview
    final class Coordinator { var preview: GIFPreview? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.layer.magnificationFilter = .nearest
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        guard context.coordinator.preview !== preview else { return }
        context.coordinator.preview = preview
        view.stopAnimating()
        view.animationImages = nil
        view.image = preview.frames.first
        if preview.frames.count > 1 {
            view.animationImages = preview.frames
            view.animationDuration = preview.duration
            view.animationRepeatCount = 0
            view.startAnimating()
        }
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        view.stopAnimating()
        view.animationImages = nil
        view.image = nil
        coordinator.preview = nil
    }
}

@MainActor
struct GIFThumbnail: View {
    @EnvironmentObject private var link: BluetoothLink
    let key: String
    let cache: Bool
    let load: @MainActor () async throws -> Data
    @State private var preview: GIFPreview?
    @State private var failure: String?
    init(key: String, cache: Bool = true, load: @escaping @MainActor () async throws -> Data) {
        self.key = key; self.cache = cache; self.load = load
    }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let preview {
                GIFPreviewImage(preview: preview).padding(4)
                Text(preview.caption).font(.caption2).padding(5).background(.black.opacity(0.75))
            } else if let failure {
                VStack(spacing: 5) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text(failure).font(.caption2).lineLimit(3)
                }.foregroundStyle(.secondary).padding(8)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .task(id: key) {
            preview = nil; failure = nil
            if cache, let cached = GIFPreviewCache.images.object(forKey: key as NSString) { preview = cached; return }
            do {
                let bytes = try await load()
                try Task.checkCancellation()
                let image = try GIFPreviewDecoder.thumbnail(bytes)
                if cache { GIFPreviewCache.images.setObject(image, forKey: key as NSString, cost: image.cost) }
                preview = image
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                link.note("GIF preview unavailable: \(error.localizedDescription)")
            }
        }
        .onDisappear { preview = nil }
    }
}
