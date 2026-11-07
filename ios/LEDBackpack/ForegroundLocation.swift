import CoreLocation
import Combine
import BackpackProtocol

enum CheckpointEligibility: String { case manual = "Manual fallback", outside = "Outside fixed checkpoint", dwelling = "Dwelling locally", eligible = "Locally eligible — manual confirmation required", cooldown = "Cooldown" }
struct LocalCheckpointEvaluator {
    private var entered: TimeInterval?
    private var lastEligible: TimeInterval?
    private var previous: TimeInterval?
    mutating func reset() { entered = nil; lastEligible = nil; previous = nil }
    mutating func discardSample() { entered = nil; previous = nil }
    mutating func evaluate(distance: Double, accuracy: Double, age: Double, radius: Double,
        now: TimeInterval, dwell: TimeInterval = 10, cooldown: TimeInterval = 60) -> CheckpointEligibility {
        guard distance.isFinite, distance >= 0, accuracy.isFinite, accuracy > 0, accuracy <= 25,
              age.isFinite, (0...5).contains(age), radius.isFinite, radius >= 1, now.isFinite,
              dwell.isFinite, dwell >= 10, cooldown.isFinite, cooldown >= 60 else {
            entered = nil; previous = nil; return .manual
        }
        if let previous, now < previous { entered = nil; self.previous = nil; return .manual }
        if let previous, now - previous > 5 { entered = nil }
        previous = now
        // Confidence bounds never enlarge the organizer's radius.
        if distance + accuracy > radius { entered = nil; return .outside }
        if let lastEligible, now - lastEligible < cooldown { return .cooldown }
        if entered == nil {
            guard distance + accuracy <= max(0, radius - 2) else { return .outside }
            entered = now
        }
        guard let entered, now - entered >= dwell else { return .dwelling }
        lastEligible = now; self.entered = nil; return .eligible
    }
}
struct ForegroundLocationScope: Equatable {
    let accountRevision: UUID
    let eventID: UUID
    let eventRevision: Int
    let participationRevision: Int
    let checkpointID: UUID
}
struct LocalCheckpointHint: Equatable {
    let id: UUID
    let scope: ForegroundLocationScope
    let observedUptime: TimeInterval
    let validUntilUptime: TimeInterval
    func require(_ expected: ForegroundLocationScope, uptime: TimeInterval) throws {
        guard scope == expected, uptime.isFinite, uptime >= 0, observedUptime.isFinite,
              observedUptime <= uptime, validUntilUptime.isFinite,
              validUntilUptime <= observedUptime + 5, uptime < validUntilUptime else {
            throw BackpackError.invalid("A fresh local GPS hint for this exact account/event/participation/checkpoint is required. No stale or wrong-target confirmation.")
        }
    }
}
@MainActor
final class ForegroundCheckpointLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status = "Local sensing off"
    @Published private(set) var sensing = false
    @Published private(set) var eligibility = CheckpointEligibility.manual
    @Published private(set) var hint: LocalCheckpointHint?
    private var manager: CLLocationManager?
    private var lastAuthorization: CLAuthorizationStatus?
    private var lastAccuracy: CLAccuracyAuthorization?
    private var scope: ForegroundLocationScope?
    private var fixed: EventRouteCheckpoint?
    private var deadlineUptime: TimeInterval?
    private var evaluator = LocalCheckpointEvaluator()
    private var expiry: Task<Void, Never>?
    private var stale: Task<Void, Never>?
    private var epoch = UUID()
    var stoppedForPermissionChange: (() -> Void)?
    var hasInitializedLocationManager: Bool { manager != nil }
    private func activatedLocationManager() -> CLLocationManager {
        if let manager {
            lastAuthorization = manager.authorizationStatus
            lastAccuracy = manager.accuracyAuthorization
            return manager
        }
        let value = CLLocationManager()
        manager = value
        value.allowsBackgroundLocationUpdates = false
        value.pausesLocationUpdatesAutomatically = true
        lastAuthorization = value.authorizationStatus
        lastAccuracy = value.accuracyAuthorization
        value.delegate = self
        return value
    }
    func requestWhenInUse(consent: Bool) {
        guard consent else { stop("Local consent required"); return }
        stop("OS permission is separate; press Start again after granting")
        activatedLocationManager().requestWhenInUseAuthorization()
    }
    func start(event: CatalogEvent, checkpoint: EventRouteCheckpoint, accountRevision: UUID,
        consent: Bool, foreground: Bool, capability: Bool) throws {
        stop("Checking foreground eligibility")
        guard consent, foreground, capability, CLLocationManager.locationServicesEnabled(),
              event.access.member, event.rsvpStatus == .going, event.requiresReconfirmation == false,
              !event.cancelled, let revision = event.participationRevision,
              event.route?.published == true, event.route?.checkpoints.contains(checkpoint) == true else {
            status = "Unavailable/denied/reduced accuracy or current event consent missing — use manual fallback"
            throw BackpackError.invalid(status)
        }
        try checkpoint.validate()
        let server = try CatalogEventTime.parse(event.serverTime), end = try CatalogEventTime.parse(event.endsAtISO)
        guard server >= (try CatalogEventTime.parse(event.startsAtISO)), server < end else {
            status = "Outside actual event window — sensing off"; throw BackpackError.invalid(status)
        }
        let manager = activatedLocationManager()
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus),
              manager.accuracyAuthorization == .fullAccuracy else {
            status = "Unavailable/denied/reduced accuracy — use manual fallback"
            throw BackpackError.invalid(status)
        }
        scope = ForegroundLocationScope(accountRevision: accountRevision, eventID: event.id, eventRevision: event.revision,
            participationRevision: revision, checkpointID: checkpoint.id)
        fixed = checkpoint
        // Short lease requires a fresh authorized event read before any explicit restart.
        let lease = min(60, end.timeIntervalSince(server))
        deadlineUptime = ProcessInfo.processInfo.systemUptime + lease
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        sensing = true; status = "Foreground local sensing active — coordinates discarded, nothing shared"
        manager.startUpdatingLocation()
        let stamp = epoch
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lease)) } catch { return }
            guard !Task.isCancelled, self?.epoch == stamp else { return }
            self?.stop("Local lease/event deadline ended — explicit refresh/start required")
        }
    }
    func stop(_ reason: String = "Local sensing off") {
        epoch = UUID()
        manager?.stopUpdatingLocation(); expiry?.cancel(); stale?.cancel()
        expiry = nil; stale = nil; scope = nil; fixed = nil; deadlineUptime = nil; hint = nil
        evaluator.reset(); eligibility = .manual; sensing = false; status = reason
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        let changed = lastAuthorization != manager.authorizationStatus || lastAccuracy != manager.accuracyAuthorization
        lastAuthorization = manager.authorizationStatus; lastAccuracy = manager.accuracyAuthorization
        if sensing && changed { stop("OS permission/accuracy changed — explicit restart required"); stoppedForPermissionChange?() }
        switch manager.authorizationStatus {
        case .denied: status = "OS location denied — manual fallback"
        case .restricted: status = "OS location restricted — manual fallback"
        case .notDetermined: status = "OS permission not requested"
        default:
            if manager.accuracyAuthorization == .reducedAccuracy { status = "Reduced accuracy — local eligibility unavailable; manual fallback" }
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard manager === self.manager, sensing, let scope, let fixed, let deadlineUptime,
              uptime < deadlineUptime, let sample = locations.last else {
            if sensing { stop("Local sensing context/lease unavailable") }; return
        }
        let target = CLLocation(latitude: fixed.latitude, longitude: fixed.longitude)
        let distance = sample.distance(from: target), age = Date().timeIntervalSince(sample.timestamp)
        let evaluated = evaluator.evaluate(distance: distance, accuracy: sample.horizontalAccuracy,
            age: age, radius: fixed.radiusMeters, now: uptime)
        if evaluated == .eligible {
            hint = LocalCheckpointHint(id: UUID(), scope: scope, observedUptime: uptime, validUntilUptime: min(deadlineUptime, uptime + 5))
        } else if evaluated == .manual || evaluated == .outside {
            hint = nil
        } else if let previous = hint {
            if previous.scope == scope, previous.validUntilUptime > uptime,
               distance + sample.horizontalAccuracy <= fixed.radiusMeters {
                hint = LocalCheckpointHint(id: previous.id, scope: scope, observedUptime: uptime, validUntilUptime: min(deadlineUptime, uptime + 5))
            } else { hint = nil }
        }
        eligibility = hint == nil ? evaluated : .eligible
        stale?.cancel()
        let stamp = epoch
        stale = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled, self?.epoch == stamp else { return }
            self?.evaluator.discardSample(); self?.hint = nil; self?.eligibility = .manual
            self?.status = "GPS fix stale — manual fallback, no confirmed arrival"
        }
    }
    func consumeHint(_ expected: ForegroundLocationScope) throws -> UUID {
        guard sensing, let hint else { throw BackpackError.invalid("A current local GPS hint is unavailable; use the separately labelled manual choice.") }
        try hint.require(expected, uptime: ProcessInfo.processInfo.systemUptime)
        self.hint = nil; eligibility = .cooldown
        return hint.id
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        stop("Location unavailable — manual fallback")
        stoppedForPermissionChange?()
    }
}
