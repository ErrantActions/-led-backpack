import SwiftUI
import BackpackProtocol

struct NativeChatPublishedPlaylist: Decodable, Identifiable {
    let id: UUID
    let title, description, expiresAtISO: String
    let order: NativePlaylistOrder
    let entryCount: Int
    let privateScheduleIncluded, privateCloudIncluded: Bool
    let url: String?
    var publishedID: NativePublishedPlaylistID { .init(value: id) }
    func validate(now: Date = Date()) throws {
        guard !privateScheduleIncluded, !privateCloudIncluded, (1...120).contains(title.utf16.count),
              description.utf16.count <= 1000, (1...100).contains(entryCount),
              try CatalogEventTime.parse(expiresAtISO) > now else { throw BackpackError.invalid("Published playlist is expired or has invalid public-only metadata.") }
        if let url { _ = try Self.referenceID(url) }
    }
    static func referenceID(_ raw: String) throws -> UUID {
        guard let c = URLComponents(string: raw), c.scheme == nil, c.host == nil, c.query == nil, c.fragment == nil,
              c.percentEncodedPath == c.path, c.path.hasPrefix("/chat-playlist/"),
              let id = UUID(uuidString: String(c.path.dropFirst("/chat-playlist/".count))),
              c.path == "/chat-playlist/\(id.uuidString.lowercased())" else {
            throw BackpackError.invalid("Only this exact authenticated chat reference may open the playlist.")
        }
        return id
    }
}
struct NativeChatPlaylistManifest: Decodable {
    let title, description, expiresAtISO: String
    let order: NativePlaylistOrder
    let entryCount: Int
    let privateScheduleIncluded, privateCloudIncluded: Bool
    let entries: [NativeHydratedPlaylistEntry]
    func validate(reference: UUID, now: Date = Date()) throws {
        guard !privateScheduleIncluded, !privateCloudIncluded, (1...120).contains(title.utf16.count),
              description.utf16.count <= 1000, (1...100).contains(entryCount), entries.count == entryCount,
              try CatalogEventTime.parse(expiresAtISO) > now else { throw BackpackError.invalid("Shared playlist expired or is no longer available.") }
        for entry in entries {
            try entry.validate()
            if let item = entry.item {
                _ = try Self.mediaPath(item.previewUrl, reference: reference, item: item.id)
                _ = try Self.mediaPath(item.gifUrl, reference: reference, item: item.id)
            }
        }
    }
    static func mediaPath(_ url: URL, reference: UUID, item: UUID) throws -> String {
        let prefix = "/api/v1/social/chat-references/\(reference.uuidString.lowercased())/playlist/items/\(item.uuidString.lowercased())/"
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == nil, c.host == nil,
              c.query == nil, c.fragment == nil, c.percentEncodedPath == c.path, c.path.hasPrefix(prefix),
              ["preview.png", "original.gif", "16x16.gif", "64x64.gif", "96x128.gif"].contains(String(c.path.dropFirst(prefix.count))) else {
            throw BackpackError.invalid("Playlist media is not authorized by this exact chat reference and item.")
        }
        return String(c.path.dropFirst("/api/v1/".count))
    }
}
struct NativeChatPublishedPlaylistPage: Decodable { let playlists: [NativeChatPublishedPlaylist]; let hasMore: Bool }
@MainActor
extension CommunityFeatureClient {
    func chatPublishedPlaylists(_ context: ChatConversation, page: Int) async throws -> NativeChatPublishedPlaylistPage {
        guard chatPlaylistReferencesEnabled, (1...1000).contains(page) else { throw BackpackError.invalid("Published playlist chat references unavailable.") }
        let value = try JSONDecoder().decode(NativeChatPublishedPlaylistPage.self, from: await send(.messaging,
            "social/chat-references/playlists", query: context.query + [.init(name: "page", value: String(page))]))
        guard chatPlaylistReferencesEnabled, value.playlists.count <= 20 else { throw BackpackError.invalid("Invalid published-share picker.") }
        for playlist in value.playlists { try playlist.validate() }
        return value
    }
    func chatPlaylistManifest(_ reference: UUID) async throws -> NativeChatPlaylistManifest {
        guard chatPlaylistReferencesEnabled, !referencePolicyChanging else { throw BackpackError.invalid("Playlist references unavailable.") }
        let policy = referencePolicyRevision
        let value = try JSONDecoder().decode(NativeChatPlaylistManifest.self, from: await send(.messaging,
            "social/chat-references/\(reference.uuidString.lowercased())/playlist"))
        try value.validate(reference: reference)
        guard chatPlaylistReferencesEnabled, policy == referencePolicyRevision, !referencePolicyChanging else {
            throw BackpackError.invalid("Playlist authorization changed.")
        }
        return value
    }
    func chatPlaylistMedia(_ reference: UUID, itemID: UUID, animated: Bool) async throws -> Data {
        let policy = referencePolicyRevision
        let before = try await chatPlaylistManifest(reference)
        guard let entry = before.entries.first(where: { $0.available && $0.item?.id == itemID }), let item = entry.item else {
            throw BackpackError.invalid("Playlist entry unavailable.")
        }
        let path = try NativeChatPlaylistManifest.mediaPath(animated ? item.gifUrl : item.previewUrl, reference: reference, item: itemID)
        let bytes = try await send(.messaging, path, maxBytes: 5_000_000)
        let after = try await chatPlaylistManifest(reference)
        guard policy == referencePolicyRevision, after.entries.contains(where: {
            $0.available && $0.item?.id == itemID && $0.item?.gifUrl == item.gifUrl && $0.item?.previewUrl == item.previewUrl
        }) else { throw BackpackError.invalid("Playlist entry changed during media I/O.") }
        return bytes
    }
}
@MainActor
struct NativeChatPlaylistCard: View {
    let playlist: NativeChatPublishedPlaylist
    let client: CommunityFeatureClient
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading) {
            Label(playlist.title, systemImage: "list.bullet.rectangle")
            Text(playlist.description)
            Text("\(playlist.entryCount) public entries · expires \(playlist.expiresAtISO)").font(.caption)
            if let url = playlist.url {
                Button("Review current snapshot (paused)") { open = true }
                    .sheet(isPresented: $open) { NativeChatPlaylistViewer(rawReference: url, client: client) }
            }
            Text("Reference only. No playlist edits, playback, RSVP, friendship or library access.").font(.caption)
        }
    }
}
@MainActor
struct NativeChatPlaylistViewer: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    let rawReference: String
    let client: CommunityFeatureClient
    @State private var manifest: NativeChatPlaylistManifest?
    @State private var reference: UUID?
    @State private var failure: String?
    @State private var generation = UUID()
    @State private var previewItem: UUID?
    @State private var previewUntil: Date?
    var body: some View {
        NavigationStack {
            List {
                if let manifest, let reference {
                    Text(manifest.title).font(.headline); Text(manifest.description)
                    Text("Paused · \(manifest.order.rawValue) · expires \(manifest.expiresAtISO)").font(.caption)
                    ForEach(Array(manifest.entries.enumerated()), id: \.offset) { _, entry in
                        if entry.available, let item = entry.item {
                            VStack {
                                GIFThumbnail(key: "chat-playlist:\(client.instanceID):\(generation):\(item.id):\(previewItem == item.id)", cache: false) {
                                    try await client.chatPlaylistMedia(reference, itemID: item.id, animated: previewItem == item.id)
                                }.frame(height: 140).accessibilityLabel(item.title)
                                Button(previewItem == item.id ? "Pause preview" : "Preview this entry for up to 10 seconds") {
                                    if previewItem == item.id { previewItem = nil; previewUntil = nil }
                                    else { previewItem = item.id; previewUntil = Date().addingTimeInterval(min(10, Double(entry.durationMilliseconds) / 1000)) }
                                }
                            }
                        } else { Text("Entry unavailable") }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.orange) }
                Button("Reload current authorized snapshot") { generation = UUID() }
                Text("No automatic sequence, device playback, schedule or private-library restore. Downloaded public copies cannot be recalled.").font(.caption)
            }.navigationTitle("Chat playlist").toolbar { Button("Close") { dismiss() } }
                .task(id: "\(generation):\(phase):\(community.accountRevision):\(community.chatAccessRevision):\(community.user?.role ?? ""):\(community.avatarPolicyRevision):\(community.config?.chatReferencesEnabled == true):\(community.config?.messagingEnabled == true):\(community.config?.chatPlaylistReferencesEnabled == true)") {
                    manifest = nil; reference = nil; previewItem = nil; previewUntil = nil
                    guard phase == .active, client.chatPlaylistReferencesEnabled, !community.avatarPolicyChanging else { return }
                    do {
                        let id = try NativeChatPublishedPlaylist.referenceID(rawReference)
                        while !Task.isCancelled {
                            let value = try await client.chatPlaylistManifest(id)
                            try Task.checkCancellation(); try client.check(.messaging)
                            manifest = value; reference = id
                            try await Task.sleep(for: .seconds(5))
                        }
                    } catch {
                        manifest = nil; reference = nil; previewItem = nil
                        if !Task.isCancelled { failure = error.localizedDescription }
                    }
                }
                .task(id: previewUntil) {
                    guard let deadline = previewUntil else { return }
                    do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))); previewItem = nil; previewUntil = nil }
                    catch { return }
                }
                .onChange(of: community.accountRevision) { _, _ in manifest = nil; previewItem = nil; dismiss() }
                .onChange(of: community.chatAccessRevision) { _, _ in manifest = nil; previewItem = nil; dismiss() }
                .onChange(of: community.avatarPolicyChanging) { _, changing in if changing { manifest = nil; previewItem = nil } }
                .onDisappear { manifest = nil; reference = nil; previewItem = nil }
        }
    }
}
