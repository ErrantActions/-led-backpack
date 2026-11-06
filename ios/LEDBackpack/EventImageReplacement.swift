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
    init(eventID: UUID, asset: NativeEventImage, gallery: NativeEventImages, bytes: Data, caption: String, alt: String, permission: Bool) throws {
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
    private func eventImagePath(_ asset: NativeEventImage, event: UUID) throws -> String {
        let expected = "/api/v1/events/\(event.uuidString.lowercased())/assets/\(asset.id.uuidString.lowercased())/image.png"
        guard origin.contains(asset.url), asset.url.path == expected, asset.url.query == nil, asset.url.fragment == nil,
              let parts = URLComponents(url: asset.url, resolvingAgainstBaseURL: false), !parts.percentEncodedPath.contains("%") else {
            throw BackpackError.invalid("Event image must use the exact authenticated event/asset URL.")
        }
        return String(expected.dropFirst("/api/v1/".count))
    }
    func eventImage(_ asset: NativeEventImage, event: UUID) async throws -> Data {
        try await send(.events, eventImagePath(asset, event: event), maxBytes: 5_000_000)
    }
    func replaceEventImage(_ intent: EventImageReplacementIntent) async throws -> NativeEventImage {
        let current = try await event(intent.eventID)
        guard current.access.canManage, !current.cancelled else { throw BackpackError.invalid("Current event organizer access is required; no admin bypass.") }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Replace an existing event image").font(.title2.bold())
                Text("Creates a new immutable image URL, retires the old URL, keeps its position/cover and resets public approval. This does not change event participation or publish to community.").font(.caption)
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if session.busy { ProgressView() }
                Button("Refresh current access / images") { refresh() }.disabled(session.busy)
                if authorized, let gallery, gallery.canReorder, let client = session.client {
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
                                permission = false; bytes = nil; selectedName = nil; intent = nil; acknowledged = nil; notice = nil
                            }.disabled(asset != nil || session.busy)
                        }.padding(16).glassPanel()
                    }
                } else if !session.busy { Text("Current event organizer access is required. Global admin status does not grant access.") }
                if let asset, let captured, authorized {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Captured image revision \(asset.revision) / \(captured.assets.count)-image order").font(.headline)
                        if let selectedName { Label(selectedName, systemImage: "doc") }
                        TextField("Caption", text: $caption, axis: .vertical)
                        TextField("Required accessible description", text: $alt, axis: .vertical)
                        Toggle("I have permission to use the replacement image", isOn: $permission)
                        Button("Choose replacement PNG / JPEG / WebP") { importing = true }
                        Button("Review replacement") { confirming = true }.disabled(bytes == nil || !permission || !authorized)
                        if acknowledged != nil { Button("Verify acknowledged replacement (do not resubmit)") { verifyReceipt() } }
                        Text("Refresh never changes the captured revision/order or selected bytes. A conflict retains this draft; explicitly cancel/reload before choosing a new target. No automatic rebase/retry.").font(.caption)
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
        .onDisappear { session.clear() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .webP]) { result in
            do {
                let file = try result.get(), value = try PhoneDisplayFileReader.read(file)
                _ = try EventImageReplacementIntent.raster(value)
                bytes = value; selectedName = file.lastPathComponent
            } catch { notice = error.localizedDescription }
        }
        .confirmationDialog("Replace captured image at the displayed revision/order?", isPresented: $confirming) {
            Button("Replace / reset public approval", role: .destructive) { replace() }
        } message: { Text("The previous image URL is retired only after an atomic accepted replacement. Current revision/order conflicts retain your selected file and descriptions.") }
        .confirmationDialog("Discard this replacement draft?", isPresented: $cancelDraft) {
            Button("Discard and reload", role: .destructive) { discard(); refresh() }
        }
    }
    private func refresh() {
        session.run { client in
            do {
                let current = try await client.event(event.id), images = try await client.eventImages(event.id)
                try session.checked(client); authorized = current.access.canManage && !current.cancelled && images.canReorder
                gallery = images
            } catch { authorized = false; throw error }
        }
    }
    private func replace() {
        session.run { client in
            guard authorized, acknowledged == nil, let captured, let asset, let bytes else { throw BackpackError.invalid("Current access and an explicit captured draft/file are required.") }
            if intent == nil { intent = try EventImageReplacementIntent(eventID: event.id, asset: asset, gallery: captured, bytes: bytes, caption: caption, alt: alt, permission: permission) }
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
    private func discard() { asset = nil; captured = nil; bytes = nil; selectedName = nil; caption = ""; alt = ""; permission = false; intent = nil; acknowledged = nil }
}
