import Foundation

public enum BackpackError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct Identity: Equatable {
    public let serial: String
    public let model: String
    public let firmware: String
}

public struct PanelSize: Equatable, Codable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct Slot: Identifiable, Equatable {
    public let id: Int
    public let identifier: [UInt8]
    public var occupied: Bool { identifier.contains { $0 != 0 } }
}

public struct Playback: Equatable, Codable {
    public let mode: UInt8
    public let index: UInt8
    public let ids: [UInt8]
    public init(mode: UInt8, index: UInt8, ids: [UInt8]) {
        self.mode = mode; self.index = index; self.ids = ids
    }
}

public enum Reply: Equatable {
    case status(UInt8)
    case identity(Identity)
    case size(PanelSize)
    case slots([Slot])
    case playback(Playback)
    case unknown
}

public struct Frame: Equatable {
    public let sequence: UInt16
    public let body: [UInt8]
}

public enum Wire {
    public static let gatt = [
        (service: "FFF0", write: "FFF2", notify: "FFF1"),
        (service: "FF00", write: "FF02", notify: "FF01")
    ]

    public static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    public static func le16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    public static func frame(_ body: [UInt8], sequence: UInt16) throws -> [UInt8] {
        guard body.count <= 65531 else { throw BackpackError.invalid("Packet body is too large.") }
        let bytes = [0xAA, 0x55, 0xFF, 0xFF] + le16(body.count + 4)
            + le16(Int(sequence)) + body
        let sum = bytes.reduce(0) { ($0 + Int($1)) & 65535 }
        return bytes + le16(sum)
    }

    public static func decode(_ bytes: [UInt8]) throws -> Frame {
        guard bytes.count >= 10, bytes[0] == 0xAA, bytes[1] == 0x55,
              u16(bytes, 4) + 6 == bytes.count else {
            throw BackpackError.invalid("Invalid packet header or length.")
        }
        let sum = bytes.dropLast(2).reduce(0) { ($0 + Int($1)) & 65535 }
        guard sum == u16(bytes, bytes.count - 2) else {
            throw BackpackError.invalid("Packet checksum mismatch.")
        }
        return Frame(sequence: UInt16(u16(bytes, 6)), body: Array(bytes[8..<(bytes.count - 2)]))
    }

    public static func length(_ value: Int) throws -> [UInt8] {
        guard (0...65535).contains(value) else { throw BackpackError.invalid("Invalid field length.") }
        if value < 128 { return [UInt8(value)] }
        if value < 256 { return [0x81, UInt8(value)] }
        return [0x82] + le16(value)
    }

    public static func field(_ bytes: [UInt8], at offset: Int) throws -> [UInt8] {
        guard offset < bytes.count else { throw BackpackError.invalid("Missing field length.") }
        let marker = bytes[offset]
        let count: Int
        let start: Int
        switch marker {
        case 0...127: count = Int(marker); start = offset + 1
        case 0x81:
            guard offset + 1 < bytes.count else { throw BackpackError.invalid("Truncated length.") }
            count = Int(bytes[offset + 1]); start = offset + 2
        case 0x82:
            guard offset + 2 < bytes.count else { throw BackpackError.invalid("Truncated length.") }
            count = u16(bytes, offset + 1); start = offset + 3
        default: throw BackpackError.invalid("Unsupported length encoding.")
        }
        guard start + count <= bytes.count else { throw BackpackError.invalid("Truncated data field.") }
        return Array(bytes[start..<(start + count)])
    }

    public static func reply(_ body: [UInt8]) throws -> Reply {
        guard body.count >= 3 else { return .unknown }
        if body[0] == 0x81 && [0x82, 0x84].contains(body[1]) { return .status(body[2]) }
        let dataResponse = body[0] == 0x81 && [0x83, 0x85].contains(body[1])
        let playbackPush = body[0] == 0xC1 && body[1] == 6 && body[2] == 0x36
        guard dataResponse || playbackPush else { return .unknown }
        switch body[2] {
        case 0x0A:
            let raw = String(bytes: body.dropFirst(3), encoding: .isoLatin1) ?? ""
            let text = raw.components(separatedBy: "power")[0]
            let values = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard values.count >= 3 else { throw BackpackError.invalid("Malformed identity response.") }
            return .identity(Identity(serial: values[0], model: values[1], firmware: values[2]))
        case 0x1B:
            let data = try field(body, at: 3)
            let offset = data.count == 22 && data.first == 0 ? 1 : 0
            guard data.count >= offset + 4 else { throw BackpackError.invalid("Missing panel dimensions.") }
            let width = u16(data, offset), height = u16(data, offset + 2)
            guard (1...1024).contains(width), (1...1024).contains(height) else {
                throw BackpackError.invalid("Invalid panel dimensions.")
            }
            return .size(PanelSize(width: width, height: height))
        case 0x35:
            let data = try field(body, at: 3)
            guard data.count.isMultiple(of: 21) else { throw BackpackError.invalid("Malformed slot records.") }
            var slots: [Slot] = []
            for offset in stride(from: 0, to: data.count, by: 21) {
                guard data[offset] < 60 else { throw BackpackError.invalid("Invalid slot identifier.") }
                slots.append(Slot(id: Int(data[offset]), identifier: Array(data[(offset + 5)..<(offset + 21)])))
            }
            return .slots(slots)
        case 0x36:
            let data = try field(body, at: 3)
            guard data.count >= 2 else { throw BackpackError.invalid("Missing playback configuration.") }
            return .playback(Playback(mode: data[0], index: data[1], ids: Array(data.dropFirst(2))))
        default: return .unknown
        }
    }

    public static func initialize(password: String, bare: Bool = false) throws -> [UInt8] {
        guard password.utf8.count <= 255, password.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw BackpackError.invalid("Panel passwords must be ASCII and at most 255 bytes.")
        }
        return [0xC1, 3, 0x0A, UInt8(password.utf8.count)] + Array(password.utf8)
            + (bare ? [] : [0x1B, 0, 4, 0, 6, 0])
    }

    public static func slotQuery(page: Int) throws -> [UInt8] {
        guard (0..<6).contains(page) else { throw BackpackError.invalid("Invalid slot page.") }
        return [0xC1, 3, 0x35, 10] + (0..<10).map { UInt8(page * 10 + $0) }
    }

    public static func play(_ value: Playback) throws -> [UInt8] {
        guard value.mode <= 2, value.ids.count <= 60, value.ids.allSatisfy({ $0 < 60 }) else {
            throw BackpackError.invalid("Unsupported playback configuration.")
        }
        return [0xC1, 2, 0x36, UInt8(value.ids.count + 2), value.mode, value.index] + value.ids
    }

    public static func playSingle(_ slot: Int) throws -> [UInt8] {
        try checkSlot(slot)
        return [0xC1, 2, 0x36, 0x3E, 1, UInt8(slot), 0] + (1...59).map(UInt8.init)
    }

    public static func checkSlot(_ value: Int) throws {
        guard (0..<60).contains(value) else { throw BackpackError.invalid("Slot must be 0 through 59.") }
    }

    public static func contentHash(_ data: [UInt8], slot: Int) throws -> [UInt8] {
        try checkSlot(slot)
        let seed = UInt32(truncatingIfNeeded: UInt64(slot + 1) * 2246822507)
        var result: [UInt8] = []
        for lane in 0..<5 {
            var hash = UInt32(2166136261) ^ UInt32(truncatingIfNeeded: UInt64(lane) * 2654435769) ^ seed
            for index in stride(from: lane, to: data.count, by: 5) {
                hash = (hash ^ UInt32(data[index])) &* 16777619
            }
            result += (0..<4).map { UInt8(truncatingIfNeeded: hash >> ($0 * 8)) }
        }
        return result
    }

    public static func upload(_ gif: [UInt8], slot: Int, size: PanelSize, playSeconds: Int? = nil) throws -> [[UInt8]] {
        try checkSlot(slot)
        guard gif.count >= 13, ["GIF87a", "GIF89a"].contains(String(bytes: gif.prefix(6), encoding: .ascii) ?? ""),
              u16(gif, 6) == size.width, u16(gif, 8) == size.height else {
            throw BackpackError.invalid("GIF dimensions must match the connected panel.")
        }
        let count = (gif.count + 959) / 960
        guard count <= 65535 else { throw BackpackError.invalid("GIF is too large for this protocol.") }
        let s = UInt8(slot)
        let dwell: [UInt8]
        if let playSeconds {
            guard (1...32767).contains(playSeconds) else { throw BackpackError.invalid("Stored dwell must be 1 through 32767 seconds.") }
            dwell = [0, 1] + le16(playSeconds)
        } else { dwell = [0, 0, 1, 0] }
        var messages: [[UInt8]] = [
            [0xC1, 2, 8, 2, 0, s, 9, 1, 1, 12, 1, s, 28, 6] + dwell + [3, 0,
             13, 1, 0, 29, 9, 0, 0, 0, 0] + le16(size.width) + le16(size.height) + [0],
            [0xC1, 2, 9, 1, 1, 12, 1, s, 13, 1, 0, 14, 1, 0, 20, 3, 1, 13, 3, 17, 4, 0, 1, 0, 10]
        ]
        for index in 0..<count {
            let chunk = Array(gif[(index * 960)..<min(gif.count, (index + 1) * 960)])
            let prefix: [UInt8] = [0xC1, 2, 9, 1, 1, 12, 1, s, 13, 1, 0, 14, 1, 0, 18, 7]
            messages.append(prefix + le16(count) + le16(index) + [0xC0, 3, 0, 19] + (try length(chunk.count)) + chunk)
        }
        messages.append([0xC1, 2, 0x35, 25, s, 19, 0, 0, 0] + (try contentHash(gif, slot: slot)))
        return messages
    }

    public static func bitmap(color: [UInt8], x: Int, y: Int, width: Int, height: Int, mask: [UInt8]) throws -> [UInt8] {
        guard color.count == 3, x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1024, y + height <= 1024,
              mask.count == ((width + 7) / 8) * height, mask.count <= 112 else {
            throw BackpackError.invalid("Invalid bitmap bounds or mask.")
        }
        return [0xC1, 2, 0x32] + le16(12 + mask.count) + color + le16(x) + le16(y)
            + le16(x + width - 1) + le16(y + height - 1) + mask
    }
}

public struct FrameAssembler {
    private var buffer: [UInt8] = []
    private var lastPush: TimeInterval = 0
    public init() {}
    public mutating func reset() { buffer = []; lastPush = 0 }

    public mutating func push(_ bytes: [UInt8], now: TimeInterval = Date().timeIntervalSince1970) -> (frames: [Frame], errors: [String]) {
        var frames: [Frame] = [], errors: [String] = []
        if !buffer.isEmpty && now - lastPush > 5 {
            errors.append("Discarded stale partial packet."); buffer = []
        }
        lastPush = now
        buffer += bytes
        while buffer.count >= 2 {
            if buffer[0] != 0xAA || buffer[1] != 0x55 {
                buffer.removeFirst(); errors.append("Resynchronized packet header."); continue
            }
            if buffer.count < 6 { break }
            let count = Wire.u16(buffer, 4) + 6
            if count < 10 || count > 65541 {
                buffer.removeFirst(2); errors.append("Invalid packet length."); continue
            }
            if buffer.count < count { break }
            let packet = Array(buffer.prefix(count))
            buffer.removeFirst(count)
            do { frames.append(try Wire.decode(packet)) }
            catch { errors.append(error.localizedDescription) }
        }
        return (frames, errors)
    }
}
