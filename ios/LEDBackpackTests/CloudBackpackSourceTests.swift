import XCTest
@testable import LEDBackpack

@MainActor
final class CloudBackpackSourceTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let itemID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let keyID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let base = "https://catalog.example"
    private func legacy(owner: UUID? = nil, bytes: Int = 35) throws -> CommunityCloudItem {
        let prefix = "\(base)/media/\(itemID.uuidString.lowercased())"
        let object: [String: Any] = ["id":itemID.uuidString,"title":"Private fixture","category":"other","tags":[],
            "displayAttribution":"Fixture credit","license":"original","pageUrl":"\(base)/items/\(itemID.uuidString)",
            "gifUrl":prefix + "/original.gif","previewUrl":prefix + "/preview.png","width":1,"height":1,"frameCount":1,
            "byteSize":bytes,"variants":[],"uploader":["id":(owner ?? self.owner).uuidString,"displayName":"Fixture owner"],
            "likeCount":0,"visibility":"private","status":"pending","moderationReason":"","aiState":"disabled","aiError":NSNull()]
        return try JSONDecoder().decode(CommunityCloudItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func vault(version: Int = 2, owner: UUID? = nil, key: UUID? = nil) throws -> CloudVaultItem {
        let account = (owner ?? self.owner).uuidString.lowercased()
        let metadata = CloudJSON.object(["title":.string("Private fixture")])
        return CloudVaultItem(id: itemID.uuidString.lowercased(), accountId: account, origin: base,
            keyId: (key ?? keyID).uuidString.lowercased(), mode: .managed, generation: 3, version: version,
            byteSize: 35, storageBytes: 100, encrypted: false, metadata: metadata, legacyItemId: nil,
            dataHash: CloudVaultWire.digest(Data([1])), metadataHash: CloudVaultWire.digest(try CloudVaultWire.json(metadata)),
            updatedAt: "2026-11-07T12:00:00Z", downloadUrl: URL(string: "\(base)/api/v1/cloud/items/\(itemID.uuidString.lowercased())/media?generation=3&version=\(version)")!)
    }
    func testLegacySourceRequiresCurrentOwnerEvenForAdminOrPublicFallback() throws {
        let item = try legacy(), origin = try CommunityOrigin.parse(base)
        XCTAssertNoThrow(try CloudBackpackSourcePolicy.validateLegacy(item, current: item, owner: owner, origin: origin))
        XCTAssertThrowsError(try CloudBackpackSourcePolicy.validateLegacy(item, current: item, owner: UUID(), origin: origin))
    }
    func testChangedLegacyDescriptorIsNotSilentlyRebased() throws {
        let item = try legacy(), changed = try legacy(bytes: 40)
        XCTAssertThrowsError(try CloudBackpackSourcePolicy.validateLegacy(item, current: changed, owner: owner, origin: CommunityOrigin.parse(base)))
    }
    func testForeignLegacyServerCannotAuthorizePrivateMedia() throws {
        let item = try legacy()
        XCTAssertThrowsError(try CloudBackpackSourcePolicy.validateLegacy(item, current: item, owner: owner, origin: CommunityOrigin.parse("https://foreign.example")))
    }
    func testVaultVersionKeyAndOwnerAreBoundToThePreparedItem() throws {
        let original = try vault()
        XCTAssertTrue(original.matches(try vault()))
        XCTAssertFalse(original.matches(try vault(version: 3)))
        XCTAssertFalse(original.matches(try vault(owner: UUID())))
        XCTAssertFalse(original.matches(try vault(key: UUID())))
    }
    func testCloudSourceIsDistinctAndDoesNotRequireLocalLibraryID() throws {
        let item = try vault()
        let source = BackpackSendSource.vault(item)
        XCTAssertEqual(source.id, "vault:\(owner.uuidString.lowercased()):3:\(itemID.uuidString.lowercased()):2")
        XCTAssertTrue(BackpackSendRequest(sources: [source]).usesVault)
        XCTAssertEqual(source.title, "Selected private cloud GIF")
    }
    func testLockedUnconfiguredVaultRejectsSendDownloadWithoutEnablingIt() async {
        let store = CloudVaultStore()
        let item: CloudVaultItem
        do { item = try vault() } catch { return XCTFail(error.localizedDescription) }
        do { _ = try await store.downloadForBackpack(item); XCTFail("No cloud/key fallback") } catch {}
        XCTAssertTrue(store.locked); XCTAssertFalse(store.available)
        XCTAssertTrue(store.items.isEmpty)
    }
}
