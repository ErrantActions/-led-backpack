import SwiftUI
import BackpackProtocol

struct NativeMessageRequestPreference: Decodable {
    let revision: Int
    let enabled: Bool
    func validate() throws {
        guard (0...9_007_199_254_740_991).contains(revision) else { throw BackpackError.invalid("Invalid request preference revision.") }
    }
}
struct NativeMessageRequest: Decodable, Identifiable {
    enum State: String, Decodable { case pending, accepted, declined, revoked }
    struct Intro: Decodable { let id: UUID; let text: String; let createdAt: Double }
    let id: UUID
    let revision: Int
    let state: State
    let available, incoming: Bool
    let createdAtISO: String
    let contact: SocialPerson?
    let message: Intro?
    func validate(account: UUID) throws {
        let created = try CatalogEventTime.parse(createdAtISO)
        guard (1...9_007_199_254_740_991).contains(revision), created.timeIntervalSince1970.isFinite,
              available ? (state == .pending || state == .accepted) && contact != nil : contact == nil && message == nil,
              contact?.id != account else { throw BackpackError.invalid("Invalid current message request.") }
        if let contact {
            guard !contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  contact.displayName.utf16.count <= 80 else { throw BackpackError.invalid("Invalid named request contact.") }
        }
        if let message {
            guard message.id == id, (1...1000).contains(message.text.utf16.count),
                  message.createdAt.isFinite, abs(message.createdAt - created.timeIntervalSince1970 * 1000) < 1 else {
                throw BackpackError.invalid("Invalid request introduction.")
            }
        }
    }
    func acceptedConversation(account: UUID) throws -> ChatConversation {
        try validate(account: account)
        guard available, state == .accepted, let contact else { throw BackpackError.invalid("This request does not grant an accepted direct thread.") }
        return .direct(peer: contact.id, event: nil)
    }
}
struct NativeMessageRequestControl {
    let requestID: UUID
    let accept: Bool?
    let data: Data
    init(_ request: NativeMessageRequest, account: UUID, accept: Bool?) throws {
        try request.validate(account: account)
        guard request.available, request.state == .pending || request.state == .accepted,
              accept == nil || request.incoming && request.state == .pending else {
            throw BackpackError.invalid("Reload this request before deciding.")
        }
        struct Body: Encodable { let expectedRevision: Int; let accept: Bool? }
        requestID = request.id; self.accept = accept
        data = try JSONEncoder().encode(Body(expectedRevision: request.revision, accept: accept))
    }
}
struct NativeMessageRequestPage: Decodable {
    let requests: [NativeMessageRequest]
    let page: Int
    let hasMore: Bool
}
struct NativeMessageRequestContacts: Decodable {
    let contacts: [SocialPerson]
    let hasMore: Bool
    let nextAfter: UUID?
}
struct NativeMessageRequestIntent {
    let account, recipient, clientID: UUID
    let data: Data
    let createdAt: Date
    init(account: UUID, contact: SocialPerson, text: String, consent: Bool, clientID: UUID = UUID(), now: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard consent, account != contact.id, !contact.displayName.isEmpty, (1...1000).contains(text.utf16.count) else {
            throw BackpackError.invalid("Choose a current named contact and deliberately approve one introduction.")
        }
        struct Body: Encodable { let recipientId, clientMessageId, text: String }
        data = try JSONEncoder().encode(Body(recipientId: contact.id.uuidString.lowercased(),
            clientMessageId: clientID.uuidString.lowercased(), text: text))
        self.account = account; recipient = contact.id; self.clientID = clientID; createdAt = now
    }
}
@MainActor
extension CommunityFeatureClient {
    private func requestData(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard messageRequestsEnabled else { throw BackpackError.invalid("Non-friend message requests are unavailable.") }
        let data = try await send(.messaging, path, method: method, body: body, query: query)
        guard messageRequestsEnabled else { throw BackpackError.invalid("Message request support was withdrawn.") }
        return data
    }
    func messageRequestPreference() async throws -> NativeMessageRequestPreference {
        let value = try JSONDecoder().decode(NativeMessageRequestPreference.self, from: await requestData("social/message-request-preferences"))
        try value.validate(); return value
    }
    func saveMessageRequestPreference(_ original: NativeMessageRequestPreference, enabled: Bool) async throws -> NativeMessageRequestPreference {
        try original.validate()
        struct Body: Encodable { let expectedRevision: Int; let enabled: Bool }
        let value = try JSONDecoder().decode(NativeMessageRequestPreference.self, from: await requestData("social/message-request-preferences",
            method: "PATCH", body: JSONEncoder().encode(Body(expectedRevision: original.revision, enabled: enabled))))
        try value.validate()
        guard value.enabled == enabled, value.revision == original.revision + (enabled == original.enabled ? 0 : 1) else { throw BackpackError.invalid("Request opt-in was not confirmed.") }
        return value
    }
    func messageRequestContacts(search: String, after: UUID?) async throws -> NativeMessageRequestContacts {
        guard search.utf16.count <= 80 else { throw BackpackError.invalid("Search names using up to 80 characters.") }
        let value = try JSONDecoder().decode(NativeMessageRequestContacts.self, from: await requestData("social/message-request-contacts",
            query: [.init(name: "search", value: search)] + (after.map { [.init(name: "after", value: $0.uuidString.lowercased())] } ?? [])))
        guard value.contacts.count <= 24, Set(value.contacts.map(\.id)).count == value.contacts.count,
              value.contacts.allSatisfy({ $0.id != accountID && !$0.displayName.isEmpty && $0.displayName.utf16.count <= 80 }),
              value.nextAfter == value.contacts.last?.id else { throw BackpackError.invalid("Invalid eligible request contacts.") }
        return value
    }
    func messageRequests(page: Int) async throws -> NativeMessageRequestPage {
        guard (1...21).contains(page) else { throw BackpackError.invalid("Invalid request page.") }
        let value = try JSONDecoder().decode(NativeMessageRequestPage.self, from: await requestData("social/message-requests",
            query: [.init(name: "page", value: String(page)), .init(name: "state", value: "all")]))
        guard value.page == page, value.requests.count <= 24, Set(value.requests.map(\.id)).count == value.requests.count else {
            throw BackpackError.invalid("Invalid bounded request list.")
        }
        for request in value.requests { try request.validate(account: accountID) }
        return value
    }
    func controlMessageRequest(_ request: NativeMessageRequest, accept: Bool?) async throws {
        let intent = try NativeMessageRequestControl(request, account: accountID, accept: accept)
        struct Result: Decodable { let request: NativeMessageRequest }
        let value = try JSONDecoder().decode(Result.self, from: await requestData(
            "social/message-requests/\(request.id.uuidString.lowercased())" + (accept == nil ? "" : "/respond"),
            method: accept == nil ? "DELETE" : "POST", body: intent.data)).request
        try value.validate(account: accountID)
        let desired: NativeMessageRequest.State = accept.map { $0 ? .accepted : .declined } ?? .revoked
        guard value.id == request.id, value.revision == request.revision + 1, value.state == desired else {
            throw BackpackError.invalid("The captured request decision was not confirmed.")
        }
        communityChatPermissionChanged()
    }
}

@MainActor
struct CommunityMessageRequestsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var preference: NativeMessageRequestPreference?
    @State private var rows: [NativeMessageRequest] = []
    @State private var contacts: [SocialPerson] = []
    @State private var search = ""
    @State private var after: UUID?
    @State private var nextAfter: UUID?
    @State private var contactsMore = false
    @State private var page = 1
    @State private var more = false
    @State private var target: SocialPerson?
    @State private var text = ""
    @State private var consent = false
    @State private var intent: NativeMessageRequestIntent?
    @State private var storedIntro: NativeChatOutboxRecord?
    @State private var decision: NativeMessageRequest?
    @State private var selected: ChatScreenSelection?
    @State private var reporting: NativeChatMessage?
    var body: some View {
        List {
            if community.config?.chatMessageRequestsEnabled == true, !session.denied {
                Section("Separate opt-in") {
                    if let preference {
                        Text(preference.enabled ? "New non-friend requests enabled" : "New non-friend requests stopped (default off)")
                        Button(preference.enabled ? "Stop new requests" : "Opt in to new requests") {
                            session.run { client in
                                let value = try await client.saveMessageRequestPreference(preference, enabled: !preference.enabled)
                                try session.checked(client); self.preference = value
                            }
                        }
                    }
                    Text("Stopping new requests does not close existing permissions. Acceptance is not friendship, location consent or library access; only server-authorized history from the introduction is shared.")
                }
                Section("Current requests") {
                    ForEach(rows) { row in
                        VStack(alignment: .leading) {
                            Text(row.contact?.displayName ?? "Unavailable request").font(.headline)
                            Text("\(row.state.rawValue) · revision \(row.revision)")
                            if let intro = row.message { Text(intro.text) }
                            if row.available, row.incoming, row.message != nil, community.config?.chatReportsEnabled == true {
                                Button("Explain an incident (no content copied)") { prepareIncident(row) }
                            }
                            if row.available {
                                if row.state == .accepted, let contact = row.contact {
                                    Button("Open authorized conversation") {
                                        do {
                                            guard let account = community.user?.id else { throw BackpackError.invalid("Sign in before opening this request.") }
                                            selected = .init(context: try row.acceptedConversation(account: account), title: contact.displayName)
                                        }
                                        catch { localFailure = error.localizedDescription }
                                    }
                                }
                                Button("Review request controls") { decision = row }
                                if let contact = row.contact {
                                    Button("Inspect my stored introduction") { inspectIntro(contact) }
                                    Button("Block this contact", role: .destructive) {
                                        session.run({ try await $0.block(contact.id) }, success: { clearPrivate(); load() })
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Previous") { page -= 1; load() }.disabled(page == 1)
                        Button("Next") { page += 1; load() }.disabled(!more || page == 21)
                    }
                }
                Section("One deliberate introduction") {
                    TextField("Search current eligible names", text: $search)
                    Button("Search eligible contacts") { after = nil; loadContacts() }.disabled(intent != nil)
                    ForEach(contacts) { contact in Button(contact.displayName) { target = contact; consent = false; inspectIntro(contact) } .disabled(intent != nil) }
                    if contactsMore { Button("More eligible names") { after = nextAfter; loadContacts() }.disabled(intent != nil) }
                    if let target { Text("To: \(target.displayName)") }
                    if let storedIntro {
                        Text("Stored introduction: \(storedIntro.state.rawValue)").font(.caption)
                        Button("Retry this same introduction / ID") {
                            session.run { client in
                                do {
                                    let result = try await client.submitOutbox(storedIntro)
                                    try session.checked(client); self.storedIntro = result
                                } catch {
                                    try session.checked(client)
                                    self.storedIntro = try NativeChatOutbox.load(origin: client.origin.url.absoluteString, account: client.accountID,
                                        context: storedIntro.context, purpose: .introduction)
                                    throw error
                                }
                            } success: { load() }
                        }.disabled(storedIntro.state != .uncertain)
                        if storedIntro.state == .uncertain {
                            Button("Abandon uncertain introduction (may have delivered)", role: .destructive) {
                                do {
                                    var abandoned = storedIntro; abandoned.state = .abandoned; abandoned.acknowledgedMessageID = nil
                                    try NativeChatOutbox.save(abandoned); try NativeChatOutbox.archiveTerminal(abandoned)
                                    self.storedIntro = nil; intent = nil; text = ""; consent = false; target = nil
                                } catch { localFailure = error.localizedDescription }
                            }
                        }
                        if storedIntro.state != .uncertain {
                            Button("Archive terminal introduction receipt (not resend)") {
                                do { try NativeChatOutbox.archiveTerminal(storedIntro); self.storedIntro = nil; intent = nil; text = ""; consent = false; target = nil }
                                catch { localFailure = error.localizedDescription }
                            }
                        }
                    }
                    TextField("Introduction (1–1,000 characters)", text: $text, axis: .vertical).disabled(intent != nil || storedIntro != nil)
                    Toggle("Send this one encrypted introduction", isOn: $consent).disabled(intent != nil || storedIntro != nil)
                    Button(intent == nil ? "Send introduction" : "Reconcile by exact introduction retry") { sendIntro() }
                        .disabled(storedIntro != nil || intent == nil && (target == nil || !consent))
                    Text("Server-managed encryption, not E2EE. No GIF, pin, attachment or earlier history is included. No silent retries. Limits: 10 new/day, 50 pending/recipient, 500 descriptors/account, 20,000/server, 120 polls/minute and 20 shared social mutations/minute. Pending expires after 14 days; closed descriptors remain up to 30 days.")
                }
                Button("Reload current requests and opt-in") { load() }
            } else { Text("Non-friend message requests are unavailable on this server.") }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let localFailure { Text(localFailure).foregroundStyle(.orange) }
        }.disabled(session.busy).modernScene().navigationTitle("Message requests")
        .task(id: "\(community.accountRevision):\(community.chatAccessRevision):\(community.user?.role ?? ""):\(community.config?.messagingEnabled == true):\(community.config?.chatMessageRequestsEnabled == true):\(phase)") {
            clearPrivate(); session.clear()
            guard phase == .active, community.config?.chatMessageRequestsEnabled == true else { return }
            session.bind(community); load()
        }
        .onChange(of: session.denied) { _, value in if value { clearPrivate() } }
        .onChange(of: community.chatAccessRevision) { _, _ in session.clear(); clearPrivate() }
        .onChange(of: community.config?.chatReportsEnabled) { _, _ in reporting = nil }
        .task(id: "requests:\(community.accountRevision):\(phase):\(community.config?.chatMessageRequestsEnabled == true)") {
            guard phase == .active, community.config?.chatMessageRequestsEnabled == true else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if !session.busy, decision == nil { load() }
            }
        }
        .onDisappear { session.clear(); clearPrivate() }
        .navigationDestination(item: $selected) { item in CommunityConversationView(context: item.context, title: item.title) }
        .sheet(item: $reporting) { message in
            MessageIncidentComposeView(message: message, context: .direct(peer: message.senderId, event: nil))
        }
        .confirmationDialog("Apply this displayed request revision?", isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } })) {
            if let row = decision {
                if row.incoming && row.state == .pending {
                    Button("Accept later direct history only") { control(row, accept: true) }
                    Button("Decline", role: .destructive) { control(row, accept: false) }
                }
                Button(row.state == .accepted ? "Close request permission" : "Cancel request", role: .destructive) { control(row, accept: nil) }
            }
        } message: { Text("A conflict requires reload and a fresh deliberate decision; no automatic revision replacement.") }
    }
    private func control(_ row: NativeMessageRequest, accept: Bool?) {
        session.run({ try await $0.controlMessageRequest(row, accept: accept) }, success: { decision = nil; load() })
    }
    @State private var localFailure: String?
    private func prepareIncident(_ request: NativeMessageRequest) {
        do {
            guard let account = community.user?.id, request.available, request.incoming,
                  let intro = request.message, let contact = request.contact else { throw BackpackError.invalid("Reload the currently available introduction.") }
            try request.validate(account: account)
            reporting = NativeChatMessage(id: intro.id, senderId: contact.id, text: "", createdAt: intro.createdAt,
                senderName: contact.displayName, recipientId: account)
        } catch { localFailure = error.localizedDescription }
    }
    private func inspectIntro(_ contact: SocialPerson) {
        guard let client = session.client else { return }
        do {
            storedIntro = try NativeChatOutbox.load(origin: client.origin.url.absoluteString, account: client.accountID,
                context: .direct(peer: contact.id, event: nil), purpose: .introduction)
            localFailure = nil
        } catch { localFailure = error.localizedDescription }
    }
    private func load() {
        guard community.config?.chatMessageRequestsEnabled == true else { return }
        rows = []; decision = nil
        session.run { client in
            let pref = try await client.messageRequestPreference()
            let result = try await client.messageRequests(page: page)
            try session.checked(client); preference = pref; rows = result.requests; more = result.hasMore
            if let reporting, !result.requests.contains(where: { $0.id == reporting.id && $0.available && $0.incoming }) { self.reporting = nil }
        }
    }
    private func loadContacts() {
        contacts = []; target = nil; consent = false
        session.run { client in
            let result = try await client.messageRequestContacts(search: search, after: after)
            try session.checked(client); contacts = result.contacts; contactsMore = result.hasMore; nextAfter = result.nextAfter
        }
    }
    private func sendIntro() {
        session.run { client in
            if intent == nil {
                guard let target else { throw BackpackError.invalid("Choose a current eligible named contact.") }
                intent = try .init(account: client.accountID, contact: target, text: text, consent: consent)
            }
            guard let intent else { throw BackpackError.invalid("No captured introduction.") }
            let context = ChatConversation.direct(peer: intent.recipient, event: nil)
            if let prior = try NativeChatOutbox.load(origin: client.origin.url.absoluteString, account: client.accountID,
                context: context, purpose: .introduction) {
                storedIntro = prior
                throw BackpackError.invalid("A stored introduction already exists. Review the current request or retry the same stored intent.")
            }
            let record = try NativeChatOutboxRecord(account: client.accountID, origin: client.origin.url.absoluteString,
                context: context, clientID: intent.clientID, bytes: intent.data, purpose: .introduction, consent: consent, now: intent.createdAt)
            try NativeChatOutbox.save(record); storedIntro = record
            let result = try await client.submitOutbox(record)
            try session.checked(client); storedIntro = result
            try session.checked(client); self.intent = nil; target = nil; text = ""; consent = false
        } success: { load() }
    }
    private func clearPrivate() {
        preference = nil; rows = []; contacts = []; target = nil; text = ""; consent = false; decision = nil; selected = nil; reporting = nil
        intent = nil; storedIntro = nil; nextAfter = nil; after = nil; contactsMore = false; more = false; localFailure = nil; search = ""
    }
}
