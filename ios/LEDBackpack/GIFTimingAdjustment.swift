import Foundation
import BackpackProtocol

struct GIFTimingAdjustment: Equatable, Sendable {
    var speed = 1.0
    var uniformCentiseconds: Int?
    func validate() throws {
        guard speed.isFinite, (0.25...4).contains(speed),
              uniformCentiseconds == nil || (1...65535).contains(uniformCentiseconds ?? 0) else {
            throw BackpackError.invalid("Choose playback speed0.25–4× and a valid1–65535-centisecond frame delay.")
        }
    }
    func applying(to original: Data) throws -> Data {
        try validate()
        let structure = try GIFStructure.inspect(original)
        guard original.count <= 5_000_000 else { throw BackpackError.invalid("Timing editing supports GIF originals up to5MB.") }
        if speed == 1 && uniformCentiseconds == nil { return original }
        var result = original
        for frame in structure.frames.reversed() {
            try Task.checkCancellation()
            let seconds = Double(uniformCentiseconds ?? max(1, frame.delayCentiseconds ?? 10)) / 100 / speed
            guard seconds.isFinite, (0.01...655.35).contains(seconds) else {
                throw BackpackError.invalid("Adjusted frame timing exceeds GIF's0.01–655.35-second range. Original retained; no silent clamp.")
            }
            let centiseconds = Int((seconds * 100).rounded())
            guard (1...65535).contains(centiseconds) else { throw BackpackError.invalid("Adjusted GIF timing cannot be represented exactly in centiseconds.") }
            let low = UInt8(truncatingIfNeeded: centiseconds), high = UInt8(truncatingIfNeeded: centiseconds >> 8)
            if let offset = frame.controlOffset {
                result[offset + 4] = low; result[offset + 5] = high
            } else {
                result.insert(contentsOf: [0x21,0xF9,4,0,low,high,0,0], at: frame.imageOffset)
                result.replaceSubrange(0..<6, with: Data("GIF89a".utf8))
            }
        }
        guard result.count <= 5_000_000 else { throw BackpackError.invalid("Timed copy exceeds5MB; original unchanged.") }
        _ = try GIFStructure.inspect(result)
        return result
    }
    static func cycleSeconds(_ data: Data) throws -> Double {
        try GIFStructure.inspect(data).frames.reduce(0) { $0 + Double(max(1, $1.delayCentiseconds ?? 10)) / 100 }
    }
    static func repeatingCopy(_ original: Data, totalLoops: Int?) throws -> Data {
        guard totalLoops == nil || (1...100).contains(totalLoops ?? 0) else { throw BackpackError.invalid("Choose1–100total GIF loops.") }
        let value = totalLoops.map { $0 - 1 } ?? 0
        let structure = try GIFStructure.inspect(original)
        var result = original
        if totalLoops == 1 {
            for range in structure.repeatExtensionRanges.reversed() { result.removeSubrange(range) }
        } else if !structure.repeatValueOffsets.isEmpty {
            for offset in structure.repeatValueOffsets {
                result[offset] = UInt8(truncatingIfNeeded: value)
                result[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
        } else {
            let flags = original[10], table = flags & 128 == 0 ? 0 : 3 * (1 << (Int(flags & 7) + 1))
            let block = [UInt8](Data("NETSCAPE2.0".utf8))
            result.insert(contentsOf: [0x21,0xFF,11] + block + [3,1,UInt8(truncatingIfNeeded: value),UInt8(truncatingIfNeeded: value >> 8),0], at: 13 + table)
            result.replaceSubrange(0..<6, with: Data("GIF89a".utf8))
        }
        guard result.count <= 5_000_000 else { throw BackpackError.invalid("Repeated copy exceeds5MB; original unchanged.") }
        _ = try GIFStructure.inspect(result)
        return result
    }
}
enum BackpackPresentationLimit: String, CaseIterable, Identifiable, Sendable {
    case time, loops
    var id: String { rawValue }
}
struct BackpackSendOptions: Equatable, Sendable {
    var timing = GIFTimingAdjustment()
    var programSeconds = 10
    var limit = BackpackPresentationLimit.time
    var totalLoops = 3
    func validate() throws {
        try timing.validate()
        guard (1...600).contains(programSeconds), (1...100).contains(totalLoops) else { throw BackpackError.invalid("Choose1–600seconds or1–100GIF loops.") }
    }
    func duration(for data: Data) throws -> Int {
        try validate()
        if limit == .time { return programSeconds }
        let duration = try GIFTimingAdjustment.cycleSeconds(data) * Double(totalLoops)
        guard duration.isFinite, duration > 0, ceil(duration) <= 600 else { throw BackpackError.invalid("Requested loops exceed600seconds; choose fewer loops or adjust frame speed.") }
        return max(1, Int(ceil(duration)))
    }
}
struct BackpackDirectSendPlan: Identifiable {
    let id = UUID()
    let inventory: BackpackErasePlan
    let size: PanelSize
    let slots: [Int]
    init(inventory: BackpackErasePlan, size: PanelSize, count: Int) throws {
        guard (1...20).contains(count), size.width > 0, size.height > 0 else { throw BackpackError.invalid("Choose1–20GIFs and a readable panel size.") }
        let free = inventory.records.filter { (2...54).contains($0.id) && !$0.occupied }.sorted { $0.id < $1.id }
        guard free.count >= count else { throw BackpackError.invalid("Not enough empty ordinary slots. Use Send queue to deliberately review overwrites; no occupied/reserved slot is chosen automatically.") }
        self.inventory = inventory; self.size = size; slots = Array(free.prefix(count).map(\.id))
    }
    func verifies(_ playback: Playback) -> Bool {
        playback.mode == 2 && playback.ids == slots.map(UInt8.init)
    }
}
