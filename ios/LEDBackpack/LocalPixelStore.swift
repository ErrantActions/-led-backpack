import Foundation
import Combine
import BackpackProtocol

struct LocalPixelProject: Codable, Sendable {
    let artwork: LocalPixelArtwork
    let selected: Int
    let original: Data?
    let originalName: String?
    func validate() throws {
        try artwork.validate()
        guard artwork.frames.indices.contains(selected), (original?.count ?? 0) <= LocalPixelCodec.fileBudget,
              (originalName?.utf16.count ?? 0) <= 160 else { throw BackpackError.invalid("Invalid local editable project or retained source budget.") }
    }
}
struct LocalPixelProjectEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let byteCount: Int
    var filename: String { id.uuidString.lowercased() + ".json" }
}

enum LocalPixelOwnedFile {
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard before.isRegularFile == true, before.isSymbolicLink != true,
              let size = before.fileSize, (1...maximum).contains(size), let stream = InputStream(url: url) else {
            throw BackpackError.invalid("Owned studio file is not regular or exceeds its byte budget; no reset was attempted.")
        }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = stream.read(&buffer, maxLength: 65536)
            guard count >= 0 else { throw stream.streamError ?? BackpackError.invalid("Could not read the owned studio file.") }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw BackpackError.invalid("Studio file grew beyond its read budget.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard data.count == size, after.fileSize == size, after.contentModificationDate == before.contentModificationDate else {
            throw BackpackError.invalid("Studio file changed during reading; previous artwork retained.")
        }
        return data
    }
}

actor LocalPixelRepository {
    private let root: URL
    init(root: URL) { self.root = root }
    static func owned() throws -> LocalPixelRepository {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BackpackError.invalid("Owned local studio directory unavailable. No cloud fallback.")
        }
        return Self(root: base.appendingPathComponent("LocalPixelProjects", isDirectory: true))
    }
    func list() throws -> [LocalPixelProjectEntry] {
        let url = root.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try LocalPixelOwnedFile.read(url, maximum: 100_000)
        let entries = try JSONDecoder().decode([LocalPixelProjectEntry].self, from: data)
        guard entries.count <= 30, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ (1...40_000_000).contains($0.byteCount) && $0.name.utf16.count <= 160 }),
              entries.reduce(0, { $0 + $1.byteCount }) <= 100_000_000 else {
            throw BackpackError.invalid("Invalid local project index; files are retained.")
        }
        return entries
    }
    func read(_ entry: LocalPixelProjectEntry) throws -> LocalPixelProject {
        guard try list().contains(where: { $0.id == entry.id && $0.byteCount == entry.byteCount }) else {
            throw BackpackError.invalid("Project selection changed or was removed.")
        }
        let url = root.appendingPathComponent(entry.filename)
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == entry.byteCount else {
            throw BackpackError.invalid("Project file size changed. Previous artwork retained.")
        }
        let data = try LocalPixelOwnedFile.read(url, maximum: 40_000_000)
        guard data.count == entry.byteCount else { throw BackpackError.invalid("Project changed while reading.") }
        try Task.checkCancellation()
        let project = try JSONDecoder().decode(LocalPixelProject.self, from: data)
        try project.validate(); return project
    }
    func save(_ project: LocalPixelProject, name: String) throws -> LocalPixelProjectEntry {
        try project.validate()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 160 else { throw BackpackError.invalid("Enter a project name of 1…160 UTF-16 units.") }
        var index = try list()
        guard index.count < 30 else { throw BackpackError.invalid("Local studio is full (30 projects). Remove an owned project explicitly.") }
        let data = try JSONEncoder().encode(project)
        guard data.count <= 40_000_000, index.reduce(data.count, { $0 + $1.byteCount }) <= 100_000_000 else {
            throw BackpackError.invalid("Project exceeds the 40 MB file / 100 MB total studio budget.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        let entry = LocalPixelProjectEntry(id: UUID(), name: name, byteCount: data.count)
        let url = root.appendingPathComponent(entry.filename)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        index.insert(entry, at: 0)
        do { try commit(index) }
        catch {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw BackpackError.invalid("Project save failed; its exact owned orphan could not be removed. No successful save was recorded.") }
            throw error
        }
        return entry
    }
    func remove(_ entry: LocalPixelProjectEntry) throws {
        var entries = try list()
        guard entries.contains(where: { $0.id == entry.id }) else { throw BackpackError.invalid("Project was already removed.") }
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.filename))
        entries.removeAll { $0.id == entry.id }; try commit(entries)
    }
    private func commit(_ entries: [LocalPixelProjectEntry]) throws {
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
    }
}

enum LocalPixelWork {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler(operation: {
            let value = try await worker.value; try Task.checkCancellation(); return value
        }, onCancel: { worker.cancel() })
    }
}

struct LocalPixelTicket: Equatable {
    let document: UUID
    let request: UUID
    let frame: UUID
}

@MainActor
final class LocalPixelStore: ObservableObject {
    @Published private(set) var document: LocalPixelDocument
    @Published private(set) var projects: [LocalPixelProjectEntry] = []
    @Published private(set) var original: Data?
    @Published private(set) var originalName: String?
    @Published private(set) var retainedImport: Data?
    @Published private(set) var retainedImportName: String?
    @Published private(set) var retainedImportAttribution: Attribution?
    @Published private(set) var busy = false
    @Published var failure: String?
    @Published var notice: String?
    @Published private(set) var playing = false
    private(set) var generation = UUID()
    private var request = UUID()
    private var task: Task<Void, Never>?
    private var foreground = true
    private var repository: LocalPixelRepository?
    var ticket: LocalPixelTicket { LocalPixelTicket(document: generation, request: request, frame: document.current.id) }
    init(repository: LocalPixelRepository? = nil) {
        self.repository = repository
        document = LocalPixelDocument()
    }
    private func storage() throws -> LocalPixelRepository {
        if let repository { return repository }
        let value = try LocalPixelRepository.owned(); repository = value; return value
    }
    func accepts(_ value: LocalPixelTicket) -> Bool { foreground && ticket == value && !Task.isCancelled }
    func cancel() { task?.cancel(); task = nil; request = UUID(); busy = false; playing = false; document.endStroke() }
    func setForeground(_ value: Bool) { foreground = value; if !value { cancel() } }
    func pause() { playing = false }
    func play(reducedMotion: Bool, dataSaving: Bool) {
        guard foreground, !busy, !reducedMotion, !dataSaving, document.artwork.frames.count > 1 else { playing = false; return }
        document.endStroke(); playing = true
    }
    func change(_ operation: (inout LocalPixelDocument) throws -> Void) {
        cancel()
        do { try operation(&document); generation = UUID(); failure = nil; notice = nil }
        catch { failure = error.localizedDescription }
    }
    func stroke(_ point: LocalPixelPoint, color: LocalPixelColor, radius: Int) {
        if busy { cancel() }
        playing = false
        do { try document.paint(point, color: color, radius: radius); generation = UUID(); failure = nil }
        catch { failure = error.localizedDescription }
    }
    func endStroke() { document.endStroke() }
    func newDocument(width: Int, height: Int) {
        do {
            let value = try LocalPixelDocument(artwork: .blank(width: width, height: height))
            cancel(); document = value; generation = UUID(); original = nil; originalName = nil
            retainedImport = nil; retainedImportName = nil; retainedImportAttribution = nil; failure = nil; notice = nil
        } catch { failure = error.localizedDescription }
    }
    private func begin() -> LocalPixelTicket? {
        guard foreground else { failure = "Return to the foreground before starting local studio work."; return nil }
        cancel(); request = UUID(); busy = true; failure = nil; notice = nil
        return ticket
    }
    func loadProjects() async {
        let stamp = ticket
        do {
            let entries = try await storage().list()
            if accepts(stamp) { projects = entries }
        } catch { if accepts(stamp) { failure = error.localizedDescription } }
    }
    func openProject(_ entry: LocalPixelProjectEntry) {
        guard let stamp = begin() else { return }
        task = Task {
            do {
                let project = try await storage().read(entry)
                guard accepts(stamp) else { return }
                var next = try LocalPixelDocument(artwork: project.artwork); try next.select(project.selected)
                document = next; original = project.original; originalName = project.originalName
                retainedImport = nil; retainedImportName = nil; retainedImportAttribution = nil; generation = UUID(); busy = false
                notice = "Opened local editable copy. Preview paused."
            } catch { finish(error, stamp: stamp) }
        }
    }
    func saveProject(name: String) {
        guard let stamp = begin() else { return }
        let project = LocalPixelProject(artwork: document.artwork, selected: document.selected, original: original, originalName: originalName)
        task = Task {
            do {
                _ = try await storage().save(project, name: name)
                let entries = try await storage().list()
                guard accepts(stamp) else { return }
                projects = entries; busy = false; notice = "New editable project saved locally, with original bytes and attribution."
            } catch { finish(error, stamp: stamp) }
        }
    }
    func removeProject(_ entry: LocalPixelProjectEntry) {
        guard let stamp = begin() else { return }
        task = Task {
            do {
                try await storage().remove(entry); let entries = try await storage().list()
                guard accepts(stamp) else { return }
                projects = entries; busy = false; notice = "Removed this owned project only."
            } catch { finish(error, stamp: stamp) }
        }
    }
    func importFile(_ url: URL, sprite: Bool, at point: LocalPixelPoint) {
        guard let stamp = begin() else { return }
        task = Task {
            do {
                let bytes = try await LocalPixelWork.run { try PhoneDisplayFileReader.read(url) }
                guard accepts(stamp) else { return }
                retainedImport = bytes; retainedImportName = String(url.deletingPathExtension().lastPathComponent.prefix(120))
                retainedImportAttribution = nil
                try await applyImport(bytes, name: retainedImportName ?? "Imported artwork", attribution: nil, sprite: sprite, point: point, stamp: stamp)
            } catch { finish(error, stamp: stamp) }
        }
    }
    func importLibrary(_ item: PhoneArtwork, library: PhoneArtworkLibrary) {
        guard let stamp = begin() else { return }
        task = Task {
            do {
                let bytes = try await library.bytes(item)
                guard accepts(stamp) else { return }
                retainedImport = bytes; retainedImportName = item.name; retainedImportAttribution = item.attribution
                try await applyImport(bytes, name: item.name, attribution: item.attribution, sprite: false,
                    point: LocalPixelPoint(x: 0, y: 0), stamp: stamp)
            } catch { finish(error, stamp: stamp) }
        }
    }
    private func applyImport(_ bytes: Data, name: String, attribution: Attribution?, sprite: Bool,
                             point: LocalPixelPoint, stamp: LocalPixelTicket) async throws {
        let artwork = try await LocalPixelWork.run { try LocalPixelCodec.decode(bytes, attribution: attribution) }
        guard accepts(stamp) else { return }
        if sprite {
            guard artwork.frames.count == 1 else { throw BackpackError.invalid("Sprite stamping accepts stills only. Original retained; selected frame unchanged.") }
            try document.stamp(rgba: artwork.frames[0].rgba, width: artwork.width, height: artwork.height, at: point)
        } else {
            document = try LocalPixelDocument(artwork: artwork)
            original = bytes; originalName = name
        }
        generation = UUID(); busy = false; notice = sprite ? "Sprite stamped as one undoable edit; no resize." : "Imported editable copy. Original bytes retained; phone display unchanged."
    }
    func export(animated: Bool, name: String, library: PhoneArtworkLibrary) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf16.count <= 160 else { failure = "Enter an export name of 1…160 UTF-16 units."; return }
        guard let stamp = begin() else { return }
        let artwork = document.artwork, selected = document.selected
        task = Task {
            do {
                let data = try await LocalPixelWork.run {
                    if animated { return try LocalPixelCodec.gif(artwork) }
                    return try LocalPixelCodec.png(artwork, frame: selected)
                }
                guard accepts(stamp) else { return }
                _ = try await library.saveCreatedCopy(data, name: cleanName, attribution: artwork.attribution)
                guard accepts(stamp) else { return }
                busy = false; notice = "New \(animated ? "GIF (all frames)" : "PNG (current frame)") saved in Phone originals. Active display was not changed."
            } catch { finish(error, stamp: stamp) }
        }
    }
    private func finish(_ error: Error, stamp: LocalPixelTicket) {
        guard accepts(stamp) else { return }
        busy = false; failure = error.localizedDescription
    }
}
