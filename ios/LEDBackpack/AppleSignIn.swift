import SwiftUI
import AuthenticationServices
import CryptoKit
import BackpackProtocol

enum AppleAuthPurpose: String, Encodable { case login, link, delete }

struct AppleAuthChallenge: Decodable {
    let challengeId: UUID
    let rawNonce: String
    let expiresAt: String
    var hashedNonce: String { SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func validExpiry(_ text: String, now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return false }
        return expiry > now && expiry.timeIntervalSince(now) <= 600
    }
    func validate(now: Date = Date()) throws {
        guard rawNonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              Self.validExpiry(expiresAt, now: now) else {
            throw BackpackError.invalid("Apple sign-in challenge is invalid or expired. Start again.")
        }
    }
}

struct AppleAuthProof: Encodable {
    let challengeId: String
    let rawNonce: String
    let identityToken: String
    let authorizationCode: String
    let displayName: Name?
    struct Name: Encodable { let givenName: String?; let familyName: String? }

    init(challenge: AppleAuthChallenge, identityToken: Data?, authorizationCode: Data?, name: PersonNameComponents? = nil) throws {
        try challenge.validate()
        guard let identityToken, (1...32768).contains(identityToken.count),
              let token = String(data: identityToken, encoding: .utf8), !token.contains("\n"),
              let authorizationCode, (1...8192).contains(authorizationCode.count),
              let code = String(data: authorizationCode, encoding: .utf8), !code.contains("\n") else {
            throw BackpackError.invalid("Apple did not provide the required identity token and authorization code.")
        }
        challengeId = challenge.challengeId.uuidString.lowercased()
        rawNonce = challenge.rawNonce
        self.identityToken = token; self.authorizationCode = code
        displayName = name.map { Name(givenName: $0.givenName, familyName: $0.familyName) }
    }
}

struct AppleAuthAttempt {
    let challenge: AppleAuthChallenge
    let purpose: AppleAuthPurpose
    let server: CommunityOrigin
    let accountRevision: UUID
    let state: String
}

@MainActor
extension CommunityController {
    func beginAppleAuth(_ purpose: AppleAuthPurpose) async throws -> AppleAuthAttempt {
        try await loadConfig()
        guard config?.appleSignInEnabled == true else {
            throw BackpackError.invalid("Sign in with Apple is not enabled on this catalog server.")
        }
        guard purpose != .login || config?.allowsNativeSignup == true else {
            throw BackpackError.invalid("Apple account creation/sign-in requires an explicitly compatible account-deletion policy.")
        }
        guard purpose == .login || signedIn else { throw BackpackError.invalid("Sign in before linking Apple or deleting an account.") }
        guard let server = origin else { throw BackpackError.invalid("Configure the catalog first.") }
        let revision = accountRevision
        struct Body: Encodable { let purpose: AppleAuthPurpose }
        let data = try await request("auth/apple/challenges", method: "POST",
            body: JSONEncoder().encode(Body(purpose: purpose)), authenticated: purpose != .login).data
        let challenge = try JSONDecoder().decode(AppleAuthChallenge.self, from: data)
        try challenge.validate()
        guard accountRevision == revision, origin == server else { throw BackpackError.invalid("The catalog account changed. Start Apple sign-in again.") }
        return AppleAuthAttempt(challenge: challenge, purpose: purpose, server: server,
            accountRevision: revision, state: UUID().uuidString)
    }

    func finishAppleAuth(_ attempt: AppleAuthAttempt, proof: AppleAuthProof, password: String?, confirmation: String?,
        appleUser: String? = nil) async throws {
        guard origin == attempt.server, accountRevision == attempt.accountRevision,
              proof.challengeId == attempt.challenge.challengeId.uuidString.lowercased(),
              proof.rawNonce == attempt.challenge.rawNonce else {
            throw BackpackError.invalid("The Apple authorization belongs to a different attempt or account.")
        }
        try attempt.challenge.validate()
        switch attempt.purpose {
        case .login:
            let result = try JSONDecoder().decode(CommunityLogin.self, from: await request("auth/apple/login",
                method: "POST", body: JSONEncoder().encode(proof), authenticated: false).data)
            guard origin == attempt.server, accountRevision == attempt.accountRevision else {
                throw BackpackError.invalid("The catalog account changed before Apple login completed.")
            }
            try establishSession(result, appleUser: appleUser)
        case .link:
            guard let password, !password.isEmpty else { throw BackpackError.invalid("Enter your existing account password to link Apple.") }
            struct Body: Encodable {
                let challengeId: String; let rawNonce: String; let identityToken: String
                let authorizationCode: String; let displayName: AppleAuthProof.Name?; let password: String
            }
            struct Result: Decodable { let user: CommunityUser }
            let body = Body(challengeId: proof.challengeId, rawNonce: proof.rawNonce, identityToken: proof.identityToken,
                authorizationCode: proof.authorizationCode, displayName: proof.displayName, password: password)
            let result = try JSONDecoder().decode(Result.self, from: await request("auth/apple/link",
                method: "POST", body: JSONEncoder().encode(body)).data)
            updateAppleLinkedUser(result.user)
        case .delete:
            guard confirmation == "DELETE" else { throw BackpackError.invalid("Confirm account deletion before reauthenticating with Apple.") }
            struct Result: Decodable { let deletionToken: String; let expiresAt: String }
            let result = try JSONDecoder().decode(Result.self, from: await request("auth/apple/deletion-proof",
                method: "POST", body: JSONEncoder().encode(proof)).data)
            guard !result.deletionToken.isEmpty, result.deletionToken.utf8.count <= 4096,
                  AppleAuthChallenge.validExpiry(result.expiresAt) else {
                throw BackpackError.invalid("Invalid Apple deletion proof returned by the catalog.")
            }
            try await deleteAccount(appleDeletionToken: result.deletionToken, confirmation: "DELETE")
        }
    }

    func checkAppleCredentialState() async throws {
        guard let appleUser = appleUserForCredentialCheck else { return }
        let revision = accountRevision
        let state: ASAuthorizationAppleIDProvider.CredentialState = try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUser) { state, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state) }
            }
        }
        guard accountRevision == revision else { return }
        switch state {
        case .authorized: return
        case .revoked, .notFound, .transferred:
            try await signOut()
            throw BackpackError.invalid("Apple account access changed. You have been signed out of the catalog; sign in again to continue.")
        @unknown default:
            throw BackpackError.invalid("Apple returned an unknown credential state. Try verifying your account again.")
        }
    }
}

@MainActor
private struct AppleSystemButton: UIViewRepresentable {
    let action: @MainActor () -> Void
    let enabled: Bool
    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func pressed() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .white)
        button.cornerRadius = 12
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action; button.isEnabled = enabled
    }
}

@MainActor
private final class AppleWindowHolder {
    weak var window: UIWindow?
}

@MainActor
private struct AppleWindowReader: UIViewRepresentable {
    let holder: AppleWindowHolder
    final class AnchorView: UIView {
        var holder: AppleWindowHolder?
        override func didMoveToWindow() { super.didMoveToWindow(); holder?.window = window }
    }
    func makeUIView(context: Context) -> AnchorView { let view = AnchorView(); view.holder = holder; return view }
    func updateUIView(_ view: AnchorView, context: Context) { holder.window = view.window }
}

@MainActor
private final class AppleAuthorizationOperation: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let window: UIWindow
    let attempt: AppleAuthAttempt
    let finish: @MainActor (Result<ASAuthorizationAppleIDCredential, Error>) -> Void
    private var controller: ASAuthorizationController?
    init(window: UIWindow, attempt: AppleAuthAttempt, finish: @escaping @MainActor (Result<ASAuthorizationAppleIDCredential, Error>) -> Void) {
        self.window = window; self.attempt = attempt; self.finish = finish
    }
    func start() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = attempt.purpose == .delete ? [] : [.fullName, .email]
        request.nonce = attempt.challenge.hashedNonce
        request.state = attempt.state
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self; controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == attempt.state else {
            finish(.failure(BackpackError.invalid("Apple authorization state did not match this sign-in."))); return
        }
        finish(.success(credential))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { finish(.failure(error)) }
}

@MainActor
struct AppleSignInControl: View {
    @EnvironmentObject private var community: CommunityController
    let purpose: AppleAuthPurpose
    var password: String? = nil
    var confirmation: String? = nil
    var enabled = true
    let busyChanged: (Bool) -> Void
    let completed: () -> Void
    @State private var holder = AppleWindowHolder()
    @State private var operation: AppleAuthorizationOperation?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppleSystemButton(action: start, enabled: enabled && !busy).frame(maxWidth: .infinity).frame(height: 48)
            if busy { ProgressView("Authorizing with Apple...") }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
        .background(AppleWindowReader(holder: holder).frame(width: 0, height: 0))
    }
    private func start() {
        guard !busy, enabled else { return }
        let password = password, confirmation = confirmation
        busy = true; failure = nil; busyChanged(true)
        Task {
            do {
                let attempt = try await community.beginAppleAuth(purpose)
                guard let window = holder.window, window.windowScene?.activationState == .foregroundActive else {
                    throw BackpackError.invalid("Return to the active app window to sign in with Apple.")
                }
                let auth = AppleAuthorizationOperation(window: window, attempt: attempt) { result in
                    Task { await finish(result, attempt: attempt, password: password, confirmation: confirmation) }
                }
                operation = auth
                auth.start()
            } catch {
                failure = error.localizedDescription; busy = false; busyChanged(false)
            }
        }
    }
    private func finish(_ result: Result<ASAuthorizationAppleIDCredential, Error>, attempt: AppleAuthAttempt,
        password: String?, confirmation: String?) async {
        defer { busy = false; busyChanged(false); operation = nil }
        do {
            let credential = try result.get()
            let proof = try AppleAuthProof(challenge: attempt.challenge, identityToken: credential.identityToken,
                authorizationCode: credential.authorizationCode, name: credential.fullName)
            try await community.finishAppleAuth(attempt, proof: proof, password: password, confirmation: confirmation,
                appleUser: credential.user)
            failure = nil; completed()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            failure = "Apple authorization cancelled. Nothing was changed."
        } catch {
            failure = error.localizedDescription
        }
    }
}
