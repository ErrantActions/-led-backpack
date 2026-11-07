import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor NearbyFixtureTransport: CommunityTransport {
    var replies: [CommunityResponse]
    var requests: [URLRequest] = []
    var late: (@MainActor @Sendable () -> Void)?
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func setLate(_ action: @escaping @MainActor @Sendable () -> Void) { late = action }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected nearby fixture request.") }
        let value = replies.removeFirst()
        if request.url?.path.hasPrefix("/api/v1/social/nearby") == true { await late?() }
        return value
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class NearbyFixtureVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class NearbyDiscoveryTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let presence = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let peer = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private var token: String { Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    private func reply(_ raw: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(raw.utf8)) }
    private func state(look: Bool = true, discoverable: Bool = false, token: Bool = false, seconds: Int = 120) -> String {
        let extra = token ? #","advertisementToken":"\#(self.token)""# : ""
        let tokenExpiry = discoverable ? #""2026-11-06T12:02:00Z""# : "null"
        let end = seconds == 120 ? "2026-11-06T12:02:00Z" : "2026-11-06T12:05:00Z"
        return #"{"presenceId":"\#(presence)","lookForFriends":\#(look),"discoverable":\#(discoverable),"ownedByCurrentSession":true,"expiresAtISO":"\#(end)","tokenExpiresAtISO":\#(tokenExpiry),"serverTimeISO":"2026-11-06T12:00:00Z","gpsUsed":false,"encounterHistoryStored":false,"physicalProximityVerified":false,"backgroundDiscoveryVerified":false\#(extra)}"#
    }
    private func setup(_ replies: [CommunityResponse], enabled: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, NearbyFixtureTransport) {
        let login = reply(#"{"user":{"id":"\#(owner)","email":"test@example.invalid","displayName":"Owner","role":"admin","verified":true},"token":"synthetic-nearby-session","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(#"{"requireEmailVerification":false,"socialEnabled":true,"nearbyDiscoveryEnabled":\#(enabled)}"#)
        let transport = NearbyFixtureTransport([login, config] + replies)
        let controller = CommunityController(vault: NearbyFixtureVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    func testCanonicalOpaqueTokenDecoderRejectsNamesPaddingAndOversize() throws {
        XCTAssertEqual(try NearbyTokenPolicy.decode(Data(token.utf8)), token)
        for value in [token + "=", "person@example.invalid", String(repeating: "A", count: 44), String(repeating: "_", count: 43)] {
            XCTAssertThrowsError(try NearbyTokenPolicy.decode(Data(value.utf8)))
        }
    }
    func testReadOnlyCharacteristicOffsetsNeverLeakExpiredOrStoppedTokens() throws {
        let data = Data(token.utf8)
        XCTAssertEqual(try NearbyTokenPolicy.readValue(data, offset: 20, active: true, expired: false), data.suffix(23))
        XCTAssertEqual(try NearbyTokenPolicy.readValue(data, offset: 43, active: true, expired: false), Data())
        XCTAssertThrowsError(try NearbyTokenPolicy.readValue(data, offset: 44, active: true, expired: false))
        XCTAssertThrowsError(try NearbyTokenPolicy.readValue(data, offset: 0, active: true, expired: true))
        XCTAssertThrowsError(try NearbyTokenPolicy.readValue(data, offset: 0, active: false, expired: false))
    }
    func testDefaultOffAndIndependentRadioControlsWithoutInitializingBluetooth() throws {
        var gate = NearbyTransportGate()
        XCTAssertFalse(gate.scanning); XCTAssertFalse(gate.advertising)
        try gate.arm(look: true, discoverable: false, foreground: true, ready: true, consent: true)
        XCTAssertTrue(gate.scanning); XCTAssertFalse(gate.advertising)
        gate.stop()
        try gate.arm(look: false, discoverable: true, foreground: true, ready: true, consent: true)
        XCTAssertFalse(gate.scanning); XCTAssertTrue(gate.advertising)
        gate.stop(); XCTAssertFalse(gate.advertising)
    }
    func testBackgroundOrPermissionLossCannotAutomaticallyArmRadio() {
        var gate = NearbyTransportGate()
        XCTAssertThrowsError(try gate.arm(look: true, discoverable: true, foreground: false, ready: true, consent: true))
        XCTAssertThrowsError(try gate.arm(look: true, discoverable: true, foreground: true, ready: false, consent: true))
        XCTAssertThrowsError(try gate.arm(look: true, discoverable: true, foreground: true, ready: true, consent: false))
        XCTAssertFalse(gate.scanning); XCTAssertFalse(gate.advertising)
    }
    func testDuplicateReplayAndStaleObservationsAreRejectedWithinLocalEpoch() throws {
        var observed = NearbyObservedTokens()
        try observed.record(token, now: 0); try observed.record(token, now: 10)
        XCTAssertEqual(observed.fresh(now: 14), [token])
        XCTAssertTrue(observed.fresh(now: 16).isEmpty)
        try observed.record(token, now: 17)
        XCTAssertTrue(observed.fresh(now: 17).isEmpty)
        observed.clear(); try observed.record(token, now: 20)
        XCTAssertEqual(observed.fresh(now: 20), [token])
    }
    func testObservedBatchIsBoundedToThirtyTwoAndContainsNoPeripheralMetadata() throws {
        var observed = NearbyObservedTokens()
        for index in 0..<32 {
            let value = Data(repeating: UInt8(index), count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            try observed.record(value, now: 1)
        }
        XCTAssertEqual(observed.fresh(now: 2).count, 32)
        let extra = Data(repeating: 33, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try observed.record(extra, now: 2))
    }
    func testMissingServiceCapabilityCannotArmOrResolveEvenAsAdmin() async throws {
        let (_, client, transport) = try await setup([], enabled: false)
        do { _ = try await client.armNearby(expected: nil, look: true, discoverable: false); XCTFail("Missing capability") } catch {}
        do { _ = try await client.resolveNearby(presence, tokens: [token]); XCTFail("Missing capability") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 2)
    }
    func testLookOnlyArmingEncodesExplicitNullCaptureAndDoesNotAdvertiseToken() async throws {
        let (_, client, transport) = try await setup([reply(state())])
        let value = try await client.armNearby(expected: nil, look: true, discoverable: false)
        XCTAssertNil(value.advertisementToken)
        let requests = await transport.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertTrue(body["expectedPresenceId"] is NSNull)
        XCTAssertEqual(Set(body.keys), ["expectedPresenceId","lookForFriends","discoverable","consent","durationSeconds"])
        XCTAssertEqual(body["durationSeconds"] as? Int, 300)
        XCTAssertEqual(body["discoverable"] as? Bool, false)
    }
    func testServiceIssuedTokenLifetimeAndTruthfulHintFlagsAreRequired() throws {
        let valid = try JSONDecoder().decode(NativeNearbyState.self, from: Data(state(discoverable: true, token: true, seconds: 300).utf8))
        try valid.validate(requireToken: true)
        let expired = state(discoverable: true, token: true).replacingOccurrences(of: "12:02:00Z", with: "12:00:00Z")
        XCTAssertThrowsError(try JSONDecoder().decode(NativeNearbyState.self, from: Data(expired.utf8)).validate(requireToken: true))
        let tooLong = state(discoverable: true, token: true, seconds: 300).replacingOccurrences(of: #""tokenExpiresAtISO":"2026-11-06T12:02:00Z""#, with: #""tokenExpiresAtISO":"2026-11-06T12:03:00Z""#)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeNearbyState.self, from: Data(tooLong.utf8)).validate(requireToken: true))
    }
    func testResolvePayloadOnlyContainsObservedTokensAndExactPresence() async throws {
        let result = #"{"contacts":[{"id":"\#(peer)","displayName":"Minimal peer"}],"distanceOrdering":false,"friendshipCreated":false,"physicalProximityVerified":false,"gpsUsed":false,"encounterHistoryStored":false}"#
        let (_, client, transport) = try await setup([reply(result)])
        let contacts = try await client.resolveNearby(presence, tokens: [token])
        XCTAssertEqual(contacts.count, 1); XCTAssertNil(contacts[0].eventBadges)
        let requests = await transport.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["expectedPresenceId","tokens"])
        XCTAssertEqual(body["tokens"] as? [String], [token])
    }
    func testLateAccountSwitchCannotRevealObservedContactCards() async throws {
        let raw = #"{"contacts":[],"distanceOrdering":false,"friendshipCreated":false,"physicalProximityVerified":false,"gpsUsed":false,"encounterHistoryStored":false}"#
        let (controller, client, transport) = try await setup([reply(raw)])
        await transport.setLate { controller.configure("https://different.example") }
        do { _ = try await client.resolveNearby(presence, tokens: [token]); XCTFail("Late account") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
    func testWithdrawalRequiresStoppedStateRatherThanBluetoothWriteSuccess() async throws {
        let stopped = #"{"presenceId":null,"lookForFriends":false,"discoverable":false,"ownedByCurrentSession":false,"expiresAtISO":null,"tokenExpiresAtISO":null,"serverTimeISO":"2026-11-06T12:00:00Z","gpsUsed":false,"encounterHistoryStored":false,"physicalProximityVerified":false,"backgroundDiscoveryVerified":false}"#
        let (_, client, transport) = try await setup([reply(stopped)])
        try await client.withdrawNearby(presence)
        let requests = await transport.history()
        XCTAssertEqual(requests[2].httpMethod, "DELETE")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String])
        XCTAssertEqual(body, ["expectedPresenceId":presence.uuidString.lowercased()])
    }
}
