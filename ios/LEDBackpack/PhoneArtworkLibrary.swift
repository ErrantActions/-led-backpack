import Foundation
import ImageIO
import UniformTypeIdentifiers
import Combine
import BackpackProtocol

struct PhoneArtwork: Codable, Identifiable, Sendable {
    let id: UUID
    let name, suffix: String
    let byteCount: Int
    var attribution: Attribution? = nil
    var filename: String { id.uuidString.lowercased() + "." + suffix }
}
actor PhoneArtworkRepository {
    private let root: URL
    init(root: URL) { self.root = root }
    func list() throws -> [PhoneArtwork] {
        let index = root.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        let size = try index.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 100_000 else { throw BackpackError.invalid("Local phone library index exceeds its budget; existing files were not reset.") }
        let bytes = try PhoneDisplayFileReader.read(index)
        guard bytes.count <= 100_000 else { throw BackpackError.invalid("Local phone library index grew beyond its budget.") }
        let values = try JSONDecoder().decode([PhoneArtwork].self, from: bytes)
        guard values.count <= 100, Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ ["gif","png","jpg","webp"].contains($0.suffix) && (1...5_000_000).contains($0.byteCount) && $0.name.utf16.count <= 160 }),
              values.reduce(0, { $0 + $1.byteCount }) <= 100_000_000 else { throw BackpackError.invalid("Local phone library metadata is invalid; no files were reset.") }
        for item in values {
            if let attribution = item.attribution {
                guard [attribution.source, attribution.author, attribution.license, attribution.licenseURL].allSatisfy({ $0.utf16.count <= 2048 }) else {
                    throw BackpackError.invalid("Local attribution metadata is outside its bounds; no files were reset.")
                }
            }
        }
        return values
    }
    func read(_ item: PhoneArtwork) throws -> Data {
        guard try list().contains(where: { $0.id == item.id && $0.filename == item.filename }) else { throw BackpackError.invalid("Phone artwork selection is no longer in the local library.") }
        let data = try PhoneDisplayFileReader.read(root.appendingPathComponent(item.filename))
        guard data.count == item.byteCount else { throw BackpackError.invalid("Local original changed. Previous selection remains intact.") }
        return data
    }
    func importFile(_ url: URL) throws -> PhoneArtwork {
        let data = try PhoneDisplayFileReader.read(url)
        return try importBytes(data, name: url.deletingPathExtension().lastPathComponent)
    }
    func importBytes(_ data: Data, name: String, attribution: Attribution? = nil) throws -> PhoneArtwork {
        if let attribution {
            guard [attribution.source, attribution.author, attribution.license, attribution.licenseURL].allSatisfy({ $0.utf16.count <= 2048 }) else {
                throw BackpackError.invalid("Local received attribution exceeds its metadata bounds.")
            }
        }
        _ = try GIFPreviewDecoder.phoneDisplay(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let raw = CGImageSourceGetType(source),
              let type = UTType(raw as String) else { throw BackpackError.invalid("Unsupported phone artwork.") }
        let suffix: String
        if type == .gif { suffix = "gif" } else if type == .png { suffix = "png" }
        else if type == .jpeg { suffix = "jpg" } else if type == .webP { suffix = "webp" }
        else { throw BackpackError.invalid("Unsupported phone original type.") }
        var index = try list()
        guard index.count < 100, index.reduce(data.count, { $0 + $1.byteCount }) <= 100_000_000 else { throw BackpackError.invalid("Local phone library is full (100 originals / 100 MB). Remove an original explicitly before importing.") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        let safeName = String(name.prefix(120))
        let item = PhoneArtwork(id: UUID(), name: safeName, suffix: suffix, byteCount: data.count, attribution: attribution)
        let target = root.appendingPathComponent(item.filename)
        try data.write(to: target, options: [.atomic, .completeFileProtection])
        index.insert(item, at: 0)
        do { try JSONEncoder().encode(index).write(to: root.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection]) }
        catch {
            do { try FileManager.default.removeItem(at: target) }
            catch { throw BackpackError.invalid("Phone import failed and its exact owned file could not be cleaned up; no success was recorded.") }
            throw error
        }
        return item
    }
    func remove(_ item: PhoneArtwork) throws {
        var index = try list()
        guard index.contains(where: { $0.id == item.id }) else { throw BackpackError.invalid("The selected local original was already removed.") }
        // Remove the exact file first; never report successful removal while its bytes remain.
        try FileManager.default.removeItem(at: root.appendingPathComponent(item.filename))
        index.removeAll { $0.id == item.id }
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
    }
}
@MainActor
final class PhoneArtworkLibrary: ObservableObject {
    @Published private(set) var items: [PhoneArtwork] = []
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    private var repository: PhoneArtworkRepository?
    private var generation = UUID()
    init(repository: PhoneArtworkRepository? = nil) { self.repository = repository }
    private func storage() throws -> PhoneArtworkRepository {
        if let repository { return repository }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BackpackError.invalid("Local phone library directory is unavailable; no fallback to cloud.")
        }
        let value = PhoneArtworkRepository(root: base.appendingPathComponent("PhoneOriginals", isDirectory: true))
        repository = value; return value
    }
    func load() async {
        let stamp = generation
        do {
            let current = try await storage().list(); try Task.checkCancellation()
            guard generation == stamp else { return }
            items = current; failure = nil
        } catch { if generation == stamp && !Task.isCancelled { failure = error.localizedDescription } }
    }
    func importFile(_ url: URL) async throws -> PhoneArtwork {
        guard !busy else { throw BackpackError.invalid("Finish the current local import.") }
        generation = UUID(); busy = true; defer { busy = false }
        let item = try await storage().importFile(url)
        items = try await storage().list()
        return item
    }
    func bytes(_ item: PhoneArtwork) async throws -> Data { try await storage().read(item) }
    func saveCreatedCopy(_ data: Data, name: String, attribution: Attribution? = nil) async throws -> PhoneArtwork {
        try await saveReceivedCopy(data, name: name, attribution: attribution)
    }
    func saveReceivedCopy(_ data: Data, name: String, attribution: Attribution? = nil) async throws -> PhoneArtwork {
        guard !busy else { throw BackpackError.invalid("Finish the current local import.") }
        generation = UUID(); busy = true; defer { busy = false }
        let item = try await storage().importBytes(data, name: name, attribution: attribution)
        items = try await storage().list(); return item
    }
    func delete(_ item: PhoneArtwork) async {
        guard !busy else { failure = "Finish the current local import/removal first."; return }
        generation = UUID(); busy = true; defer { busy = false }
        do { try await storage().remove(item); items = try await storage().list(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
enum NativeDisplayTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case phone = "Phone", hardware = "Backpack"
    var id: String { rawValue }
}
@MainActor
final class DisplayTargetSelection: ObservableObject {
    @Published var target = NativeDisplayTarget.phone
    @Published private(set) var hardwareArtworkID: UUID?
    @Published private(set) var phonePeerOwner: UUID?
    func stageHardware(_ mediaID: UUID) { hardwareArtworkID = mediaID; target = .hardware }
    func acquirePhone(_ owner: UUID) throws {
        guard target == .phone, phonePeerOwner == nil || phonePeerOwner == owner else {
            throw BackpackError.invalid("Another peer controller owns the phone target. Explicitly stop/recover it before arming another interaction.")
        }
        phonePeerOwner = owner
    }
    func releasePhone(_ owner: UUID) { if phonePeerOwner == owner { phonePeerOwner = nil } }
}
