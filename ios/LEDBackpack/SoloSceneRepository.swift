import Foundation
import BackpackProtocol

struct SoloVersionedArchive: Sendable {
    let revision: UUID
    let archive: SoloArchive
}
actor SoloSceneRepository {
    private struct Envelope: Codable {
        let schema: Int
        let revision: UUID
        let payload: Data
        let sha256: String
    }
    private let root: URL
    private var file: URL { root.appendingPathComponent("scenes.json") }
    init(root: URL) { self.root = root }
    static func owned() throws -> SoloSceneRepository {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BackpackError.invalid("Owned SOLO directory unavailable. No cloud or default recovery fallback.")
        }
        return Self(root: base.appendingPathComponent("SoloScenes", isDirectory: true))
    }
    func load() throws -> SoloVersionedArchive? {
        do { _ = try file.resourceValues(forKeys: [.isRegularFileKey]) }
        catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError else { throw error }
            return nil
        }
        let bytes = try LocalPixelOwnedFile.read(file, maximum: 75_000_000)
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.schema == 1, envelope.sha256 == LocalSwapOriginal.digest(envelope.payload) else {
            throw BackpackError.invalid("SOLO storage version/integrity mismatch. Existing bytes retained, not treated as empty.")
        }
        let archive = try JSONDecoder().decode(SoloArchive.self, from: envelope.payload)
        try archive.validate(); try Task.checkCancellation()
        return SoloVersionedArchive(revision: envelope.revision, archive: archive)
    }
    func save(_ archive: SoloArchive, expected: UUID?) throws -> SoloVersionedArchive {
        try Task.checkCancellation()
        let current = try load()
        guard current?.revision == expected else { throw BackpackError.invalid("SOLO storage changed. Reload before saving; no original was overwritten.") }
        try archive.validate()
        let payload = try JSONEncoder().encode(archive)
        let revision = UUID()
        let bytes = try JSONEncoder().encode(Envelope(schema: 1, revision: revision, payload: payload, sha256: LocalSwapOriginal.digest(payload)))
        guard bytes.count <= 75_000_000 else { throw BackpackError.invalid("SOLO atomic archive exceeds its 75 MB encoded bound. Delete selected copies explicitly.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try Task.checkCancellation()
        try bytes.write(to: file, options: [.atomic, .completeFileProtection])
        guard let checked = try load(), checked.revision == revision else {
            throw BackpackError.invalid("SOLO durable read-back failed; reload required, no success was recorded.")
        }
        return checked
    }
}
