import Foundation
import BackpackProtocol

enum PeerIncidentCategory: String, Codable, CaseIterable, Identifiable {
    case spam, harassment, threat, unexpectedContent = "unexpected-content", other
    var id: String { rawValue }
}
enum PeerIncidentText {
    static func checked(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1000).contains(value.utf16.count), String(data: Data(value.utf8), encoding: .utf8) == value else {
            throw BackpackError.invalid("Enter a deliberate, well-formed explanation/note of 1–1000 UTF-16 code units.")
        }
        return value
    }
}
struct PeerIncidentSelection: Identifiable {
    let id = UUID()
    let reportedUserID: UUID
    let label: String
    let reporterID, accountEpoch: UUID
    let origin: CommunityOrigin
    let reporterRole: String
    @MainActor
    init(peer: LocalMetFriend, community: CommunityController) throws {
        try community.checkAccountSession()
        guard let reporter = community.user, let origin = community.origin, reporter.id != peer.id,
              (1...80).contains(peer.displayName.utf16.count) else { throw BackpackError.invalid("Explicitly select another minimal peer card under the current reporting account.") }
        reportedUserID = peer.id; label = peer.displayName; reporterID = reporter.id
        accountEpoch = community.accountRevision; self.origin = origin; reporterRole = reporter.role
    }
    @MainActor
    func check(_ community: CommunityController) throws {
        try community.checkAccountSession()
        guard community.user?.id == reporterID, community.accountRevision == accountEpoch,
              community.origin == origin, community.user?.role == reporterRole else {
            throw BackpackError.invalid("Reporter/server/role context changed. Discard this selected-peer draft; do not adopt it into another account.")
        }
    }
}
struct PeerIncidentIntent {
    let selection: PeerIncidentSelection
    let category: PeerIncidentCategory
    let details: String
    let data: Data
    @MainActor
    init(selection: PeerIncidentSelection, category: PeerIncidentCategory, details: String,
        consent: Bool, community: CommunityController) throws {
        try selection.check(community)
        guard consent else { throw BackpackError.invalid("Separate explicit consent is required before retaining your explanation.") }
        let explanation = try PeerIncidentText.checked(details)
        struct Body: Encodable { let reportedUserId: String; let category: PeerIncidentCategory; let details: String; let consent = true }
        self.selection = selection; self.category = category; self.details = explanation
        data = try JSONEncoder().encode(Body(reportedUserId: selection.reportedUserID.uuidString.lowercased(),
            category: category, details: explanation))
    }
}
struct NativePeerIncident: Decodable, Identifiable {
    let id, reportedUserId: UUID
    let category: PeerIncidentCategory
    let details: String
    let revision: Int
    let resolved, claimVerified: Bool
    let createdAtISO, expiresAtISO: String
    let reporterId: UUID?
    let review: Review?
    struct Review: Decodable { let note, atISO: String }
    func validate(staff: Bool) throws {
        guard revision >= 1, !claimVerified, staff ? reporterId != nil : reporterId == nil && review == nil else {
            throw BackpackError.invalid("Invalid peer-incident claim/owner/staff separation. Review never verifies a claim.")
        }
        guard try PeerIncidentText.checked(details) == details else { throw BackpackError.invalid("Invalid retained explanation.") }
        let start = try CatalogEventTime.parse(createdAtISO), end = try CatalogEventTime.parse(expiresAtISO)
        guard end > start, end.timeIntervalSince(start) <= 30 * 86400 else { throw BackpackError.invalid("Invalid case retention deadline.") }
        if let review { _ = try PeerIncidentText.checked(review.note); _ = try CatalogEventTime.parse(review.atISO) }
    }
}
struct NativePeerIncidentPage: Decodable {
    let reports: [NativePeerIncident]
    let page, limit: Int
    let hasMore: Bool
    let serverTimeISO: String
    func validate(requested: Int, staff: Bool) throws {
        let now = try CatalogEventTime.parse(serverTimeISO)
        guard page == requested, limit == 24, reports.count <= 24, Set(reports.map(\.id)).count == reports.count else {
            throw BackpackError.invalid("Invalid bounded peer-report page.")
        }
        for report in reports {
            try report.validate(staff: staff)
            guard try CatalogEventTime.parse(report.expiresAtISO) > now else { throw BackpackError.invalid("Description retention expired; use explicit metadata receipts for withdrawal.") }
        }
    }
}
struct NativePeerIncidentReceipt: Decodable, Identifiable {
    let id, reportedUserId: UUID
    let revision: Int
    let resolved, claimVerified, expired: Bool
    let createdAtISO, expiresAtISO: String
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let allowed: Set<String> = ["id","reportedUserId","revision","resolved","claimVerified","expired","createdAtISO","expiresAtISO"]
        guard Set(c.allKeys.map(\.stringValue)) == allowed else { throw BackpackError.invalid("Metadata-only receipt must not include descriptions, category, notes or encrypted content.") }
        func key(_ name: String) -> Key { Key(name) }
        id = try c.decode(UUID.self, forKey: key("id")); reportedUserId = try c.decode(UUID.self, forKey: key("reportedUserId"))
        revision = try c.decode(Int.self, forKey: key("revision")); resolved = try c.decode(Bool.self, forKey: key("resolved"))
        claimVerified = try c.decode(Bool.self, forKey: key("claimVerified")); expired = try c.decode(Bool.self, forKey: key("expired"))
        createdAtISO = try c.decode(String.self, forKey: key("createdAtISO")); expiresAtISO = try c.decode(String.self, forKey: key("expiresAtISO"))
        guard revision >= 1, !claimVerified else { throw BackpackError.invalid("Receipt cannot certify a claim.") }
        let created = try CatalogEventTime.parse(createdAtISO), expires = try CatalogEventTime.parse(expiresAtISO)
        guard expires > created, expires.timeIntervalSince(created) <= 30 * 86400 else { throw BackpackError.invalid("Invalid owned receipt retention metadata.") }
    }
}
struct NativePeerIncidentReceipts: Decodable {
    let receipts: [NativePeerIncidentReceipt]
    let page, limit: Int
    let hasMore, descriptionsIncluded: Bool
    let serverTimeISO: String
    func validate(requested: Int) throws {
        let now = try CatalogEventTime.parse(serverTimeISO)
        guard page == requested, limit == 24, receipts.count <= 24, !descriptionsIncluded,
              Set(receipts.map(\.id)).count == receipts.count else { throw BackpackError.invalid("Invalid labelled withdrawal-only page; no description fallback.") }
        for receipt in receipts {
            let deadline = try CatalogEventTime.parse(receipt.expiresAtISO)
            // Expiry can cross while the server constructs a page; it never blocks own withdrawal.
            guard !receipt.expired || deadline <= now else { throw BackpackError.invalid("Receipt expiry is inconsistent with server read time.") }
        }
    }
}
struct NativePeerIncidentResult: Decodable {
    let report: NativePeerIncident
    let serverTimeISO: String
    var accountActionTaken: Bool? = nil
}
struct PeerIncidentReviewIntent {
    let report: NativePeerIncident
    let resolved: Bool
    let note: String
    let data: Data
    init(report: NativePeerIncident, resolved: Bool, note: String) throws {
        try report.validate(staff: true)
        self.report = report; self.resolved = resolved; self.note = try PeerIncidentText.checked(note)
        struct Body: Encodable { let expectedRevision: Int; let resolved: Bool; let note: String }
        data = try JSONEncoder().encode(Body(expectedRevision: report.revision, resolved: resolved, note: self.note))
    }
}
@MainActor
extension CommunityFeatureClient {
    func submitPeerIncident(_ intent: PeerIncidentIntent, community: CommunityController) async throws -> NativePeerIncidentResult {
        try intent.selection.check(community)
        guard peerReportsAvailable, accountID == intent.selection.reporterID, origin == intent.selection.origin else {
            throw BackpackError.invalid("Encrypted peer report creation is unavailable or selected reporter context changed.")
        }
        let value = try JSONDecoder().decode(NativePeerIncidentResult.self, from: await send(.peerIncidents, "social/peer-reports",
            method: "POST", body: intent.data))
        try intent.selection.check(community); try value.report.validate(staff: false)
        let serverNow = try CatalogEventTime.parse(value.serverTimeISO)
        guard peerReportsAvailable, value.report.reportedUserId == intent.selection.reportedUserID,
              value.report.category == intent.category, value.report.details == intent.details,
              try CatalogEventTime.parse(value.report.expiresAtISO) > serverNow,
              value.accountActionTaken != true else { throw BackpackError.invalid("Captured unverified peer explanation was not confirmed without account action.") }
        return value
    }
    func ownPeerIncidents(page: Int) async throws -> NativePeerIncidentPage {
        guard peerReportsAvailable, (1...10000).contains(page) else { throw BackpackError.invalid("Peer descriptions require the actual encrypted-report capability.") }
        let result = try JSONDecoder().decode(NativePeerIncidentPage.self, from: await send(.peerIncidents, "social/peer-reports",
            query: [.init(name: "page", value: String(page)), .init(name: "limit", value: "24")]))
        guard peerReportsAvailable else { throw BackpackError.invalid("Peer description key/capability changed. Choose withdrawal-only mode explicitly.") }
        try result.validate(requested: page, staff: false); return result
    }
    func ownPeerReceipts(page: Int) async throws -> NativePeerIncidentReceipts {
        guard peerWithdrawalAvailable, (1...10000).contains(page) else { throw BackpackError.invalid("Owned metadata receipt management is unavailable.") }
        let result = try JSONDecoder().decode(NativePeerIncidentReceipts.self, from: await send(.peerIncidents, "social/peer-reports/receipts",
            query: [.init(name: "page", value: String(page)), .init(name: "limit", value: "24")]))
        guard peerWithdrawalAvailable else { throw BackpackError.invalid("Owned receipt management capability changed.") }
        try result.validate(requested: page); return result
    }
    func withdrawPeerIncident(id: UUID, expectedRevision: Int) async throws {
        guard peerWithdrawalAvailable, expectedRevision >= 1 else { throw BackpackError.invalid("Owned receipt and captured revision required; no event/game/key dependency.") }
        struct Body: Encodable { let expectedRevision: Int }
        struct Receipt: Decodable { let withdrawn, accountActionTaken: Bool }
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.peerIncidents, "social/peer-reports/\(id.uuidString.lowercased())",
            method: "DELETE", body: JSONEncoder().encode(Body(expectedRevision: expectedRevision))))
        guard peerWithdrawalAvailable, result.withdrawn, !result.accountActionTaken else { throw BackpackError.invalid("Owned withdrawal was not confirmed without account action.") }
    }
}
