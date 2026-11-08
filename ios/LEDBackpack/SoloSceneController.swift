import Foundation
import CoreLocation
import Combine
import BackpackProtocol

@MainActor
protocol SoloLocationSource: AnyObject {
    var received: ((SoloFix) -> Void)? { get set }
    var invalidated: ((String) -> Void)? { get set }
    var hasCreatedManager: Bool { get }
    func requestWhenInUse(consent: Bool, foreground: Bool) throws
    func start(consent: Bool, foreground: Bool) throws
    func capture(consent: Bool, foreground: Bool) async throws -> SoloFix
    func stop()
}

@MainActor
final class SoloForegroundLocation: NSObject, CLLocationManagerDelegate, SoloLocationSource {
    private var manager: CLLocationManager?
    private var running = false
    private var authorization: CLAuthorizationStatus?
    private var accuracy: CLAccuracyAuthorization?
    private var captureID: UUID?
    private var captureResult: CheckedContinuation<SoloFix, Error>?
    private var captureTimeout: Task<Void, Never>?
    private var captureWindow: SoloFixedPointWindow?
    var received: ((SoloFix) -> Void)?
    var invalidated: ((String) -> Void)?
    var hasCreatedManager: Bool { manager != nil }
    private func deliberateManager() -> CLLocationManager {
        if let manager { return manager }
        let value = CLLocationManager()
        authorization = value.authorizationStatus; accuracy = value.accuracyAuthorization
        value.delegate = self
        value.allowsBackgroundLocationUpdates = false
        value.pausesLocationUpdatesAutomatically = true
        manager = value
        return value
    }
    func requestWhenInUse(consent: Bool, foreground: Bool) throws {
        guard consent, foreground else { throw BackpackError.invalid("Deliberately enable foreground local sensing first.") }
        stop()
        deliberateManager().requestWhenInUseAuthorization()
    }
    func start(consent: Bool, foreground: Bool) throws {
        guard consent, foreground, captureID == nil else { throw BackpackError.invalid("Foreground sensing consent is off or a fixed-point capture is active.") }
        let value = deliberateManager()
        guard CLLocationManager.locationServicesEnabled(), value.authorizationStatus == .authorizedWhenInUse || value.authorizationStatus == .authorizedAlways,
              value.accuracyAuthorization == .fullAccuracy else {
            throw BackpackError.invalid("Fresh full-accuracy When-In-Use access is unavailable. Use manual offers; press Start again after granting. No automatic regrant restart.")
        }
        value.desiredAccuracy = kCLLocationAccuracyBest; value.distanceFilter = kCLDistanceFilterNone
        running = true; value.startUpdatingLocation()
    }
    func capture(consent: Bool, foreground: Bool) async throws -> SoloFix {
        try Task.checkCancellation()
        guard consent, foreground, !running, captureID == nil else {
            throw BackpackError.invalid("Explicit foreground fixed-point consent and stopped sensing are required.")
        }
        let value = deliberateManager()
        guard CLLocationManager.locationServicesEnabled(),
              [.authorizedWhenInUse, .authorizedAlways].contains(value.authorizationStatus),
              value.accuracyAuthorization == .fullAccuracy else {
            throw BackpackError.invalid("Grant full-accuracy When-In-Use permission separately, then retry or enter a fixed point manually.")
        }
        let id = UUID()
        let window = SoloFixedPointWindow()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                captureID = id; captureResult = continuation; captureWindow = window
                value.desiredAccuracy = kCLLocationAccuracyBest
                captureTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.finishCapture(.failure(BackpackError.invalid("No usable fresh fix arrived within10s. Retry explicitly or use manual geometry.")), id: id)
                }
                value.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishCapture(.failure(CancellationError()), id: id) }
        }
    }
    private func finishCapture(_ result: Result<SoloFix, Error>, id: UUID) {
        guard captureID == id, let continuation = captureResult else { return }
        captureID = nil; captureResult = nil; captureWindow = nil; captureTimeout?.cancel(); captureTimeout = nil
        if !running { manager?.stopUpdatingLocation() }
        continuation.resume(with: result)
    }
    func stop() {
        running = false; manager?.stopUpdatingLocation()
        if let id = captureID { finishCapture(.failure(CancellationError()), id: id) }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        let changed = authorization != manager.authorizationStatus || accuracy != manager.accuracyAuthorization
        authorization = manager.authorizationStatus; accuracy = manager.accuracyAuthorization
        if (running || captureID != nil) && changed {
            let wasRunning = running
            if let id = captureID { finishCapture(.failure(BackpackError.invalid("OS permission/accuracy changed during fixed-point capture.")), id: id) }
            stop()
            if wasRunning { invalidated?("OS location permission/accuracy changed — explicit enable/start required") }
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, let last = locations.last else { return }
        let fix = SoloFix(point: SoloPoint(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude),
            accuracy: last.horizontalAccuracy, timestamp: last.timestamp)
        if let id = captureID {
            do {
                guard let captureWindow else { throw BackpackError.invalid("Fixed-point capture deadline is unavailable.") }
                try captureWindow.require()
            } catch { finishCapture(.failure(error), id: id); return }
        }
        if let id = captureID, fix.usable(at: Date()),
           [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus),
           manager.accuracyAuthorization == .fullAccuracy {
            finishCapture(.success(fix), id: id)
        }
        if running { received?(fix) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager else { return }
        let wasRunning = running
        if let id = captureID { finishCapture(.failure(error), id: id) }
        stop()
        if wasRunning { invalidated?("Local fix unavailable — stopped, manual operation only") }
    }
}

@MainActor
final class SoloSceneController: ObservableObject {
    static let recoveryScope = "solo-device-local-v1"
    @Published private(set) var archive = SoloArchive()
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var status = "SOLO sensing and PHONE automation off"
    @Published private(set) var sensingConsent = false
    @Published private(set) var sensing = false
    @Published private(set) var automationConsent = false
    @Published private(set) var armed = false
    @Published private(set) var trip = SoloTrip()
    @Published var recapConsent = false
    @Published private(set) var offer: UUID?
    @Published private(set) var areaStates: [UUID: SoloAreaResult] = [:]
    @Published private(set) var recoveryAvailable = false
    @Published private(set) var daylightDescription = "No daylight plan selected"
    let location: any SoloLocationSource
    private var repository: SoloSceneRepository?
    private let recoveryRepository: SwapRecoveryRepository?
    private var revision: UUID?
    private var epoch = UUID()
    private var foreground = false
    private weak var phone: PhoneDisplayController?
    private weak var targets: DisplayTargetSelection?
    private let lease = UUID()
    private var ownedRevision: UUID?
    private var evaluators: [UUID: SoloAreaEvaluator] = [:]
    private var stale: Task<Void, Never>?
    private var latestFix = UUID()
    private var presentation: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    private var io: Task<Void, Never>?
    private var daylightFired: Set<String> = []
    private var sessionUnlocks: [SoloUnlock] = []
    private var journal: LocalSwapOriginal?
    private var selectedDaylight: UUID?
    init(repository: SoloSceneRepository? = nil, recoveryRepository: SwapRecoveryRepository? = nil,
        location: (any SoloLocationSource)? = nil) {
        self.repository = repository
        self.recoveryRepository = recoveryRepository
        self.location = location ?? SoloForegroundLocation()
        self.location.received = { [weak self] in self?.receive($0) }
        self.location.invalidated = { [weak self] in self?.stop($0) }
    }
    func bind(phone: PhoneDisplayController, targets: DisplayTargetSelection) { self.phone = phone; self.targets = targets }
    private func storage() throws -> SoloSceneRepository {
        if let repository { return repository }
        let value = try SoloSceneRepository.owned(); repository = value; return value
    }
    private func recovery() throws -> SwapRecoveryRepository {
        if let recoveryRepository { return recoveryRepository }
        guard let value = SwapRecoveryRepository.shared else { throw BackpackError.invalid("Durable original journal unavailable; PHONE automation prohibited.") }
        return value
    }
    func setForeground(_ value: Bool) { if !value { stop("Foreground left — sensing, schedules and playback stopped; no restart") }; foreground = value }
    func setSensingConsent(_ value: Bool) {
        if !value { stop("Local sensing consent removed — explicit start required") }
        sensingConsent = value
    }
    func setAutomationConsent(_ value: Bool) {
        if !value { stop("Independent PHONE automation consent removed") }
        automationConsent = value
    }
    func requestPermission() {
        do {
            try location.requestWhenInUse(consent: sensingConsent, foreground: foreground)
            sensing = false; stale?.cancel(); stale = nil; latestFix = UUID()
            discardSample()
            status = "Sensing paused for the separate OS permission step. After granting, deliberately press Start sensing."
        } catch { report(error) }
    }
    func requestFixedPointPermission(consent: Bool) throws {
        guard !sensing, !armed, !busy else { throw BackpackError.invalid("Stop sensing/PHONE automation before preparing a fixed-point capture.") }
        try location.requestWhenInUse(consent: consent, foreground: foreground)
    }
    func captureFixedPoint(consent: Bool) async throws -> SoloPoint {
        guard consent, foreground, !sensing, !armed, !busy else {
            throw BackpackError.invalid("Explicit foreground capture consent and stopped sensing/automation are required.")
        }
        let stamp = epoch
        let window = SoloFixedPointWindow()
        let fix = try await location.capture(consent: consent, foreground: foreground)
        try Task.checkCancellation()
        try window.require()
        guard epoch == stamp, foreground, !sensing, !armed, !busy else { throw CancellationError() }
        guard fix.usable(at: Date()) else { throw BackpackError.invalid("Captured point is stale, coarse or invalid; manual draft retained.") }
        return fix.point
    }
    func startSensing() {
        do {
            guard loaded, !busy else { throw BackpackError.invalid("Load reliable local configuration first.") }
            try location.start(consent: sensingConsent, foreground: foreground)
            sensing = true; status = "Foreground SOLO sensing active — samples discarded, no route stored or shared"
        } catch { report(error) }
    }
    func stop(_ reason: String = "Stopped — first original retained; explicit restore available") {
        epoch = UUID(); io?.cancel(); presentation?.cancel(); schedule?.cancel(); stale?.cancel()
        io = nil; presentation = nil; schedule = nil; stale = nil
        location.stop(); sensing = false; sensingConsent = false; automationConsent = false; recapConsent = false
        armed = false; offer = nil; busy = false; selectedDaylight = nil
        for id in Array(evaluators.keys) { evaluators[id]?.restartSession() }
        areaStates.removeAll(); trip.pause()
        if targets?.phonePeerOwner == lease { phone?.cancelPendingSelection(); phone?.stopPeerPlayback() }
        targets?.releasePhone(lease); ownedRevision = nil; status = reason
        // A cancelled write may already have committed: require a fresh read before another mutation.
        loaded = false
    }
    func manualPhoneChange() {
        if armed || presentation != nil || (busy && targets?.phonePeerOwner == lease) { stop("Manual PHONE selection/close changed context — recovery original retained") }
    }
    func policyChanged() {
        if armed || (busy && targets?.phonePeerOwner == lease) { stop("Motion / data-saving / manual playback policy changed — no silent rearm") }
    }
    func report(_ error: Error) { if !(error is CancellationError) { failure = error.localizedDescription } }
    private func reconcileEvaluators() {
        let areaIDs = Set(archive.areas.map(\.id))
        evaluators = evaluators.filter { areaIDs.contains($0.key) }
    }
    func load() async {
        guard !busy, !armed, !sensing else { return }
        let stamp = epoch; busy = true
        defer { if stamp == epoch { busy = false } }
        do {
            let value = try await storage().load()
            try Task.checkCancellation(); guard stamp == epoch else { return }
            archive = value?.archive ?? SoloArchive(); revision = value?.revision; loaded = true; failure = nil
            reconcileEvaluators()
            let retained = try await recovery().load()
            guard stamp == epoch, !Task.isCancelled else { return }
            journal = retained?.peerPurpose == "solo-v1" ? retained : nil
            recoveryAvailable = journal?.needsRecovery == true
        } catch {
            if stamp == epoch && !Task.isCancelled { loaded = false; report(error) }
        }
    }
    func edit(_ change: (inout SoloArchive) throws -> Void) async throws {
        guard loaded, !busy, !armed, !sensing else { throw BackpackError.invalid("Stop sensing/automation and reload before editing. Previous state retained.") }
        var proposed = archive
        try change(&proposed)
        let stamp = epoch, expected = revision
        busy = true; defer { if stamp == epoch { busy = false } }
        do {
            let saved = try await storage().save(proposed, expected: expected)
            try Task.checkCancellation()
            guard stamp == epoch else { throw CancellationError() }
            archive = saved.archive; revision = saved.revision; failure = nil
            reconcileEvaluators()
        } catch {
            if stamp == epoch { loaded = false; report(error) }
            throw error
        }
    }
    func startTrip() throws {
        guard sensingConsent, sensing, foreground else { throw BackpackError.invalid("Start independent foreground sensing before measuring a new trip.") }
        trip.start(); status = "Approximate trip started — no pace, route or samples are saved"
    }
    func pauseTrip() { trip.pause(); status = "Trip paused — no gap distance will be invented" }
    func resetTrip() { trip.reset(); sessionUnlocks.removeAll(); status = "Trip distance and one-shot milestone state reset explicitly" }
    func stopTrip() { trip.pause(); status = "Trip stopped; optional explicit distance-only recap remains available" }
    func saveRecap(name: String, selectedUnlocks: Set<UUID>) async throws {
        guard recapConsent, !trip.running else { throw BackpackError.invalid("Stop the trip and explicitly opt in to a local recap first.") }
        let summaries = archive.unlocks.filter { selectedUnlocks.contains($0.id) }
        guard summaries.count == selectedUnlocks.count else { throw BackpackError.invalid("A selected local unlock was removed. Previous recap state retained.") }
        let recap = SoloRecap(id: UUID(), name: name, approximateMeters: trip.meters, summaries: summaries.map(\.name))
        try await edit { $0.recaps.append(recap) }
    }
    func unlock(_ area: SoloArea, manual: Bool) async throws {
        guard area.kind == .adventure, !archive.unlocks.contains(where: { $0.id == area.id }),
              archive.areas.contains(where: { $0.id == area.id }) else { throw BackpackError.invalid("Choose a remaining own local adventure target.") }
        let value = SoloUnlock(id: area.id, name: area.badge ?? area.name, sceneID: area.sceneID, manual: manual)
        // Sensed awards are serialized separately; no server claim or event attendance is generated.
        try await persistUnlock(value)
    }
    private func persistUnlock(_ value: SoloUnlock) async throws {
        guard loaded, !busy else { throw BackpackError.invalid("Local badge save unavailable/busy; no unlock was recorded.") }
        var proposed = archive
        proposed.unlocks.append(value)
        let stamp = epoch; busy = true; defer { if stamp == epoch { busy = false } }
        do {
            let saved = try await storage().save(proposed, expected: revision)
            try Task.checkCancellation(); guard stamp == epoch else { throw CancellationError() }
            archive = saved.archive; revision = saved.revision
            if sessionUnlocks.count < 50 { sessionUnlocks.append(value) }
            status = value.manual ? "Own local badge recorded manually — not sensed or certified attendance" : "Own local adventure badge saved — approximate local eligibility only"
        } catch { if stamp == epoch { loaded = false }; throw error }
    }
    private func receive(_ fix: SoloFix) {
        guard foreground, sensing, sensingConsent, loaded else { return }
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let fixStamp = UUID(), sessionStamp = epoch
        latestFix = fixStamp
        stale?.cancel()
        guard fix.usable(at: now) else { discardSample(); status = "Fix stale/inaccurate — no measured progress; manual fallback"; return }
        stale = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled, self?.epoch == sessionStamp, self?.latestFix == fixStamp else { return }
            self?.discardSample()
        }
        var selectedArea: SoloArea?
        for area in archive.areas {
            var evaluator = evaluators[area.id] ?? SoloAreaEvaluator()
            let result = evaluator.evaluate(area: area, fix: fix, now: now, uptime: uptime)
            evaluators[area.id] = evaluator; areaStates[area.id] = result
            if result == .entered && selectedArea == nil { selectedArea = area }
        }
        let milestones = trip.sample(fix, now: now, milestones: archive.milestones)
        if let area = selectedArea {
            offerScene(area.sceneID)
            if area.kind == .adventure && !archive.unlocks.contains(where: { $0.id == area.id }) {
                io = Task { [weak self] in
                    do { try await self?.unlock(area, manual: false) } catch { self?.report(error) }
                }
            }
        } else if let milestone = milestones.first { offerScene(milestone.sceneID) }
    }
    private func discardSample() {
        trip.discardSample()
        for id in Array(evaluators.keys) { evaluators[id]?.discardSample(); areaStates[id] = .unavailable }
    }
    func offerScene(_ id: UUID) {
        guard archive.scenes.contains(where: { $0.id == id }) else { failure = "Chosen owned local scene was removed."; return }
        offer = id
        if armed { playScene(id) }
        else { status = "Local scene offered — explicitly arm PHONE automation or choose manual preview" }
    }
    func arm() async {
        guard !busy else { return }
        let stamp = epoch
        busy = true; defer { if stamp == epoch { busy = false } }
        do {
            guard loaded, automationConsent, foreground, let phone, let targets,
                  phone.canApplyAutomaticPhoneArtwork, phone.hasArtwork else {
                throw BackpackError.invalid("Explicit PHONE consent, an open visible PHONE original and foreground context are required. Hardware/unknown original is unavailable.")
            }
            try targets.acquirePhone(lease)
            let expected = phone.artworkRevision, snapshot = phone.snapshot()
            let original = try await recovery().prepareGame(snapshot: snapshot, artworkRevision: expected,
                ownerScope: Self.recoveryScope, attribution: nil, purpose: "solo-v1")
            try Task.checkCancellation()
            guard stamp == epoch, foreground, automationConsent, targets.target == .phone,
                  targets.phonePeerOwner == lease, phone.artworkRevision == expected,
                  phone.canApplyAutomaticPhoneArtwork else { throw CancellationError() }
            journal = original; recoveryAvailable = true; ownedRevision = expected; armed = true
            failure = nil; status = "PHONE automation armed with durable first original; sensing remains independently controlled"
        } catch {
            if stamp == epoch { targets?.releasePhone(lease); report(error) }
        }
    }
    private func requirePlayer(_ stamp: UUID, expected: UUID) throws {
        guard stamp == epoch, foreground, armed, automationConsent, let phone, let targets,
              targets.target == .phone, targets.phonePeerOwner == lease, ownedRevision == expected,
              phone.artworkRevision == expected, phone.canApplyAutomaticPhoneArtwork else {
            throw BackpackError.invalid("SOLO PHONE ownership/consent/context changed; first original retained.")
        }
    }
    func playScene(_ id: UUID, brightness: Double? = nil, duration: Double? = nil) {
        guard presentation == nil, !busy, let scene = archive.scenes.first(where: { $0.id == id }) else {
            failure = "Another operation is active or this owned local scene is unavailable."; return
        }
        let stamp = epoch
        presentation = Task { [weak self] in
            guard let self else { return }
            defer { if stamp == self.epoch { self.presentation = nil } }
            do {
                var index = 0
                let end = duration.map { ProcessInfo.processInfo.systemUptime + $0 }
                repeat {
                    guard let expected = self.ownedRevision, let phone = self.phone else { throw BackpackError.invalid("Arm the current PHONE target first.") }
                    try self.requirePlayer(stamp, expected: expected)
                    let item = scene.items[index], next = UUID()
                    let staged = try await self.recovery().stageSoloReplacement(ownerScope: Self.recoveryScope,
                        expectedRevision: expected, nextRevision: next, incoming: item.bytes, now: Date())
                    try Task.checkCancellation()
                    try self.requirePlayer(stamp, expected: expected)
                    self.journal = staged
                    try await phone.applyValidatedGameGIF(item.bytes, expectedRevision: expected, nextRevision: next,
                        explicitlyArmedPlayback: true, validateContext: { [weak self] in
                            guard let self else { throw CancellationError() }
                            try self.requirePlayer(stamp, expected: expected)
                        })
                    self.ownedRevision = next; self.offer = nil
                    if let brightness {
                        guard brightness.isFinite, (0.1...0.6).contains(brightness), end != nil else { throw BackpackError.invalid("Daylight brightness requires its explicit capped duration.") }
                        try phone.applySoloBrightness(brightness, expectedRevision: next)
                    }
                    self.status = "Playing own local scene \(scene.name) on PHONE; authored GIF bytes/timing unchanged"
                    index += 1
                    if index == scene.items.count && scene.repeatPlaylist { index = 0 }
                    if index == scene.items.count {
                        guard let end else { break }
                        let remaining = max(0, end - ProcessInfo.processInfo.systemUptime)
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                        guard stamp == self.epoch else { throw CancellationError() }
                        self.stop("Daylight presentation window ended — explicit restore original / rearm required")
                        return
                    }
                    let remaining = end.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) }
                    let wait = min(scene.interval, remaining ?? scene.interval)
                    try await Task.sleep(for: .seconds(wait))
                    if let end, ProcessInfo.processInfo.systemUptime >= end {
                        self.stop("Daylight presentation window ended — explicit restore original / rearm required")
                        return
                    }
                } while !Task.isCancelled
            } catch {
                if stamp == self.epoch { self.stop("Scene stopped/uncertain — original retained, explicit recovery required"); self.report(error) }
            }
        }
    }
    func previewManually(_ id: UUID) async throws {
        guard let scene = archive.scenes.first(where: { $0.id == id }), let item = scene.items.first,
              let phone, targets?.target == .phone, targets?.phonePeerOwner == nil, foreground else {
            throw BackpackError.invalid("Select an unowned PHONE target in foreground for manual first-item preview. No hardware fallback.")
        }
        try await phone.show(item.bytes)
        status = "Manual preview (first playlist item), not automatic sensing or a measured visit"
    }
    func scheduleDaylight(_ id: UUID) throws {
        guard armed, automationConsent, foreground, let plan = archive.daylight.first(where: { $0.id == id }) else {
            throw BackpackError.invalid("Arm PHONE automation and select an explicit local daylight plan.")
        }
        try plan.validate()
        schedule?.cancel(); selectedDaylight = id
        let stamp = epoch
        schedule = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard stamp == self.epoch, self.foreground, self.armed, self.selectedDaylight == id else { return }
                let now = Date()
                switch SoloSolar.calculate(day: now, point: plan.point, timeZoneID: plan.timeZoneID) {
                case .events(let rise, let set):
                    self.daylightDescription = "Approximate sunrise \(rise.formatted()) / sunset \(set.formatted()); explicit zone \(plan.timeZoneID)"
                    for (event, scene) in [(rise, plan.sunriseSceneID), (set, plan.sunsetSceneID)] {
                        let key = id.uuidString + "|" + String(event.timeIntervalSince1970)
                        let age = now.timeIntervalSince(event)
                        if (0...60).contains(age), !self.daylightFired.contains(key), self.presentation == nil {
                            if self.daylightFired.count >= 40 { self.stop("Daylight session bound reached — explicit restart required"); return }
                            self.daylightFired.insert(key)
                            self.playScene(scene, brightness: plan.brightness, duration: plan.duration)
                        }
                    }
                case .polarDay: self.daylightDescription = "Polar day: no sunrise/sunset today — manual preview available"
                case .polarNight: self.daylightDescription = "Polar night: no sunrise/sunset today — manual preview available"
                case .unavailable: self.daylightDescription = "Solar/time zone/date unavailable — no guessed schedule; manual preview available"
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    func restore() async {
        stop("Explicit restore requested — automatic work stopped")
        let stamp = epoch
        busy = true; defer { if stamp == epoch { busy = false } }
        do {
            guard foreground, let phone, let targets, targets.target == .phone else {
                throw BackpackError.invalid("Select PHONE and remain foreground before explicit original restore.")
            }
            try targets.acquirePhone(lease); defer { targets.releasePhone(lease) }
            let capturedRevision = phone.artworkRevision
            guard let retained = try await recovery().load(), retained.peerPurpose == "solo-v1", retained.needsRecovery else {
                throw BackpackError.invalid("No active known SOLO original exists. Another journal is never adopted or overwritten.")
            }
            let original = try await recovery().beginRestore(id: retained.transactionID, ownerScope: Self.recoveryScope, target: .phone)
            try Task.checkCancellation()
            guard stamp == epoch, foreground, targets.target == .phone, targets.phonePeerOwner == lease,
                  phone.artworkRevision == capturedRevision else { throw CancellationError() }
            try await phone.restore(original.phone)
            let actual = phone.snapshot()
            guard stamp == epoch, foreground, targets.target == .phone, targets.phonePeerOwner == lease,
                  actual.data == original.phone.data, actual.mediaID == original.phone.mediaID,
                  abs(actual.elapsed - original.phone.elapsed) < 1,
                  actual.keepAwake == original.phone.keepAwake, actual.wantsPlayback == original.phone.wantsPlayback,
                  actual.brightnessEnabled == original.phone.brightnessEnabled,
                  actual.brightnessLevel == original.phone.brightnessLevel,
                  actual.animationsEnabled == original.phone.animationsEnabled,
                  actual.dataSaving == original.phone.dataSaving,
                  actual.crispPixels == original.phone.crispPixels, actual.pixelGrid == original.phone.pixelGrid,
                  actual.motionOverride == original.phone.motionOverride else {
                throw BackpackError.invalid("Exact current original/presentation restore was not acknowledged; journal retained.")
            }
            let acknowledged = try await recovery().acknowledgeRestore(id: original.transactionID,
                originalSHA256: LocalSwapOriginal.digest(actual.data ?? Data()), ownerScope: Self.recoveryScope)
            guard stamp == epoch else { return }
            journal = acknowledged
            recoveryAvailable = false; failure = nil; phone.open()
            status = "First original restored and durably acknowledged; no automatic restart or hardware operation"
        } catch { if stamp == epoch { report(error) } }
    }
}
