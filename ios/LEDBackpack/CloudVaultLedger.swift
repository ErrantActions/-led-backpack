import Foundation
import BackpackProtocol

struct CloudLocalLink: Codable, Sendable {
    let remoteID: String
    let generation: Int
    var version: Int
    var localHash: String
    var localMetadataHash: String? = nil
    var remoteMissing = false
}

struct CloudDevicePin: Codable, Sendable {
    var paused = true
    var generation: Int?
    var revision = 0
    var keyID: String?
    var userHeld = false
    var remoteReset = false
    var links: [String: CloudLocalLink] = [:]

    mutating func accept(_ state: CloudVaultState) throws {
        if let generation, state.generation < generation {
            paused = true
            throw BackpackError.invalid("Private cloud generation rolled back. Synchronization is paused.")
        }
        if let generation, generation == state.generation, state.revision < revision {
            paused = true
            throw BackpackError.invalid("Discarded stale private cloud state.")
        }
        if let generation, generation == state.generation, let keyID,
           let nextKey = state.keyId, nextKey != keyID, state.enabled {
            paused = true; remoteReset = true
            throw BackpackError.invalid("Private cloud changed keys without a new generation. Synchronization is paused.")
        }
        if userHeld && state.enabled && state.mode != .userHeld {
            paused = true
            throw BackpackError.invalid("A trusted user-held library unexpectedly became server-managed. No files were uploaded.")
        }
        if generation != nil && generation != state.generation || !state.enabled || state.deleting {
            paused = true; remoteReset = true
        }
        generation = state.generation; revision = state.revision; keyID = state.keyId
        userHeld = userHeld || state.mode == .userHeld
    }
}

@MainActor
final class CloudVaultLedger {
    private struct Document: Codable {
        var version = 1
        var devices: [String: CloudDevicePin] = [:]
    }
    private let file: URL
    private var document: Document
    init(folder: URL? = nil) throws {
        let root = try folder ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LEDBackpack", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("cloud-device.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 2_000_000 else { throw BackpackError.invalid("Private cloud device state exceeds its budget.") }
            document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1 else { throw BackpackError.invalid("Unsupported private cloud device state.") }
        } else { document = Document() }
    }
    private func identifier(_ scope: CloudVaultScope) throws -> String {
        CloudVaultWire.digest(try CloudVaultWire.json([scope.origin.url.absoluteString, scope.account]))
    }
    func pin(_ scope: CloudVaultScope) throws -> CloudDevicePin { document.devices[try identifier(scope)] ?? CloudDevicePin() }
    func hasForeignLink(_ localID: UUID, scope: CloudVaultScope) throws -> Bool {
        let current = try identifier(scope), id = localID.uuidString.lowercased()
        return document.devices.contains { $0.key != current && $0.value.links[id] != nil }
    }
    func save(_ pin: CloudDevicePin, scope: CloudVaultScope) throws {
        var next = document
        next.devices[try identifier(scope)] = pin
        let bytes = try CloudVaultWire.json(next)
        guard bytes.count <= 2_000_000 else { throw BackpackError.invalid("Private cloud device state exceeds its budget.") }
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        document = next
    }
}
