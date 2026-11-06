import SwiftUI
import BackpackProtocol

struct ChatReferenceSelection: Encodable {
    let kind: String
    let id: UUID
    let expectedRevision, expectedParticipationRevision: Int?
    init(gif: UUID) { kind = "communityGif"; id = gif; expectedRevision = nil; expectedParticipationRevision = nil }
    init(event: SharedChatEvent) throws {
        guard event.revision > 0, event.participationRevision > 0, event.status != "ended", event.status != "cancelled" else {
            throw BackpackError.invalid("Select a current, available event; review changed revisions before sharing.")
        }
        kind = "event"; id = event.id; expectedRevision = event.revision; expectedParticipationRevision = event.participationRevision
    }
    private enum CodingKeys: String, CodingKey { case kind, id, expectedRevision, expectedParticipationRevision }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        try c.encodeIfPresent(expectedParticipationRevision, forKey: .expectedParticipationRevision)
    }
}
struct SharedChatEvent: Decodable, Identifiable {
    let id: UUID
    let title, visibility, status, startsAtISO, endsAtISO, timezone: String
    let revision, participationRevision: Int
    let location: CatalogEventLocation
    let coverUrl: String?
    let coverRevision: Int?
    func dates(locale: Locale = .autoupdatingCurrent) throws -> String {
        guard let zone = TimeZone(identifier: timezone) else { throw BackpackError.invalid("Invalid event timezone.") }
        try location.validate()
        let start = try CatalogEventTime.parse(startsAtISO), end = try CatalogEventTime.parse(endsAtISO)
        guard end > start else { throw BackpackError.invalid("Invalid event interval.") }
        let format = DateFormatter(); format.locale = locale; format.dateStyle = .medium; format.timeStyle = .short; format.timeZone = zone
        return "\(format.string(from: start)) – \(format.string(from: end)) (\(timezone))"
    }
}
struct SharedChatGIF: Decodable, Identifiable {
    let id: UUID
    let title, attribution, license, gifUrl, previewUrl: String
    let mature, animated: Bool
    let width, height: Int
}
struct HydratedChatReference: Decodable {
    let kind: String
    let available: Bool
    let event: SharedChatEvent?
    let gif: SharedChatGIF?
    let changed, planChanged: Bool
    private enum CodingKeys: String, CodingKey { case kind, available, changed, planChanged }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind); available = try c.decode(Bool.self, forKey: .available)
        guard ["event", "communityGif"].contains(kind) else { throw BackpackError.invalid("Unsupported shared-reference kind.") }
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? false
        planChanged = try c.decodeIfPresent(Bool.self, forKey: .planChanged) ?? false
        event = available && kind == "event" ? try SharedChatEvent(from: decoder) : nil
        gif = available && kind == "communityGif" ? try SharedChatGIF(from: decoder) : nil
        if let event { _ = try event.dates() }
    }
    var fingerprint: String {
        "\(kind):\(available):\(event?.id.uuidString ?? gif?.id.uuidString ?? ""):\(event?.revision ?? 0):\(event?.participationRevision ?? 0):\(event?.coverRevision ?? 0):\(gif?.gifUrl ?? ""):\(changed):\(planChanged)"
    }
}
enum ChatReferenceMedia {
    static func path(_ raw: String, context: ChatConversation?, event: UUID? = nil) throws -> (String, [URLQueryItem]) {
        guard let p = URLComponents(string: raw), p.scheme == nil, p.host == nil, p.fragment == nil,
              raw.hasPrefix("/api/v1/"), !p.percentEncodedPath.contains("%"), !p.path.contains("\\") else {
            throw BackpackError.invalid("Shared media must remain canonical and API-root relative.")
        }
        let parts = p.path.split(separator: "/").map(String.init)
        if let event {
            guard parts.count == 7, parts[2] == "events", parts[3] == event.uuidString.lowercased(),
                  parts[4] == "assets", UUID(uuidString: parts[5]) != nil, parts[6] == "image.png",
                  p.query == nil else { throw BackpackError.invalid("Wrong approved event cover scope.") }
        } else {
            guard parts.count == 6 || parts.count == 7, Array(parts.prefix(4)) == ["api", "v1", "social", "chat-references"],
                  ["original.gif", "preview.png", "16x16.gif", "64x64.gif", "96x128.gif"].contains(parts.last ?? "") else {
                throw BackpackError.invalid("Only scoped reference GIF media is permitted.")
            }
            if parts.count == 7 {
                guard parts[4] == "catalog", UUID(uuidString: parts[5]) != nil, let context,
                      let query = p.queryItems, query.count == context.query.count,
                      context.query.allSatisfy({ expected in query.filter { $0.name == expected.name && $0.value == expected.value }.count == 1 }) else {
                    throw BackpackError.invalid("Picker media belongs to a different sending context.")
                }
            } else {
                guard UUID(uuidString: parts[4]) != nil, p.query == nil else { throw BackpackError.invalid("Wrong message/history reference media scope.") }
            }
        }
        return (String(p.path.dropFirst("/api/v1/".count)), p.queryItems ?? [])
    }
}
@MainActor
extension CommunityFeatureClient {
    func referenceGIFs(_ context: ChatConversation, page: Int, search: String) async throws -> (items: [HydratedChatReference], more: Bool) {
        guard chatReferencesEnabled, (1...1000).contains(page), search.utf16.count <= 120 else { throw BackpackError.invalid("Scoped GIF references are unavailable or the search/page is invalid.") }
        struct Page: Decodable { let items: [HydratedChatReference]; let page: Int; let hasMore: Bool }
        let result = try JSONDecoder().decode(Page.self, from: await send(.messaging, "social/chat-references/catalog",
            query: context.query + [.init(name: "page", value: String(page)), .init(name: "q", value: search)]))
        guard result.page == page, result.items.count <= 24 else { throw BackpackError.invalid("Invalid bounded reference picker response.") }
        return (result.items, result.hasMore)
    }
    func referenceEvents(_ context: ChatConversation, page: Int) async throws -> (items: [SharedChatEvent], more: Bool) {
        guard chatReferencesEnabled, (1...1000).contains(page) else { throw BackpackError.invalid("Scoped event references are unavailable.") }
        struct Page: Decodable { let events: [SharedChatEvent]; let page: Int; let hasMore: Bool }
        let result = try JSONDecoder().decode(Page.self, from: await send(.messaging, "social/chat-references/events",
            query: context.query + [.init(name: "page", value: String(page))]))
        guard result.page == page, result.events.count <= 24 else { throw BackpackError.invalid("Invalid bounded event picker response.") }
        for event in result.events { _ = try event.dates() }
        return (result.events, result.hasMore)
    }
    func referenceMedia(_ raw: String, context: ChatConversation?, event: UUID? = nil) async throws -> Data {
        guard chatReferencesEnabled, !referencePolicyChanging else { throw BackpackError.invalid("Shared media policy/access is changing or unavailable.") }
        let policy = referencePolicyRevision
        let target = try ChatReferenceMedia.path(raw, context: context, event: event)
        let bytes = try await send(event == nil ? .messaging : .events, target.0, query: target.1, maxBytes: 5_000_000)
        try Task.checkCancellation()
        guard chatReferencesEnabled, !referencePolicyChanging, referencePolicyRevision == policy else {
            throw BackpackError.invalid("Discarding shared media returned under an older policy.")
        }
        return bytes
    }
}
@MainActor
struct ChatReferenceCardView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.accessibilityReduceMotion) private var reduced
    let card: HydratedChatReference
    let client: CommunityFeatureClient
    var context: ChatConversation? = nil
    var reconciliationEpoch = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !card.available || community.avatarPolicyChanging || !client.chatReferencesEnabled {
                Label("Shared content unavailable", systemImage: "rectangle.slash").foregroundStyle(.secondary)
            } else if let gif = card.gif {
                GIFThumbnail(key: "reference:\(client.instanceID):\(card.fingerprint):\(reconciliationEpoch):\(reduced):\(community.avatarPolicyRevision)", cache: false) {
                    try await client.referenceMedia(reduced || !gif.animated ? gif.previewUrl : gif.gifUrl, context: context)
                }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 16))
                Text(gif.title).font(.headline)
                Text("\(gif.attribution) • \(gif.license)").font(.caption).foregroundStyle(.secondary)
            } else if let event = card.event {
                if let cover = event.coverUrl {
                    GIFThumbnail(key: "event-card:\(client.instanceID):\(card.fingerprint):\(reconciliationEpoch):\(community.avatarPolicyRevision)", cache: false) {
                        try await client.referenceMedia(cover, context: nil, event: event.id)
                    }.frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Label(event.title, systemImage: "calendar").font(.headline)
                SharedChatEventDateView(event: event)
                Text(event.location.label).font(.subheadline)
                if card.changed || card.planChanged { Label("Event changed — review current details", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                NavigationLink("Review event / RSVP") { CommunityEventDetailView(id: event.id) }
                Text("Sharing is not an invitation, RSVP or access grant. No GPS/progress is enabled.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).glassPanel()
    }
}
@MainActor
private struct SharedChatEventDateView: View {
    let event: SharedChatEvent
    @State private var label: String?
    @State private var failure: String?
    var body: some View {
        Group { if let label { Text(label).font(.caption) }; if let failure { Text(failure).foregroundStyle(.orange) } }
            .task(id: "\(event.revision):\(event.timezone)") { do { label = try event.dates() } catch { failure = error.localizedDescription } }
    }
}
@MainActor
struct ChatReferencePicker: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    let client: CommunityFeatureClient
    let context: ChatConversation
    let choose: (ChatReferenceSelection) -> Void
    @State private var events = false
    @State private var search = ""
    @State private var page = 1
    @State private var gifs: [HydratedChatReference] = []
    @State private var eventRows: [SharedChatEvent] = []
    @State private var more = false
    @State private var failure: String?
    @State private var selected: ChatReferenceSelection?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Share a reference into this exact conversation. Private events require current organizer access; no invitation or attendance is granted.").font(.caption)
                    Picker("Content", selection: $events) { Text("Community GIF").tag(false); Text("Event").tag(true) }.pickerStyle(.segmented)
                    if !events { TextField("Search approved community GIFs", text: $search).textFieldStyle(.roundedBorder) }
                    if let failure { Text(failure).foregroundStyle(.orange) }
                    if events {
                        ForEach(eventRows) { event in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(event.title).font(.headline); SharedChatEventDateView(event: event); Text(event.location.label)
                                Text("Event revision \(event.revision) · participation plan \(event.participationRevision)").font(.caption).foregroundStyle(.secondary)
                                Button("Review sharing this event") { do { selected = try ChatReferenceSelection(event: event) } catch { failure = error.localizedDescription } }
                            }.padding(16).glassPanel()
                        }
                    } else {
                        ForEach(Array(gifs.enumerated()), id: \.offset) { _, card in
                            if let gif = card.gif, card.available {
                                ChatReferenceCardView(card: card, client: client, context: context)
                                Button("Share this community GIF") { selected = ChatReferenceSelection(gif: gif.id) }
                            }
                        }
                    }
                    HStack { Button("Previous") { page -= 1 }.disabled(page == 1); Spacer(); Button("Next") { page += 1 }.disabled(!more) }
                }.padding(20)
            }.modernScene().navigationTitle("Share into chat").toolbar { Button("Cancel") { dismiss() } }
            .task(id: "\(events):\(search):\(page):\(community.avatarPolicyRevision)") {
                gifs = []; eventRows = []; selected = nil; more = false; failure = nil
                do {
                    if events { let result = try await client.referenceEvents(context, page: page); try Task.checkCancellation(); eventRows = result.items; more = result.more }
                    else { let result = try await client.referenceGIFs(context, page: page, search: search); try Task.checkCancellation(); gifs = result.items; more = result.more }
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
            .onChange(of: community.accountRevision) { _, _ in dismiss() }
            .onChange(of: events) { _, _ in page = 1 }
            .onChange(of: search) { _, _ in page = 1 }
            .onChange(of: community.avatarPolicyChanging) { _, changing in if changing { gifs = []; eventRows = []; selected = nil; dismiss() } }
            .confirmationDialog("Share this displayed reference?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { Button("Attach reference to draft") { choose(selected); dismiss() } }
            } message: {
                Text("Displayed event revision \(selected?.expectedRevision.map(String.init) ?? "not applicable"), participation plan \(selected?.expectedParticipationRevision.map(String.init) ?? "not applicable"). A changed/unavailable reference is rejected, never automatically rebased. Nothing is sent until Send.")
            }
        }
    }
}
