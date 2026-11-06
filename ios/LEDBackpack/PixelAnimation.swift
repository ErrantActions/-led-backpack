import Foundation
import BackpackProtocol

struct DrawingFrame: Identifiable, Equatable {
    let id: UUID
    var pixels: PixelFrame
    var delay: Double
    init(pixels: PixelFrame, delay: Double = 0.1) {
        id = UUID(); self.pixels = pixels; self.delay = delay
    }
}

struct PixelDrawingDocument {
    private(set) var frames = [DrawingFrame(pixels: .black(PanelSize(width: 64, height: 64)))]
    private(set) var selected = 0
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var stroke = false
    private var previous: (x: Int, y: Int)?
    private struct Snapshot { let frames: [DrawingFrame]; let selected: Int }
    var current: DrawingFrame { frames[selected] }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private mutating func checkpoint() {
        undoStack.append(Snapshot(frames: frames, selected: selected))
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack = []
    }
    mutating func endStroke() { stroke = false; previous = nil }
    mutating func select(_ index: Int) throws {
        guard frames.indices.contains(index) else { throw BackpackError.invalid("Select an existing frame.") }
        endStroke(); selected = index
    }
    mutating func resetCanvas(_ size: PanelSize) throws {
        guard [PanelSize(width: 16, height: 16), PanelSize(width: 64, height: 64),
               PanelSize(width: 96, height: 128)].contains(size) else {
            throw BackpackError.invalid("Choose a supported panel size.")
        }
        endStroke(); checkpoint()
        frames = [DrawingFrame(pixels: .black(size))]; selected = 0
    }
    mutating func addFrame(copy: Bool) throws {
        guard frames.count < 120 else { throw BackpackError.invalid("Animations support at most 120 frames.") }
        endStroke(); checkpoint()
        let next = DrawingFrame(pixels: copy ? current.pixels : .black(current.pixels.size), delay: current.delay)
        frames.insert(next, at: selected + 1); selected += 1
    }
    mutating func deleteFrame() throws {
        guard frames.count > 1 else { throw BackpackError.invalid("Keep at least one frame.") }
        endStroke(); checkpoint(); frames.remove(at: selected); selected = min(selected, frames.count - 1)
    }
    mutating func moveFrame(by delta: Int) throws {
        let target = selected + delta
        guard frames.indices.contains(target), delta == -1 || delta == 1 else {
            throw BackpackError.invalid("Move the selected frame one position within the timeline.")
        }
        endStroke(); checkpoint()
        let frame = frames.remove(at: selected); frames.insert(frame, at: target); selected = target
    }
    mutating func setDelay(_ delay: Double) throws {
        guard delay.isFinite, (0.02...10).contains(delay) else {
            throw BackpackError.invalid("Frame delays must be 0.02 to 10 seconds.")
        }
        endStroke(); checkpoint(); frames[selected].delay = delay
    }
    func sample(x: Int, y: Int) throws -> RGB8 {
        let size = current.pixels.size
        guard (0..<size.width).contains(x), (0..<size.height).contains(y) else {
            throw BackpackError.invalid("Pick a color inside the canvas.")
        }
        let offset = (y * size.width + x) * 3
        return RGB8(r: current.pixels.rgb[offset], g: current.pixels.rgb[offset + 1], b: current.pixels.rgb[offset + 2])
    }
    mutating func paint(x: Int, y: Int, color: RGB8, radius: Int) throws {
        let size = current.pixels.size
        guard (0..<size.width).contains(x), (0..<size.height).contains(y), (0...4).contains(radius) else {
            throw BackpackError.invalid("Brush coordinates or size are outside the canvas.")
        }
        if !stroke { checkpoint(); stroke = true }
        var px = previous?.x ?? x, py = previous?.y ?? y
        let dx = abs(x - px), dy = -abs(y - py), sx = px < x ? 1 : -1, sy = py < y ? 1 : -1
        var error = dx + dy
        while true {
            for yy in max(0, py - radius)...min(size.height - 1, py + radius) {
                for xx in max(0, px - radius)...min(size.width - 1, px + radius) {
                    let offset = (yy * size.width + xx) * 3
                    frames[selected].pixels.rgb.replaceSubrange(offset..<(offset + 3), with: color.bytes)
                }
            }
            if px == x && py == y { break }
            let twice = 2 * error
            if twice >= dy { error += dy; px += sx }
            if twice <= dx { error += dx; py += sy }
        }
        previous = (x, y)
    }
    mutating func undo() throws {
        guard let old = undoStack.popLast() else { throw BackpackError.invalid("Nothing to undo.") }
        endStroke(); redoStack.append(Snapshot(frames: frames, selected: selected))
        frames = old.frames; selected = old.selected
    }
    mutating func redo() throws {
        guard let next = redoStack.popLast() else { throw BackpackError.invalid("Nothing to redo.") }
        endStroke(); undoStack.append(Snapshot(frames: frames, selected: selected))
        frames = next.frames; selected = next.selected
    }
}
