import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor PeerIncidentFixtureTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    var late: (@MainActor @Sendable () -> Void)?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func setLate(_ action: @escaping @MainActor @Sendable () -> Void) { late = action }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected private-peer fixture request.") }
        let value = responses.removeFirst()
        if request.url?.path.contains("peer-reports") == true { await late?() }
        return value
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class PeerIncidentFixtureVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class PeerIncidentTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let target = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let id = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let now = "2026-11-06T12:00:00Z"
    private let expiry = "2026-12-06T12:00:00Z"
    private let explanation = "Deliberately typed unverified allegation"
    private func user(role: String) -> String {
        #"{"id":"\#(owner)","email":"test@example.invalid","displayName":"Reporter","role":"\#(role)","verified":true}"#
    }
    private func reply(_ raw: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(raw.utf8)) }
    private func report(staff: Bool = false, revision: Int = 1, resolved: Bool = false, reviewed: Bool = false, verified: Bool = false) -> String {
        let reporter = staff ? #","reporterId":"\#(owner)""# : ""
        let review = reviewed ? #","review":{"note":"Literal staff note","atISO":"\#(now)"}"# : ""
        return #"{"id":"\#(id)","reportedUserId":"\#(target)","category":"unexpected-content","details":"\#(explanation)","revision":\#(revision),"resolved":\#(resolved),"claimVerified":\#(verified),"createdAtISO":"\#(now)","expiresAtISO":"\#(expiry)"\#(reporter)\#(review)}"#
    }
    private func receipt(expired: Bool = false) -> String {
        #"{"id":"\#(id)","reportedUserId":"\#(target)","revision":2,"resolved":true,"claimVerified":false,"createdAtISO":"\#(now)","expiresAtISO":"\#(expiry)","expired":\#(expired)}"#
    }
    private func setup(_ responses: [CommunityResponse], reports: Bool = true, withdrawal: Bool = true,
        social: Bool = true, admin: Bool = false) async throws -> (CommunityController, CommunityFeatureClient, PeerIncidentFixtureTransport) {
        let login = reply(#"{"user":\#(user(role: admin ? "admin" : "user")),"token":"synthetic-private-peer-report-session","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(#"{"requireEmailVerification":false,"socialEnabled":\#(social),"peerIncidentReportsEnabled":\#(reports),"peerIncidentWithdrawalEnabled":\#(withdrawal)}"#)
        let transport = PeerIncidentFixtureTransport([login, config] + responses)
        let controller = CommunityController(vault: PeerIncidentFixtureVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    private func selection(_ community: CommunityController) throws -> PeerIncidentSelection {
        try PeerIncidentSelection(peer: LocalMetFriend(id: target, displayName: "Explicitly selected minimal card", canRequestFriendship: false), community: community)
    }
    func testSelectedPeerConsentPayloadContainsNoAutomaticArtworkHashEvidenceOrProfileData() async throws {
        let (community, _, _) = try await setup([])
        let selected = try selection(community)
        XCTAssertThrowsError(try PeerIncidentIntent(selection: selected, category: .other, details: explanation, consent: false, community: community))
        let intent = try PeerIncidentIntent(selection: selected, category: .unexpectedContent, details: explanation, consent: true, community: community)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["reportedUserId","category","details","consent"])
        XCTAssertEqual(body["reportedUserId"] as? String, target.uuidString.lowercased())
        XCTAssertNil(body["gif"]); XCTAssertNil(body["hash"]); XCTAssertNil(body["coordinates"])
        XCTAssertFalse(String(decoding: intent.data, as: UTF8.self).contains(selected.label))
    }
    func testUtf16ExplanationBoundsTrimAndLiteralScriptLookingText() throws {
        XCTAssertEqual(try PeerIncidentText.checked("  <script>literal</script>  "), "<script>literal</script>")
        XCTAssertThrowsError(try PeerIncidentText.checked("  "))
        XCTAssertNoThrow(try PeerIncidentText.checked(String(repeating: "a", count: 1000)))
        XCTAssertThrowsError(try PeerIncidentText.checked(String(repeating: "😀", count: 501)))
    }
    func testSelectionRemainsAValueSnapshotIndependentOfGameStopButInvalidatesAccountOrOrigin() async throws {
        let (community, _, _) = try await setup([])
        let selected = try selection(community), context = selected.id
        let intent = try PeerIncidentIntent(selection: selected, category: .other, details: explanation, consent: true, community: community)
        XCTAssertEqual(intent.selection.id, context)
        try selected.check(community) // No game-enabled/session-array/radio dependency.
        community.configure("https://different.example")
        XCTAssertThrowsError(try selected.check(community))
        XCTAssertThrowsError(try PeerIncidentIntent(selection: selected, category: .other, details: explanation, consent: true, community: community))
    }
    func testOwnerDescriptionDecoderRejectsStaffNotesAndReporterFields() throws {
        let value = try JSONDecoder().decode(NativePeerIncident.self, from: Data(report(staff: true, reviewed: true).utf8))
        XCTAssertThrowsError(try value.validate(staff: false))
        XCTAssertNoThrow(try value.validate(staff: true))
    }
    func testResolvedAndReviewedClaimsCanNeverBecomeVerifiedMisconductOrIdentityProof() throws {
        let value = try JSONDecoder().decode(NativePeerIncident.self, from: Data(report(staff: true, revision: 2, resolved: true, reviewed: true).utf8))
        try value.validate(staff: true); XCTAssertFalse(value.claimVerified)
        let invalid = try JSONDecoder().decode(NativePeerIncident.self, from: Data(report(staff: true, verified: true).utf8))
        XCTAssertThrowsError(try invalid.validate(staff: true))
    }
    func testMetadataReceiptStrictlyRejectsCategoryExplanationOrReviewEvenWhenEmpty() throws {
        _ = try JSONDecoder().decode(NativePeerIncidentReceipt.self, from: Data(receipt().utf8))
        for field in [#""details":"""#, #""category":"other""#, #""review":{}"#] {
            let raw = String(receipt().dropLast()) + "," + field + "}"
            XCTAssertThrowsError(try JSONDecoder().decode(NativePeerIncidentReceipt.self, from: Data(raw.utf8)))
        }
    }
    func testKeylessReceiptsRemainIndependentFromDisabledDescriptionsAndGeneralSocialFeatures() async throws {
        let page = #"{"receipts":[\#(receipt(expired: true))],"page":1,"limit":24,"hasMore":false,"descriptionsIncluded":false,"serverTimeISO":"\#(expiry)"}"#
        let (_, client, transport) = try await setup([reply(page)], reports: false, social: false)
        let value = try await client.ownPeerReceipts(page: 1)
        XCTAssertTrue(value.receipts[0].expired); XCTAssertFalse(value.descriptionsIncluded)
        do { _ = try await client.ownPeerIncidents(page: 1); XCTFail("No fake description fallback") } catch {}
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].url?.path, "/api/v1/social/peer-reports/receipts")
    }
    func testKnownOwnedExpiredWithdrawalNeedsOnlyCapturedIdRevisionNotGameFriendProfileOrKey() async throws {
        let (_, client, transport) = try await setup([reply(#"{"withdrawn":true,"accountActionTaken":false}"#)], reports: false, social: false)
        try await client.withdrawPeerIncident(id: id, expectedRevision: 7)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].httpMethod, "DELETE")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Int])
        XCTAssertEqual(body, ["expectedRevision":7])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Catalog-Expected-Account"), owner.uuidString.lowercased())
    }
    func testCreateUnknownClaimedIdentifierDoesNotLookupTargetOrCopyPeerContent() async throws {
        let response = #"{"report":\#(report()),"serverTimeISO":"\#(now)"}"#
        let (community, client, transport) = try await setup([reply(response)])
        let intent = try PeerIncidentIntent(selection: selection(community), category: .unexpectedContent, details: explanation, consent: true, community: community)
        let value = try await client.submitPeerIncident(intent, community: community)
        XCTAssertFalse(value.report.claimVerified)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].url?.path, "/api/v1/social/peer-reports")
        XCTAssertFalse(requests.contains { $0.url?.path.contains("/profiles/") == true })
    }
    func testChangedExplanationConflictRetainsExactIntentWithoutRetryOrRebase() async throws {
        let (community, client, transport) = try await setup([reply(#"{"error":{"code":"peer_report_exists","message":"Withdraw the previous case explicitly"}}"#, status: 409)])
        let intent = try PeerIncidentIntent(selection: selection(community), category: .unexpectedContent, details: explanation, consent: true, community: community)
        let original = intent.data
        do { _ = try await client.submitPeerIncident(intent, community: community); XCTFail("Conflict") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 409) }
        XCTAssertEqual(intent.data, original)
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].httpBody, original)
    }
    func testLateAccountSwitchDiscardsReportResponseAndCannotAdoptItIntoNewOwner() async throws {
        let (community, client, transport) = try await setup([reply(#"{"report":\#(report()),"serverTimeISO":"\#(now)"}"#)])
        let intent = try PeerIncidentIntent(selection: selection(community), category: .unexpectedContent, details: explanation, consent: true, community: community)
        await transport.setLate { community.configure("https://different.example") }
        do { _ = try await client.submitPeerIncident(intent, community: community); XCTFail("Late owner") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
    func testOnlyCurrentGlobalAdminCanObtainStaffReviewClient() async throws {
        let (ordinary, _, _) = try await setup([])
        XCTAssertThrowsError(try CommunityAdminClient(ordinary))
        let (admin, _, transport) = try await setup([reply(#"{"user":\#(user(role: "user"))}"#)], admin: true)
        let client = try CommunityAdminClient(admin)
        try await admin.refreshUser()
        do { _ = try await client.peerIncidents(page: 1); XCTFail("Current role lost") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
    func testAdminReviewCapturesRevisionLiteralNoteAndNoAccountAction() async throws {
        let response = #"{"report":\#(report(staff: true, revision: 2, resolved: true, reviewed: true)),"accountActionTaken":false,"serverTimeISO":"\#(now)"}"#
        let (community, _, transport) = try await setup([reply(response)], admin: true)
        let initial = try JSONDecoder().decode(NativePeerIncident.self, from: Data(report(staff: true).utf8))
        let intent = try PeerIncidentReviewIntent(report: initial, resolved: true, note: " Literal staff note ")
        let value = try await CommunityAdminClient(community).reviewPeerIncident(intent)
        XCTAssertFalse(value.report.claimVerified); XCTAssertEqual(value.accountActionTaken, false)
        let requests = await transport.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["expectedRevision","resolved","note"])
        XCTAssertEqual(body["expectedRevision"] as? Int, 1); XCTAssertEqual(body["note"] as? String, "Literal staff note")
    }
    func testWithdrawalRevisionConflictIsExplicitAndNeverChangesAccountState() async throws {
        let (_, client, transport) = try await setup([reply(#"{"error":{"code":"peer_report_revision_conflict","message":"Reload owned receipt"}}"#, status: 409)], reports: false)
        do { try await client.withdrawPeerIncident(id: id, expectedRevision: 1); XCTFail("Conflict") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.code, "peer_report_revision_conflict") }
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
    func testDescriptionReadStopsAtExactRetentionBoundaryWhileReceiptsCanRemain() throws {
        let page = #"{"reports":[\#(report())],"page":1,"limit":24,"hasMore":false,"serverTimeISO":"\#(expiry)"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(NativePeerIncidentPage.self, from: Data(page.utf8)).validate(requested: 1, staff: false))
        let metadata = #"{"receipts":[\#(receipt(expired: true))],"page":1,"limit":24,"hasMore":false,"descriptionsIncluded":false,"serverTimeISO":"\#(expiry)"}"#
        XCTAssertNoThrow(try JSONDecoder().decode(NativePeerIncidentReceipts.self, from: Data(metadata.utf8)).validate(requested: 1))
    }
    func testReporterRoleChangeInvalidatesCapturedSelectedPeerEvenWithoutAnotherGame() async throws {
        let (community, _, _) = try await setup([reply(#"{"user":\#(user(role: "admin"))}"#)])
        let captured = try selection(community), epoch = community.accountRevision
        try await community.refreshUser()
        XCTAssertEqual(community.accountRevision, epoch)
        XCTAssertThrowsError(try captured.check(community))
    }
}
