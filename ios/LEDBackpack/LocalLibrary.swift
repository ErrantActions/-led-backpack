import Foundation
import Combine
import Security
import BackpackProtocol

struct Attribution: Codable, Equatable {
    var source: String
    var author: String
    var license: String
    var licenseURL: String
}

struct SavedMedia: Identifiable, Codable {
    var id = UUID()
    var name: String
    var attribution: Attribution?
    var created = Date()
    var category: String?
    var favorite: Bool?
    var cloudSource: MediaCloudSource?
    var categoryName: String {
        let value = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Uncategorized" : value
    }
    var isFavorite: Bool { favorite == true }
    var filename: String { id.uuidString + ".gif" }
}

struct MediaCloudSource: Codable, Equatable {
    let server: String
    let accountID: UUID?
    let itemID: UUID
    let assetURL: String
}

struct SavedPlaylist: Identifiable, Codable {
    var id = UUID()
    var name: String
    var slots: [Int]
    var durations: [Double]?
}

struct SlotPreviewLink: Codable {
    var panel: String
    var slot: Int
    var identifier: [UInt8]
    var mediaID: UUID
}

struct Preferences: Codable {
    static let defaultCommunityURL = "https://led.errantactions.com"
    var communityURL: String?
    var effectiveCommunityURL: String? {
        guard let communityURL else { return Self.defaultCommunityURL }
        return communityURL.isEmpty ? nil : communityURL
    }
    var mph = true
    var fahrenheit = true
    var reconnect = true
    var backgroundLocation = false
    var brakeDisplay = false
    var speedCapEnabled = false
    var speedCap = 60
    var disconnectAlerts = true
}

struct LibraryState: Codable {
    var version = 1
    var media: [SavedMedia] = []
    var playlists: [SavedPlaylist] = []
    var preferences = Preferences()
    var liveThemes: [String: LiveTheme]?
    var livePresets: [LivePreset]?
    var slotPreviews: [SlotPreviewLink]?
    var scenes: [SavedScene]?
}

struct LibraryBackup: Codable {
    var state: LibraryState
    var files: [String: Data]
}

@MainActor
final class LocalLibrary: ObservableObject {
    @Published private(set) var state: LibraryState
    private let folder: URL
    private var stateURL: URL { folder.appendingPathComponent("library.json") }

    init(folder: URL? = nil) throws {
        self.folder = try folder ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LEDBackpack", isDirectory: true)
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("library.json").path) {
            state = try JSONDecoder().decode(LibraryState.self,
                from: Data(contentsOf: self.folder.appendingPathComponent("library.json")))
            guard state.version == 1 else { throw BackpackError.invalid("Unsupported library version.") }
            let scenes = state.scenes ?? []
            guard scenes.count <= 50, Set(scenes.map(\.id)).count == scenes.count else {
                throw BackpackError.invalid("Stored scenes have duplicate IDs or exceed the 50-scene limit.")
            }
            for scene in scenes { try scene.validate() }
            for item in state.media { _ = try checkedCategory(item.category) }
        } else { state = LibraryState() }
    }

    private func commit(_ value: LibraryState) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = value
    }

    func data(_ item: SavedMedia) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(item.filename)) }

    var mediaCategories: [String] {
        Array(Set(state.media.map(\.categoryName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func checkedCategory(_ value: String?) throws -> String? {
        let category = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard category.count <= 40 else { throw BackpackError.invalid("Category names must be at most 40 characters.") }
        return category.isEmpty || category == "Uncategorized" ? nil : category
    }

    func organize(_ id: UUID, category: String?, favorite: Bool) throws {
        guard let index = state.media.firstIndex(where: { $0.id == id }) else {
            throw BackpackError.invalid("This artwork is no longer in the library.")
        }
        let normalized = try checkedCategory(category)
        var value = state
        value.media[index].category = normalized
        value.media[index].favorite = favorite
        try commit(value)
    }

    func add(name: String, data: Data, attribution: Attribution? = nil, category: String? = nil) throws {
        _ = try store(name: name, data: data, attribution: attribution, category: category, cloudSource: nil)
    }

    @discardableResult
    func saveCatalogGIF(_ data: Data, item: CommunityItem, origin: CommunityOrigin, accountID: UUID?,
        assetURL: URL) throws -> SavedMedia {
        guard origin.contains(assetURL), assetURL.path.hasPrefix("/media/") else {
            throw BackpackError.invalid("The GIF source does not belong to this catalog.")
        }
        let source = MediaCloudSource(server: origin.url.absoluteString, accountID: accountID,
            itemID: item.id, assetURL: assetURL.absoluteString)
        if let existing = state.media.first(where: { $0.cloudSource == source }) {
            _ = try self.data(existing)
            return existing
        }
        let category = CommunityCategory(rawValue: item.category)?.label ?? item.category
        return try store(name: item.title, data: data, attribution: item.credit, category: category, cloudSource: source)
    }

    func connectCloudCopy(mediaID: UUID, itemID: UUID, origin: CommunityOrigin, accountID: UUID) throws {
        guard let index = state.media.firstIndex(where: { $0.id == mediaID }) else {
            throw BackpackError.invalid("Cloud upload succeeded, but the local artwork was removed. Refresh the cloud library.")
        }
        let assetURL = origin.url.appendingPathComponent("media")
            .appendingPathComponent(itemID.uuidString.lowercased()).appendingPathComponent("original.gif")
        var value = state
        value.media[index].cloudSource = MediaCloudSource(server: origin.url.absoluteString,
            accountID: accountID, itemID: itemID, assetURL: assetURL.absoluteString)
        try commit(value)
    }

    private func store(name: String, data: Data, attribution: Attribution?, category: String?,
        cloudSource: MediaCloudSource?) throws -> SavedMedia {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              state.media.count < 100, data.count <= 5_000_000 else {
            throw BackpackError.invalid("Provide a name; the library allows 100 items up to 5 MB each.")
        }
        guard ["GIF87a", "GIF89a"].contains(String(data: data.prefix(6), encoding: .ascii) ?? "") else {
            throw BackpackError.invalid("Local artwork must be encoded as GIF.")
        }
        let normalized = try checkedCategory(category)
        _ = try MediaCodec.decode(data)
        var item = SavedMedia(name: String(name.prefix(100)), attribution: attribution)
        item.category = normalized
        item.cloudSource = cloudSource
        let url = folder.appendingPathComponent(item.filename)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var value = state; value.media.insert(item, at: 0)
        do { try commit(value) }
        catch {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw BackpackError.invalid("Library save and cleanup failed: \(error.localizedDescription)") }
            throw error
        }
        return item
    }

    func delete(_ item: SavedMedia) throws {
        var value = state; value.media.removeAll { $0.id == item.id }
        value.slotPreviews?.removeAll { $0.mediaID == item.id }
        try commit(value)
        do { try FileManager.default.removeItem(at: folder.appendingPathComponent(item.filename)) }
        catch { throw BackpackError.invalid("Item removed from library, but file cleanup failed: \(error.localizedDescription)") }
    }

    func savePlaylist(name: String, slots: [Int], durations: [Double]? = nil) throws {
        guard !name.isEmpty, !slots.isEmpty, slots.count <= 60, slots.allSatisfy({ (0..<60).contains($0) }) else {
            throw BackpackError.invalid("Playlist needs a name and 1 to 60 slot IDs in 0...59.")
        }
        if let durations {
            guard durations.count == slots.count, durations.allSatisfy({ $0.isFinite && (1...3600).contains($0) }) else {
                throw BackpackError.invalid("Playlist durations must match the slots and be 1...3600 seconds.")
            }
        }
        var value = state; value.playlists.append(SavedPlaylist(name: String(name.prefix(100)), slots: slots, durations: durations))
        try commit(value)
    }

    func updatePlaylist(_ playlist: SavedPlaylist) throws {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlist.id }),
              !playlist.name.isEmpty, !playlist.slots.isEmpty, playlist.slots.count <= 60,
              playlist.slots.allSatisfy({ (0..<60).contains($0) }),
              let durations = playlist.durations, durations.count == playlist.slots.count,
              durations.allSatisfy({ $0.isFinite && (1...3600).contains($0) }) else {
            throw BackpackError.invalid("Invalid playlist or per-item timing.")
        }
        var value = state; value.playlists[index] = playlist; try commit(value)
    }

    func rememberSlot(panel: String, slot: Int, identifier: [UInt8], mediaID: UUID) throws {
        guard (0..<60).contains(slot), identifier.count == 16,
              state.media.contains(where: { $0.id == mediaID }) else { throw BackpackError.invalid("Invalid cached slot association.") }
        var value = state
        var links = value.slotPreviews ?? []
        links.removeAll { $0.panel == panel && $0.slot == slot }
        links.append(SlotPreviewLink(panel: panel, slot: slot, identifier: identifier, mediaID: mediaID))
        value.slotPreviews = links; try commit(value)
    }

    func cachedSlot(panel: String, slot: Int, identifier: [UInt8]) throws -> Data? {
        guard let link = state.slotPreviews?.first(where: {
            $0.panel == panel && $0.slot == slot && $0.identifier == identifier
        }) else { return nil }
        guard let media = state.media.first(where: { $0.id == link.mediaID }) else {
            throw BackpackError.invalid("Cached slot artwork is missing from the local library.")
        }
        return try data(media)
    }

    func removePlaylist(_ id: UUID) throws {
        var value = state; value.playlists.removeAll { $0.id == id }; try commit(value)
    }

    func savePreferences(_ preferences: Preferences) throws {
        var value = state; value.preferences = preferences; try commit(value)
    }

    func theme(for mode: LiveMode) -> LiveTheme {
        state.liveThemes?[mode.rawValue] ?? .standard(for: mode)
    }

    func saveTheme(_ theme: LiveTheme, for mode: LiveMode) throws {
        try theme.validate()
        var value = state
        var themes = value.liveThemes ?? [:]
        themes[mode.rawValue] = theme; value.liveThemes = themes
        try commit(value)
    }

    func savePreset(name: String, mode: LiveMode, theme: LiveTheme) throws {
        try theme.validate()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 40, (state.livePresets?.count ?? 0) < 100 else {
            throw BackpackError.invalid("Preset needs a name up to 40 characters; at most 100 presets are supported.")
        }
        var value = state
        value.livePresets = (value.livePresets ?? []) + [LivePreset(name: name, mode: mode.rawValue, theme: theme)]
        try commit(value)
    }

    func deletePreset(_ id: UUID) throws {
        var value = state; value.livePresets?.removeAll { $0.id == id }; try commit(value)
    }

    func saveScene(_ scene: SavedScene) throws {
        try scene.validate()
        var value = state
        var scenes = value.scenes ?? []
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[index] = scene
        } else {
            guard scenes.count < 50 else { throw BackpackError.invalid("The library allows at most 50 scenes.") }
            scenes.append(scene)
        }
        value.scenes = scenes
        try commit(value)
    }

    func deleteScene(_ id: UUID) throws {
        var value = state
        value.scenes?.removeAll { $0.id == id }
        try commit(value)
    }

    func backup() throws -> Data {
        var files: [String: Data] = [:]
        var total = 0
        for item in state.media {
            let bytes = try data(item)
            total += bytes.count
            guard total <= 40_000_000 else { throw BackpackError.invalid("Backup exceeds 40 MB. Export fewer assets first.") }
            files[item.filename] = bytes
        }
        var exported = state
        exported.media = state.media.map { item in
            var value = item
            value.cloudSource = nil
            return value
        }
        return try JSONEncoder().encode(LibraryBackup(state: exported, files: files))
    }

    func importBackup(_ data: Data) throws {
        guard data.count <= 60_000_000 else { throw BackpackError.invalid("Backup exceeds 60 MB.") }
        let backup = try JSONDecoder().decode(LibraryBackup.self, from: data)
        guard backup.state.version == 1, backup.state.media.count + state.media.count <= 100 else {
            throw BackpackError.invalid("Unsupported or oversized backup.")
        }
        let scenes = backup.state.scenes ?? []
        guard scenes.count + (state.scenes?.count ?? 0) <= 50,
              Set(scenes.map(\.id)).count == scenes.count else {
            throw BackpackError.invalid("Backup scenes have duplicate IDs or would exceed the 50-scene limit.")
        }
        for scene in scenes { try scene.validate() }
        for list in backup.state.playlists {
            guard list.slots.count <= 60, list.slots.allSatisfy({ (0..<60).contains($0) }) else {
                throw BackpackError.invalid("Backup has invalid playlist slot IDs.")
            }
            if let durations = list.durations {
                guard durations.count == list.slots.count, durations.allSatisfy({ $0.isFinite && (1...3600).contains($0) }) else {
                    throw BackpackError.invalid("Backup contains invalid playlist timings.")
                }
            }
            for (mode, theme) in backup.state.liveThemes ?? [:] {
                guard LiveMode(rawValue: mode) != nil else { throw BackpackError.invalid("Backup contains an unknown live screen.") }
                try theme.validate()
            }
            for preset in backup.state.livePresets ?? [] {
                guard LiveMode(rawValue: preset.mode) != nil, !preset.name.isEmpty, preset.name.count <= 40 else {
                    throw BackpackError.invalid("Backup contains an invalid live preset.")
                }
                try preset.theme.validate()
            }
            guard (backup.state.livePresets?.count ?? 0) + (state.livePresets?.count ?? 0) <= 100 else {
                throw BackpackError.invalid("Merged backup would exceed 100 live presets.")
            }
        }
        for item in backup.state.media {
            _ = try checkedCategory(item.category)
            guard let bytes = backup.files[item.filename], bytes.count <= 5_000_000 else {
                throw BackpackError.invalid("Backup is missing a media file or it exceeds 5 MB.")
            }
            _ = try MediaCodec.decode(bytes)
        }
        let mediaIDs = Set(backup.state.media.map(\.id))
        for link in backup.state.slotPreviews ?? [] {
            guard !link.panel.isEmpty, (0..<60).contains(link.slot), link.identifier.count == 16,
                  mediaIDs.contains(link.mediaID) else { throw BackpackError.invalid("Backup contains an invalid slot preview association.") }
        }
        var value = state
        var created: [URL] = []
        var importedIDs: [UUID: UUID] = [:]
        do {
            // Imported names are never used as paths; all files receive fresh UUIDs.
            for item in backup.state.media {
                guard let bytes = backup.files[item.filename],
                      ["GIF87a", "GIF89a"].contains(String(data: bytes.prefix(6), encoding: .ascii) ?? "") else {
                    throw BackpackError.invalid("Missing or invalid backup GIF.")
                }
                var imported = SavedMedia(name: String(item.name.prefix(100)), attribution: item.attribution)
                imported.category = try checkedCategory(item.category)
                imported.favorite = item.favorite
                let url = folder.appendingPathComponent(imported.filename)
                try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                created.append(url); value.media.append(imported)
                importedIDs[item.id] = imported.id
            }
            value.playlists += backup.state.playlists.map { SavedPlaylist(name: $0.name, slots: $0.slots, durations: $0.durations) }
            var themes = value.liveThemes ?? [:]
            for (mode, theme) in backup.state.liveThemes ?? [:] where themes[mode] == nil { themes[mode] = theme }
            value.liveThemes = themes
            value.livePresets = (value.livePresets ?? []) + (backup.state.livePresets ?? []).map {
                LivePreset(name: $0.name, mode: $0.mode, theme: $0.theme)
            }
            var links = value.slotPreviews ?? []
            for link in backup.state.slotPreviews ?? [] {
                if links.contains(where: { $0.panel == link.panel && $0.slot == link.slot }) { continue }
                guard let id = importedIDs[link.mediaID] else { throw BackpackError.invalid("Missing imported preview media.") }
                links.append(SlotPreviewLink(panel: link.panel, slot: link.slot, identifier: link.identifier, mediaID: id))
            }
            value.slotPreviews = links
            value.scenes = (value.scenes ?? []) + scenes.map {
                var imported = $0
                imported.id = UUID()
                return imported
            }
            try commit(value)
        } catch {
            let original = error
            var cleanupErrors: [String] = []
            for url in created {
                do { try FileManager.default.removeItem(at: url) } catch { cleanupErrors.append(error.localizedDescription) }
            }
            if !cleanupErrors.isEmpty {
                throw BackpackError.invalid("Backup import failed: \(original.localizedDescription). Cleanup: \(cleanupErrors.joined(separator: "; "))")
            }
            throw original
        }
    }
}

enum PanelSecrets {
    private static let service = "LEDBackpack.panel-password"

    static func read(_ id: UUID) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let bytes = result as? Data,
              let text = String(data: bytes, encoding: .utf8) else {
            throw BackpackError.invalid("Keychain read failed (\(status)).")
        }
        return text
    }

    static func save(_ password: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if password.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw BackpackError.invalid("Keychain delete failed (\(status)).")
            }
            return
        }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(password.utf8)] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw BackpackError.invalid("Keychain update failed (\(updated)).") }
        var value = query
        value[kSecValueData as String] = Data(password.utf8)
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw BackpackError.invalid("Keychain save failed (\(status)).") }
    }
}
