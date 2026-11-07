import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private struct NativePublicGuestVault: CommunityVault {
    func read(_ key: String) throws -> Data? { nil }
    func save(_ data: Data, key: String) throws {
        throw BackpackError.invalid("Read-only guest integration must not create credentials or receipts.")
    }
    func remove(_ key: String) throws {
        throw BackpackError.invalid("Read-only guest integration must not mutate credential storage.")
    }
}

@MainActor
final class NativePublicIntegrationTests: XCTestCase {
    func testLiveGuestConfigCatalogAndTrustedDownloadThroughNativeClient() async throws {
        guard ProcessInfo.processInfo.environment["NATIVE_PUBLIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Live read-only integration runs only in its explicit dedicated workflow step.")
        }
        let controller = CommunityController(vault: NativePublicGuestVault())
        controller.configure("https://led.errantactions.com")
        XCTAssertFalse(controller.signedIn)
        try await controller.loadConfig()
        let config = try XCTUnwrap(controller.config)
        guard config.appIntegrityEnforcementEnabled != true else {
            throw BackpackError.invalid("Live integration is blocked: this server now requires signed native integrity.")
        }
        guard config.catalogDownloadManifestEnabled == true else {
            throw BackpackError.invalid("Live integration is blocked: the expected trusted manifest capability is unavailable.")
        }
        let page = try await controller.items(query: "", category: "", page: 1)
        XCTAssertEqual(page.page, 1)
        XCTAssertLessThanOrEqual(page.items.count, page.limit)
        let item = try XCTUnwrap(page.items.first, "Live integration requires a currently eligible public catalog item.")
        let file = try XCTUnwrap(item.recordedFiles.first, "The current public item must have a recorded file descriptor.")
        let download = try await controller.downloadCatalogFile(itemID: item.id, file: file)
        XCTAssertEqual(download.integrity, .manifestSHA256)
        XCTAssertFalse(download.data.isEmpty)
        XCTAssertLessThanOrEqual(download.data.count, 5_000_000)
        XCTAssertFalse(controller.signedIn)
        XCTAssertNil(controller.user)
        let evidence = XCTAttachment(string:
            "Read-only live native guest config/catalog/current-access/manifest/hash verification at https://led.errantactions.com/api/v1. No account, mutation, provider activation or physical-device proof.")
        evidence.name = "Native public integration scope"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
