import XCTest
@testable import LEDBackpack

final class SocialTabTests: XCTestCase {
    private func config(_ fields: [String: Any]) throws -> CommunityConfig {
        var values = fields; values["requireEmailVerification"] = false
        return try JSONDecoder().decode(CommunityConfig.self, from: JSONSerialization.data(withJSONObject: values))
    }
    func testSocialTabIsARealDistinctApplicationTab() {
        XCTAssertNotEqual(AppTab.social, .library)
        XCTAssertNotEqual(AppTab.social, .create)
    }
    func testGuestCannotGainPrivateSocialAccessFromCapabilities() throws {
        let config = try config(["socialEnabled":true,"messagingEnabled":true,"eventsEnabled":true,"gifSwapPresenceEnabled":true])
        for feature in [SocialFeature.friends,.messages,.events,.gifSwap] {
            XCTAssertFalse(feature.available(config, signedIn: false))
        }
    }
    func testMissingCapabilitiesStayUnavailableNotSilentTrueDefaults() throws {
        let config = try config([:])
        for feature in [SocialFeature.friends,.nearby,.friendSessions,.events,.messages,.playlists,.appleAlerts] {
            XCTAssertFalse(feature.available(config, signedIn: true))
        }
    }
    func testSwapGameDoesNotRequireFriendDiscoverabilityOrMessaging() throws {
        let config = try config(["gifSwapPresenceEnabled":true,"socialEnabled":false,"messagingEnabled":false])
        XCTAssertTrue(SocialFeature.gifSwap.available(config, signedIn: true))
        XCTAssertFalse(SocialFeature.friends.available(config, signedIn: true))
    }
    func testKeylessPeerWithdrawalRemainsIndependentOfReportCreation() throws {
        let config = try config(["peerIncidentReportsEnabled":false,"peerIncidentWithdrawalEnabled":true,"messagingEnabled":false,"socialEnabled":false])
        XCTAssertTrue(SocialFeature.peerReports.available(config, signedIn: true))
    }
    func testMessageRequestsRequireTheirIndependentActualCapability() throws {
        let config = try config(["messagingEnabled":true,"chatMessageRequestsEnabled":false])
        XCTAssertTrue(SocialFeature.messages.available(config, signedIn: true))
        XCTAssertFalse(SocialFeature.messageRequests.available(config, signedIn: true))
    }
    func testNearbyAndFriendSessionsRetainPurposeSeparatedAvailability() throws {
        let config = try config(["socialEnabled":true,"nearbyDiscoveryEnabled":true,"friendSessionsAvailable":false])
        XCTAssertTrue(SocialFeature.nearby.available(config, signedIn: true))
        XCTAssertFalse(SocialFeature.friendSessions.available(config, signedIn: true))
    }
}
