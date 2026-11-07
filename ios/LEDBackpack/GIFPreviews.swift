import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

// Frames and timing are immutable; workers only create images, and views consume them on MainActor.
final class GIFPreview: NSObject, @unchecked Sendable {
    let frames: [UIImage]
    let duration: Double
    let frameEnds: [Double]
    let cost: Int
    let cycles: Int?
    init(frames: [UIImage], delays: [Double], cost: Int, cycles: Int? = nil) {
        self.frames = frames
        var elapsed = 0.0
        self.frameEnds = delays.map { elapsed += $0; return elapsed }
        self.duration = frames.count > 1 ? elapsed : 0
        self.cost = cost
        self.cycles = cycles
    }

    func frameIndex(at elapsed: TimeInterval) -> Int {
        guard duration > 0, elapsed.isFinite else { return 0 }
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        return frameEnds.firstIndex(where: { phase < $0 }) ?? (frames.count - 1)
    }
}

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
        try decode(data, maximumPixelSize: 160, pixelBudget: 4_000_000, costLimit: 8_000_000, phone: false)
    }

    static func phoneDisplay(_ data: Data) throws -> GIFPreview {
        try decode(data, maximumPixelSize: 2048, pixelBudget: 32_000_000, costLimit: 40_000_000, phone: true)
    }

    private static func decode(_ data: Data, maximumPixelSize: Int, pixelBudget: Double, costLimit: Int, phone: Bool) throws -> GIFPreview {
        guard data.count <= 5_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw BackpackError.invalid("This image cannot be previewed.")
        }
        try checkDimensions(source)
        if phone {
            guard let raw = CGImageSourceGetType(source), let type = UTType(raw as String),
                  [.gif, .png, .jpeg, .webP].contains(type) else { throw BackpackError.invalid("Phone display supports GIF or PNG/JPEG/WebP stills only.") }
        }
        let count = CGImageSourceGetCount(source)
        guard (1...1200).contains(count) else {
            throw BackpackError.invalid("The preview supports 1 to 1200 frames.")
        }
        let structure = GIFStructure.isGIF(data) ? try GIFStructure.inspect(data) : nil
        guard structure == nil || structure?.frames.count == count else { throw BackpackError.invalid("GIF preview timing/image frame counts do not match.") }
        if phone && count > 1 {
            guard let type = CGImageSourceGetType(source), type as String == UTType.gif.identifier else {
                throw BackpackError.invalid("Use GIF for phone animations; other supported images must be stills.")
            }
        }
        var frames: [UIImage] = []
        var delays: [Double] = []
        var cost = 0
        // Bound decoded pixels across the whole animation, not just its first frame.
        let budgetSize = min(maximumPixelSize, Int(sqrt(pixelBudget / Double(count * 4))))
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let originalSize = max(first[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
            first[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        let pixelSize = phone ? min(budgetSize, originalSize) : budgetSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCache: false
        ]
        for index in 0..<count {
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  (1...4096).contains(width), (1...4096).contains(height) else { throw BackpackError.invalid("A frame exceeds the bounded phone/preview dimensions.") }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw BackpackError.invalid("Could not decode the GIF preview.")
            }
            frames.append(UIImage(cgImage: image))
            cost += image.bytesPerRow * image.height
            guard cost <= costLimit else {
                throw BackpackError.invalid("The animation exceeds the preview memory budget.")
            }
            delays.append(structure?.frames[index].previewDelay ?? 0.1)
        }
        var cycles: Int?
        if phone {
            let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:]
            let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            if let repeats = gif?[kCGImagePropertyGIFLoopCount as String] as? Int {
                guard (0...65535).contains(repeats) else { throw BackpackError.invalid("Unsupported GIF repeat count.") }
                cycles = repeats == 0 ? nil : repeats + 1
            } else { cycles = 1 }
        }
        return GIFPreview(frames: frames, delays: delays, cost: cost, cycles: cycles)
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
    let index: Int
    final class Coordinator {
        var preview: GIFPreview?
        var index: Int?
    }
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
        guard context.coordinator.preview !== preview || context.coordinator.index != index else { return }
        context.coordinator.preview = preview
        context.coordinator.index = index
        view.image = preview.frames[index]
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        view.image = nil
        coordinator.preview = nil
        coordinator.index = nil
    }
}

@MainActor
struct GIFThumbnail: View {
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.scenePhase) private var scenePhase
    let key: String
    let cache: Bool
    let load: @MainActor () async throws -> Data
    @State private var preview: GIFPreview?
    @State private var failure: String?
    @State private var visible = false
    init(key: String, cache: Bool = true, load: @escaping @MainActor () async throws -> Data) {
        self.key = key; self.cache = cache; self.load = load
    }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let preview {
                TimelineView(.animation(minimumInterval: 0.02,
                    paused: !visible || scenePhase != .active || preview.duration == 0)) { context in
                    GIFPreviewImage(preview: preview,
                        index: preview.frameIndex(at: context.date.timeIntervalSinceReferenceDate))
                }.accessibilityHidden(true)
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
        .onAppear { visible = true }
        .onDisappear { visible = false; preview = nil }
    }
}
