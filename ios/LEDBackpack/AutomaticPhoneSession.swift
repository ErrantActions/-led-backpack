import SwiftUI
import BackpackProtocol

@MainActor
final class AutomaticPhoneSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Automatic PHONE session off"
    @Published private(set) var failure: String?
    private weak var phone: PhoneDisplayController?
    private weak var targets: DisplayTargetSelection?
    private let repository: SwapRecoveryRepository?
    private let lease = UUID()
    private var epoch = UUID()
    private var ownedRevision: UUID?
    private var original: LocalSwapOriginal?
    private var purpose: String?
    private var scope: String?
    private var currentScope: (@MainActor () -> String)?
    private var authorize: (@MainActor () throws -> Void)?
    var hasRecovery: Bool { original?.needsRecovery == true }
    init(repository: SwapRecoveryRepository? = SwapRecoveryRepository.shared) { self.repository = repository }
    func bind(phone: PhoneDisplayController, targets: DisplayTargetSelection) { self.phone = phone; self.targets = targets }
    func begin(id: UUID, scope: String, currentScope: @escaping @MainActor () -> String,
        authorize: @escaping @MainActor () throws -> Void) async throws {
        guard !running, !busy, let phone, let targets, let repository, phone.hasArtwork else {
            throw BackpackError.invalid("Choose a real PHONE original and stop the other automatic session first.")
        }
        try authorize()
        try targets.acquirePhone(lease)
        let stamp = UUID(); epoch = stamp; busy = true; failure = nil
        let revision = phone.artworkRevision, snapshot = phone.snapshot()
        defer { if stamp == epoch { busy = false } }
        do {
            let purpose = "phone-session-v1:" + id.uuidString.lowercased()
            let journal = try await repository.prepareGame(snapshot: snapshot, artworkRevision: revision,
                ownerScope: scope, attribution: nil, purpose: purpose)
            try Task.checkCancellation(); try authorize()
            guard epoch == stamp, targets.target == .phone, targets.phonePeerOwner == lease,
                  phone.artworkRevision == revision, currentScope() == scope else { throw CancellationError() }
            self.original = journal; self.purpose = purpose; self.scope = scope
            self.currentScope = currentScope; self.authorize = authorize; ownedRevision = revision
            phone.open()
            for _ in 0..<100 {
                try Task.checkCancellation(); try authorize()
                guard epoch == stamp else { throw CancellationError() }
                if phone.canApplyAutomaticPhoneArtwork { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard phone.canApplyAutomaticPhoneArtwork else { throw BackpackError.invalid("PHONE canvas is not visible; original retained, no automatic replacement.") }
            running = true; status = "PHONE ownership and durable initial original prepared"
        } catch {
            if epoch == stamp { targets.releasePhone(lease); self.authorize = nil; failure = error.localizedDescription }
            throw error
        }
    }

    @MainActor
    struct ScopedPhoneCanvasControls: View {
        @ObservedObject var session: AutomaticPhoneSession
        let stop: @MainActor () -> Void
        let restore: @MainActor () async -> Void
        var body: some View {
            if session.running || session.busy || session.hasRecovery {
                VStack {
                    Text(session.status).font(.caption)
                    if let error = session.failure { Text(error).font(.caption).foregroundStyle(.orange) }
                    Button("Stop automatic PHONE / retain recovery", role: .destructive, action: stop)
                    Button("Restore initial PHONE original") { Task { await restore() } }
                }
            }
        }
    }
    func check() throws {
        try Task.checkCancellation()
        guard running, let phone, let targets, let scope, currentScope?() == scope,
              targets.target == .phone, targets.phonePeerOwner == lease,
              phone.artworkRevision == ownedRevision, phone.canApplyAutomaticPhoneArtwork else {
            throw BackpackError.invalid("Automatic PHONE ownership/account/visibility changed. Recovery retained.")
        }
        try authorize?()
    }
    func apply(_ data: Data, title: String, verify: @escaping @MainActor () async throws -> Void) async throws {
        try check()
        guard !busy, let expected = ownedRevision, let phone, let repository, let scope, let purpose else {
            throw BackpackError.invalid("Automatic PHONE replacement is busy or missing its known original.")
        }
        let stamp = epoch, next = UUID(); busy = true
        defer { if epoch == stamp { busy = false } }
        try await verify(); try check()
        let staged = try await repository.stagePhoneSession(purpose: purpose, ownerScope: scope,
            expectedRevision: expected, nextRevision: next, bytes: data)
        try check()
        guard epoch == stamp else { throw CancellationError() }
        original = staged
        try await phone.applyValidatedGameGIF(data, expectedRevision: expected, nextRevision: next,
            explicitlyArmedPlayback: true, reauthorize: verify, validateContext: {
                try self.check()
                guard self.epoch == stamp else { throw CancellationError() }
            })
        ownedRevision = next; status = title
    }
    func stop(_ message: String = "Automatic PHONE session stopped — original retained") {
        epoch = UUID(); running = false; busy = false; authorize = nil
        if targets?.phonePeerOwner == lease, phone?.artworkRevision == ownedRevision {
            phone?.cancelPendingSelection(); phone?.stopPeerPlayback()
        }
        targets?.releasePhone(lease); status = message
    }
    func fail(_ error: Error) {
        stop(hasRecovery ? "Automatic PHONE work stopped; explicit original recovery remains available" : "Stopped before an active recovery transaction; no replacement authorized")
        failure = error.localizedDescription
    }
    func restore() async {
        stop()
        guard let phone, let targets, let repository, let scope, currentScope?() == scope,
              let original, phone.artworkRevision == ownedRevision else {
            failure = "A newer selection/account or unknown journal cannot be overwritten. Use separately confirmed Recovery first."; return
        }
        let stamp = epoch
        busy = true
        defer { if epoch == stamp { busy = false } }
        do {
            try targets.acquirePhone(lease); defer { targets.releasePhone(lease) }
            let retained = try await repository.beginRestore(id: original.transactionID, ownerScope: scope, target: .phone)
            guard stamp == epoch, currentScope?() == scope, phone.artworkRevision == ownedRevision else { throw CancellationError() }
            try await phone.restore(retained.phone)
            guard stamp == epoch, currentScope?() == scope, targets.target == .phone,
                  targets.phonePeerOwner == lease, phone.data == retained.phone.data else { throw CancellationError() }
            self.original = try await repository.acknowledgeRestore(id: retained.transactionID,
                originalSHA256: retained.originalSHA256, ownerScope: scope)
            status = "Initial PHONE original restored and acknowledged; durable copy retained"; failure = nil
        } catch { failure = error.localizedDescription }
    }
}
