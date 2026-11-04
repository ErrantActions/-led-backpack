import SwiftUI

@MainActor
struct CommunitySettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var community: CommunityController
    @State private var address = ""
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Optional community catalog") {
                TextField(Preferences.defaultCommunityURL, text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save catalog URL") {
                    do {
                        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = trimmed.isEmpty ? "" : try CommunityOrigin.parse(trimmed).url.absoluteString
                        var preferences = library.state.preferences
                        preferences.communityURL = value
                        try library.savePreferences(preferences)
                        app.apply(preferences)
                        failure = nil
                    } catch { failure = error.localizedDescription }
                }
                Text("The official catalog is preconfigured. You can use another trusted HTTPS catalog or clear the address to disable the service. No API secret is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if let error = community.setupError { Text(error).font(.caption).foregroundStyle(.orange) }
            if community.origin != nil { NavigationLink("Account and deletion") { CommunityAccountView() } }
            Text("Accounts are optional. Bluetooth, local artwork, scenes and Wikimedia Commons work without this service. Passwords and sessions are not included in library backups.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .modernScene().navigationTitle("Community catalog")
        .task { address = library.state.preferences.communityURL ?? Preferences.defaultCommunityURL }
    }
}

@MainActor
struct CommunityAccountView: View {
    @EnvironmentObject private var community: CommunityController
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var creating = false
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?

    var body: some View {
        Form {
            if community.origin == nil {
                NavigationLink("Configure a catalog first") { CommunitySettingsView() }
            } else {
                if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let error = community.setupError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let message { Text(message).font(.callout) }
                if busy { ProgressView() }
                if community.signedIn { signedInControls } else { signInControls }
                if !community.signedIn, community.deletion != nil { CommunityDeletionStatus() }
            }
        }
        .modernScene().navigationTitle("Catalog account")
        .task { await refresh() }
        .onChange(of: community.signedIn) { _, value in
            if !value { email = ""; displayName = ""; password = ""; message = nil }
        }
        .onDisappear { password = "" }
    }

    private var signedInControls: some View {
        Section("Signed in") {
            if let user = community.user {
                LabeledContent("Name", value: user.displayName)
                LabeledContent("Email", value: user.email)
                Text(user.verified ? "Email confirmed." : "Email is not confirmed.")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("Delete account / review data retention") {
                    CommunityDeleteAccountView()
                }
            } else {
                Text("Refresh your account before managing deletion.").font(.caption)
            }
            Button("Refresh account") { perform { try await community.refreshUser(); return nil } }
            NavigationLink("My uploads") { CommunityUploadsView() }
            Button("Sign in again") {
                do { try community.forgetLocalSession() }
                catch { failure = error.localizedDescription }
            }
            Button("Sign out", role: .destructive) { perform { try await community.signOut(); return "Signed out." } }
        }.disabled(busy)
    }

    private var signInControls: some View {
        Section(creating ? "Create account" : "Sign in") {
            Toggle("Create a new account", isOn: $creating).disabled(community.config?.allowsNativeSignup != true)
            if community.config?.allowsNativeSignup != true {
                Text("Native signup is unavailable while the server retains approved shared GIFs after account deletion, or its policy is unknown. Guest browsing and existing-account sign-in remain available.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if creating { TextField("Display name", text: $displayName) }
            TextField("Email", text: $email).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(creating ? "Password (12-128 characters)" : "Password", text: $password)
            if let config = community.config {
                Text(config.requireEmailVerification
                    ? "New accounts must confirm email using the server's verification link before signing in."
                    : "This server currently allows signup without email confirmation. That does not verify ownership of an email address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(creating ? "Create account" : "Sign in") {
                let enteredEmail = email, enteredPassword = password, enteredName = displayName
                perform {
                    if creating {
                        return try await community.signUp(email: enteredEmail, password: enteredPassword, displayName: enteredName)
                    }
                    try await community.signIn(email: enteredEmail, password: enteredPassword)
                    return "Signed in."
                }
            }.buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty || (creating && (community.config?.allowsNativeSignup != true ||
                    displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !(12...128).contains(password.utf16.count))))
            Button("Forgot password") {
                perform { try await community.forgotPassword(email: email) }
            }.disabled(email.isEmpty || community.config?.passwordRecoveryAvailable != true)
            if community.config?.passwordRecoveryAvailable == false {
                Text("Password recovery is not available on this server.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reload server policy") { perform { try await community.loadConfig(); return nil } }
            if community.setupError != nil {
                Button("Forget saved sign-in on this iPhone") {
                    do { try community.forgetLocalSession(); failure = nil }
                    catch { failure = error.localizedDescription }
                }
            }
        }.disabled(busy)
    }

    private func refresh() async {
        guard community.origin != nil, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if community.setupError != nil { community.reloadLocalState() }
            try await community.loadConfig()
            try await community.refreshUser()
        } catch { failure = error.localizedDescription }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> String?) {
        guard !busy else { return }
        busy = true; failure = nil; message = nil
        Task {
            defer { busy = false; password = "" }
            do { message = try await action() }
            catch { failure = error.localizedDescription }
        }
    }
}

@MainActor
struct CommunityDeletionStatus: View {
    @EnvironmentObject private var community: CommunityController
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Section("Deletion receipt") {
            if let receipt = community.deletion {
                Text(receipt.status == .completed ? "Account cleanup completed." : "Deletion accepted. Server cleanup is pending.")
                if let retained = receipt.retainedSharedGifs {
                    Text("\(retained) approved shared GIF(s) retained by the server, including existing credits.")
                        .font(.caption).foregroundStyle(retained > 0 ? .orange : .secondary)
                } else {
                    Text("This receipt does not specify how many shared GIFs were retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Receipt requested: \(receipt.requestedAt)").font(.caption).foregroundStyle(.secondary)
                if let error = receipt.error { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("Sessions for the deleted account were revoked. This receipt contains no account identity; status checks do not send Authorization. Completed receipts expire after 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
                if receipt.status == .pending {
                    Button("Check deletion status") {
                        guard !busy else { return }
                        busy = true; failure = nil
                        Task {
                            defer { busy = false }
                            do { try await community.refreshDeletion() }
                            catch { failure = error.localizedDescription }
                        }
                    }.disabled(busy)
                }
            }
            if busy { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }
    }
}

@MainActor
private struct CommunityDeleteAccountView: View {
    @EnvironmentObject private var community: CommunityController
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Form {
            if community.signedIn {
                Section("Permanent server deletion") {
                    if let user = community.user { Text("Delete \(user.email)") }
                    Text(community.config?.accountDeletionRetainsSharedGifs == false
                        ? "This removes your server account and associated uploaded work under this server's deletion policy. All sessions are revoked immediately; cleanup may continue after you leave."
                        : "This removes your server account, private-library GIFs and unpublished/rejected uploads. Approved shared GIFs and their credits are retained under the server's policy, attributed to 'Deleted account'. Names in existing credit/source text may remain. All sessions are revoked immediately; cleanup may continue after you leave.")
                        .foregroundStyle(.orange)
                    Text("Your iPhone's local artwork and backpack storage are not erased.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Current password", text: $password)
                    TextField("Type DELETE", text: $confirmation).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Delete account permanently", role: .destructive) {
                        guard !busy else { return }
                        let enteredPassword = password, enteredConfirmation = confirmation
                        busy = true; failure = nil
                        Task {
                            defer { busy = false; password = "" }
                            do { try await community.deleteAccount(password: enteredPassword, confirmation: enteredConfirmation) }
                            catch { failure = error.localizedDescription }
                        }
                    }.disabled(busy || password.isEmpty || confirmation != "DELETE" || community.config?.accountDeletionRetainsSharedGifs == nil)
                    if community.config?.accountDeletionRetainsSharedGifs == nil {
                        Text("Load the server's deletion policy before confirming.").font(.caption).foregroundStyle(.orange)
                        Button("Load policy") {
                            Task {
                                do { try await community.loadConfig() }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    }
                }.disabled(busy)
            }
            if busy { ProgressView("Requesting deletion...") }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if !community.signedIn, community.deletion != nil { CommunityDeletionStatus() }
        }
        .modernScene().navigationTitle("Delete account")
        .onDisappear { password = "" }
    }
}
