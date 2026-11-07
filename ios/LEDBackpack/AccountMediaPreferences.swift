import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

struct ViewerMediaPreferences: Codable, Equatable {
    let revision: Int
    let animationsEnabled, dataSaving: Bool
    func validate() throws {
        guard revision >= 0 else { throw BackpackError.invalid("Invalid viewer-preference revision.") }
    }
    func permitsAnimation(reducedMotion: Bool, manual: Bool) -> Bool {
        manual || (animationsEnabled && !dataSaving && !reducedMotion)
    }
}

struct NativeAvatarCrop: Codable, Equatable {
    var leftPercent = 0
    var topPercent = 0
    var widthPercent = 100
    var heightPercent = 100
    func validate() throws {
        guard (0...99).contains(leftPercent), (0...99).contains(topPercent),
              (1...100).contains(widthPercent), (1...100).contains(heightPercent),
              leftPercent + widthPercent <= 100, topPercent + heightPercent <= 100 else {
            throw BackpackError.invalid("Crop percentages must describe a nonempty rectangle inside the oriented source.")
        }
    }
    func rectangle(width: Int, height: Int) throws -> CGRect {
        try validate()
        guard (1...4096).contains(width), (1...4096).contains(height) else { throw BackpackError.invalid("Missing or oversized oriented source dimensions.") }
        let x = width * leftPercent / 100, y = height * topPercent / 100
        let w = width * widthPercent / 100, h = height * heightPercent / 100
        guard w > 0, h > 0 else { throw BackpackError.invalid("The crop is smaller than one source pixel.") }
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
    }
}

struct NativeAvatarSelection {
    let id = UUID()
    let bytes: Data
    let expectedVersion: UUID?
    let scope: UUID
    let orientedStill: CGImage
    init(url: URL, expectedVersion: UUID?, scope: UUID) throws {
        guard url.isFileURL else { throw BackpackError.invalid("Choose a local raster file.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 5_000_001) ?? Data()
        try self.init(bytes: data, expectedVersion: expectedVersion, scope: scope)
    }
    init(bytes data: Data, expectedVersion: UUID?, scope: UUID) throws {
        _ = try NativeAvatarInput.kind(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width * height <= 16_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw BackpackError.invalid("A safe oriented still preview is unavailable (16 megapixel limit).")
        }
        bytes = data; self.expectedVersion = expectedVersion; self.scope = scope; orientedStill = image
    }
    func preview(crop: NativeAvatarCrop?) throws -> CGImage {
        guard let crop else { return orientedStill }
        guard let image = orientedStill.cropping(to: try crop.rectangle(width: orientedStill.width, height: orientedStill.height)) else {
            throw BackpackError.invalid("Could not preview this crop.")
        }
        return image
    }
}

@MainActor
extension CommunityController {
    func loadViewerPreferences() async throws -> ViewerMediaPreferences {
        guard config?.viewerMediaPreferencesEnabled == true, let account = user?.id else {
            throw BackpackError.invalid("Saved viewer preferences are unavailable.")
        }
        let revision = accountRevision
        let result = try JSONDecoder().decode(ViewerMediaPreferences.self, from: await request("social/media-preferences",
            expectedAccountRevision: revision, expectedAccountID: account).data)
        try result.validate()
        guard accountRevision == revision, user?.id == account else { throw BackpackError.invalid("Account changed.") }
        applyViewerPreferences(result)
        return result
    }
    func saveViewerPreferences(_ value: ViewerMediaPreferences, animations: Bool, dataSaving: Bool) async throws {
        try value.validate()
        guard config?.viewerMediaPreferencesEnabled == true, let account = user?.id else { throw BackpackError.invalid("Saved viewer preferences are unavailable.") }
        let revision = accountRevision
        struct Body: Encodable { let expectedRevision: Int; let animationsEnabled, dataSaving: Bool }
        let result = try JSONDecoder().decode(ViewerMediaPreferences.self, from: await request("social/media-preferences",
            method: "PATCH", body: JSONEncoder().encode(Body(expectedRevision: value.revision,
                animationsEnabled: animations, dataSaving: dataSaving)), expectedAccountRevision: revision, expectedAccountID: account).data)
        try result.validate()
        guard accountRevision == revision, user?.id == account, result.animationsEnabled == animations, result.dataSaving == dataSaving else {
            throw BackpackError.invalid("The preference receipt changed. Reload; no automatic retry.")
        }
        applyViewerPreferences(result)
    }
}

@MainActor
struct ViewerMediaPreferencesView: View {
    @EnvironmentObject private var community: CommunityController
    @State private var saved: ViewerMediaPreferences?
    @State private var animations = true
    @State private var dataSaving = false
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Form {
            Text("Viewer-only settings. Static previews and explicit Play/download still use data. This does not change GIF timing, local originals or backpack playback.")
            if let mature = community.user?.allowMature {
                Toggle("Show mature avatars and community content", isOn: Binding(get: { community.user?.allowMature ?? mature }, set: { allowed in
                    perform { try await community.setMaturePreference(allowed, expectedRevision: community.accountRevision) }
                })).disabled(community.avatarPolicyChanging)
                Text("Applies to your own avatar, approved contributors, friends, events and administrators. It never grants access to otherwise private media.")
                    .font(.caption)
            } else { Text("This server has not supplied a saved mature-content preference. No preference is invented.").font(.caption) }
            if community.config?.viewerMediaPreferencesEnabled == true {
                Toggle("Animate visible media", isOn: $animations)
                Toggle("Data saving / manual playback", isOn: $dataSaving)
                if let saved { Button("Save captured revision \(saved.revision)") { perform {
                    try await community.saveViewerPreferences(saved, animations: animations, dataSaving: dataSaving)
                    self.saved = community.user?.mediaPreferences
                } } }
                Button("Reload saved preferences") { load() }
            } else { Text("Unavailable on this server. Existing viewer behavior is unchanged.") }
            if busy { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }.disabled(busy).navigationTitle("Motion and data")
            .task(id: community.accountRevision) { saved = nil; failure = nil; busy = false; if community.config?.viewerMediaPreferencesEnabled == true { load() } }
    }

    private func load() { perform {
        saved = nil
        let result = try await community.loadViewerPreferences()
        saved = result; animations = result.animationsEnabled; dataSaving = result.dataSaving
    } }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; failure = nil
        let epoch = community.accountRevision
        Task {
            do { try await work() }
            catch { if community.accountRevision == epoch { failure = "\(error.localizedDescription) Reload on conflict; changes are not retried." } }
            if community.accountRevision == epoch { busy = false }
        }
    }
}

@MainActor
struct AccountApprovedProfileAvatar: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = CommunityFeatureSession()
    let person: SocialPerson
    var body: some View {
        Group {
            if let client = session.client, community.config?.avatarsEnabled == true {
                CommunityProfileAvatar(person: person, client: client)
            } else { Image(systemName: "person.crop.circle").resizable().scaledToFit() }
        }.task(id: "\(community.accountRevision):\(community.avatarPolicyRevision):\(community.config?.avatarsEnabled == true)") { session.bind(community) }
            .onDisappear { session.clear() }
    }
}
