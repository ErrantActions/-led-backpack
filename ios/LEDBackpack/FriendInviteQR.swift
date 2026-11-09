import SwiftUI
import CoreImage.CIFilterBuiltins
import BackpackProtocol

enum FriendInviteLink {
    static func token(_ input: String, origin: CommunityOrigin) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if NearbyTokenPolicy.valid(value) { return value }
        guard value.utf8.count <= 2400, value.utf8.allSatisfy({ (33...126).contains($0) }),
              !value.contains("\\"), let url = URL(string: value),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              origin.contains(url), parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.percentEncodedPath == "/social",
              let fragment = parts.percentEncodedFragment, fragment.hasPrefix("invite=") else {
            throw BackpackError.invalid("Use this configured catalog's exact /social#invite=TOKEN link or a canonical invite token.")
        }
        let token = String(fragment.dropFirst(7))
        guard NearbyTokenPolicy.valid(token), parts.fragment == "invite=" + token else {
            throw BackpackError.invalid("Invite fragment must contain only one canonical opaque token, without encoded/path/query aliases.")
        }
        return token
    }
    static func link(token: String, origin: CommunityOrigin) throws -> URL {
        guard NearbyTokenPolicy.valid(token),
              var parts = URLComponents(url: origin.url, resolvingAgainstBaseURL: false) else { throw BackpackError.invalid("Cannot encode this friend invitation.") }
        parts.path = "/social"; parts.query = nil; parts.fragment = "invite=" + token
        guard let url = parts.url else { throw BackpackError.invalid("Invalid configured friend invitation URL.") }
        return url
    }
}
struct NativeFriendInvitePreview: Decodable {
    struct Person: Decodable { let id: UUID; let displayName: String }
    let profile: Person
    let expiresAt, serverTime: Double
    let canRedeem: Bool
    func validate(account: UUID) throws {
        guard canRedeem, profile.id != account, !profile.displayName.isEmpty,
              profile.displayName.utf16.count <= 80, expiresAt.isFinite, serverTime.isFinite,
              expiresAt > serverTime, expiresAt - serverTime <= 900_000 else {
            throw BackpackError.invalid("Own, expired, revoked or unavailable invitation. No profile/media grant was obtained.")
        }
    }
}
struct FriendInvitePreviewState {
    private(set) var token: String?
    private(set) var inviter: UUID?
    private(set) var accountEpoch: UUID?
    mutating func clear() { token = nil; inviter = nil; accountEpoch = nil }
    mutating func capture(token: String, preview: NativeFriendInvitePreview, account: UUID, epoch: UUID) throws {
        try preview.validate(account: account)
        guard NearbyTokenPolicy.valid(token) else { throw BackpackError.invalid("Invalid invitation token.") }
        self.token = token; inviter = preview.profile.id; accountEpoch = epoch
    }
}
struct NativeOwnedFriendInvite: Decodable {
    let invite: SocialInvite
    let serverTime: Double
}
@MainActor
extension CommunityFeatureClient {
    func createFriendQRInvite() async throws -> NativeOwnedFriendInvite {
        struct Empty: Encodable {}
        let value = try JSONDecoder().decode(NativeOwnedFriendInvite.self, from: await send(.social, "social/invites",
            method: "POST", body: JSONEncoder().encode(Empty())))
        guard NearbyTokenPolicy.valid(value.invite.token), value.serverTime.isFinite,
              value.invite.expiresAt.isFinite, value.invite.expiresAt > value.serverTime,
              value.invite.expiresAt - value.serverTime <= 900_000 else { throw BackpackError.invalid("Invalid server invitation lifetime/token. Nothing can be shared.") }
        return value
    }
    func previewFriendInvite(_ token: String) async throws -> NativeFriendInvitePreview {
        guard NearbyTokenPolicy.valid(token) else { throw BackpackError.invalid("Invalid friend invite token.") }
        struct Body: Encodable { let token: String }
        let value = try JSONDecoder().decode(NativeFriendInvitePreview.self, from: await send(.social,
            "social/invites/preview", method: "POST", body: JSONEncoder().encode(Body(token: token))))
        try value.validate(account: accountID); return value
    }
    func requestFromPreview(token: String, inviter: UUID) async throws {
        let current = try await previewFriendInvite(token)
        guard current.profile.id == inviter else { throw BackpackError.invalid("Captured inviter changed. Preview again; no automatic request.") }
        struct Body: Encodable { let token: String }
        struct Result: Decodable { let request: SocialFriendRequest }
        let value = try JSONDecoder().decode(Result.self, from: await send(.social,
            "social/invites/redeem", method: "POST", body: JSONEncoder().encode(Body(token: token)))).request
        guard Set([value.senderId, value.recipientId]) == Set([accountID, inviter]),
              ["pending","accepted"].contains(value.status) else { throw BackpackError.invalid("The explicit invite request was not bound to the displayed accounts.") }
    }
}

@MainActor
struct FriendInviteQRView: View {
    enum EntryMode: String, Identifiable { case all, myCode, scan; var id: String { rawValue } }
    let entryMode: EntryMode
    init(entryMode: EntryMode = .all) { self.entryMode = entryMode }
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    @State private var own: NativeOwnedFriendInvite?
    @State private var ownClock: CatalogEventClock?
    @State private var qr: UIImage?
    @State private var shareURL: URL?
    @State private var input = ""
    @State private var preview: NativeFriendInvitePreview?
    @State private var previewClock: CatalogEventClock?
    @State private var capture = FriendInvitePreviewState()
    @State private var scanning = false
    @State private var confirming = false
    @State private var notice: String?
    @State private var qrTask: Task<Void, Never>?
    @State private var openedScanner = false
    @State private var showOwnCode = false
    var body: some View {
        Form {
            Text("Scan to preview a friend. Sending a request is a separate choice.").font(.caption)
            if let error = session.failure { Text(error).foregroundStyle(.orange) }
            if let notice { Text(notice).font(.caption) }
            if session.busy { ProgressView() }
            if community.config?.socialEnabled == true && community.signedIn {
                if entryMode != .scan {
                DisclosureGroup("My QR Code", isExpanded: $showOwnCode) {
                    Button("Create a new 15-minute invitation") { create() }.disabled(session.busy)
                    if let own, let ownClock {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if ownClock.now() < own.invite.expires {
                                if let qr { Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 250).accessibilityLabel("Your expiring friend invitation QR") }
                                if let shareURL { ShareLink("Share this fragment-only invite link", item: shareURL) }
                                Text("Server deadline: \(own.invite.expires.formatted())").font(.caption)
                            } else { Text("Invitation expired; no code/link is shown. Create another explicitly.") }
                        }
                        Button("Revoke displayed invitation", role: .destructive) {
                            qrTask?.cancel(); qr = nil; shareURL = nil
                            let id = own.invite.id
                            session.run({ try await $0.revokeInvite(id) }, success: { self.own = nil; notice = "Displayed invitation revoked." })
                        }.disabled(session.busy)
                    }
                    Text("Codes expire after15 minutes. New codes do not revoke older ones.").font(.caption)
                }
                }
                if entryMode != .myCode {
                Section("Scan or enter an invitation") {
                    Button("Scan friend QR with camera (explicit)") { scanning = true; clearPreview() }.disabled(session.busy)
                    DisclosureGroup("Paste an invitation") {
                    TextField("Configured catalog link or invite token", text: Binding(get: { input }, set: {
                        input = $0; clearPreview(); session.bind(community)
                    })).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Button("Preview minimal inviter (do not request yet)") { consume(input) }.disabled(session.busy || input.isEmpty)
                    }
                    if let preview, let previewClock {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if previewClock.now() < Date(timeIntervalSince1970: preview.expiresAt / 1000) {
                                Text(preview.profile.displayName).font(.headline)
                                Text("Authenticated minimal inviter preview only; no avatar/profile lookup or new grant.").font(.caption)
                                Button("Review explicit friend request") { confirming = true }.disabled(session.busy)
                            } else { Text("Preview expired. Enter/scan and preview a fresh invitation explicitly.") }
                        }
                    }
                    Button("Cancel / clear received invitation") { clearPreview(); input = ""; session.bind(community) }
                    Text("Camera unavailable? Paste the link instead.").font(.caption)
                }
                }
            } else { Text("Sign in to this configured catalog and enable the actual social capability to manage/preview friend invitations.") }
        }.modernScene().navigationTitle(entryMode == .myCode ? "My QR Code" : entryMode == .scan ? "Scan QR Code" : "Friend invitation").buttonStyle(.borderless)
        .toolbar { if entryMode != .all { Button("Done") { dismiss() } } }
        .task(id: community.accountRevision) {
            session.bind(community); showOwnCode = entryMode == .myCode
            if entryMode == .scan, !openedScanner, community.signedIn, community.config?.socialEnabled == true {
                openedScanner = true; scanning = true
            }
        }
        .onChange(of: community.accountRevision) { _, _ in clearAll(); session.clear(); dismiss() }
        .onChange(of: phase) { _, value in
            if value != .active { scanning = false; clearPreview(); input = ""; qrTask?.cancel(); qr = nil; shareURL = nil; session.clear() }
            else { session.bind(community) }
        }
        .onDisappear { scanning = false; qrTask?.cancel(); session.clear(); clearPreview(); input = ""; qr = nil; shareURL = nil }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                FriendInviteCamera { result in
                    scanning = false
                    switch result {
                    case .success(let value): consume(value)
                    case .failure(let error):
                        if session.client == nil || session.denied { session.bind(community) }
                        session.run { _ in throw error }
                    }
                }.navigationTitle("Scan friend invitation")
                    .toolbar { Button("Cancel") { scanning = false } }
            }
        }
        .confirmationDialog("Send only a friend request to this inviter?", isPresented: $confirming) {
            if let token = capture.token, let inviter = capture.inviter, capture.accountEpoch == community.accountRevision {
                Button("Send deliberate request") {
                    session.run({ client in try await client.requestFromPreview(token: token, inviter: inviter) },
                        success: { clearPreview(); notice = "Explicit request processed. Recipient acceptance/existing relationship is independent; no new location/game/library grant." })
                }
            }
        } message: { Text("The authenticated preview is checked again for the exact inviter/expiry/revocation. No automatic redeem, acceptance, discovery or game activation.") }
    }
    private func consume(_ raw: String) {
        clearPreview(); input = "" // The consumed fragment never becomes native navigation/history.
        if session.client == nil || session.denied { session.bind(community) }
        session.run { client in
            let token = try FriendInviteLink.token(raw, origin: client.origin)
            let result = try await client.previewFriendInvite(token)
            try session.checked(client)
            try capture.capture(token: token, preview: result, account: client.accountID, epoch: community.accountRevision)
            preview = result; previewClock = try CatalogEventClock(serverTime: CatalogEventTime.wire(Date(timeIntervalSince1970: result.serverTime / 1000)))
        }
    }
    private func create() {
        qrTask?.cancel()
        if session.client == nil || session.denied { session.bind(community) }
        session.run { client in
            let value = try await client.createFriendQRInvite()
            try session.checked(client)
            own = value; qr = nil; shareURL = nil
            ownClock = try CatalogEventClock(serverTime: CatalogEventTime.wire(Date(timeIntervalSince1970: value.serverTime / 1000)))
            let link = try FriendInviteLink.link(token: value.invite.token, origin: client.origin)
            let id = value.invite.id, epoch = community.accountRevision
            qrTask = Task {
                do {
                    let worker = Task.detached {
                        let filter = CIFilter.qrCodeGenerator()
                        filter.message = Data(link.absoluteString.utf8); filter.correctionLevel = "M"
                        guard let image = filter.outputImage,
                              let cg = CIContext().createCGImage(image.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: image.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else {
                            throw BackpackError.invalid("Local QR rendering unavailable. Use the same invite link instead.")
                        }
                        return UIImage(cgImage: cg)
                    }
                    let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard epoch == community.accountRevision, own?.invite.id == id, phase == .active else { return }
                    qr = image; shareURL = link
                } catch {
                    if !Task.isCancelled && epoch == community.accountRevision && own?.invite.id == id && phase == .active {
                        notice = error.localizedDescription; shareURL = link
                    }
                }
            }
        }
    }
    private func clearPreview() { preview = nil; previewClock = nil; capture.clear(); confirming = false }
    private func clearAll() { clearPreview(); input = ""; own = nil; qr = nil; shareURL = nil; qrTask?.cancel(); scanning = false }
}
