import Foundation
import BackpackProtocol

struct DeviceRecoveryOwner: Decodable {
    struct AvatarScope: Decodable { let kind, token: String }
    let id: UUID
    let displayName: String
    let avatarUrl, avatarPreviewUrl: URL?
    let avatarAnimated: Bool?
    let avatarScope: AvatarScope?

    func validate(account: UUID, token: String) throws {
        guard id != account, (1...80).contains(displayName.utf16.count),
              displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (avatarUrl == nil) == (avatarPreviewUrl == nil),
              avatarScope == nil || avatarScope?.kind == "device-recovery" && avatarScope?.token == token,
              avatarUrl == nil ? avatarScope == nil : avatarScope != nil else {
            throw BackpackError.invalid("The recovery profile is invalid or has no matching avatar authorization.")
        }
    }
}

struct DeviceRecoveryPreview: Decodable {
    struct Authorization: Decodable { let token, expiresAtISO: String }
    let owner: DeviceRecoveryOwner
    let contactAuthorization: Authorization
}

struct DeviceRegistryLookup: Decodable {
    enum Status: String, Decodable { case available, owned, registeredElsewhere = "registered-elsewhere", ambiguous }
    let status: Status
    let device: AccountDevice?
    let recoveryEnabled: Bool
    let serverTimeISO: String
    let recovery: DeviceRecoveryPreview?

    func validate(vendorID: String, account: UUID) throws {
        try VendorDeviceID.validate(vendorID)
        let serverTime = try CatalogEventTime.parse(serverTimeISO)
        if status == .owned {
            guard let device, device.connection?.vendorDeviceId == vendorID,
                  !recoveryEnabled, recovery == nil else {
                throw BackpackError.invalid("The registry did not return this account's matching device.")
            }
            try device.validate()
            return
        }
        guard device == nil else { throw BackpackError.invalid("The registry disclosed a foreign private device record.") }
        if status != .registeredElsewhere {
            guard !recoveryEnabled, recovery == nil else {
                throw BackpackError.invalid("An available or ambiguous device cannot disclose an owner.")
            }
            return
        }
        guard recoveryEnabled == (recovery != nil) else {
            throw BackpackError.invalid("The recovery opt-in and profile disclosure do not match.")
        }
        if let recovery {
            let authorization = recovery.contactAuthorization
            let expiry = try CatalogEventTime.parse(authorization.expiresAtISO)
            guard NearbyTokenPolicy.valid(authorization.token), expiry > serverTime,
                  expiry.timeIntervalSince(serverTime) <= 125 else {
                throw BackpackError.invalid("The device recovery authorization is invalid or expired.")
            }
            try recovery.owner.validate(account: account, token: authorization.token)
        }
    }
}

struct DeviceRegistryReview {
    let lookup: DeviceRegistryLookup
    let clock: CatalogEventClock
    private let contactDeadline: Date?

    init(lookup: DeviceRegistryLookup, clock: CatalogEventClock) throws {
        self.lookup = lookup; self.clock = clock
        if let preview = lookup.recovery {
            contactDeadline = min(try CatalogEventTime.parse(preview.contactAuthorization.expiresAtISO),
                clock.now().addingTimeInterval(120))
        } else { contactDeadline = nil }
    }

    func recovery() throws -> DeviceRecoveryPreview {
        guard lookup.status == .registeredElsewhere, let preview = lookup.recovery,
              lookup.recoveryEnabled,
              let contactDeadline, contactDeadline > clock.now() else {
            throw BackpackError.invalid("Recovery contact expired or is unavailable. Check the connected backpack again.")
        }
        return preview
    }

    var recoverySecondsRemaining: TimeInterval? {
        guard let contactDeadline else { return nil }
        return max(0, contactDeadline.timeIntervalSince(clock.now()))
    }
}

@MainActor
extension AccountServiceScope {
    func checkDeviceRegistry(recovery: Bool = false) throws {
        try check()
        guard capability == .devices, community.config?.connectedDeviceRegistrationEnabled == true,
              (community.config?.connectedDeviceRegistrationVersion ?? 0) >= 2,
              !recovery || community.config?.deviceRecoveryEnabled == true else {
            throw BackpackError.invalid(recovery ? "Device recovery messaging is unavailable." : "This server does not support current device adoption.")
        }
    }

    func lookupConnectedDevice(_ identity: ConnectedBackpackIdentity, consent: Bool) async throws -> DeviceRegistryReview {
        try checkDeviceRegistry()
        try identity.validate()
        guard consent else { throw BackpackError.invalid("Choose to check the connected backpack first.") }
        struct Body: Encodable { let consent = true; let vendorDeviceId: String }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await send(DeviceRegistryLookup.self, "devices/connected/lookup", method: "POST",
            body: JSONEncoder().encode(Body(vendorDeviceId: identity.vendorDeviceId)))
        try checkDeviceRegistry()
        try result.validate(vendorID: identity.vendorDeviceId, account: accountID)
        if result.recoveryEnabled { try checkDeviceRegistry(recovery: true) }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard elapsed.isFinite, (0..<120).contains(elapsed) else {
            throw BackpackError.invalid("The device check took too long. Check the backpack again.")
        }
        let conservativeServerTime = try CatalogEventTime.parse(result.serverTimeISO).addingTimeInterval(elapsed)
        let clock = try CatalogEventClock(serverTime: CatalogEventTime.wire(conservativeServerTime))
        let review = try DeviceRegistryReview(lookup: result, clock: clock)
        if result.recoveryEnabled { _ = try review.recovery() }
        return review
    }

    func setDeviceRecovery(_ device: AccountDevice, enabled: Bool, consent: Bool) async throws -> AccountDevice {
        try checkDeviceRegistry(recovery: enabled)
        try device.validate()
        guard device.connection != nil, !device.transferPending, !enabled || consent else {
            throw BackpackError.invalid("Choose a connected device and approve recovery contact before enabling it.")
        }
        struct Body: Encodable { let expectedRevision: Int; let enabled: Bool; let consent: Bool? }
        let result = try await send(AccountDeviceResult.self,
            "devices/\(device.id.uuidString.lowercased())/recovery", method: "PATCH",
            body: JSONEncoder().encode(Body(expectedRevision: device.revision, enabled: enabled, consent: enabled ? true : nil))).device
        try checkDeviceRegistry(recovery: enabled)
        try result.validate()
        let expected = device.revision + ((device.recoveryEnabled == true) == enabled ? 0 : 1)
        guard result.id == device.id, result.revision == expected, result.recoveryEnabled == enabled,
              result.connection?.vendorDeviceId == device.connection?.vendorDeviceId,
              result.nickname == device.nickname, result.model == device.model, result.matrix == device.matrix,
              result.ownerCardEnabled == device.ownerCardEnabled, !result.transferPending else {
            throw BackpackError.invalid("The recovery setting was not confirmed. Refresh My devices.")
        }
        return result
    }

    func recoveryAvatar(_ review: DeviceRegistryReview) async throws -> Data? {
        try checkDeviceRegistry(recovery: true)
        let recovery = try review.recovery()
        guard let url = recovery.owner.avatarPreviewUrl else { return nil }
        guard community.config?.avatarsEnabled == true else {
            throw BackpackError.invalid("Profile avatars are currently unavailable.")
        }
        let client = try CommunityFeatureClient(community)
        let resolved = try client.resolvedAvatarURL(url)
        let parts = resolved.path.split(separator: "/")
        guard parts.count >= 5, parts[4] == Substring(recovery.owner.id.uuidString.lowercased()) else {
            throw BackpackError.invalid("Recovery avatar belongs to a different profile.")
        }
        let data = try await bytes(parts.dropFirst(2).joined(separator: "/"), maxBytes: 5_000_000,
            recoveryToken: recovery.contactAuthorization.token)
        try checkDeviceRegistry(recovery: true)
        _ = try review.recovery()
        return data
    }
}
