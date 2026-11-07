import Foundation
import BackpackProtocol

enum CloudBackpackSourcePolicy {
    static func validateLegacy(_ selected: CommunityCloudItem, current: CommunityCloudItem, owner: UUID,
        origin: CommunityOrigin) throws {
        guard selected.item.uploader.id == owner, current.item.uploader.id == owner, current.id == selected.id,
              ["private","shared"].contains(current.visibility), current.visibility == selected.visibility,
              current.status != "deleted", current.item.recordedFiles == selected.item.recordedFiles else {
            throw BackpackError.invalid("Selected owned cloud GIF changed or belongs to another account. No public/admin fallback or library scan.")
        }
        guard let original = current.item.recordedFiles.first(where: \.original) else { throw BackpackError.invalid("Owned cloud original descriptor unavailable.") }
        try NativeCatalogDescriptorPolicy.validate(original, itemID: selected.id, origin: origin)
    }
}
@MainActor
extension CommunityController {
    func authorizeLegacyBackpackGIF(_ selected: CommunityCloudItem) async throws {
        guard signedIn, let owner = user?.id, let origin else { throw BackpackError.invalid("Sign in to read your selected cloud GIF.") }
        guard selected.item.uploader.id == owner else { throw BackpackError.invalid("Only your explicitly selected owned cloud GIF can be sent; no arbitrary private-item lookup.") }
        let epoch = accountRevision, policy = avatarPolicyRevision
        struct Reply: Decodable { let item: CommunityCloudItem }
        let current = try JSONDecoder().decode(Reply.self, from: await request("items/\(selected.id.uuidString.lowercased())",
            expectedAccountRevision: epoch, expectedAccountID: owner).data).item
        guard accountRevision == epoch, avatarPolicyRevision == policy, self.origin == origin, user?.id == owner else { throw CancellationError() }
        try CloudBackpackSourcePolicy.validateLegacy(selected, current: current, owner: owner, origin: origin)
    }
    func downloadLegacyBackpackGIF(_ selected: CommunityCloudItem) async throws -> Data {
        try await authorizeLegacyBackpackGIF(selected)
        guard let original = selected.item.recordedFiles.first(where: \.original) else { throw BackpackError.invalid("Selected owned GIF original is unavailable.") }
        let copy = try await downloadCatalogFile(itemID: selected.id, file: original)
        try await authorizeLegacyBackpackGIF(selected)
        return copy.data
    }
}
