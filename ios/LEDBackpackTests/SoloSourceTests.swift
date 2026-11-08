import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class SoloLocationFixture: SoloLocationSource {
    var received: ((SoloFix) -> Void)?
    var invalidated: ((String) -> Void)?
    var hasCreatedManager: Bool { false }
    private(set) var running = false
    var captureFix: SoloFix?
    var captureAction: (() -> Void)?
    private(set) var captures = 0
    func requestWhenInUse(consent: Bool, foreground: Bool) throws {
        guard consent, foreground else { throw BackpackError.invalid("Fixture consent/foreground is off.") }
        stop()
    }
    func start(consent: Bool, foreground: Bool) throws {
        guard consent, foreground else { throw BackpackError.invalid("Fixture consent/foreground is off.") }
        running = true
    }
    func stop() { running = false }
    func capture(consent: Bool, foreground: Bool) async throws -> SoloFix {
        guard consent, foreground, !running else { throw BackpackError.invalid("Fixture capture requires explicit inactive foreground consent.") }
        captures += 1; captureAction?()
        try Task.checkCancellation()
        guard let captureFix else { throw BackpackError.invalid("Fixture has no current point.") }
        return captureFix
    }
}

@MainActor
final class SoloSourceTests: XCTestCase {
    private let sceneID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let now = Date(timeIntervalSince1970: 1794000000)
    private func area() -> SoloArea {
        SoloArea(name: "Own local place", center: .init(latitude: 0, longitude: 0), radius: 100,
            dwell: 10, hysteresis: 10, cooldown: 60, sceneID: sceneID, kind: .place)
    }
    private func fix(_ meters: Double = 0, age: Double = 0, accuracy: Double = 1) -> SoloFix {
        .init(point: .init(latitude: 0, longitude: meters / 111195), accuracy: accuracy, timestamp: now.addingTimeInterval(-age))
    }
    private func scene() -> SoloScene {
        let gif = Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,0,0,0,255,255,255,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
        return SoloScene(id: sceneID, name: "Own art", items: [.init(id: UUID(), name: "Local original", bytes: gif, attribution: nil)])
    }
    private func sensingController() async throws -> (SoloSceneController, SoloLocationFixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("solo-permission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let source = SoloLocationFixture()
        let controller = SoloSceneController(repository: SoloSceneRepository(root: root.appendingPathComponent("solo")),
            recoveryRepository: SwapRecoveryRepository(root: root.appendingPathComponent("recovery")), location: source)
        await controller.load()
        XCTAssertTrue(controller.loaded)
        controller.setForeground(true); controller.setSensingConsent(true); controller.startSensing()
        return (controller, source)
    }
    func testPermissionRequestPausesControllerAndAllowsExplicitRestart() async throws {
        let (controller, source) = try await sensingController()
        XCTAssertTrue(controller.sensing); XCTAssertTrue(source.running)
        controller.requestPermission()
        XCTAssertFalse(controller.sensing); XCTAssertFalse(source.running)
        XCTAssertTrue(controller.sensingConsent); XCTAssertTrue(controller.loaded)
        controller.startSensing()
        XCTAssertTrue(controller.sensing); XCTAssertTrue(source.running)
        XCTAssertFalse(source.hasCreatedManager)
    }
    func testPermissionPauseDropsTripAnchorBeforeRestart() async throws {
        let (controller, source) = try await sensingController()
        try controller.startTrip()
        source.received?(SoloFix(point: .init(latitude: 0, longitude: 0), accuracy: 1,
            timestamp: Date().addingTimeInterval(-1)))
        controller.requestPermission(); controller.startSensing()
        source.received?(SoloFix(point: .init(latitude: 0, longitude: 50 / 111195.0), accuracy: 1,
            timestamp: Date().addingTimeInterval(-1)))
        XCTAssertEqual(controller.trip.meters, 0)
        source.received?(SoloFix(point: .init(latitude: 0, longitude: 60 / 111195.0), accuracy: 1,
            timestamp: Date().addingTimeInterval(-0.1)))
        XCTAssertGreaterThan(controller.trip.meters, 0)
        controller.stop()
    }
    func testFixedPointCaptureNeedsExplicitConsentAndDoesNotStartSensing() async throws {
        let source = SoloLocationFixture(), controller = SoloSceneController(location: source)
        controller.setForeground(true)
        source.captureFix = SoloFix(point: .init(latitude: 1, longitude: 2), accuracy: 3, timestamp: Date())
        do { _ = try await controller.captureFixedPoint(consent: false); XCTFail("Missing capture consent") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(source.captures, 0)
        let point = try await controller.captureFixedPoint(consent: true)
        XCTAssertEqual(point, .init(latitude: 1, longitude: 2))
        XCTAssertEqual(source.captures, 1); XCTAssertFalse(source.running)
        XCTAssertFalse(controller.sensing); XCTAssertFalse(controller.sensingConsent); XCTAssertFalse(controller.armed)
        XCTAssertTrue(controller.archive.areas.isEmpty)
        XCTAssertFalse(source.hasCreatedManager)
    }
    func testFixedPointCaptureRejectsStaleCoarseAndChangedContext() async throws {
        let source = SoloLocationFixture(), controller = SoloSceneController(location: source)
        controller.setForeground(true)
        for sample in [
            SoloFix(point: .init(latitude: 1, longitude: 2), accuracy: 3, timestamp: Date().addingTimeInterval(-6)),
            SoloFix(point: .init(latitude: 1, longitude: 2), accuracy: 26, timestamp: Date())
        ] {
            source.captureFix = sample
            do { _ = try await controller.captureFixedPoint(consent: true); XCTFail("Invalid captured quality") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        source.captureFix = SoloFix(point: .init(latitude: 1, longitude: 2), accuracy: 3, timestamp: Date())
        source.captureAction = { controller.stop() }
        do { _ = try await controller.captureFixedPoint(consent: true); XCTFail("Stopped capture context") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(controller.archive.areas.isEmpty); XCTAssertFalse(controller.sensing)
    }
    func testUnconsentedOneShotCaptureDoesNotCreateLocationManager() async throws {
        let location = SoloForegroundLocation()
        do { _ = try await location.capture(consent: false, foreground: false); XCTFail("Unconsented capture") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertFalse(location.hasCreatedManager)
    }
    func testFixedPointRejectsNonfiniteAndInvalidCoordinates() {
        for value in [SoloPoint(latitude: .nan, longitude: 0), .init(latitude: 91, longitude: 0), .init(latitude: 0, longitude: 181)] {
            XCTAssertThrowsError(try value.validate())
        }
    }
    func testFixRequiresFreshAccurateSampleWithoutFutureOrCoarseFallback() {
        XCTAssertTrue(fix(age: 5, accuracy: 25).usable(at: now))
        XCTAssertFalse(fix(age: 5.01).usable(at: now)); XCTAssertFalse(fix(age: -1).usable(at: now))
        XCTAssertFalse(fix(accuracy: 25.01).usable(at: now)); XCTAssertFalse(fix(accuracy: -1).usable(at: now))
    }
    func testDwellRequiresContinuousFreshSamplesBeforeEntry() {
        var evaluator = SoloAreaEvaluator()
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 0), .dwelling)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 5), .dwelling)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 10), .entered)
    }
    func testStationaryRecurringFixesCompleteDwellWithoutMovementOrRepeatedEntry() {
        var evaluator = SoloAreaEvaluator()
        for second in 0...10 {
            let current = now.addingTimeInterval(Double(second))
            let stationary = SoloFix(point: .init(latitude: 0, longitude: 0), accuracy: 3, timestamp: current)
            XCTAssertEqual(evaluator.evaluate(area: area(), fix: stationary, now: current, uptime: Double(second)),
                second == 10 ? .entered : .dwelling)
        }
        let current = now.addingTimeInterval(11)
        XCTAssertEqual(evaluator.evaluate(area: area(),
            fix: SoloFix(point: .init(latitude: 0, longitude: 0), accuracy: 3, timestamp: current),
            now: current, uptime: 11), .inside)
    }
    func testStationaryFixNoiseDoesNotCreateTripDistanceOrMilestones() {
        var trip = SoloTrip(); trip.start()
        let offsets = [0.0, 1.5, -2.0, 2.0]
        let milestone = SoloMilestone(meters: 100, sceneID: sceneID)
        for second in 0...30 {
            let current = now.addingTimeInterval(Double(second))
            let sample = SoloFix(point: .init(latitude: 0, longitude: offsets[second % offsets.count] / 111195),
                accuracy: 5, timestamp: current)
            XCTAssertTrue(trip.sample(sample, now: current, milestones: [milestone]).isEmpty)
        }
        XCTAssertEqual(trip.meters, 0); XCTAssertTrue(trip.fired.isEmpty)
    }
    func testEntryUsesInnerAccuracyBoundaryNotExpandedRadius() {
        var evaluator = SoloAreaEvaluator()
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(95, accuracy: 3), now: now, uptime: 0), .outside)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(80, accuracy: 3), now: now, uptime: 1), .dwelling)
    }
    func testSampleLossResetsDwellAndDoesNotInventEntry() {
        var evaluator = SoloAreaEvaluator()
        _ = evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 0)
        evaluator.discardSample()
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 20), .dwelling)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 26), .dwelling)
    }
    func testExitAndReentryRespectCooldownWithoutRepeatingInside() {
        var evaluator = SoloAreaEvaluator()
        for t in [0.0,5,10] { _ = evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: t) }
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 11), .inside)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(200), now: now, uptime: 12), .outside)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 13), .cooldown)
    }
    func testSessionRestartClearsObservationButPreservesAreaCooldown() {
        var evaluator = SoloAreaEvaluator()
        for t in [0.0, 5, 10] { _ = evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: t) }
        evaluator.restartSession()
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 11), .cooldown)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 69), .cooldown)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 70), .dwelling)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 75), .dwelling)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 80), .entered)
    }
    func testRestartCannotResumePartiallyAccumulatedDwell() {
        var evaluator = SoloAreaEvaluator()
        _ = evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 0)
        _ = evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 5)
        evaluator.restartSession()
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 6), .dwelling)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 11), .dwelling)
        XCTAssertEqual(evaluator.evaluate(area: area(), fix: fix(), now: now, uptime: 16), .entered)
    }
    func testTripPauseAndLongGapNeverAddStraightLineCatchupDistance() {
        var trip = SoloTrip(); trip.start()
        _ = trip.sample(fix(), now: now, milestones: [])
        trip.pause(); trip.start()
        _ = trip.sample(fix(1000), now: now, milestones: [])
        XCTAssertEqual(trip.meters, 0)
        let late = SoloFix(point: .init(latitude: 0, longitude: 0), accuracy: 1, timestamp: now.addingTimeInterval(30))
        _ = trip.sample(late, now: now.addingTimeInterval(30), milestones: [])
        XCTAssertEqual(trip.meters, 0)
    }
    func testRecapSerializationContainsNoRouteTimeOrCoordinateFields() throws {
        let recap = SoloRecap(id: UUID(), name: "Optional own recap", approximateMeters: 100, summaries: ["Own badge"])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recap)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["id","name","approximateMeters","summaries"])
    }
    func testArchiveRejectsMissingSceneReferenceAndExcessiveCounts() throws {
        var archive = SoloArchive(); archive.areas = [area()]
        XCTAssertThrowsError(try archive.validate())
        archive.scenes = [scene()]; XCTAssertNoThrow(try archive.validate())
        archive.scenes = (0..<21).map { _ in var next = scene(); next.id = UUID(); return next }
        XCTAssertThrowsError(try archive.validate())
    }
    func testRepositoryAtomicReadbackAndStaleRevisionCannotOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("solo-source-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = SoloSceneRepository(root: root)
        var archive = SoloArchive(); archive.scenes = [scene()]
        let saved = try await store.save(archive, expected: nil)
        let reopened = try await SoloSceneRepository(root: root).load()
        XCTAssertEqual(reopened?.revision, saved.revision)
        do { _ = try await store.save(SoloArchive(), expected: nil); XCTFail("Stale revision") } catch {}
        let retained = try await store.load(); XCTAssertEqual(retained?.archive.scenes.count, 1)
    }
    func testSolarIsLocalApproximateAndHandlesPolarAndInvalidZone() {
        let june = Date(timeIntervalSince1970: 1782043200)
        if case .events(let rise, let set) = SoloSolar.calculate(day: june, point: .init(latitude: 0, longitude: 0), timeZoneID: "UTC") {
            XCTAssertLessThan(rise, set)
        } else { XCTFail("Equatorial solar events") }
        XCTAssertEqual(SoloSolar.calculate(day: june, point: .init(latitude: 85, longitude: 0), timeZoneID: "UTC"), .polarDay)
        XCTAssertEqual(SoloSolar.calculate(day: june, point: .init(latitude: 0, longitude: 0), timeZoneID: "invalid-zone"), .unavailable)
    }
    func testColdConstructionStopAndDeniedPreparationDoNotCreateLocationManager() {
        let location = SoloForegroundLocation()
        XCTAssertFalse(location.hasCreatedManager); location.stop(); XCTAssertFalse(location.hasCreatedManager)
        XCTAssertThrowsError(try location.requestWhenInUse(consent: false, foreground: false))
        XCTAssertFalse(location.hasCreatedManager)
        let controller = SoloSceneController()
        controller.stop(); controller.setForeground(false)
        XCTAssertFalse(controller.location.hasCreatedManager); XCTAssertFalse(controller.sensing)
    }
}
