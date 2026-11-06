import SwiftUI
import AuthenticationServices
import CryptoKit
import BackpackProtocol

@MainActor
final class CloudVaultWindow: ObservableObject { weak var window: UIWindow? }

@MainActor
struct CloudVaultWindowReader: UIViewRepresentable {
    let holder: CloudVaultWindow
    final class Anchor: UIView {
        weak var holder: CloudVaultWindow?
        override func didMoveToWindow() { super.didMoveToWindow(); holder?.window = window }
    }
    func makeUIView(context: Context) -> Anchor { let view = Anchor(); view.holder = holder; return view }
    func updateUIView(_ view: Anchor, context: Context) { holder.window = view.window }
}

@available(iOS 18.0, *)
@MainActor
final class CloudVaultPasskeyOperation: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private enum Result { case registered(Data), asserted(Data, SymmetricKey) }
    private var continuation: CheckedContinuation<Result, Error>?
    private var controller: ASAuthorizationController?
    private var window: UIWindow?
    private var expectedChallenge = Data()
    private var expectedCredential: Data?
    private var relyingParty = ""

    func register(rp: String, account: String, name: String, challenge: Data, window: UIWindow) async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: name, userID: Data(account.utf8))
        request.userVerificationPreference = .required
        request.prf = .checkForSupport
        let response = try await perform(request, rp: rp, challenge: challenge, credential: nil, window: window)
        guard case .registered(let id) = response else { throw BackpackError.invalid("Unexpected passkey registration result.") }
        return id
    }
    func evaluate(rp: String, credential: Data, input: Data, challenge: Data, window: UIWindow) async throws -> SymmetricKey {
        guard (1...1024).contains(credential.count), input.count == 32 else { throw BackpackError.invalid("Invalid passkey PRF input.") }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = [ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credential)]
        request.prf = .inputValues(.init(saltInput1: input, saltInput2: nil))
        let response = try await perform(request, rp: rp, challenge: challenge, credential: credential, window: window)
        guard case .asserted(let returned, let output) = response, returned == credential, output.bitCount == 256 else {
            throw BackpackError.invalid("This provider/credential did not return supported PRF output.")
        }
        return output
    }
    private func perform(_ request: ASAuthorizationRequest, rp: String, challenge: Data, credential: Data?, window: UIWindow) async throws -> Result {
        guard continuation == nil, challenge.count == 32, window.windowScene?.activationState == .foregroundActive else {
            throw BackpackError.invalid("Return to the active app window and finish any current passkey request.")
        }
        expectedChallenge = challenge; expectedCredential = credential; relyingParty = rp; self.window = window
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                let operation = ASAuthorizationController(authorizationRequests: [request])
                operation.delegate = self; operation.presentationContextProvider = self; controller = operation
                operation.performRequests()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.controller?.cancel(); self?.finish(.failure(CancellationError())) } }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let window else { preconditionFailure("Passkey presentation requires its captured window.") }
        return window
    }
    private func clientData(_ bytes: Data, type: String) throws {
        struct ClientData: Decodable { let type: String; let challenge: String; let origin: String; let crossOrigin: Bool? }
        guard bytes.count <= 16_384 else { throw BackpackError.invalid("Passkey client data exceeds its budget.") }
        let data = try JSONDecoder().decode(ClientData.self, from: bytes)
        guard data.type == type, data.challenge == CloudVaultWire.base64(expectedChallenge), data.crossOrigin != true,
              let origin = URLComponents(string: data.origin), origin.scheme == "https", origin.host == relyingParty,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.port == nil || origin.port == 443, origin.path.isEmpty || origin.path == "/" else {
            throw BackpackError.invalid("Passkey assertion does not match the local challenge/relying party.")
        }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard self.controller === controller else { return }
        do {
            if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration, expectedCredential == nil {
                try clientData(credential.rawClientDataJSON, type: "webauthn.create")
                guard credential.prf?.isSupported == true, (1...1024).contains(credential.credentialID.count) else {
                    throw BackpackError.invalid("This credential provider does not support vault PRF. Keep using the separate recovery password.")
                }
                finish(.success(.registered(credential.credentialID)))
            } else if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
                      credential.credentialID == expectedCredential, let output = credential.prf?.first {
                try clientData(credential.rawClientDataJSON, type: "webauthn.get")
                guard output.bitCount == 256 else { throw BackpackError.invalid("Unsupported passkey PRF output length.") }
                finish(.success(.asserted(credential.credentialID, output)))
            } else { throw BackpackError.invalid("Passkey provider returned an unsupported credential or no PRF output.") }
        } catch { finish(.failure(error)) }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard self.controller === controller else { return }
        finish(.failure(error))
    }
    private func finish(_ result: Swift.Result<Result, Error>) {
        let pending = continuation; continuation = nil; controller = nil; window = nil; expectedChallenge = Data()
        pending?.resume(with: result)
    }
}
