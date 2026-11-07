import Foundation
import CryptoKit
import BackpackProtocol

enum PhoneSwapWire {
    static let maximumGIF = 131072
    static let chunkBytes = 512
    static let maximumPacket = 4096
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    static func b64(_ data: Data) -> String { NativeIntegrityBinding.base64URL(data) }
    static func randomNonce() -> String { b64(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
    static func bytes(_ value: String) throws -> Data {
        guard NearbyTokenPolicy.valid(value), let result = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=") else { throw BackpackError.invalid("Invalid 32-byte game binding.") }
        return result
    }
    struct Hello: Codable, Sendable {
        let version: Int
        let sessionID: UUID
        let initiatorToken, responderToken, nonce: String
        let response: Bool
    }
    struct Outer: Codable, Sendable {
        let hello: Hello?
        let counter: UInt64?
        let encrypted: Data?
    }
    struct Message: Codable, Sendable {
        let kind: String
        var hash: String? = nil
        var length: Int? = nil
        var index: Int? = nil
        var bytes: Data? = nil
        var credit: Credit? = nil
        var interaction: String? = nil
        var preset: String? = nil
        var role: String? = nil
        var mediaConsent: Bool? = nil
        var sceneReady: Bool? = nil
        var ticks: [Double]? = nil
    }
    struct Credit: Codable, Equatable, Sendable {
        let author, license: String
        init(_ value: Attribution?) throws {
            author = value?.author ?? ""; license = value?.license ?? ""
            for field in [author, license] {
                guard field.utf16.count <= 120, !field.contains("://"), !field.contains("@"), !field.contains("\\"),
                      !field.lowercased().contains("token="), !field.lowercased().contains("bearer "),
                      field.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                    throw BackpackError.invalid("Chosen GIF credit contains private URL/credential/contact-like metadata. Use a candidate with safe author/license credit; original remains unchanged.")
                }
            }
        }
        func attribution() throws -> Attribution {
            let result = Attribution(source: "User-selected peer GIF", author: author, license: license, licenseURL: "")
            _ = try Credit(result); return result
        }
    }
    static func packet(_ value: Outer) throws -> Data {
        let data = try encoder().encode(value)
        guard (1...maximumPacket).contains(data.count) else { throw BackpackError.invalid("Game packet exceeds its bounded framing.") }
        let n = UInt32(data.count)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) + data
    }
}
struct PhoneSwapFrameDecoder {
    private var buffer = Data()
    mutating func push(_ data: Data) throws -> [PhoneSwapWire.Outer] {
        guard data.count <= 4096, buffer.count + data.count <= 8196 else { throw BackpackError.invalid("Game GATT/frame buffer exceeded.") }
        buffer.append(data)
        var output: [PhoneSwapWire.Outer] = []
        while buffer.count >= 4 {
            let prefix = [UInt8](buffer.prefix(4))
            let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(prefix[$1]) << ($1 * 8) }
            guard length > 0, length <= PhoneSwapWire.maximumPacket else { throw BackpackError.invalid("Unsupported game frame length.") }
            guard buffer.count >= 4 + Int(length) else { break }
            let raw = Data(buffer.dropFirst(4).prefix(Int(length)))
            let value = try JSONDecoder().decode(PhoneSwapWire.Outer.self, from: raw)
            guard (value.hello != nil) != (value.encrypted != nil),
                  value.hello == nil || value.counter == nil else { throw BackpackError.invalid("Ambiguous game envelope.") }
            output.append(value); buffer = Data(buffer.dropFirst(4 + Int(length)))
        }
        return output
    }
}
struct PhoneSwapCipher {
    private let sendKey, receiveKey: SymmetricKey
    private let transcript: Data
    private let outgoingRole, incomingRole: UInt8
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    let transcriptHash: String
    init(privateKey: Curve25519.KeyAgreement.PrivateKey, initiator: PhoneSwapContact, responder: PhoneSwapContact,
        first: PhoneSwapWire.Hello, second: PhoneSwapWire.Hello, origin: String, isInitiator: Bool,
        domain: String = "nyan.phone-swap.v1", binding: [String] = []) throws {
        guard ["nyan.phone-swap.v1","nyan.accepted-friend.v1","nyan.local-pair.v1"].contains(domain),
              domain == "nyan.phone-swap.v1" || !binding.isEmpty else { throw BackpackError.invalid("Missing purpose-separated peer-session transcript.") }
        guard first.version == 1, second.version == 1, !first.response, second.response,
              first.sessionID == second.sessionID,
              first.initiatorToken == initiator.token, first.responderToken == responder.token,
              second.initiatorToken == first.initiatorToken, second.responderToken == first.responderToken,
              first.nonce != second.nonce, initiator.id != responder.id, initiator.publicKey != responder.publicKey else {
            throw BackpackError.invalid("Game role/session/token transcript binding mismatch.")
        }
        _ = try PhoneSwapWire.bytes(first.nonce); _ = try PhoneSwapWire.bytes(second.nonce)
        let own = isInitiator ? initiator : responder, peer = isInitiator ? responder : initiator
        guard privateKey.publicKey.rawRepresentation == (try PhoneSwapWire.bytes(own.publicKey)) else { throw BackpackError.invalid("Local registered game key no longer matches.") }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: PhoneSwapWire.bytes(peer.publicKey)))
        guard shared.withUnsafeBytes({ $0.contains(where: { $0 != 0 }) }) else { throw BackpackError.invalid("Low-order/invalid peer key cannot establish a game cipher.") }
        let fields = [domain, origin, first.sessionID.uuidString.lowercased(),
            initiator.id.uuidString.lowercased(), responder.id.uuidString.lowercased(),
            initiator.publicKey, responder.publicKey, initiator.token, responder.token, first.nonce, second.nonce] + binding
        transcript = Data(SHA256.hash(data: try PhoneSwapWire.encoder().encode(fields)))
        transcriptHash = PhoneSwapWire.b64(transcript)
        let firstKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
            sharedInfo: Data((domain + ":initiator-to-responder").utf8), outputByteCount: 32)
        let secondKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
            sharedInfo: Data((domain + ":responder-to-initiator").utf8), outputByteCount: 32)
        sendKey = isInitiator ? firstKey : secondKey; receiveKey = isInitiator ? secondKey : firstKey
        outgoingRole = isInitiator ? 1 : 2; incomingRole = isInitiator ? 2 : 1
    }
    private func nonce(_ role: UInt8, _ counter: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data([0x4E,0x53,1,role] + (0..<8).map { UInt8(truncatingIfNeeded: counter >> ($0 * 8)) }))
    }
    mutating func seal(_ message: PhoneSwapWire.Message) throws -> PhoneSwapWire.Outer {
        guard sent < 4096 else { throw BackpackError.invalid("Game message budget exhausted; new explicit session required.") }
        let bytes = try PhoneSwapWire.encoder().encode(message)
        guard bytes.count <= 2048 else { throw BackpackError.invalid("Game application message exceeds its budget.") }
        let counter = sent
        let nonce = try nonce(outgoingRole, counter)
        let box = try AES.GCM.seal(bytes, using: sendKey, nonce: nonce, authenticating: transcript + Data(nonce))
        sent += 1
        return PhoneSwapWire.Outer(hello: nil, counter: counter, encrypted: box.ciphertext + box.tag)
    }
    mutating func open(_ outer: PhoneSwapWire.Outer) throws -> PhoneSwapWire.Message {
        guard outer.hello == nil, let counter = outer.counter, counter == received, received < 4096,
              let data = outer.encrypted, (16...2064).contains(data.count) else { throw BackpackError.invalid("Replayed, out-of-order or oversized authenticated game frame.") }
        let nonce = try nonce(incomingRole, counter)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
        let plain = try AES.GCM.open(box, using: receiveKey, authenticating: transcript + Data(nonce))
        let result = try JSONDecoder().decode(PhoneSwapWire.Message.self, from: plain)
        received += 1; return result
    }
}
struct PhoneSwapIncoming: Sendable {
    private(set) var data = Data()
    let length: Int
    let hash: String
    let credit: PhoneSwapWire.Credit
    init(_ offer: PhoneSwapWire.Message) throws {
        guard offer.kind == "offer", let length = offer.length, (1...PhoneSwapWire.maximumGIF).contains(length),
              let hash = offer.hash, hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let credit = offer.credit else { throw BackpackError.invalid("Invalid bounded GIF offer.") }
        _ = try credit.attribution()
        self.length = length; self.hash = hash; self.credit = credit
    }
    mutating func append(_ message: PhoneSwapWire.Message) throws {
        guard message.kind == "chunk", message.index == data.count, let bytes = message.bytes,
              !bytes.isEmpty, bytes.count <= PhoneSwapWire.chunkBytes, data.count + bytes.count <= length else {
            throw BackpackError.invalid("Incomplete/duplicate/out-of-order GIF application chunk.")
        }
        data.append(bytes)
    }
    func complete() throws -> Data {
        guard data.count == length, LocalSwapOriginal.digest(data) == hash else { throw BackpackError.invalid("Complete GIF bytes/hash not validated; phone remains unchanged.") }
        return try PrivateOutgoingGIF.inspectAlreadySanitized(data)
    }
}
enum PrivateOutgoingGIF {
    static func make(_ original: Data) throws -> Data {
        guard GIFStructure.isGIF(original), original.count <= PhoneSwapWire.maximumGIF else {
            throw BackpackError.invalid("Automatic peer game currently requires a GIF <=128 KiB. Still-image phone display remains supported, but no still is secretly converted.")
        }
        _ = try GIFStructure.inspect(original)
        let bytes = [UInt8](original)
        func palette(_ flags: UInt8) -> Int { flags & 128 == 0 ? 0 : 3 * (1 << (Int(flags & 7) + 1)) }
        func blocks(_ start: Int) throws -> Int {
            var p = start
            while p < bytes.count {
                let n = Int(bytes[p]); p += 1
                if n == 0 { return p }
                guard n <= bytes.count - p else { throw BackpackError.invalid("Truncated GIF sub-block.") }; p += n
            }
            throw BackpackError.invalid("Unterminated GIF sub-block.")
        }
        var position = 13 + palette(bytes[10]), result = Array(bytes.prefix(13 + palette(bytes[10])))
        while position < bytes.count {
            switch bytes[position] {
            case 0x3B: result.append(0x3B); return Data(result)
            case 0x2C:
                let code = position + 10 + palette(bytes[position + 9])
                let end = try blocks(code + 1); result += bytes[position..<end]; position = end
            case 0x21:
                let label = bytes[position + 1], end = try blocks(position + 2)
                if label == 0xF9 { result += bytes[position..<end] }
                else if label == 0xFF {
                    let name = String(bytes: bytes[(position + 3)..<min(position + 14, end)], encoding: .ascii)
                    if bytes[position + 2] == 11 && ["NETSCAPE2.0","ANIMEXTS1.0"].contains(name ?? "") {
                        guard end - position == 19, bytes[position + 14] == 3, bytes[position + 15] == 1 else {
                            throw BackpackError.invalid("Unsupported GIF repeat extension; no opaque metadata may be transmitted.")
                        }
                        result += bytes[position..<end]
                    }
                } else if label != 0xFE { throw BackpackError.invalid("Unsupported rendering extension in GIF. Choose another original; no silent rendering rewrite.") }
                position = end
            default: throw BackpackError.invalid("Invalid GIF block.")
            }
        }
        throw BackpackError.invalid("Missing GIF trailer.")
    }
    static func inspectAlreadySanitized(_ data: Data) throws -> Data {
        guard try make(data) == data else { throw BackpackError.invalid("Peer GIF contains non-rendering/private metadata or trailing payload. Rejected, not silently repaired.") }
        _ = try GIFPreviewDecoder.phoneDisplay(data)
        return data
    }
}
