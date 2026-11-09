import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

struct NativeEventRaster {
    let bytes: Data
    let kind: NativeAvatarInput.Kind
    let preview: Data
    init(_ bytes: Data) throws {
        kind = try EventImageReplacementIntent.raster(bytes)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw BackpackError.invalid("The still image could not be decoded within the preview budget.") }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw BackpackError.invalid("Image preview cannot be prepared.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), result.length <= 5_000_000 else {
            throw BackpackError.invalid("Decoded still preview exceeds 5 MB.")
        }
        self.bytes = bytes; preview = result as Data
    }
    static func read(_ url: URL) throws -> NativeEventRaster {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, (1...5_000_000).contains(size) else {
            throw BackpackError.invalid("Choose a regular PNG/JPEG/WebP file up to 5 MB.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 5_000_001) ?? Data()
        guard bytes.count == size else { throw BackpackError.invalid("The selected file changed during staging; choose it again.") }
        return try NativeEventRaster(bytes)
    }
}
struct NativeEventGalleryIntent: Identifiable {
    enum Action {
        case upload, metadata(UUID, Int), order([UUID]), remove(UUID, Int)
    }
    let id = UUID()
    let event: CatalogEvent
    let gallery: NativeEventImages
    let action: Action
    let scope: UUID
    let draftVersion: UUID
    let body: Data?
    let contentType: String
    let caption, alt: String
    init(event: CatalogEvent, gallery: NativeEventImages, action: Action, scope: UUID, draftVersion: UUID,
         caption: String = "", alt: String = "", raster: NativeEventRaster? = nil, permission: Bool = false) throws {
        try gallery.validate()
        guard event.access.canManage, gallery.canReorder, !event.cancelled, event.moderation?.held != true else {
            throw BackpackError.invalid("Current ordinary event organizer access is required; no global-admin override.")
        }
        self.event = event; self.gallery = gallery; self.action = action; self.scope = scope; self.draftVersion = draftVersion
        self.caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .upload:
            guard gallery.assets.count < 20, permission, let raster, self.caption.utf16.count <= 500,
                  (1...500).contains(self.alt.utf16.count) else { throw BackpackError.invalid("Explicit image permission, descriptions and a free gallery slot are required.") }
            struct Metadata: Encodable { let caption, alt: String; let permissionAttested = true }
            let metadata = try JSONEncoder().encode(Metadata(caption: self.caption, alt: self.alt))
            let boundary = "LEDBackpack-\(UUID().uuidString)"
            guard raster.bytes.range(of: Data(boundary.utf8)) == nil else { throw BackpackError.invalid("Staged upload boundary collision.") }
            var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
            data.append(metadata)
            data.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"event.\(raster.kind.extensionName)\"\r\nContent-Type: \(raster.kind.mime)\r\n\r\n".utf8))
            data.append(raster.bytes); data.append(Data("\r\n--\(boundary)--\r\n".utf8))
            body = data; contentType = "multipart/form-data; boundary=\(boundary)"
        case .metadata(let id, let revision):
            guard gallery.assets.contains(where: { $0.id == id && $0.revision == revision }),
                  self.caption.utf16.count <= 500, (1...500).contains(self.alt.utf16.count) else {
                throw BackpackError.invalid("Captured image revision and 1–500 character alt text are required.")
            }
            struct Body: Encodable { let caption, alt: String; let expectedRevision: Int }
            body = try JSONEncoder().encode(Body(caption: self.caption, alt: self.alt, expectedRevision: revision))
            contentType = "application/json"
        case .order(let ids):
            guard ids.count == gallery.assets.count, Set(ids) == Set(gallery.assets.map(\.id)), Set(ids).count == ids.count else {
                throw BackpackError.invalid("Use every captured image exactly once in the requested order.")
            }
            struct Body: Encodable { let assetIds, expectedAssetIds: [String] }
            body = try JSONEncoder().encode(Body(assetIds: ids.map { $0.uuidString.lowercased() },
                expectedAssetIds: gallery.assets.map { $0.id.uuidString.lowercased() }))
            contentType = "application/json"
        case .remove(let id, let revision):
            guard gallery.assets.contains(where: { $0.id == id && $0.revision == revision }) else {
                throw BackpackError.invalid("Select a currently captured image before removal.")
            }
            body = nil; contentType = "application/json"
        }
    }
    func check(_ current: CatalogEvent, gallery: NativeEventImages) throws {
        guard current.id == event.id, current.revision == event.revision,
              current.access.role == event.access.role, current.access.canManage, !current.cancelled,
              current.moderation?.held != true, gallery.canReorder else {
            throw CommunityFailure(status: 403, code: "event_access_changed", message: "Event/role/access changed; clear stale gallery requests and covers.")
        }
        guard gallery.assets.map(\.id) == self.gallery.assets.map(\.id),
              gallery.assets.map(\.revision) == self.gallery.assets.map(\.revision) else {
            throw CommunityFailure(status: 409, code: "event_gallery_conflict", message: "Image revisions/full order changed. Keep choices and explicitly cancel/reload.")
        }
    }
}
@MainActor
extension CommunityFeatureClient {
    func applyEventGallery(_ intent: NativeEventGalleryIntent) async throws {
        let current = try await event(intent.event.id), gallery = try await eventImages(intent.event.id)
        try intent.check(current, gallery: gallery)
        let root = "events/\(intent.event.id.uuidString.lowercased())/assets"
        switch intent.action {
        case .upload:
            struct Receipt: Decodable { let asset: NativeEventImage }
            let value = try JSONDecoder().decode(Receipt.self, from: await send(.events, root, method: "POST", body: intent.body, contentType: intent.contentType)).asset
            guard !gallery.assets.contains(where: { $0.id == value.id }), !value.approved,
                  value.revision > 0, (1...5_000_000).contains(value.byteSize),
                  value.caption == intent.caption, value.alt == intent.alt else { throw BackpackError.invalid("Staged upload receipt was not confirmed. Refresh before retrying.") }
            _ = try eventImagePath(value, event: intent.event.id)
        case .metadata(let id, let revision):
            struct Receipt: Decodable { let asset: NativeEventImage }
            let value = try JSONDecoder().decode(Receipt.self, from: await send(.events, "\(root)/\(id.uuidString.lowercased())", method: "PATCH", body: intent.body)).asset
            guard value.id == id, value.caption == intent.caption, value.alt == intent.alt else { throw BackpackError.invalid("Image description receipt was not confirmed.") }
            if let previous = gallery.assets.first(where: { $0.id == id }),
               previous.caption != intent.caption || previous.alt != intent.alt {
                guard value.revision > revision, !value.approved else { throw BackpackError.invalid("Changed metadata must advance actual asset revision and reset public approval.") }
            }
            _ = try eventImagePath(value, event: intent.event.id)
        case .order(let ids):
            struct Receipt: Decodable { let ordered: Bool; let coverAssetId: UUID? }
            let value = try JSONDecoder().decode(Receipt.self, from: await send(.events, "\(root)/order", method: "PATCH", body: intent.body))
            guard value.ordered, value.coverAssetId == ids.first else { throw BackpackError.invalid("Exact cover/order receipt was not confirmed.") }
        case .remove(let id, _):
            _ = try JSONDecoder().decode(CommunityMessage.self, from: await send(.events, "\(root)/\(id.uuidString.lowercased())", method: "DELETE"))
        }
    }
}
@MainActor
final class EventGalleryStore: ObservableObject {
    let session = CommunityFeatureSession()
    @Published private(set) var event: CatalogEvent?
    @Published private(set) var gallery: NativeEventImages?
    @Published private(set) var captured: NativeEventImages?
    @Published var selected: NativeEventImage? { didSet { changed() } }
    @Published var caption = "" { didSet { changed() } }
    @Published var alt = "" { didSet { changed() } }
    @Published var permission = false { didSet { changed() } }
    @Published private(set) var raster: NativeEventRaster?
    @Published var order: [UUID] = [] { didSet { changed() } }
    @Published var intent: NativeEventGalleryIntent?
    @Published private(set) var conflict = false
    @Published private(set) var acknowledged = false
    @Published private(set) var notice: String?
    private(set) var draftVersion = UUID()
    private(set) var contextVersion = UUID()
    var hasDraft: Bool { captured != nil }
    private func changed() { draftVersion = UUID(); intent = nil }
    func clear() {
        contextVersion = UUID(); event = nil; gallery = nil
        discard(); session.clear()
    }
    func discard() {
        selected = nil; captured = nil; raster = nil; caption = ""; alt = ""; permission = false
        order = []; intent = nil; conflict = false; acknowledged = false; notice = nil; changed()
    }
    func begin(_ image: NativeEventImage? = nil) {
        guard !hasDraft, let gallery, gallery.canReorder else { return }
        captured = gallery; selected = image; caption = image?.caption ?? ""; alt = image?.alt ?? ""
        permission = false; raster = nil; order = gallery.assets.map(\.id); changed()
    }
    func stage(_ file: URL, context: UUID) throws {
        guard contextVersion == context, event != nil, captured != nil, selected == nil, !conflict else {
            throw BackpackError.invalid("Late file selection was dropped after access/selection changed.")
        }
        raster = try NativeEventRaster.read(file); changed()
    }
    func review(_ action: NativeEventGalleryIntent.Action) {
        do {
            guard !conflict, !acknowledged, let event, let captured, let client = session.client else { throw BackpackError.invalid("Explicitly reload current event/gallery authority.") }
            intent = try NativeEventGalleryIntent(event: event, gallery: captured, action: action,
                scope: client.instanceID, draftVersion: draftVersion, caption: caption, alt: alt, raster: raster, permission: permission)
        } catch { notice = error.localizedDescription }
    }
    func load(id: UUID, organizer: Bool) {
        gallery = nil; contextVersion = UUID(); let context = contextVersion
        session.run { client in
            do {
                let current = try await client.event(id)
                guard current.moderation?.held != true, !organizer || current.access.canManage else {
                    throw CommunityFailure(status: 403, code: "event_access_changed", message: "Current gallery authority is unavailable.")
                }
                let images = try await client.eventImages(id)
                try self.session.checked(client)
                guard context == self.contextVersion else { return }
                let definitionChanged = self.event.map { $0.revision != current.revision } ?? false
                if let previous = self.event, previous.access.role != current.access.role {
                    self.discard(); self.contextVersion = UUID()
                }
                self.event = current; self.gallery = images
                if let captured = self.captured {
                    self.conflict = definitionChanged || captured.assets.map(\.id) != images.assets.map(\.id) ||
                        captured.assets.map(\.revision) != images.assets.map(\.revision)
                }
            } catch {
                if let failure = error as? CommunityFailure, [403, 404].contains(failure.status) {
                    self.event = nil; self.gallery = nil; self.discard(); self.contextVersion = UUID()
                }
                throw error
            }
        }
    }
    func apply(_ capturedIntent: NativeEventGalleryIntent) {
        guard !conflict, !acknowledged, capturedIntent.draftVersion == draftVersion else { intent = nil; return }
        let context = contextVersion
        session.run(expected: capturedIntent.scope) { client in
            do {
                try await client.applyEventGallery(capturedIntent)
                try self.session.checked(client)
                guard context == self.contextVersion else { return }
                self.acknowledged = true; self.intent = nil
                if self.draftVersion == capturedIntent.draftVersion {
                    self.discard()
                } else {
                    self.notice = "Captured write acknowledged. New edits remain local and are not overwritten. Cancel/reload explicitly before another write."
                }
                self.load(id: capturedIntent.event.id, organizer: true)
            } catch {
                self.intent = nil; self.conflict = true
                if let failure = error as? CommunityFailure, [403, 404].contains(failure.status) {
                    self.event = nil; self.gallery = nil; self.discard(); self.contextVersion = UUID()
                }
                throw error
            }
        }
    }
}
