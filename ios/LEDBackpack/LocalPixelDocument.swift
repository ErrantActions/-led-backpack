import Foundation
import BackpackProtocol

struct LocalPixelColor: Codable, Equatable, Hashable, Sendable {
    var r, g, b, a: UInt8
    static let clear = Self(r: 0, g: 0, b: 0, a: 0)
    static let cyan = Self(r: 0, g: 255, b: 255, a: 255)
    var bytes: [UInt8] { [r, g, b, a] }
    func over(_ destination: Self) -> Self {
        let alpha = Int(a), back = Int(destination.a), denominator = alpha * 255 + back * (255 - alpha)
        guard denominator > 0 else { return .clear }
        func channel(_ front: UInt8, _ rear: UInt8) -> UInt8 {
            UInt8((Int(front) * alpha * 255 + Int(rear) * back * (255 - alpha) + denominator / 2) / denominator)
        }
        return Self(r: channel(r, destination.r), g: channel(g, destination.g), b: channel(b, destination.b),
            a: UInt8((denominator + 127) / 255))
    }
}

struct LocalPixelFrame: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var rgba: [UInt8]
    var centiseconds = 10
}

struct LocalPixelArtwork: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var frames: [LocalPixelFrame]
    // nil means one pass (no Netscape extension), zero means forever, positive values mean repeats.
    var repeats: Int? = nil
    var attribution: Attribution? = nil
    var byteCost: Int { frames.reduce(0) { $0 + $1.rgba.count } }
    static func blank(width: Int, height: Int) throws -> Self {
        guard (1...128).contains(width), (1...128).contains(height) else {
            throw BackpackError.invalid("Canvas dimensions must each be 1…128. Nothing was resized.")
        }
        return Self(width: width, height: height,
            frames: [LocalPixelFrame(rgba: Array(repeating: 0, count: width * height * 4))])
    }
    func validate() throws {
        guard (1...128).contains(width), (1...128).contains(height), (1...120).contains(frames.count),
              Set(frames.map(\.id)).count == frames.count,
              frames.allSatisfy({ $0.rgba.count == width * height * 4 && (0...65535).contains($0.centiseconds) }),
              repeats == nil || (0...65535).contains(repeats ?? -1), byteCost <= 8_000_000 else {
            throw BackpackError.invalid("Invalid artwork: 1…128 sides, 1…120 frames, 8 MB decoded RGBA and GIF-representable timing/repeats required.")
        }
        if let attribution {
            guard [attribution.source, attribution.author, attribution.license, attribution.licenseURL]
                .allSatisfy({ $0.utf16.count <= 2048 }) else { throw BackpackError.invalid("Artwork attribution exceeds its metadata budget.") }
        }
    }
}

struct LocalPixelPoint: Equatable, Sendable { let x, y: Int }
enum LocalPixelMapping {
    static func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double,
                      width: Int, height: Int) -> LocalPixelPoint? {
        guard x.isFinite, y.isFinite, viewWidth.isFinite, viewHeight.isFinite,
              viewWidth > 0, viewHeight > 0, (1...128).contains(width), (1...128).contains(height),
              x >= 0, y >= 0, x < viewWidth, y < viewHeight else { return nil }
        return LocalPixelPoint(x: Int(floor(x * Double(width) / viewWidth)),
            y: Int(floor(y * Double(height) / viewHeight)))
    }
}

struct LocalPixelDocument {
    private(set) var artwork: LocalPixelArtwork
    private(set) var selected = 0
    private struct Snapshot { let artwork: LocalPixelArtwork; let selected: Int }
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []
    private var strokeStart: Snapshot?
    private var previous: LocalPixelPoint?
    static let historyBudget = 24_000_000
    static let historyLimit = 30
    var historyBytes: Int { (undoStack + redoStack).reduce(0) { $0 + $1.artwork.byteCost } + (strokeStart?.artwork.byteCost ?? 0) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var current: LocalPixelFrame { artwork.frames[selected] }
    init() {
        artwork = LocalPixelArtwork(width: 64, height: 64,
            frames: [LocalPixelFrame(rgba: Array(repeating: 0, count: 64 * 64 * 4))])
    }
    init(artwork: LocalPixelArtwork) throws { try artwork.validate(); self.artwork = artwork }
    private var snapshot: Snapshot { Snapshot(artwork: artwork, selected: selected) }
    private mutating func trimHistory() {
        while undoStack.count + redoStack.count + (strokeStart == nil ? 0 : 1) > Self.historyLimit || historyBytes > Self.historyBudget {
            if !undoStack.isEmpty { undoStack.removeFirst() }
            else if !redoStack.isEmpty { redoStack.removeFirst() }
            else { break }
        }
    }
    mutating func endStroke() {
        if let before = strokeStart, before.artwork != artwork {
            undoStack.append(before); redoStack = []
        }
        strokeStart = nil; previous = nil; trimHistory()
    }
    private mutating func edit(_ body: (inout LocalPixelArtwork, inout Int) throws -> Void) throws {
        endStroke()
        var next = artwork, index = selected
        try body(&next, &index); try next.validate()
        guard next.frames.indices.contains(index) else { throw BackpackError.invalid("Selected frame no longer exists.") }
        guard next != artwork else { return }
        undoStack.append(snapshot); redoStack = []; artwork = next; selected = index; trimHistory()
    }
    mutating func select(_ index: Int) throws {
        guard artwork.frames.indices.contains(index) else { throw BackpackError.invalid("Choose an existing frame.") }
        endStroke(); selected = index
    }
    mutating func undo() throws {
        endStroke()
        guard let old = undoStack.popLast() else { throw BackpackError.invalid("Nothing to undo.") }
        redoStack.append(snapshot); artwork = old.artwork; selected = old.selected; trimHistory()
    }
    mutating func redo() throws {
        endStroke()
        guard let next = redoStack.popLast() else { throw BackpackError.invalid("Nothing to redo.") }
        undoStack.append(snapshot); artwork = next.artwork; selected = next.selected; trimHistory()
    }
    mutating func addFrame(copy: Bool) throws {
        try edit { value, index in
            guard value.frames.count < 120 else { throw BackpackError.invalid("120-frame limit reached. Remove a frame explicitly.") }
            var frame = value.frames[index]; frame.id = UUID()
            if !copy { frame.rgba = Array(repeating: 0, count: value.width * value.height * 4) }
            value.frames.insert(frame, at: index + 1); index += 1
        }
    }
    mutating func removeFrame() throws {
        try edit { value, index in
            guard value.frames.count > 1 else { throw BackpackError.invalid("Keep at least one frame.") }
            value.frames.remove(at: index); index = min(index, value.frames.count - 1)
        }
    }
    mutating func moveFrame(_ delta: Int) throws {
        try edit { value, index in
            guard [-1, 1].contains(delta), value.frames.indices.contains(index + delta) else {
                throw BackpackError.invalid("Move one place inside the timeline.")
            }
            value.frames.swapAt(index, index + delta); index += delta
        }
    }
    mutating func setTiming(_ centiseconds: Int) throws {
        guard (1...65535).contains(centiseconds) else { throw BackpackError.invalid("Edited delays must be 1…65535 whole centiseconds (0.01…655.35 seconds).") }
        try edit { value, index in value.frames[index].centiseconds = centiseconds }
    }
    mutating func setRepeats(_ repeats: Int?) throws {
        guard repeats == nil || (0...65535).contains(repeats ?? -1) else { throw BackpackError.invalid("GIF repeats must be 0…65535, or once.") }
        try edit { value, _ in value.repeats = repeats }
    }
    private func check(_ point: LocalPixelPoint) throws {
        guard (0..<artwork.width).contains(point.x), (0..<artwork.height).contains(point.y) else {
            throw BackpackError.invalid("Coordinate is outside the actual canvas. Previous art is unchanged.")
        }
    }
    func sample(_ point: LocalPixelPoint) throws -> LocalPixelColor {
        try check(point); return Self.color(current.rgba, (point.y * artwork.width + point.x) * 4)
    }
    private static func color(_ bytes: [UInt8], _ offset: Int) -> LocalPixelColor {
        LocalPixelColor(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], a: bytes[offset + 3])
    }
    mutating func paint(_ point: LocalPixelPoint, color: LocalPixelColor, radius: Int) throws {
        try check(point)
        guard (0...4).contains(radius) else { throw BackpackError.invalid("Brush radius must be 0…4.") }
        if strokeStart == nil { strokeStart = snapshot; trimHistory() }
        var x = previous?.x ?? point.x, y = previous?.y ?? point.y
        let dx = abs(point.x - x), dy = -abs(point.y - y)
        let sx = x < point.x ? 1 : -1, sy = y < point.y ? 1 : -1
        var error = dx + dy
        while true {
            for yy in max(0, y - radius)...min(artwork.height - 1, y + radius) {
                for xx in max(0, x - radius)...min(artwork.width - 1, x + radius) {
                    let offset = (yy * artwork.width + xx) * 4
                    // A brush sets the authored RGBA value; stamping below uses source-over.
                    artwork.frames[selected].rgba.replaceSubrange(offset..<offset + 4, with: color.bytes)
                }
            }
            if x == point.x && y == point.y { break }
            let twice = 2 * error
            if twice >= dy { error += dy; x += sx }
            if twice <= dx { error += dx; y += sy }
        }
        previous = point
    }
    mutating func fill(_ point: LocalPixelPoint, color: LocalPixelColor) throws {
        try check(point)
        try edit { value, index in
            let target = Self.color(value.frames[index].rgba, (point.y * value.width + point.x) * 4)
            guard target != color else { return }
            var queue = [point.y * value.width + point.x], cursor = 0
            var visited = Set(queue)
            while cursor < queue.count {
                let pixel = queue[cursor]; cursor += 1
                let offset = pixel * 4
                guard Self.color(value.frames[index].rgba, offset) == target else { continue }
                value.frames[index].rgba.replaceSubrange(offset..<offset + 4, with: color.bytes)
                let x = pixel % value.width, y = pixel / value.width
                let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                for (xx, yy) in neighbors where (0..<value.width).contains(xx) && (0..<value.height).contains(yy) {
                    let next = yy * value.width + xx
                    if visited.insert(next).inserted { queue.append(next) }
                }
            }
        }
    }
    mutating func stamp(rgba: [UInt8], width: Int, height: Int, at point: LocalPixelPoint) throws {
        guard (1...128).contains(width), (1...128).contains(height), rgba.count == width * height * 4,
              point.x > -width, point.y > -height, point.x < artwork.width, point.y < artwork.height else {
            throw BackpackError.invalid("Sprite must be bounded RGBA and overlap the canvas. No resize or placement was guessed.")
        }
        try edit { value, index in
            for y in 0..<height {
                for x in 0..<width {
                    let xx = point.x + x, yy = point.y + y
                    guard (0..<value.width).contains(xx), (0..<value.height).contains(yy) else { continue }
                    let offset = (yy * value.width + xx) * 4
                    let color = Self.color(rgba, (y * width + x) * 4).over(Self.color(value.frames[index].rgba, offset))
                    value.frames[index].rgba.replaceSubrange(offset..<offset + 4, with: color.bytes)
                }
            }
        }
    }
    mutating func dim(_ amount: Double) throws {
        guard amount.isFinite, (0...1).contains(amount) else { throw BackpackError.invalid("Authored dim must be 0…1.") }
        try edit { value, index in
            for offset in stride(from: 0, to: value.frames[index].rgba.count, by: 4) {
                for channel in 0..<3 { value.frames[index].rgba[offset + channel] = UInt8((Double(value.frames[index].rgba[offset + channel]) * amount).rounded()) }
            }
        }
    }
    mutating func replacePaletteColor(_ old: LocalPixelColor, with new: LocalPixelColor) throws {
        try edit { value, index in
            for offset in stride(from: 0, to: value.frames[index].rgba.count, by: 4)
            where Self.color(value.frames[index].rgba, offset) == old {
                value.frames[index].rgba.replaceSubrange(offset..<offset + 4, with: new.bytes)
            }
        }
    }
}
