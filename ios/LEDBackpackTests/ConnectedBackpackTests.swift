import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class RegistrationReader: ConnectedBackpackReading {
    var connection: ConnectedBackpackConnection? = .init(peripheralID: UUID(), revision: UUID())
    var reads = 0
    var identity = ConnectedBackpackIdentity(vendorDeviceId: "Ab12345678", model: "BP10", firmware: "V2.9.1",
        matrix: NativeMatrixSize(width: 64, height: 64))
    var suspended: CheckedContinuation<ConnectedBackpackIdentity, Error>?
    var suspend = false
    func read() async throws -> ConnectedBackpackIdentity {
        reads += 1
        if suspend { return try await withCheckedThrowingContinuation { suspended = $0 } }
        return identity
    }
}

@MainActor
final class ConnectedBackpackTests: XCTestCase {
    private func settle(_ model: ConnectedBackpackRegistration) async {
        for _ in 0..<100 {
            if !model.busy { return }
            await Task.yield()
        }
        XCTFail("Registration operation did not settle.")
    }

    private func device() throws -> AccountDevice {
        try JSONDecoder().decode(AccountDevice.self, from: Data(#"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","revision":1,"nickname":"My backpack","model":"BP10","matrix":{"width":64,"height":64},"ownerCardEnabled":false,"transferPending":false,"claimStatus":"unverified-tag","physicalOwnershipVerified":false,"hardwareIdentityVerified":false,"flashingCompatibilityVerified":false}"#.utf8))
    }

    func testVendorIDPreservesCaseAndRejectsDefaultsMalformedAndCSVDelimiters() throws {
        for value in ["Ab12345678", "power12345", "aB!23-56_8", "tlvdefidv5"] { try VendorDeviceID.validate(value) }
        for value in ["", "TLVDEFIDV5", "0000000000", "XXXXXXXXXX", "123", "Ab123456789",
                      " Ab1234567", "Ab1234567 ", "Ab123,5678", "Ab1234567\n", "Ä12345678"] {
            XCTAssertThrowsError(try VendorDeviceID.validate(value), value)
        }
    }

    func testReadOnlyIdentityBodyAndPowerSubstringPreserved() throws {
        XCTAssertEqual(try Wire.initialize(password: "", bare: true), [0xC1, 3, 0x0A, 0])
        XCTAssertEqual(try Wire.initialize(password: "123456", bare: true),
            [0xC1, 3, 0x0A, 6] + Array("123456".utf8))
        let reply = try Wire.reply([0x81, 0x83, 0x0A] + Array("power12345,BP10,V2.9.1,model,power".utf8))
        guard case .identity(let identity) = reply else { return XCTFail("Missing identity") }
        XCTAssertEqual(identity.serial, "power12345")
        XCTAssertEqual(identity.model, "BP10")
        XCTAssertEqual(identity.firmware, "V2.9.1")
    }

    func testObservationRejectsExactExpiryBackwardTimeAndReconnectToSamePhoneUUID() throws {
        let reader = RegistrationReader()
        let connection = try XCTUnwrap(reader.connection)
        let observation = ConnectedBackpackObservation(identity: reader.identity, connection: connection, readAt: 100)
        try observation.validate(connection: connection, now: 219.99)
        for time in [99, 220, .infinity, .nan] {
            XCTAssertThrowsError(try observation.validate(connection: connection, now: time))
        }
        XCTAssertThrowsError(try observation.validate(connection: .init(peripheralID: connection.peripheralID, revision: UUID()), now: 101))
        XCTAssertThrowsError(try observation.validate(connection: nil, now: 101))
    }

    func testNoReadOnConstructionAndExplicitReadRequiresAccountAuthorization() async {
        let reader = RegistrationReader()
        let model = ConnectedBackpackRegistration()
        XCTAssertEqual(reader.reads, 0)
        model.read(using: reader) { throw BackpackError.invalid("Sign in") }
        await settle(model)
        XCTAssertEqual(reader.reads, 0)
        XCTAssertNil(model.observation)
        XCTAssertNotNil(model.failure)
    }

    func testMissingConsentNeverReadsAgainOrSubmits() async {
        let reader = RegistrationReader()
        let model = ConnectedBackpackRegistration()
        model.read(using: reader, authorize: {})
        await settle(model)
        var submissions = 0
        model.register(nickname: "Mine", consent: false, using: reader, authorize: {}) { _, _ in
            submissions += 1; return try self.device()
        }
        await settle(model)
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(submissions, 0)
        XCTAssertNotNil(model.failure)
    }

    func testRegistrationRereadsAndSendsOnlyCapturedValidatedMetadata() async {
        let reader = RegistrationReader()
        let model = ConnectedBackpackRegistration()
        model.read(using: reader, authorize: {})
        await settle(model)
        var submissions = 0
        model.register(nickname: "My backpack", consent: true, using: reader, authorize: {}) { identity, metadata in
            submissions += 1
            XCTAssertEqual(identity.vendorDeviceId, "Ab12345678")
            XCTAssertEqual(metadata.nickname, "My backpack")
            XCTAssertEqual(metadata.matrix, NativeMatrixSize(width: 64, height: 64))
            return try self.device()
        }
        await settle(model)
        XCTAssertEqual(reader.reads, 2)
        XCTAssertEqual(submissions, 1)
        XCTAssertNotNil(model.registered)
        XCTAssertNil(model.observation)
        XCTAssertNil(model.failure)
    }

    func testChangedDeviceIDOrDimensionsBeforeSubmitRequiresNewConfirmation() async {
        for changeID in [true, false] {
            let reader = RegistrationReader()
            let model = ConnectedBackpackRegistration()
            model.read(using: reader, authorize: {})
            await settle(model)
            reader.identity = .init(vendorDeviceId: changeID ? "Cd12345678" : "Ab12345678", model: "BP10",
                firmware: "V2.9.1", matrix: NativeMatrixSize(width: changeID ? 64 : 32, height: 64))
            var submissions = 0
            model.register(nickname: "Mine", consent: true, using: reader, authorize: {}) { _, _ in
                submissions += 1; return try self.device()
            }
            await settle(model)
            XCTAssertEqual(submissions, 0)
            XCTAssertNil(model.registered)
            XCTAssertNil(model.observation)
            XCTAssertNotNil(model.failure)
        }
    }

    func testExpiredSnapshotDoesNotReadOrSubmit() async {
        var time: TimeInterval = 100
        let reader = RegistrationReader()
        let model = ConnectedBackpackRegistration(now: { time })
        model.read(using: reader, authorize: {})
        await settle(model)
        time = 220
        var submissions = 0
        model.register(nickname: "Mine", consent: true, using: reader, authorize: {}) { _, _ in
            submissions += 1; return try self.device()
        }
        await settle(model)
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(submissions, 0)
        XCTAssertNotNil(model.failure)
    }

    func testDisconnectDuringInitialReadDiscardsIdentity() async {
        let reader = RegistrationReader()
        reader.suspend = true
        let model = ConnectedBackpackRegistration()
        model.read(using: reader, authorize: {})
        for _ in 0..<100 { if reader.suspended != nil { break }; await Task.yield() }
        reader.connection = nil
        reader.suspended?.resume(returning: reader.identity)
        await settle(model)
        XCTAssertNil(model.observation)
        XCTAssertNotNil(model.failure)
    }

    func testBackgroundInvalidationDiscardsLateReadEvenIfTransportIgnoresCancellation() async {
        let reader = RegistrationReader()
        reader.suspend = true
        let model = ConnectedBackpackRegistration()
        model.read(using: reader, authorize: {})
        for _ in 0..<100 { if reader.suspended != nil { break }; await Task.yield() }
        model.invalidate("Background")
        reader.suspended?.resume(returning: reader.identity)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.observation)
        XCTAssertNil(model.registered)
        XCTAssertEqual(model.failure, "Background")
    }

    func testOneFlightAndNetworkFailureRemainExplicitWithoutAutomaticRetry() async {
        let reader = RegistrationReader()
        let model = ConnectedBackpackRegistration()
        model.read(using: reader, authorize: {})
        await settle(model)
        var submissions = 0
        let failingSubmit: (ConnectedBackpackIdentity, AccountDeviceMetadata) async throws -> AccountDevice = { _, _ in
            submissions += 1
            throw BackpackError.invalid("Receipt lost")
        }
        model.register(nickname: "Mine", consent: true, using: reader, authorize: {}, submit: failingSubmit)
        model.register(nickname: "Mine", consent: true, using: reader, authorize: {}, submit: failingSubmit)
        await settle(model)
        XCTAssertEqual(submissions, 1)
        XCTAssertNil(model.registered)
        XCTAssertTrue(model.failure?.contains("Receipt lost") == true)
    }

    func testAccountChangesDuringRereadPreventSubmission() async {
        let reader = RegistrationReader()
        let model = ConnectedBackpackRegistration()
        var authorized = true
        let authorize = { if !authorized { throw BackpackError.invalid("Account changed") } }
        model.read(using: reader, authorize: authorize)
        await settle(model)
        reader.suspend = true
        var submissions = 0
        model.register(nickname: "Mine", consent: true, using: reader, authorize: authorize) { _, _ in
            submissions += 1; return try self.device()
        }
        for _ in 0..<100 { if reader.suspended != nil { break }; await Task.yield() }
        authorized = false
        reader.suspended?.resume(returning: reader.identity)
        await settle(model)
        XCTAssertEqual(submissions, 0)
        XCTAssertNotNil(model.failure)
    }
}
