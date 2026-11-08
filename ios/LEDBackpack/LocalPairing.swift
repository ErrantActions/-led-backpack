import Foundation
import CryptoKit
import BackpackProtocol

struct LocalPairCode: Codable, Equatable, Sendable {
    let version: Int
    let id: UUID
    let key, hint: String
    let expiresAt: String
    func validate(now: Date) throws {
        let expiry = try CatalogEventTime.parse(expiresAt)
        guard version == 1, expiry > now, expiry.timeIntervalSince(now) <= 180,
              try PhoneSwapWire.bytes(key).contains(where: { $0 != 0 }), NearbyTokenPolicy.valid(hint) else {
            throw BackpackError.invalid("Unsupported/expired local pair code. Use a fresh code; no online friend identity is inferred.")
        }
    }
    func text() throws -> String { "nyan-local-pair:1:" + PhoneSwapWire.b64(try PhoneSwapWire.encoder().encode(self)) }
    static func parse(_ text: String, now: Date) throws -> Self {
        let prefix = "nyan-local-pair:1:"
        guard text.utf8.count <= 1200, text.hasPrefix(prefix) else { throw BackpackError.invalid("Paste only an explicit local-pair code; no URL/token/profile fallback.") }
        let raw = String(text.dropFirst(prefix.count))
        guard raw.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - raw.count % 4) % 4)),
              PhoneSwapWire.b64(data) == raw else { throw BackpackError.invalid("Noncanonical local-pair encoding.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(now: now)
        guard try value.text() == text else { throw BackpackError.invalid("Unexpected local-pair fields or alternate encoding.") }
        return value
    }
    static func comparison(_ first: Self, _ second: Self) throws -> String {
        guard first.id != second.id, first.key != second.key, first.hint != second.hint else { throw BackpackError.invalid("Cannot pair with your own code/key or reused hint.") }
        let strings = try [first.text(), second.text()].sorted()
        let hash = LocalSwapOriginal.digest(Data(("nyan.local-pair.compare.v1\n" + strings.joined(separator: "\n")).utf8))
        let prefix = String(hash.prefix(16))
        return stride(from: 0, to: 16, by: 4).map { String(prefix.dropFirst($0).prefix(4)) }.joined(separator: " ")
    }
    func contact() -> PhoneSwapContact {
        PhoneSwapContact(id: id, displayName: "Locally paired device — account identity unverified",
            canRequestFriendship: false, publicKey: key, token: hint, tokenExpiresAtISO: expiresAt)
    }
}
struct LocalPairApplicationState {
    var applying = false
    var localApplied = false
    var localReceiptSent = false
    var peerApplied = false
    var canApply: Bool { !applying && !localApplied }
    var confirmed: Bool { !applying && localApplied && localReceiptSent && peerApplied }
}
struct LocalRangeStability {
    private var previous: (distance: Float, time: Double)?
    private var start: Double?
    mutating func reset() { previous = nil; start = nil }
    func fresh(uptime: Double) -> Bool {
        guard let previous, let start, uptime.isFinite, uptime >= previous.time,
              uptime < previous.time + 2, previous.time - start >= 1 else { return false }
        return true
    }
    func requireFresh(uptime: Double) throws {
        guard fresh(uptime: uptime) else {
            throw BackpackError.invalid("The local NI sample expired before its queued operation; no stale nearby claim.")
        }
    }
    mutating func observe(distance: Float?, uptime: Double) -> Bool {
        guard let distance, distance.isFinite, (0.3...3).contains(distance), uptime.isFinite, uptime >= 0,
              previous == nil || (uptime > previous!.time && uptime - previous!.time <= 2) else {
            reset(); return false
        }
        if let previous, abs(previous.distance - distance) > 0.25 { start = nil }
        if start == nil { start = uptime }
        previous = (distance, uptime)
        return uptime - (start ?? uptime) >= 1
    }
}
