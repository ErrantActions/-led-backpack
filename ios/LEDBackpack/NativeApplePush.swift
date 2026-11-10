import SwiftUI
import UserNotifications
import BackpackProtocol

@MainActor
final class NativeApplePushEvents: ObservableObject {
    static let shared = NativeApplePushEvents()
    @Published private(set) var token: Data?
    @Published private(set) var failure: String?
    @Published private(set) var activity: UUID?
    func registered(_ value: Data) {
        guard (16...256).contains(value.count) else { failure = "OS push token exceeds the server's actual bound."; token = nil; return }
        token = value; failure = nil
    }
    func failed(_ error: Error) { failure = error.localizedDescription; token = nil }
    func tapped(_ value: UUID) { activity = value }
    func clearActivity() { activity = nil }
}
@MainActor
final class NativeApplePushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NativeApplePushEvents.shared.registered(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NativeApplePushEvents.shared.failed(error)
    }
}
struct NativeAppleDevice: Codable, Identifiable {
    let id: UUID
    let revision: Int
    let permission: String
    let hasToken: Bool
    let updatedAtISO: String
}
struct NativePushDestination: Decodable {
    let kind: String
    let peerId, eventId, roomId: UUID?
}
enum NativePushPermission {
    static func value(_ status: UNAuthorizationStatus) throws -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .ephemeral: throw BackpackError.invalid("Ephemeral push permission is not in the official app/server contract.")
        @unknown default: throw BackpackError.invalid("Unsupported OS push permission state.")
        }
    }
}
enum NativeApplePushRoute {
    static func valid(_ path: String, method: String) -> Bool {
        if path == "notifications/apple-devices" { return method == "GET" || method == "POST" }
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "notifications", let id = UUID(uuidString: String(parts[2])),
              id.uuidString.lowercased() == parts[2] else { return false }
        return parts[1] == "apple-devices" && method == "DELETE" || parts[1] == "apple-activity" && method == "GET"
    }
}
@MainActor
final class NativeApplePushCoordinator: ObservableObject {
    @Published private(set) var device: NativeAppleDevice?
    @Published private(set) var permission = "notDetermined"
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var destination: NativePushDestination?
    private weak var community: CommunityController?
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private let cache = CommunityKeychain()
    private var registeredTokenHash: String?
    private var registrationUncertain = false
    private var pendingActivity: UUID?
    func bind(_ value: CommunityController) {
        reset(); community = value
        value.nativePushCleanup = { [weak self] in try await self?.removeCurrent() }
    }
    func reset() {
        task?.cancel(); task = nil; epoch = UUID(); device = nil; destination = nil; failure = nil; busy = false
        registeredTokenHash = nil
        registrationUncertain = false; pendingActivity = nil
    }
    func report(_ error: Error) { failure = error.localizedDescription }
    func clearDestination() { destination = nil }
    private func cacheKey(_ value: CommunityController) throws -> String {
        guard let origin = value.origin, let id = value.user?.id, let key = try value.nativeAppleKeyID() else {
            throw BackpackError.invalid("This device's attestation/registration identity is not established.")
        }
        return "apple-push|\(origin.url.absoluteString)|\(id.uuidString.lowercased())|\(key)"
    }
    func refresh() {
        guard !busy else { return }
        run { community, revision in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            try self.checkScope(community, revision)
            self.permission = try NativePushPermission.value(settings.authorizationStatus)
            struct Devices: Decodable { let devices: [NativeAppleDevice] }
            let all = try JSONDecoder().decode(Devices.self, from: await community.applePushRequest("notifications/apple-devices", revision: revision)).devices
            let key = try self.cacheKey(community)
            if let bytes = try self.cache.read(key) {
                let saved = try JSONDecoder().decode(NativeAppleDevice.self, from: bytes)
                self.device = all.first { $0.id == saved.id }
            }
            if let device = self.device,
               device.permission != self.permission ||
                (NativeApplePushEvents.shared.token != nil && self.registeredTokenHash != NativeApplePushEvents.shared.token.map(NativeIntegrityBinding.digest)) {
                try await self.saveOSState(community, revision: revision, expectedRevision: device.revision)
            }
        }
    }
    func requestPermissionAndToken() {
        run { community, revision in
            guard community.nativeApplePushAvailable else { throw BackpackError.invalid("Real device/provider/App Attest readiness is unavailable. Simulator/headers do not grant permission.") }
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            try self.checkScope(community, revision)
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            try self.checkScope(community, revision)
            self.permission = try NativePushPermission.value(settings.authorizationStatus)
            if ["authorized", "provisional"].contains(self.permission) { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
    func registerCurrentToken(expectedRevision: Int) {
        run { community, revision in
            try await self.saveOSState(community, revision: revision, expectedRevision: expectedRevision)
        }
    }
    private func checkScope(_ value: CommunityController, _ revision: UUID) throws {
        try Task.checkCancellation()
        guard value.accountRevision == revision, value.nativeApplePushAvailable else { throw BackpackError.invalid("Native permission/device scope changed.") }
    }
    private func saveOSState(_ community: CommunityController, revision: UUID, expectedRevision: Int) async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        try checkScope(community, revision)
        let permission = try NativePushPermission.value(settings.authorizationStatus)
        let token = NativeApplePushEvents.shared.token
        if ["authorized", "provisional"].contains(permission), token == nil { throw BackpackError.invalid("Wait for the actual OS token callback before registering.") }
        struct Body: Encodable { let expectedRevision: Int; let permission: String; let token: String? }
        struct Result: Decodable { let device: NativeAppleDevice }
        let body = Body(expectedRevision: expectedRevision, permission: permission,
            token: ["authorized", "provisional"].contains(permission) ? token?.map { String(format: "%02x", $0) }.joined() : nil)
        let scopeKey = try cacheKey(community)
        try cache.save(Data([1]), key: scopeKey + "|pending")
        registrationUncertain = true
        let data = try await community.applePushRequest("notifications/apple-devices", method: "POST",
            body: JSONEncoder().encode(body), revision: revision)
        let result = try JSONDecoder().decode(Result.self, from: data).device
        guard result.permission == permission, result.revision >= expectedRevision else { throw BackpackError.invalid("The current OS state/device revision was not confirmed.") }
        try cache.save(JSONEncoder().encode(result), key: cacheKey(community))
        try cache.remove(scopeKey + "|pending")
        device = result; self.permission = permission; registeredTokenHash = token.map(NativeIntegrityBinding.digest)
        registrationUncertain = false
    }
    func removeCurrent(expected: NativeAppleDevice? = nil) async throws {
        let pending = task
        await pending?.value
        guard let community else { return }
        guard let device else {
            let pending = try community.nativeAppleKeyID() != nil ? cache.read(cacheKey(community) + "|pending") : nil
            if registrationUncertain || pending != nil { throw BackpackError.invalid("Registration acknowledgment was lost; no device ID is guessed. Fresh-account attestation key recovery/revocation must resolve this before native push revocation can be confirmed.") }
            return
        }
        guard expected == nil || expected?.id == device.id && expected?.revision == device.revision else {
            throw BackpackError.invalid("Displayed device/version changed; refresh before confirming revocation.")
        }
        struct Body: Encodable { let expectedRevision: Int }
        struct Result: Decodable { let removed: Bool }
        let data = try await community.applePushRequest("notifications/apple-devices/\(device.id.uuidString.lowercased())",
            method: "DELETE", body: JSONEncoder().encode(Body(expectedRevision: device.revision)), revision: community.accountRevision)
        guard try JSONDecoder().decode(Result.self, from: data).removed else { throw BackpackError.invalid("Native push revocation was not confirmed.") }
        let key = try cacheKey(community)
        try cache.remove(key); try cache.remove(key + "|pending"); self.device = nil; registrationUncertain = false
    }
    func resolve(_ activity: UUID) {
        if busy { pendingActivity = activity; return }
        run { community, revision in
            self.destination = nil
            struct Result: Decodable { let destination: NativePushDestination }
            let result = try JSONDecoder().decode(Result.self, from: await community.applePushRequest(
                "notifications/apple-activity/\(activity.uuidString.lowercased())", revision: revision)).destination
            guard ["inbox", "invitations", "friendRequests", "friends", "avatar", "direct", "room", "event"].contains(result.kind),
                  result.kind != "direct" || result.peerId != nil,
                  result.kind != "room" || result.roomId != nil,
                  result.kind != "event" || result.eventId != nil else { throw BackpackError.invalid("Unrecognized authorized activity destination.") }
            self.destination = result
        }
    }
    private func run(_ action: @escaping @MainActor (CommunityController, UUID) async throws -> Void) {
        guard let community, community.nativeApplePushAvailable, !busy else {
            failure = "Apple push requires actual configured provider, current account and supported official App Attest. No registration fallback."; return
        }
        let revision = community.accountRevision, stamp = epoch
        busy = true; failure = nil
        task = Task {
            do {
                try await action(community, revision)
                guard stamp == epoch, community.accountRevision == revision else { return }
                busy = false
                if let next = pendingActivity { pendingActivity = nil; resolve(next) }
            } catch {
                guard stamp == epoch, !Task.isCancelled else { return }
                busy = false; failure = error.localizedDescription
                destination = nil
                if let next = pendingActivity { pendingActivity = nil; resolve(next) }
            }
        }
    }
}
@MainActor
struct NativeApplePushView: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var apple: NativeApplePushCoordinator
    @ObservedObject private var events = NativeApplePushEvents.shared
    @Environment(\.scenePhase) private var phase
    @State private var confirming = false
    @State private var removing = false
    @State private var capturedRevision = 0
    @State private var capturedRemoval: NativeAppleDevice?
    var body: some View {
        Form {
            if community.nativeApplePushAvailable {
                Text("Server availability is not OS permission, token registration or delivery proof. This screen uses actual App Attest challenges/assertions for every device/activity request.").font(.caption)
                LabeledContent("OS permission", value: apple.permission)
                LabeledContent("Current registration", value: apple.device?.hasToken == true ? "Token registered" : "Not registered")
                Button("Request OS permission / refresh token") { apple.requestPermissionAndToken() }
                Button("Refresh verified current registration") { apple.refresh() }
                Button("Review registration update") { capturedRevision = apple.device?.revision ?? 0; confirming = true }
                Button("Remove native alerts", role: .destructive) { capturedRemoval = apple.device; removing = true }.disabled(apple.device == nil)
            } else {
                Text("Apple push is unavailable. Production/provider/proof configuration and a supported physical App Attest device are required; simulator or a native-looking header cannot register.")
            }
            if apple.busy { ProgressView() }
            if let failure = apple.failure ?? events.failure { Text(failure).foregroundStyle(.orange) }
            InteractionExplanation("Provider acceptance is not on-device delivery. OS/Focus settings still apply; this screen provisions no credentials.",
                details: "Provider acceptance is not proof of on-device delivery. Focus/OS settings still apply. No keys, models, credentials, developer profiles or entitlements are provisioned by this screen.").font(.caption)
        }.disabled(apple.busy).modernScene().navigationTitle("Apple device alerts")
        .task { if community.nativeApplePushAvailable { apple.refresh() } }
        .onChange(of: phase) { _, phase in if phase == .active && community.nativeApplePushAvailable { apple.refresh() } }
        .confirmationDialog("Register this actual device/token state?", isPresented: $confirming) {
            Button("Register displayed revision") { apple.registerCurrentToken(expectedRevision: capturedRevision) }
        } message: { Text("Scope is the verified attestation key/current account, not a caller-supplied device ID. A conflict requires refresh; no auto rebase.") }
        .confirmationDialog("Revoke native push registration?", isPresented: $removing) {
            Button("Revoke", role: .destructive) {
                Task { do { try await apple.removeCurrent(expected: capturedRemoval) } catch { apple.report(error) } }
            }
        }
    }
}

@MainActor
struct NativePushDestinationView: View {
    let destination: NativePushDestination
    var body: some View {
        Group {
            switch destination.kind {
            case "direct":
                if let peer = destination.peerId { CommunityConversationView(context: .direct(peer: peer, event: destination.eventId), title: "Authorized message activity") }
            case "room":
                if let room = destination.roomId { CommunityConversationView(context: .room(room), title: "Authorized room activity") }
            case "event":
                if let event = destination.eventId { CommunityEventDetailView(id: event) }
            case "avatar": CommunityAvatarView()
            case "friendRequests", "friends", "invitations": CommunitySocialView()
            default: CommunityActivityView()
            }
        }
    }
}
