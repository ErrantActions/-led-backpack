import SwiftUI
import BackpackProtocol

struct NativeIntegrityOwnedKey: Decodable, Identifiable {
    let keyId, createdAt: String
    var id: String { keyId }
    func validate() throws {
        guard NativeIntegrityBinding.canonicalKey(keyId) else { throw BackpackError.invalid("Noncanonical owned App Attest key.") }
        _ = try CatalogEventTime.parse(createdAt)
    }
}
enum NativeIntegrityKeyRoute {
    static func url(origin: CommunityOrigin, key: String?) throws -> URL {
        guard let key else { return try origin.api("app-integrity/keys") }
        guard NativeIntegrityBinding.canonicalKey(key), var parts = URLComponents(url: origin.url, resolvingAgainstBaseURL: false) else {
            throw BackpackError.invalid("Invalid App Attest key recovery target.")
        }
        let encoded = key.replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "=", with: "%3D")
        parts.percentEncodedPath = "/api/v1/app-integrity/keys/" + encoded
        guard let url = parts.url else { throw BackpackError.invalid("Could not encode owned key recovery path.") }
        return url
    }
}
@MainActor
struct NativeIntegrityRecoveryView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [NativeIntegrityOwnedKey] = []
    @State private var selected: NativeIntegrityOwnedKey?
    @State private var approval = ScopedActionConfirmation<String>()
    @State private var busy = false
    @State private var failure: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        Form {
            InteractionExplanation("Recent primary sign-in is required. Recovery does not grant private content access or establish app identity.", details: "Fresh primary account authentication within ten minutes is required by the server. Recovery does not establish app identity or grant private content access. It works without a device proof so a lost key cannot permanently block recovery.").font(.caption)
            if community.integrityControlsAvailable {
                Button("Refresh my owned App Attest keys") { load() }.disabled(busy || selected != nil)
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key …\(key.keyId.suffix(10))").font(.headline)
                        Text(key.createdAt).font(.caption)
                        Button("Review revoking this key", role: .destructive) { selected = key; approval.reset() }
                    }.disabled(busy)
                }
                if let selected {
                    Text("Captured key …\(selected.keyId.suffix(10))")
                    Toggle("Revoke this reviewed app key", isOn: Binding(
                        get: { approval.isConfirmed(for: approvalScope) },
                        set: { approval.setConfirmed($0, for: approvalScope) }))
                    Button("Revoke captured owned key", role: .destructive) { revoke(selected) }.disabled(!approval.isConfirmed(for: approvalScope) || busy)
                    Button("Cancel") { self.selected = nil; approval.reset() }.disabled(busy)
                    InteractionExplanation("Revokes this key and pending challenges. New use needs a new key ceremony; no access to another account’s keys.", details: "Revocation invalidates this public-key binding and its pending challenges. New use requires a new ceremony/key, never attestation replay. Other accounts' keys are not accessible, including to admins.").font(.caption)
                }
            } else { Text("The actual source integrity gate is unavailable/OFF; this view cannot enable it.") }
            if busy { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }.modernScene().navigationTitle("App key recovery")
        .task { if community.integrityControlsAvailable { load() } }
        .onChange(of: community.accountRevision) { _, _ in operation?.cancel(); keys = []; selected = nil; dismiss() }
        .onChange(of: approvalScope) { _, _ in approval.reset() }
        .onDisappear { operation?.cancel(); approval.reset() }
    }
    private var approvalScope: String {
        "\(community.accountRevision):\(community.integrityControlsAvailable):\(selected?.keyId ?? "")"
    }
    private func load() {
        guard !busy else { return }
        busy = true; failure = nil; let scope = community.accountRevision
        operation = Task {
            do { let value = try await community.integrityKeys(); try Task.checkCancellation(); guard scope == community.accountRevision else { return }; keys = value }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
            if scope == community.accountRevision { busy = false }
        }
    }
    private func revoke(_ key: NativeIntegrityOwnedKey) {
        guard !busy, community.integrityControlsAvailable, selected?.keyId == key.keyId,
              approval.consume(for: approvalScope) else { failure = "Key or approval changed. Review revocation again."; return }
        busy = true; failure = nil; let scope = community.accountRevision
        operation = Task {
            do {
                try await community.revokeIntegrityKey(key); try Task.checkCancellation()
                guard scope == community.accountRevision else { return }
                keys.removeAll { $0.keyId == key.keyId }; selected = nil; approval.reset()
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            if scope == community.accountRevision { busy = false }
        }
    }
}
