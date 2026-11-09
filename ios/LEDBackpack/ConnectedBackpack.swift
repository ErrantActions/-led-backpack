import Foundation
import Combine
import BackpackProtocol

enum VendorDeviceID {
    static func validate(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes.allSatisfy({ (33...126).contains($0) }),
              !value.contains(","), Set(bytes).count > 1,
              value != "TLVDEFIDV5" else {
            throw BackpackError.invalid("This backpack did not provide a usable 10-character vendor ID. Default, malformed or repeated-character IDs cannot be registered.")
        }
    }
}

struct AccountDeviceConnection: Decodable {
    let kind: String
    let vendorDeviceId: String
    let mutable: Bool
    let ownershipProof: Bool

    func validate() throws {
        try VendorDeviceID.validate(vendorDeviceId)
        guard kind == "vendor-id", mutable, !ownershipProof else {
            throw BackpackError.invalid("Unsupported connected-backpack identity claim.")
        }
    }
}

struct ConnectedDeviceRequest: Encodable {
    let consent: Bool
    let vendorDeviceId: String
    let device: AccountDeviceMetadata

    func validate() throws {
        guard consent else { throw BackpackError.invalid("Confirm physical access and account association first.") }
        try VendorDeviceID.validate(vendorDeviceId)
        try device.validate()
    }
}

struct ConnectedDeviceResult: Decodable {
    let created: Bool
    let device: AccountDevice

    func validate(_ request: ConnectedDeviceRequest) throws {
        try request.validate()
        try device.validate()
        guard device.connection?.vendorDeviceId == request.vendorDeviceId else {
            throw BackpackError.invalid("The registration receipt did not match the confirmed vendor ID. Reload My devices.")
        }
        if created {
            guard device.nickname == request.device.nickname, device.model == request.device.model,
                  device.matrix == request.device.matrix, !device.ownerCardEnabled, !device.transferPending else {
                throw BackpackError.invalid("The new device record did not match the confirmed private metadata.")
            }
        }
    }
}

@MainActor
extension AccountServiceScope {
    func addConnectedDevice(_ identity: ConnectedBackpackIdentity, metadata: AccountDeviceMetadata,
        consent: Bool) async throws -> AccountDevice {
        try checkDeviceRegistry()
        try identity.validate()
        guard metadata.model == identity.model, metadata.matrix == identity.matrix else {
            throw BackpackError.invalid("Connected device metadata must match its fresh hardware reading.")
        }
        let body = ConnectedDeviceRequest(consent: consent, vendorDeviceId: identity.vendorDeviceId, device: metadata)
        try body.validate()
        let result = try await send(ConnectedDeviceResult.self, "devices/connected", method: "POST",
            body: JSONEncoder().encode(body))
        guard community.config?.connectedDeviceRegistrationEnabled == true else {
            throw BackpackError.invalid("Registration availability changed. Reload My devices before retrying.")
        }
        try result.validate(body)
        return result.device
    }
}

struct ConnectedBackpackConnection: Equatable {
    let peripheralID: UUID
    let revision: UUID
}

struct ConnectedBackpackIdentity: Equatable {
    let vendorDeviceId: String
    let model: String
    let firmware: String
    let matrix: NativeMatrixSize

    func validate() throws {
        try VendorDeviceID.validate(vendorDeviceId)
        try AccountDeviceMetadata(nickname: "Backpack", model: model, matrix: matrix).validate()
        guard !firmware.isEmpty, firmware.utf8.count <= 80,
              !firmware.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BackpackError.invalid("The backpack returned an invalid firmware label. Reconnect and read again.")
        }
    }
}

@MainActor
protocol ConnectedBackpackReading {
    var connection: ConnectedBackpackConnection? { get }
    func read() async throws -> ConnectedBackpackIdentity
}

@MainActor
final class PanelConnectedBackpackReader: ConnectedBackpackReading {
    private let panel: PanelController
    private let link: BluetoothLink
    init(panel: PanelController, link: BluetoothLink) { self.panel = panel; self.link = link }

    var connection: ConnectedBackpackConnection? {
        guard link.connected, let id = link.selectedID else { return nil }
        return ConnectedBackpackConnection(peripheralID: id, revision: link.connectionRevision)
    }

    func read() async throws -> ConnectedBackpackIdentity {
        guard let captured = connection else {
            throw BackpackError.invalid("Connect your backpack on the Backpack tab first.")
        }
        return try await panel.transaction {
            try Task.checkCancellation()
            let reply = try await link.request(try Wire.initialize(password: panel.password, bare: true), sensitive: true) {
                if case .identity = $0 { return true }; return false
            }
            guard connection == captured, case .identity(let identity) = reply else {
                throw BackpackError.invalid("The backpack connection changed. Read it again.")
            }
            let dimensions = try await link.request([0xC1, 3, 0x1B, 0]) {
                if case .size = $0 { return true }; return false
            }
            try Task.checkCancellation()
            guard connection == captured, case .size(let size) = dimensions else {
                throw BackpackError.invalid("The backpack connection changed. Read it again.")
            }
            let result = ConnectedBackpackIdentity(vendorDeviceId: identity.serial, model: identity.model,
                firmware: identity.firmware, matrix: NativeMatrixSize(width: size.width, height: size.height))
            try result.validate()
            return result
        }
    }
}

struct ConnectedBackpackObservation: Equatable {
    let identity: ConnectedBackpackIdentity
    let connection: ConnectedBackpackConnection
    let readAt: TimeInterval

    func validate(connection: ConnectedBackpackConnection?, now: TimeInterval) throws {
        try identity.validate()
        guard connection == self.connection, now.isFinite, readAt.isFinite,
              now >= readAt, now - readAt < 120 else {
            throw BackpackError.invalid("The connection changed or the device reading expired. Read and confirm the backpack again.")
        }
    }
}

@MainActor
final class ConnectedBackpackRegistration: ObservableObject {
    @Published private(set) var observation: ConnectedBackpackObservation?
    @Published private(set) var busy = false
    @Published private(set) var registering = false
    @Published private(set) var failure: String?
    @Published private(set) var registered: AccountDevice?
    @Published private(set) var registryReview: DeviceRegistryReview?
    @Published private(set) var contactConversationID: UUID?
    @Published private(set) var pendingContact: DeviceRecoveryIntent?
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var generation = UUID()
    private let now: () -> TimeInterval
    private let outbox: DeviceRecoveryOutbox
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        outbox: DeviceRecoveryOutbox? = nil) {
        self.now = now; self.outbox = outbox ?? DeviceRecoveryOutbox(vault: CommunityKeychain())
    }

    func invalidate(_ reason: String? = nil) {
        task?.cancel(); task = nil; expiryTask?.cancel(); expiryTask = nil; generation = UUID()
        observation = nil; registered = nil; busy = false; registering = false; failure = reason
        registryReview = nil; contactConversationID = nil; pendingContact = nil
    }

    func read(using reader: ConnectedBackpackReading,
        registryLookup: ((ConnectedBackpackIdentity) async throws -> DeviceRegistryReview)? = nil,
        authorize: @escaping () throws -> Void) {
        guard !busy else { return }
        invalidate()
        let generation = self.generation
        busy = true
        task = Task {
            do {
                try authorize()
                guard let connection = reader.connection else {
                    throw BackpackError.invalid("Connect your backpack on the Backpack tab first.")
                }
                let identity = try await reader.read()
                try authorize()
                try Task.checkCancellation()
                try identity.validate()
                guard reader.connection == connection else {
                    throw BackpackError.invalid("The backpack connection changed. Read it again.")
                }
                let captured = ConnectedBackpackObservation(identity: identity, connection: connection, readAt: now())
                let review = try await registryLookup?(identity)
                try authorize()
                try Task.checkCancellation()
                try captured.validate(connection: reader.connection, now: now())
                guard self.generation == generation else { return }
                observation = captured; registryReview = review
                let remaining = min(120 - (now() - captured.readAt), review?.recoverySecondsRemaining ?? 120)
                expiryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, remaining))) }
                    catch is CancellationError { return }
                    catch { self?.invalidate(error.localizedDescription); return }
                    guard let self, self.generation == generation else { return }
                    self.invalidate("Device check expired. Check the connected backpack again.")
                }
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            if self.generation == generation { busy = false }
        }
    }

    func register(nickname: String, consent: Bool, using reader: ConnectedBackpackReading,
        authorize: @escaping () throws -> Void,
        submit: @escaping (ConnectedBackpackIdentity, AccountDeviceMetadata) async throws -> AccountDevice) {
        guard !busy else { return }
        failure = nil; registered = nil
        guard let captured = observation else {
            failure = "Read the connected backpack before adding it."
            return
        }
        guard registryReview?.lookup.status == .available else {
            failure = "Check the registry first. A backpack already adopted by another account cannot be taken over."
            return
        }
        let generation = self.generation
        busy = true; registering = true
        task = Task {
            do {
                try authorize()
                guard consent else { throw BackpackError.invalid("Confirm physical access and account association first.") }
                try captured.validate(connection: reader.connection, now: now())
                let metadata = AccountDeviceMetadata(nickname: nickname, model: captured.identity.model, matrix: captured.identity.matrix)
                try metadata.validate()
                let current = try await reader.read()
                try authorize()
                try Task.checkCancellation()
                try captured.validate(connection: reader.connection, now: now())
                guard current == captured.identity else {
                    observation = nil
                    throw BackpackError.invalid("The backpack identity or dimensions changed. Read and confirm it again.")
                }
                let result = try await submit(current, metadata)
                try authorize()
                try Task.checkCancellation()
                try captured.validate(connection: reader.connection, now: now())
                guard self.generation == generation else { return }
                expiryTask?.cancel(); expiryTask = nil
                registered = result; observation = nil; registryReview = nil
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                failure = "\(error.localizedDescription) Reload My devices after an uncertain response; retrying the same ID will not add another record."
            }
            if self.generation == generation { busy = false; registering = false }
        }
    }

    func contactOwner(using reader: ConnectedBackpackReading, scope: AccountServiceScope,
        authorize: @escaping () throws -> Void) {
        guard !busy else { return }
        failure = nil; contactConversationID = nil
        guard let captured = observation, let review = registryReview else {
            failure = "Check the connected backpack before contacting its registered account."
            return
        }
        let stamp = generation
        busy = true
        task = Task {
            var attempted: DeviceRecoveryIntent?
            do {
                try authorize(); try scope.checkDeviceRegistry(recovery: true)
                try captured.validate(connection: reader.connection, now: now())
                let recovery = try review.recovery()
                var saved = try outbox.load(account: scope.accountID, origin: scope.origin.url.absoluteString, kind: .contact)
                if let prior = saved {
                    pendingContact = prior
                    if prior.state == .acknowledged {
                        if prior.peerID == recovery.owner.id, prior.vendorID == captured.identity.vendorDeviceId,
                           let id = prior.receiptID {
                            try authorize()
                            contactConversationID = id; busy = false
                            return
                        }
                        try outbox.clearResolved(prior); saved = nil; pendingContact = nil
                    } else {
                        try prior.requireRetry(account: scope.accountID, origin: scope.origin.url.absoluteString,
                            peer: recovery.owner.id, vendorID: captured.identity.vendorDeviceId)
                    }
                }
                let fresh = try await reader.read()
                try authorize(); try scope.checkDeviceRegistry(recovery: true)
                try Task.checkCancellation()
                try captured.validate(connection: reader.connection, now: now())
                guard fresh == captured.identity else {
                    observation = nil; registryReview = nil
                    throw BackpackError.invalid("The connected backpack changed. Check it again before sending.")
                }
                _ = try review.recovery()
                let intent = try saved ?? DeviceRecoveryIntent(account: scope.accountID,
                    origin: scope.origin.url.absoluteString, peer: recovery.owner.id, kind: .contact,
                    vendorID: fresh.vendorDeviceId, text: "I found your device.")
                if saved == nil { try outbox.save(intent) }
                try outbox.requireCurrent(intent)
                attempted = intent; pendingContact = intent
                let conversation = try await scope.contactDeviceOwner(review, identity: fresh, intent: intent)
                try authorize(); try Task.checkCancellation()
                guard generation == stamp else { return }
                try outbox.acknowledge(intent, receipt: conversation.id)
                pendingContact = nil; contactConversationID = conversation.id
            } catch {
                guard generation == stamp, !Task.isCancelled else { return }
                if var attempted, let error = error as? CommunityFailure,
                   [401, 403, 404].contains(error.status) ||
                    error.status == 409 && ["device_recovery_closed", "device_recovery_contact_exists"].contains(error.code) {
                    attempted.state = .retired
                    do { try outbox.save(attempted); pendingContact = attempted }
                    catch { failure = "Recovery state could not be saved: \(error.localizedDescription)" }
                }
                if failure == nil {
                    failure = "\(error.localizedDescription) Check recovery messages before starting a new request."
                }
            }
            if generation == stamp { busy = false }
        }
    }

    func discardPendingContact() {
        guard !busy, let pendingContact else { return }
        do {
            try outbox.discard(pendingContact)
            self.pendingContact = nil; failure = nil
        } catch { failure = error.localizedDescription }
    }
}
