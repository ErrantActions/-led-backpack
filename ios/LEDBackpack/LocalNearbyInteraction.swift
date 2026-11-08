import Foundation
import NearbyInteraction
import Combine
import BackpackProtocol

@MainActor
final class LocalNearbyInteraction: NSObject, ObservableObject, NISessionDelegate {
    @Published private(set) var status = "Optional NI ranging off; manual pairing/game remains available"
    @Published private(set) var stableNearby = false
    private var session: NISession?
    private var peer: NIDiscoveryToken?
    private var stability = LocalRangeStability()
    private var expiry: Task<Void, Never>?
    private var generation = UUID()
    var changed: (() -> Void)?
    var failed: ((String) -> Void)?
    var initialized: Bool { session != nil }
    func hasFreshStableHint(uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        session != nil && peer != nil && stableNearby && stability.fresh(uptime: uptime)
    }
    func prepare(consent: Bool, foreground: Bool) throws -> Data {
        guard consent, foreground, NISession.isSupported,
              let usage = Bundle.main.object(forInfoDictionaryKey: "NSNearbyInteractionUsageDescription") as? String,
              !usage.isEmpty else { throw BackpackError.invalid("Supported NI/explicit foreground ranging consent/purpose text required. Choose manual mode deliberately if unavailable.") }
        stop()
        let current = NISession(); current.delegate = self; session = current
        guard let token = current.discoveryToken else { stop(); throw BackpackError.invalid("NI discovery token unavailable; no automatic retry.") }
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        guard data.count <= 1400 else { stop(); throw BackpackError.invalid("NI token exceeds encrypted peer-frame budget.") }
        status = "NI prepared, waiting for this paired peer's authenticated token"
        return data
    }
    func run(peerToken: Data) throws {
        guard peer == nil, (1...1400).contains(peerToken.count), let session,
              let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: peerToken) else {
            throw BackpackError.invalid("Invalid/unprepared paired NI token.")
        }
        peer = token
        session.run(NINearbyPeerConfiguration(peerToken: token))
        status = "NI active for this explicitly paired foreground peer; no exact-distance/direction UI"
    }
    func stop() {
        generation = UUID()
        expiry?.cancel(); expiry = nil
        session?.delegate = nil; session?.invalidate(); session = nil
        peer = nil; stableNearby = false; stability.reset(); status = "NI stopped — no automatic resume"
    }
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard session === self.session else { return }
        let stamp = UUID(); generation = stamp
        expiry?.cancel(); expiry = nil
        guard nearbyObjects.count <= 1, let object = nearbyObjects.first, object.discoveryToken == peer else {
            stability.reset(); stableNearby = false; status = "No matching paired NI object — uncertain"; changed?(); return
        }
        stableNearby = stability.observe(distance: object.distance, uptime: ProcessInfo.processInfo.systemUptime)
        status = stableNearby ? "Coarse stable-nearby hint; not verified identity/proximity/safety" : "Ranging uncertain/outside/stabilizing — game waits"
        changed?()
        expiry = Task { [weak self, weak session] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, let session, self?.session === session, self?.generation == stamp else { return }
            self?.stability.reset(); self?.stableNearby = false
            self?.status = "NI hint stale — game waits/stops, no proximity inference"
            self?.changed?()
        }
    }
    func sessionWasSuspended(_ session: NISession) { guard session === self.session else { return }; stop(); failed?("NI suspended — stopped, explicit new pairing required") }
    func sessionSuspensionEnded(_ session: NISession) { guard session === self.session else { return }; stop(); failed?("NI suspension ended; no automatic sensing restart") }
    func session(_ session: NISession, didInvalidateWith error: Error) { guard session === self.session else { return }; stop(); failed?("NI unavailable: \(error.localizedDescription). No silent fallback/restart.") }
    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard session === self.session else { return }
        stop(); failed?("Paired NI object removed; stop and explicitly choose manual/new pairing")
    }
}
