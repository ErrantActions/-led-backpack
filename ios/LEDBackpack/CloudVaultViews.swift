import SwiftUI
import BackpackProtocol

@MainActor
struct CloudVaultSettingsView: View {
    @EnvironmentObject private var vault: CloudVaultStore
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var library: LocalLibrary
    @State private var enable = false
    @State private var deleting = false
    @State private var confirmation = ""
    @State private var failure: String?
    @StateObject private var anchor = CloudVaultWindow()

    var body: some View {
        Form {
            if !community.signedIn {
                NavigationLink("Sign in for private cloud") { CommunityAccountView() }
                Text("Public browsing, local GIFs and Bluetooth never require cloud.")
            } else if !vault.available {
                ContentUnavailableView("Private cloud unavailable", systemImage: "icloud.slash",
                    description: Text("This server has not enabled encrypted cloud protocol 1. No vault upload or enrollment is available."))
                Button("Reload server capabilities") { Task { await vault.bind(community) } }
            } else {
                Section("This device") {
                    Toggle("Private cloud synchronization", isOn: Binding(get: { vault.syncing }, set: { value in
                        if value { enable = true }
                        else {
                            do { try vault.pause() }
                            catch { failure = error.localizedDescription }
                        }
                    })).disabled(vault.busy && !vault.syncing)
                    Text("Pausing keeps your phone and cloud copies.")
                        .font(.caption)
                    if vault.pin.remoteReset { Label("Cloud changed or was disabled remotely. Sync stays off until you explicitly enable it.", systemImage: "pause.circle").font(.caption) }
                    Text("Changes sync automatically while the app is open.")
                        .font(.caption)
                    if vault.failure != nil { Button("Retry sync") { vault.requestSynchronization(library) }
                        .disabled(!vault.syncing || vault.locked || vault.busy || vault.state?.migrationId != nil)
                    }
                }
                if let state = vault.state {
                    Text(state.mode == .managed ? "Server-managed encryption: the server can decrypt." : "User-held encryption")
                        .font(.caption)
                    if state.mode == .userHeld && vault.locked {
                        NavigationLink("Unlock library") { CloudVaultPasswordView(mode: .unlock) }
                    }
                    DisclosureGroup("Encryption & recovery") {
                        Text(state.enabled ? (state.mode == .userHeld ? "User-held encrypted library" : "Server-managed encrypted storage") : "Cloud is disabled")
                            .font(.headline)
                        Text(state.mode == .managed
                            ? "The authenticated server can decrypt server-managed storage. User-held encryption is a separate, optional enrollment."
                            : "The library/recovery password and enrolled PRF passkeys are alternative unlock methods. They are separate from account sign-in.")
                            .font(.caption)
                        if state.legacyMigrationPending || state.legacyItemCount > 0 {
                            Text("Legacy private GIFs remaining: \(state.legacyItemCount). Old data is not labeled encrypted until migration completes.").font(.caption)
                            if let error = state.legacyMigrationError { Text(error).foregroundStyle(.orange) }
                            Button("Request legacy private migration") { vault.run { try await vault.requestLegacyMigration() } }
                                .disabled(!vault.syncing || vault.busy)
                        }
                        if vault.canEnroll && state.mode == .managed {
                            NavigationLink("Enroll user-held encryption") { CloudVaultPasswordView(mode: .enroll) }
                        }
                        if state.mode == .userHeld && !vault.locked && vault.canEnroll {
                            NavigationLink("Change recovery password") { CloudVaultPasswordView(mode: .replace) }
                            NavigationLink("Rotate library key") { CloudVaultPasswordView(mode: .enroll) }
                        }
                        if state.migrationId != nil || vault.migration != nil {
                            NavigationLink("Resume verified migration") { CloudVaultPasswordView(mode: .resume) }
                            Button("Cancel pending migration", role: .destructive) { vault.run { try await vault.cancelMigration() } }
                            Text("Cancellation retains the active library; staged copies are cleaned up by the server.").font(.caption)
                        }
                    }
                    if state.mode == .userHeld {
                        DisclosureGroup("Passkeys") {
                            if #available(iOS 18.0, *), vault.passkeyRP != nil {
                                ForEach(state.passkeys, id: \.credentialId) { wrapper in
                                    if vault.locked {
                                        Button("Unlock with enrolled passkey …\(wrapper.credentialId.suffix(6))") {
                                            vault.run {
                                                guard let window = anchor.window else { throw BackpackError.invalid("An active window is required.") }
                                                try await vault.unlockPasskey(wrapper, operation: CloudVaultPasskeyOperation(), window: window)
                                                if vault.syncing { try await vault.synchronize(library) }
                                            }
                                        }
                                    } else {
                                        Button("Remove passkey …\(wrapper.credentialId.suffix(6))", role: .destructive) {
                                            vault.run { try await vault.removePasskey(wrapper.credentialId) }
                                        }
                                    }
                                }
                                if !vault.locked {
                                    Button("Enroll a supported passkey") {
                                        vault.run {
                                            guard let window = anchor.window else { throw BackpackError.invalid("An active window is required.") }
                                            try await vault.addPasskey(operation: CloudVaultPasskeyOperation(), window: window,
                                                displayName: community.user?.email ?? "Private library")
                                        }
                                    }.disabled(state.passkeys.count >= 10)
                                }
                            } else {
                                Text("Use the recovery password. Native PRF requires iOS 18+, configured app/domain association and support from the actual credential provider.")
                            }
                            Text("Passkeys unlock encryption locally, not server login. Unsupported PRF never replaces or removes the required recovery password.").font(.caption)
                        }
                    }
                    if vault.canAdopt {
                        Section("Trusted devices") {
                            if vault.locked {
                                NavigationLink("Adopt this device with a QR code") { CloudVaultAdoptionView() }
                            } else { NavigationLink("Approve another device") { CloudVaultAdoptionApprovalView() } }
                        }
                    }
                    Section("Cloud-only deletion") {
                        Button("Delete all private cloud copies", role: .destructive) { deleting = true }
                        Text("Requires sign-in within ten minutes. Community submissions, local files and your account are retained. This is not account deletion.").font(.caption)
                        NavigationLink("Sign in again for sensitive cloud operations") { CommunityAccountView() }
                    }
                }
            }
            if vault.busy { ProgressView(vault.progress.isEmpty ? "Working with private cloud…" : vault.progress) }
            if let error = failure ?? vault.failure { Text(error).foregroundStyle(.orange) }
        }
        .modernScene().navigationTitle("Private cloud").buttonStyle(.borderless)
        .background(CloudVaultWindowReader(holder: anchor).frame(width: 0, height: 0))
        .confirmationDialog("Enable private cloud on this device?", isPresented: $enable, titleVisibility: .visible) {
            Button(vault.pin.userHeld && vault.state?.enabled == false ? "Create NEW server-managed library" : "Enable private cloud") {
                vault.run {
                    try await vault.enableExplicitly(createNewManagedAfterReset: true)
                    if !vault.locked { try await vault.synchronize(library) }
                }
            }
        } message: {
            Text("Your GIFs will sync automatically and stay available offline after download. Deleted or reset cloud libraries are not restored automatically. Storage starts server-managed; user-held encryption is optional.")
        }
        .alert("Delete all private cloud copies?", isPresented: $deleting) {
            TextField("Type DELETE CLOUD", text: $confirmation)
            Button("Cancel", role: .cancel) { confirmation = "" }
            Button("Delete cloud copies", role: .destructive) {
                let value = confirmation; confirmation = ""
                vault.run { try await vault.deleteCloudOnly(confirmation: value) }
            }
        } message: { Text("Type DELETE CLOUD. Local files, public submissions and your account remain.") }
    }
}

@MainActor
struct CloudVaultPasswordView: View {
    enum Mode: Equatable { case unlock, enroll, replace, resume }
    let mode: Mode
    @EnvironmentObject private var vault: CloudVaultStore
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var storedRecovery = false
    var body: some View {
        Form {
            Section(mode == .unlock ? "Separate library/recovery password" : "Separate recovery passphrase") {
                SecureField("Library/recovery password — not account password", text: $password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if mode != .unlock && mode != .resume {
                    SecureField("Confirm recovery passphrase", text: $confirmation)
                    Text("Use at least 20 characters. Spaces are preserved; Unicode is normalized to NFC. This password is derived locally and never sent to the server.")
                        .font(.caption)
                }
                if mode == .enroll || mode == .replace {
                    Toggle("I have stored this separate recovery passphrase safely", isOn: $storedRecovery)
                }
                if mode == .enroll {
                    Text("Migration downloads and verifies every existing cloud asset, encrypts and verifies staged copies, then signs an independently computed manifest. Temporary quota headroom is required. Historical server-readable backups/logs need expiration; this does not promise retroactive secrecy or forensic erasure.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Button(mode == .unlock ? "Unlock library" : mode == .replace ? "Verify and replace recovery wrapper" : "Verify and migrate") {
                let value = password, repeated = confirmation
                password = ""; confirmation = ""
                vault.run {
                    switch mode {
                    case .unlock: try await vault.unlock(libraryPassword: value)
                    case .replace: try await vault.replaceRecovery(password: value, confirmation: repeated)
                    case .enroll, .resume: try await vault.migrate(password: value, confirmation: repeated)
                    }
                    if vault.syncing { try await vault.synchronize(library) }
                    dismiss()
                }
            }.buttonStyle(.borderedProminent)
                .disabled(vault.busy || password.isEmpty || ((mode == .enroll || mode == .replace) && !storedRecovery))
            if vault.busy { ProgressView(vault.progress.isEmpty ? "Verifying…" : vault.progress) }
            if let failure = vault.failure { Text(failure).foregroundStyle(.orange) }
        }
        .modernScene().navigationTitle(mode == .unlock ? "Unlock library" : "Library recovery")
        .onDisappear { password = ""; confirmation = "" }
    }
}

@MainActor
struct CloudVaultArtworkRow: View {
    @EnvironmentObject private var vault: CloudVaultStore
    let item: CloudVaultItem
    @State private var directSend: BackpackSendRequest?
    var body: some View {
        NavigationLink {
            CloudVaultArtworkDetail(item: item)
        } label: {
            Group {
                if !vault.locked {
                    GIFThumbnail(key: "vault:\(item.accountId):\(item.generation):\(item.id):\(item.version)", cache: false) {
                        try await vault.download(item).data
                    }
                } else { Image(systemName: "lock.icloud").frame(maxWidth: .infinity, minHeight: 120) }
            }.aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(.plain)
            .accessibilityLabel("Preview \(vault.titles[item.id] ?? "Encrypted private artwork")")
            .contextMenu {
                Button("Send & Play directly from cloud") { directSend = BackpackSendRequest(sources: [.vault(item)]) }
                    .disabled(vault.locked || vault.busy || !vault.syncing)
            }
            .sheet(item: $directSend) { request in BackpackDirectSendView(request: request) }
    }
}

@MainActor
struct CloudVaultArtworkDetail: View {
    @EnvironmentObject private var vault: CloudVaultStore
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    let item: CloudVaultItem
    @State private var bytes: Data?
    @State private var failure: String?
    @State private var deleting = false
    @State private var directSend: BackpackSendRequest?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let bytes { AnimatedPreview(data: bytes).frame(height: 280) }
                Text(vault.titles[item.id] ?? "Private artwork").font(.title2.bold())
                NavigationLink("Private cloud settings / unlock") { CloudVaultSettingsView() }
                Button("Send & Play directly from cloud") { directSend = BackpackSendRequest(sources: [.vault(item)]) }
                    .buttonStyle(.borderedProminent).disabled(vault.locked || vault.busy || !vault.syncing)
                Text("Artwork downloads automatically when sync is enabled and storage is available.").font(.caption)
                Button("Delete this private cloud copy", role: .destructive) { deleting = true }.disabled(vault.locked || vault.busy)
                if let failure = failure ?? vault.failure { Text(failure).foregroundStyle(.orange) }
            }.padding(24)
        }
        .modernScene().navigationTitle("Private artwork")
        .task {
            do {
                let copy = try await vault.download(item)
                _ = try GIFPreviewDecoder.originalFrameCount(copy.data)
                try Task.checkCancellation(); bytes = copy.data
            } catch { failure = error.localizedDescription }
        }
        .onChange(of: vault.syncing) { _, value in if !value { bytes = nil } }
        .onChange(of: vault.state?.keyId) { _, _ in bytes = nil; dismiss() }
        .onChange(of: community.accountRevision) { _, _ in bytes = nil; dismiss() }
        .onDisappear { bytes = nil }
        .sheet(item: $directSend) { request in BackpackDirectSendView(request: request) }
        .confirmationDialog("Delete only this cloud copy? Local files remain.", isPresented: $deleting) {
            Button("Delete cloud copy", role: .destructive) { vault.run { try await vault.deleteItem(item); dismiss() } }
        }
    }
}
