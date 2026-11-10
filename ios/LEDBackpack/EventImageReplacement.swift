import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

struct NativeEventImage: Decodable, Identifiable {
    let id: UUID
    let caption, alt, createdAt: String
    let byteSize, revision: Int
    let approved: Bool
    let url: URL
}
struct NativeEventImages: Decodable {
    let assets: [NativeEventImage]
    let canReorder: Bool
    let coverAssetId: UUID?
    func validate() throws {
        guard assets.count <= 20, Set(assets.map(\.id)).count == assets.count,
              coverAssetId == nil || assets.first?.id == coverAssetId,
              assets.allSatisfy({ $0.revision > 0 && (1...5_000_000).contains($0.byteSize) }) else {
            throw BackpackError.invalid("Invalid event image snapshot/order/cover.")
        }
    }
}
struct EventImageReplacementIntent {
    let eventID, previousID: UUID
    let expectedIDs: [UUID]
    let previousCover: UUID?
    let data: Data
    let contentType: String
    let eventRevision: Int?
    let eventRole: CatalogEventRole?
    init(eventID: UUID, asset: NativeEventImage, gallery: NativeEventImages, bytes: Data, caption: String, alt: String, permission: Bool,
         eventContext: CatalogEvent? = nil) throws {
        try gallery.validate()
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines), alt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard gallery.canReorder, gallery.assets.contains(where: { $0.id == asset.id && $0.revision == asset.revision }),
              permission, caption.utf16.count <= 500, (1...500).contains(alt.utf16.count) else {
            throw BackpackError.invalid("Review the captured image/order, permission and descriptions before replacing.")
        }
        let kind = try Self.raster(bytes)
        struct Metadata: Encodable { let caption, alt: String; let permissionAttested = true; let expectedRevision: Int; let expectedAssetIds: [String] }
        let metadata = try JSONEncoder().encode(Metadata(caption: caption, alt: alt, expectedRevision: asset.revision,
            expectedAssetIds: gallery.assets.map { $0.id.uuidString.lowercased() }))
        let boundary = "LEDBackpack-\(UUID().uuidString)"
        guard bytes.range(of: Data(boundary.utf8)) == nil else { throw BackpackError.invalid("Replacement upload boundary collision.") }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"replacement.\(kind.extensionName)\"\r\nContent-Type: \(kind.mime)\r\n\r\n".utf8))
        body.append(bytes); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        self.eventID = eventID; previousID = asset.id; expectedIDs = gallery.assets.map(\.id); previousCover = gallery.coverAssetId
        data = body; contentType = "multipart/form-data; boundary=\(boundary)"
        eventRevision = eventContext?.revision; eventRole = eventContext?.access.role
    }
    static func raster(_ bytes: Data) throws -> NativeAvatarInput.Kind {
        guard (1...5_000_000).contains(bytes.count),
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let raw = CGImageSourceGetType(source) else {
            throw BackpackError.invalid("Choose one PNG/JPEG/WebP still up to 5 MB.")
        }
        let type = UTType(raw as String)
        guard type == .png || type == .jpeg || type == .webP,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 40_000_000 else {
            throw BackpackError.invalid("Replacement must be a PNG/JPEG/WebP still, at most 8192px and 40 million pixels.")
        }
        return NativeAvatarInput.Kind(extensionName: type == .png ? "png" : type == .jpeg ? "jpg" : "webp",
            mime: type == .png ? "image/png" : type == .jpeg ? "image/jpeg" : "image/webp")
    }
    func verify(_ current: NativeEventImages, newID: UUID) throws {
        try current.validate()
        let expected = expectedIDs.map { $0 == previousID ? newID : $0 }
        guard newID != previousID, current.assets.map(\.id) == expected,
              current.coverAssetId == (previousCover == previousID ? newID : previousCover),
              current.assets.first(where: { $0.id == newID })?.approved == false else {
            throw BackpackError.invalid("Replacement was acknowledged but exact new identity/order/cover/approval could not be verified. Refresh; never resubmit the retired asset.")
        }
    }
}
@MainActor
extension CommunityFeatureClient {
    func eventImages(_ id: UUID) async throws -> NativeEventImages {
        let value = try JSONDecoder().decode(NativeEventImages.self, from: await send(.events, "events/\(id.uuidString.lowercased())/assets"))
        try value.validate()
        for asset in value.assets { _ = try eventImagePath(asset, event: id) }
        return value
    }
    func eventImagePath(_ asset: NativeEventImage, event: UUID) throws -> String {
        let expected = "/api/v1/events/\(event.uuidString.lowercased())/assets/\(asset.id.uuidString.lowercased())/image.png"
        guard origin.contains(asset.url), asset.url.path == expected, asset.url.query == nil, asset.url.fragment == nil,
              let parts = URLComponents(url: asset.url, resolvingAgainstBaseURL: false), !parts.percentEncodedPath.contains("%") else {
            throw BackpackError.invalid("Event image must use the exact authenticated event/asset URL.")
        }
        return String(expected.dropFirst("/api/v1/".count))
    }
    func eventImage(_ asset: NativeEventImage, event: UUID) async throws -> Data {
        let before = try await self.event(event)
        guard before.moderation?.held != true else { throw CommunityFailure(status: 403, code: "event_withdrawn", message: "Held event media is unavailable.") }
        let bytes = try await send(.events, eventImagePath(asset, event: event), maxBytes: 5_000_000)
        let after = try await self.event(event)
        guard after.revision == before.revision, after.access.role == before.access.role, after.moderation?.held != true else {
            throw CommunityFailure(status: 403, code: "event_access_changed", message: "Event media context changed; drop the late image.")
        }
        return bytes
    }
    func replaceEventImage(_ intent: EventImageReplacementIntent) async throws -> NativeEventImage {
        let current = try await event(intent.eventID)
        guard current.access.canManage, !current.cancelled, current.moderation?.held != true,
              intent.eventRevision == nil || intent.eventRevision == current.revision,
              intent.eventRevision == nil || intent.eventRole == current.access.role else {
            throw CommunityFailure(status: 403, code: "event_access_changed", message: "Current event organizer access/revision is required; clear stale replacement requests.")
        }
        struct Receipt: Decodable { let asset: NativeEventImage; let replacedAssetId: UUID }
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.events,
            "events/\(intent.eventID.uuidString.lowercased())/assets/\(intent.previousID.uuidString.lowercased())/replace",
            method: "POST", body: intent.data, contentType: intent.contentType))
        guard result.replacedAssetId == intent.previousID, result.asset.id != intent.previousID,
              !result.asset.approved, result.asset.revision >= 1 else {
            throw BackpackError.invalid("Immutable replacement receipt was not confirmed; no automatic retry.")
        }
        _ = try eventImagePath(result.asset, event: intent.eventID)
        return result.asset
    }
}
@MainActor
struct EventImageReplacementView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    let event: CatalogEvent
    @State private var gallery: NativeEventImages?
    @State private var captured: NativeEventImages?
    @State private var asset: NativeEventImage?
    @State private var bytes: Data?
    @State private var selectedName: String?
    @State private var caption = ""
    @State private var alt = ""
    @State private var permission = false
    @State private var intent: EventImageReplacementIntent?
    @State private var acknowledged: NativeEventImage?
    @State private var authorized = false
    @State private var importing = false
    @State private var confirming = false
    @State private var cancelDraft = false
    @State private var notice: String?
    @State private var currentEvent: CatalogEvent?
    @State private var importScope: UUID?
    @State private var importAsset: UUID?
    @State private var stagedPreview: Data?
    @State private var reviewIntent: EventImageReplacementIntent?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Replace an existing event image").font(.title2.bold())
                Text("Choose the image, then its replacement. The old URL retires and public approval resets.").font(.subheadline).foregroundStyle(.secondary)
                FeatureDetails("What stays unchanged") {
                    Text("Position and cover stay the same. No event participation changes or community publication.")
                }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if session.busy { ProgressView() }
                Button("Refresh current access / images") { refresh() }.disabled(session.busy)
                if authorized, let gallery, gallery.canReorder, let client = session.client {
                    if asset == nil {
                    ForEach(gallery.assets) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            GIFThumbnail(key: "event-replacement:\(client.instanceID):\(item.id):\(item.revision)", cache: false) {
                                try await client.eventImage(item, event: event.id)
                            }.frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 16))
                            Text(item.alt).font(.headline)
                            Text(item.caption)
                            Text("Revision \(item.revision)\(gallery.coverAssetId == item.id ? " · Cover" : "") · \(item.approved ? "Approved" : "Unapproved")").font(.caption)
                            Button("Select this image for replacement") {
                                asset = item; captured = gallery; caption = item.caption; alt = item.alt
                                permission = false; bytes = nil; selectedName = nil; intent = nil; acknowledged = nil; notice = nil; stagedPreview = nil; reviewIntent = nil
                            }.disabled(asset != nil || session.busy)
                        }.padding(16).glassPanel()
                    }
                    }
                } else if !session.busy { Text("Current event organizer access is required. Global admin status does not grant access.") }
                if let asset, let captured, authorized {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose the replacement").font(.headline)
                        FeatureDetails("Captured target & order") {
                            Text("Image revision \(asset.revision) · \(captured.assets.count)-image order")
                            Text(asset.alt)
                        }
                        if let selectedName { Label(selectedName, systemImage: "doc") }
                        TextField("Caption", text: $caption, axis: .vertical)
                        TextField("Required accessible description", text: $alt, axis: .vertical)
                        Toggle("I have permission to use the replacement image", isOn: $permission)
                        if let stagedPreview, let image = UIImage(data: stagedPreview) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240) }
                        Button("Choose replacement PNG / JPEG / WebP") { importScope = session.client?.instanceID; importAsset = asset.id; importing = true }
                        Text("Saving retires the old URL and resets public approval. Earlier downloaded copies cannot be recalled.").font(.caption).foregroundStyle(.orange)
                        Button("Review replacement") {
                            do {
                                guard let bytes else { throw BackpackError.invalid("Choose a replacement still first.") }
                                reviewIntent = try EventImageReplacementIntent(eventID: event.id, asset: asset, gallery: captured,
                                    bytes: bytes, caption: caption, alt: alt, permission: permission, eventContext: currentEvent)
                                confirming = true
                            } catch { notice = error.localizedDescription }
                        }.buttonStyle(AuroraPrimaryButton()).disabled(bytes == nil || !permission || !authorized)
                        if acknowledged != nil { Button("Verify acknowledged replacement (do not resubmit)") { verifyReceipt() } }
                        InteractionExplanation("Conflicts keep this draft and its captured target. Cancel/reload to choose again; no automatic retry or rebase.", details: "Refresh never changes the captured revision/order or selected bytes. A conflict retains this draft; explicitly cancel/reload before choosing a new target. No automatic rebase/retry.").font(.caption)
                    }.padding(16).glassPanel().disabled(session.busy)
                        .disabled(intent != nil || acknowledged != nil)
                    if intent != nil && acknowledged == nil {
                        Button("Discard captured request, retain file/descriptions") { intent = nil }
                        Text("An uncertain connection may have accepted the replacement. Refresh first; do not retry automatically.").font(.caption).foregroundStyle(.orange)
                    }
                    if acknowledged != nil { Button("Verify current replacement") { verifyReceipt() }.disabled(session.busy) }
                }
                if asset != nil {
                    if !authorized { Text("Selected file/draft retained locally; editing is unavailable without current organizer access.") }
                    Button("Cancel captured draft / explicitly reload", role: .destructive) { cancelDraft = true }.disabled(session.busy)
                }
            }.padding(20)
        }.modernScene().navigationTitle("Replace event image")
        .task { session.bind(community); refresh() }
        .onChange(of: community.accountRevision) { _, _ in discard(); session.clear(); dismiss() }
        .onChange(of: community.avatarPolicyRevision) { _, _ in gallery = nil; authorized = false; discard(); session.clear(); dismiss() }
        .onChange(of: phase) { _, state in
            if state == .background { gallery = nil; currentEvent = nil; authorized = false; discard(); session.clear(); dismiss() }
        }
        .onChange(of: session.denied) { _, denied in if denied { gallery = nil; currentEvent = nil; authorized = false; discard() } }
        .onChange(of: caption) { _, _ in reviewIntent = nil; confirming = false }
        .onChange(of: alt) { _, _ in reviewIntent = nil; confirming = false }
        .onChange(of: permission) { _, _ in reviewIntent = nil; confirming = false }
        .onDisappear { if !importing { gallery = nil; authorized = false; session.clear() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .webP]) { result in
            do {
                guard authorized, importScope == session.client?.instanceID, importAsset == asset?.id else { throw CancellationError() }
                let file = try result.get(), raster = try NativeEventRaster.read(file)
                bytes = raster.bytes; stagedPreview = raster.preview; selectedName = file.lastPathComponent
                reviewIntent = nil; confirming = false
            } catch { notice = error.localizedDescription }
        }
        .confirmationDialog("Replace captured image at the displayed revision/order?", isPresented: $confirming) {
            Button("Replace / reset public approval", role: .destructive) { replace() }
        } message: { Text("Caption: \(caption)\nAlt: \(alt)\nCaptured asset revision \(asset?.revision ?? 0), exact \(captured?.assets.count ?? 0)-image order, explicit permission true. Previous URL retires; cover/order retained, approval resets. Conflicts retain file/descriptions.") }
        .confirmationDialog("Discard this replacement draft?", isPresented: $cancelDraft) {
            Button("Discard and reload", role: .destructive) { discard(); refresh() }
        }
    }
    private func refresh() {
        session.run { client in
            do {
                let current = try await client.event(event.id), images = try await client.eventImages(event.id)
                try session.checked(client); authorized = current.access.canManage && !current.cancelled && images.canReorder && current.moderation?.held != true
                if !authorized || (currentEvent != nil && (currentEvent?.revision != current.revision || currentEvent?.access.role != current.access.role)) {
                    gallery = nil; discard()
                }
                currentEvent = current
                gallery = images
            } catch {
                authorized = false; gallery = nil; currentEvent = nil
                if let failure = error as? CommunityFailure, [403, 404].contains(failure.status) { discard() }
                throw error
            }
        }
    }
    private func replace() {
        session.run { client in
            guard authorized, acknowledged == nil, let captured, let asset, let bytes else { throw BackpackError.invalid("Current access and an explicit captured draft/file are required.") }
            if intent == nil { intent = reviewIntent }
            guard let intent else { throw BackpackError.invalid("Replacement intent is unavailable.") }
            let receipt = try await client.replaceEventImage(intent)
            try session.checked(client); acknowledged = receipt
            let current = try await client.eventImages(event.id); try intent.verify(current, newID: receipt.id)
            try session.checked(client); discard(); gallery = current; notice = "Verified immutable replacement, original position/cover and reset approval."
        }
    }
    private func verifyReceipt() {
        session.run { client in
            guard let intent, let acknowledged else { throw BackpackError.invalid("No acknowledged replacement to verify.") }
            let current = try await client.eventImages(event.id); try intent.verify(current, newID: acknowledged.id)
            try session.checked(client); discard(); gallery = current; notice = "Verified acknowledged replacement."
        }
    }
    private func discard() { asset = nil; captured = nil; bytes = nil; selectedName = nil; caption = ""; alt = ""; permission = false; intent = nil; acknowledged = nil; stagedPreview = nil; reviewIntent = nil; importScope = nil; importAsset = nil; importing = false }
}
