import Foundation
import Combine
import BackpackProtocol

struct DeviceRecoveryTimeline {
    let account, id: UUID
    private(set) var conversation: DeviceRecoveryConversation?
    private(set) var messages: [DeviceRecoveryMessage] = []
    private(set) var before: Int?
    private(set) var hasMore = true

    mutating func append(_ page: DeviceRecoveryHistory) throws {
        guard hasMore else { throw BackpackError.invalid("Recovery history is already complete.") }
        try page.validate(account: account, id: id, before: before, limit: 50)
        if let prior = conversation {
            guard prior.revision == page.conversation.revision, prior.state == page.conversation.state,
                  prior.role == page.conversation.role, prior.peer.id == page.conversation.peer.id,
                  prior.createdAtISO == page.conversation.createdAtISO,
                  prior.expiresAtISO == page.conversation.expiresAtISO,
                  prior.deviceId == page.conversation.deviceId else {
                throw BackpackError.invalid("The recovery conversation changed while loading. Refresh it.")
            }
        }
        let combined = page.messages + messages
        guard combined.count <= 100, Set(combined.map(\.id)).count == combined.count,
              Set(combined.map(\.sequence)).count == combined.count,
              !page.hasMore || combined.count < 100 else {
            throw BackpackError.invalid("Recovery history exceeded its bounds or repeated a message.")
        }
        conversation = page.conversation; messages = combined
        before = page.nextBefore; hasMore = page.hasMore
    }
}

@MainActor
final class DeviceRecoveryThreadStore: ObservableObject {
    @Published private(set) var conversation: DeviceRecoveryConversation?
    @Published private(set) var messages: [DeviceRecoveryMessage] = []
    @Published private(set) var pending: DeviceRecoveryIntent?
    @Published private(set) var pendingElsewhere: UUID?
    @Published private(set) var busy = false
    @Published private(set) var writing = false
    @Published private(set) var failure: String?
    @Published private(set) var draftFailure: String?
    @Published private(set) var closed = false
    @Published var text = ""
    private var scope: AccountServiceScope?
    private var generation = UUID()
    private var id: UUID?
    private let outbox: DeviceRecoveryOutbox

    init(outbox: DeviceRecoveryOutbox? = nil) {
        self.outbox = outbox ?? DeviceRecoveryOutbox(vault: CommunityKeychain())
    }

    var canCompose: Bool {
        guard let conversation, !closed, pending == nil, !writing else { return false }
        return conversation.state == .accepted || conversation.role == .owner && conversation.state == .pending
    }
    var canSend: Bool {
        canCompose && !busy && pendingElsewhere == nil
            && (1...1000).contains(text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count)
    }

    func flushDraft() throws {
        guard let scope, let conversation else { return }
        try outbox.saveDraft(text, account: scope.accountID, origin: scope.origin.url.absoluteString,
            conversation: conversation)
        draftFailure = nil
    }

    func saveDraft() {
        do { try flushDraft() }
        catch { draftFailure = error.localizedDescription }
    }

    func clear() {
        generation = UUID(); scope = nil; id = nil
        conversation = nil; messages = []; text = ""; pending = nil; pendingElsewhere = nil
        busy = false; writing = false; closed = false; failure = nil; draftFailure = nil
    }

    func bind(_ community: CommunityController, id: UUID) async {
        let retainedFailure: String?
        do { try flushDraft(); retainedFailure = nil }
        catch { retainedFailure = error.localizedDescription }
        clear(); draftFailure = retainedFailure; self.id = id
        do {
            let scope = try AccountServiceScope(community, capability: .devices)
            self.scope = scope
            try restorePending(scope)
        } catch { failure = error.localizedDescription; return }
        await refresh(restoreDraft: true)
    }

    private func checked(_ scope: AccountServiceScope, _ stamp: UUID) throws {
        try Task.checkCancellation()
        guard generation == stamp, self.scope?.revision == scope.revision else { throw CancellationError() }
        try scope.checkDeviceRegistry(recovery: true)
    }

    private func restorePending(_ scope: AccountServiceScope) throws {
        pending = nil; pendingElsewhere = nil
        if let value = try outbox.load(account: scope.accountID, origin: scope.origin.url.absoluteString, kind: .message) {
            if value.conversationID == id { pending = value; text = value.text }
            else if value.state == .uncertain { pendingElsewhere = value.conversationID }
        }
    }

    private func history(_ scope: AccountServiceScope, _ stamp: UUID, id: UUID) async throws -> DeviceRecoveryTimeline {
        var timeline = DeviceRecoveryTimeline(account: scope.accountID, id: id)
        for _ in 0..<2 {
            try checked(scope, stamp)
            let page = try await scope.recoveryHistory(id, before: timeline.before)
            try checked(scope, stamp)
            try timeline.append(page)
            if !timeline.hasMore { return timeline }
        }
        throw BackpackError.invalid("Recovery history did not finish within its message limit.")
    }

    func refresh(restoreDraft: Bool = false) async {
        guard !busy, let scope, let id else { return }
        let stamp = generation
        busy = true; failure = nil
        defer { if generation == stamp { busy = false } }
        do {
            let result = try await history(scope, stamp, id: id)
            conversation = result.conversation; messages = result.messages
            try restorePending(scope)
            if restoreDraft, pending == nil, let conversation {
                text = try outbox.draft(account: scope.accountID, origin: scope.origin.url.absoluteString,
                    conversation: conversation) ?? ""
            }
        } catch {
            guard generation == stamp, !Task.isCancelled else { return }
            conversation = nil; messages = []; failure = error.localizedDescription
        }
    }

    func send(retry: Bool = false) async {
        guard !busy, let scope, let id else { return }
        let stamp = generation
        let capturedText = text
        busy = true; writing = true; failure = nil
        defer { if generation == stamp { busy = false; writing = false } }
        var receipt: DeviceRecoveryMessage?
        do {
            try checked(scope, stamp)
            let latest = try await history(scope, stamp, id: id)
            guard var context = latest.conversation else {
                throw BackpackError.invalid("Recovery conversation is unavailable.")
            }
            conversation = context; messages = latest.messages
            guard context.state == .accepted || context.role == .owner && context.state == .pending else {
                throw BackpackError.invalid("Wait for the registered account to reply before sending another message.")
            }
            let intent: DeviceRecoveryIntent
            if retry {
                guard let pending else { throw BackpackError.invalid("No pending reply to retry.") }
                intent = pending
            } else {
                guard pending == nil, pendingElsewhere == nil else {
                    throw BackpackError.invalid("Resolve the pending reply before starting another.")
                }
                if let resolved = try outbox.load(account: scope.accountID, origin: scope.origin.url.absoluteString, kind: .message) {
                    try outbox.clearResolved(resolved)
                }
                intent = try DeviceRecoveryIntent(account: scope.accountID, origin: scope.origin.url.absoluteString,
                    peer: context.peer.id, kind: .message, conversationID: id, text: capturedText,
                    expiresAt: CatalogEventTime.parse(context.expiresAtISO))
                try outbox.save(intent)
                pending = intent; text = intent.text
            }
            try intent.requireRetry(account: scope.accountID, origin: scope.origin.url.absoluteString,
                peer: context.peer.id, conversation: id)
            try outbox.requireCurrent(intent)
            if context.role == .owner, context.state == .pending {
                context = try await scope.respondRecovery(context, accept: true)
                try checked(scope, stamp)
                conversation = context
            }
            try checked(scope, stamp)
            let result = try await scope.sendRecovery(intent, conversation: context)
            receipt = result
            try checked(scope, stamp)
            try outbox.acknowledge(intent, receipt: result.id)
            try outbox.saveDraft("", account: scope.accountID, origin: scope.origin.url.absoluteString, conversation: context)
            let acknowledged = try outbox.load(account: scope.accountID, origin: scope.origin.url.absoluteString, kind: .message)
            if let acknowledged { try outbox.clearResolved(acknowledged) }
            pending = nil; text = ""; draftFailure = nil
            messages = (messages.filter { $0.id != result.id } + [result]).sorted { $0.sequence < $1.sequence }
        } catch {
            guard generation == stamp, !Task.isCancelled else { return }
            if let receipt {
                messages = (messages.filter { $0.id != receipt.id } + [receipt]).sorted { $0.sequence < $1.sequence }
                failure = "Sent, but local delivery state could not be saved: \(error.localizedDescription) Refresh before clearing the pending reply."
            } else { failure = error.localizedDescription }
        }
    }

    func discardPending() {
        guard !busy, let pending else { return }
        do {
            try outbox.discard(pending)
            self.pending = nil; text = ""; failure = nil
            try flushDraft()
        } catch { failure = error.localizedDescription }
    }

    func close() async {
        guard !busy, let scope, let conversation else { return }
        let stamp = generation
        busy = true; writing = true; failure = nil
        defer { if generation == stamp { busy = false; writing = false } }
        do {
            try checked(scope, stamp)
            _ = try await scope.closeRecovery(conversation)
            try checked(scope, stamp)
            closed = true; self.conversation = nil; messages = []
            if let pending { try outbox.discard(pending); self.pending = nil }
            try outbox.saveDraft("", account: scope.accountID, origin: scope.origin.url.absoluteString, conversation: conversation)
            text = ""
        } catch {
            guard generation == stamp, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}
