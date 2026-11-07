import SwiftUI
import BackpackProtocol

enum LocalPixelPlayback {
    static func position(_ artwork: LocalPixelArtwork, elapsed: Double) -> (index: Int, finished: Bool) {
        let delays = artwork.frames.map { Double(max(1, $0.centiseconds)) / 100 }
        let duration = delays.reduce(0, +)
        guard elapsed.isFinite, elapsed >= 0, duration > 0 else { return (0, false) }
        let cycles: Int?
        if let repeats = artwork.repeats { cycles = repeats == 0 ? nil : repeats + 1 }
        else { cycles = 1 }
        if let cycles, elapsed >= duration * Double(cycles) { return (artwork.frames.count - 1, true) }
        var phase = elapsed.truncatingRemainder(dividingBy: duration)
        for (index, delay) in delays.enumerated() {
            if phase < delay { return (index, false) }
            phase -= delay
        }
        return (artwork.frames.count - 1, false)
    }
}

final class LocalPixelRaster: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

enum LocalPixelPreviewRenderer {
    static func render(frame: LocalPixelFrame, width: Int, height: Int, brightness: Double, blackFloor: Double) throws -> LocalPixelRaster {
        guard brightness.isFinite, blackFloor.isFinite, (0...1).contains(brightness), (0...0.2).contains(blackFloor),
              (1...128).contains(width), (1...128).contains(height),
              frame.rgba.count == width * height * 4 else { throw BackpackError.invalid("Invalid local preview parameters.") }
        var rgba = frame.rgba
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            for channel in 0..<3 {
                let value = Double(rgba[offset + channel]) / 255
                rgba[offset + channel] = UInt8(((blackFloor + value * (1 - blackFloor)) * brightness * 255).rounded())
            }
        }
        return LocalPixelRaster(try LocalPixelCodec.image(rgba, width: width, height: height))
    }
}

@MainActor
struct LocalPixelCanvas: View {
    let frame: LocalPixelFrame
    let width: Int
    let height: Int
    let brightness: Double
    let blackFloor: Double
    let grid: Bool
    let revision: UUID
    let paint: (LocalPixelPoint) -> Void
    let end: () -> Void
    @State private var raster: UIImage?
    @State private var error: String?
    private struct Key: Hashable {
        let revision: UUID
        let frame: UUID
        let brightness: Double
        let floor: Double
    }
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / CGFloat(width), geometry.size.height / CGFloat(height))
            let canvasWidth = CGFloat(width) * scale
            let canvasHeight = CGFloat(height) * scale
            ZStack {
                Canvas { context, size in
                    let cell = 12.0
                    for y in 0...Int(size.height / cell) {
                        for x in 0...Int(size.width / cell) {
                            let rect = CGRect(x: Double(x) * cell, y: Double(y) * cell, width: cell, height: cell)
                            context.fill(Path(rect), with: .color((x + y).isMultiple(of: 2) ? .gray.opacity(0.35) : .gray.opacity(0.15)))
                        }
                    }
                }
                if let raster {
                    Image(uiImage: raster).interpolation(.none).resizable()
                        .frame(width: canvasWidth, height: canvasHeight)
                }
                if grid {
                    Canvas { context, size in
                        var lines = Path()
                        for x in 0...width {
                            let xx = CGFloat(x) * size.width / CGFloat(width)
                            lines.move(to: CGPoint(x: xx, y: 0)); lines.addLine(to: CGPoint(x: xx, y: size.height))
                        }
                        for y in 0...height {
                            let yy = CGFloat(y) * size.height / CGFloat(height)
                            lines.move(to: CGPoint(x: 0, y: yy)); lines.addLine(to: CGPoint(x: size.width, y: yy))
                        }
                        context.stroke(lines, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                    }.allowsHitTesting(false)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange).padding() }
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if let point = LocalPixelMapping.point(x: Double(value.location.x), y: Double(value.location.y),
                    viewWidth: Double(canvasWidth), viewHeight: Double(canvasHeight), width: width, height: height) {
                    paint(point)
                } else { end() }
            }.onEnded { _ in end() })
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(height: 320)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transparent RGBA canvas, \(width) columns by \(height) rows. Use coordinate controls below to edit.")
        .task(id: Key(revision: revision, frame: frame.id, brightness: brightness, floor: blackFloor)) {
            raster = nil; error = nil
            let capturedFrame = frame, w = width, h = height, light = brightness, floor = blackFloor
            do {
                let result = try await LocalPixelWork.run {
                    try LocalPixelPreviewRenderer.render(frame: capturedFrame, width: w, height: h, brightness: light, blackFloor: floor)
                }
                try Task.checkCancellation()
                raster = UIImage(cgImage: result.image); error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; raster = nil }
            }
        }
    }
}
