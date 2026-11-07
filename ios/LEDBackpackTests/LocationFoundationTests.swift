import XCTest
@testable import LEDBackpack

final class LocationFoundationTests: XCTestCase {
    func testFreshAccurateSamplesRequireDwellAndExplicitManualAction() {
        var evaluator = LocalCheckpointEvaluator()
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 1, radius: 30, now: 0), .dwelling)
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 1, radius: 30, now: 9.99), .dwelling)
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 1, radius: 30, now: 10), .eligible)
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 1, radius: 30, now: 11), .cooldown)
    }
    func testStaleFutureAndUnusableAccuracyFailToManualWithoutExpandingRadius() {
        for (accuracy, age) in [(26.0,1.0),(-1,1),(3,5.01),(3,-1),(Double.nan,1)] {
            var evaluator = LocalCheckpointEvaluator()
            XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: accuracy, age: age, radius: 100, now: 1), .manual)
        }
    }
    func testHysteresisUsesAnInnerEntryBoundaryNeverAnEnlargedExitRadius() {
        var evaluator = LocalCheckpointEvaluator()
        XCTAssertEqual(evaluator.evaluate(distance: 26, accuracy: 3, age: 0, radius: 30, now: 0), .outside)
        XCTAssertEqual(evaluator.evaluate(distance: 24, accuracy: 3, age: 0, radius: 30, now: 1), .dwelling)
        XCTAssertEqual(evaluator.evaluate(distance: 26, accuracy: 3, age: 0, radius: 30, now: 11), .eligible)
        evaluator.reset()
        XCTAssertEqual(evaluator.evaluate(distance: 29, accuracy: 3, age: 0, radius: 30, now: 12), .outside)
    }
    func testOutsideAndSampleLossResetDwellButRetainCooldown() {
        var evaluator = LocalCheckpointEvaluator()
        _ = evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 20, now: 0)
        XCTAssertEqual(evaluator.evaluate(distance: 30, accuracy: 1, age: 0, radius: 20, now: 9), .outside)
        XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 20, now: 10), .dwelling)
        XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 20, now: 20), .eligible)
        evaluator.discardSample()
        XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 20, now: 21), .cooldown)
    }
    func testContextResetRequiresNewDwellAndCannotAutoRestart() {
        var evaluator = LocalCheckpointEvaluator()
        _ = evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 20, now: 0)
        evaluator.reset()
        XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 20, now: 10), .dwelling)
    }
    func testPerFriendMutualPermissionAndExplicitSessionConsentAreIndependent() throws {
        let id = UUID()
        let peer = try JSONDecoder().decode(SocialPerson.self, from: Data(#"{"id":"\#(id)","displayName":"Peer","locationFeaturesAllowed":true,"mutualLocationFeaturesAllowed":false}"#.utf8))
        XCTAssertThrowsError(try FriendSessionIntent(peer: peer, kind: .greeting, seconds: 60, consent: true))
        var mutual = peer; mutual.mutualLocationFeaturesAllowed = true
        XCTAssertThrowsError(try FriendSessionIntent(peer: mutual, kind: .greeting, seconds: 60, consent: false))
        XCTAssertNoThrow(try FriendSessionIntent(peer: mutual, kind: .greeting, seconds: 60, consent: true))
    }
    func testSessionIntentUsesOnlyControlFieldsNoLocationOrArtworkAndKeepsExactBytes() throws {
        let id = UUID(), clientID = UUID()
        let peer = SocialPerson(id: id, displayName: "Peer", locationFeaturesAllowed: true, mutualLocationFeaturesAllowed: true)
        let intent = try FriendSessionIntent(peer: peer, kind: .pass, seconds: 900, consent: true, clientID: clientID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["peerId","clientSessionId","kind","durationSeconds","consent"])
        XCTAssertEqual(object["clientSessionId"] as? String, clientID.uuidString.lowercased())
        XCTAssertEqual(object["durationSeconds"] as? Int, 900)
        let captured = intent.data; XCTAssertEqual(intent.data, captured)
        XCTAssertThrowsError(try FriendSessionIntent(peer: peer, kind: .greeting, seconds: 901, consent: true))
    }
    func testServiceSessionNeverClaimsPhysicalProximityPlaybackOrEncounterHistory() throws {
        let id = UUID()
        let raw = #"{"id":"\#(id)","revision":1,"durationSeconds":60,"kind":"greeting","direction":"incoming","status":"pending","peer":{"id":"\#(id)","displayName":"Peer"},"expiresAtISO":"2026-11-06T12:01:00Z","serverTimeISO":"2026-11-06T12:00:00Z","ownedByCurrentSession":false,"coordinatesIncluded":false,"physicalProximityVerified":false,"playbackStarted":false,"automaticGifExchangeEnabled":false,"clockSynchronizationVerified":false,"historyStored":false}"#
        let value = try JSONDecoder().decode(NativeFriendSession.self, from: Data(raw.utf8))
        try value.validate()
        let invalid = raw.replacingOccurrences(of: #""playbackStarted":false"#, with: #""playbackStarted":true"#)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeFriendSession.self, from: Data(invalid.utf8)).validate())
    }
    func testOptionalControlRevisionMissingDoesNotBecomeAZeroCapture() throws {
        let id = UUID()
        let old = #"{"profile":{"id":"\#(id)","displayName":"Owner"},"discoverable":false,"allowRequests":false,"messagingEnabled":false,"encryption":"server-managed"}"#
        let profile = try JSONDecoder().decode(SocialPreferences.self, from: Data(old.utf8))
        XCTAssertNil(profile.locationControlsRevision); XCTAssertNil(profile.friendSessionsAvailable)
        let list = try JSONDecoder().decode(SocialFriendsPage.self, from: Data(#"{"friends":[],"page":1,"limit":50,"locationControlsRevision":8}"#.utf8))
        XCTAssertEqual(list.locationControlsRevision, 8)
    }
    func testInvalidDistanceAndTinyRadiusNeverCertifyArrival() {
        var evaluator = LocalCheckpointEvaluator()
        XCTAssertEqual(evaluator.evaluate(distance: .infinity, accuracy: 1, age: 0, radius: 20, now: 0), .manual)
        XCTAssertEqual(evaluator.evaluate(distance: 0, accuracy: 3, age: 0, radius: 1, now: 10), .outside)
    }
}
