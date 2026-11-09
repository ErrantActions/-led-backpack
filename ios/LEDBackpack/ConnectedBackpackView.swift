import SwiftUI
import BackpackProtocol

@MainActor
struct ConnectedBackpackView: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.scenePhase) private var phase
    @StateObject private var registration = ConnectedBackpackRegistration()
    @State private var nickname = ""
    @State private var consent = false
    @State private var availabilityError: String?

    private var available: Bool {
        community.signedIn && community.config?.unverifiedDeviceTagsEnabled == true
            && community.config?.connectedDeviceRegistrationEnabled == true
    }

    var body: some View {
        Form {
            Section {
                Text("Add the backpack connected to this phone. Its vendor ID links a private account record across phones.")
                Text("This ID can be changed or cloned. Adding it does not prove ownership, lock the backpack, or verify firmware compatibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !community.signedIn {
                NavigationLink("Sign in to add a backpack") { CommunityAccountView() }
            } else if !available {
                Text("Connected backpack registration is unavailable on this server.")
                Button("Refresh availability") {
                    Task {
                        do { try await community.loadConfig(); availabilityError = nil }
                        catch { availabilityError = error.localizedDescription }
                    }
                }
            } else if let device = registration.registered {
                Section("Added to your account") {
                    Text(device.nickname).font(.headline)
                    Text("Private association · ownership unverified")
                    Text("Owner sharing stays off for new records. Existing records keep their settings. No backpack settings or artwork changed.")
                        .font(.caption)
                    NavigationLink("My devices") { AccountDevicesView() }
                    Button("Read another backpack") { reset() }
                }
            } else {
                Section("1. Read connected backpack") {
                    if !link.connected {
                        Text("Connect on the Backpack tab first. If it is locked, enter its existing password there. Then return here.")
                    }
                    Button(registration.observation == nil ? "Read connected backpack" : "Read again") {
                        consent = false
                        do {
                            let scope = try AccountServiceScope(community, capability: .devices)
                            registration.read(using: PanelConnectedBackpackReader(panel: panel, link: link)) {
                                try authorize(scope)
                            }
                        } catch { registration.invalidate(error.localizedDescription) }
                    }
                    .disabled(!link.connected || panel.busy || panel.hasDisplayOwner || registration.busy)
                    .accessibilityIdentifier("connected-backpack-read")
                    Text("Reads device information and dimensions only. No scanning, password changes, ID writes, firmware writes or display changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let observation = registration.observation {
                    Section("2. Confirm this backpack") {
                        LabeledContent("Vendor ID", value: observation.identity.vendorDeviceId)
                        LabeledContent("Model", value: observation.identity.model)
                        LabeledContent("Firmware", value: observation.identity.firmware)
                        LabeledContent("Panel", value: observation.identity.matrix.id)
                        TextField("Backpack nickname", text: $nickname)
                            .accessibilityIdentifier("connected-backpack-nickname")
                        Toggle("I have physical access to this backpack and want its ID saved privately to my account", isOn: $consent)
                            .accessibilityIdentifier("connected-backpack-consent")
                        Text("Only continue if this is your intended backpack. Bluetooth proximity and this confirmation are not ownership proof. Its ID is not included in public owner cards.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Add to my account") {
                            do {
                                let scope = try AccountServiceScope(community, capability: .devices)
                                registration.register(nickname: nickname, consent: consent,
                                    using: PanelConnectedBackpackReader(panel: panel, link: link),
                                    authorize: { try authorize(scope) },
                                    submit: { identity, metadata in
                                        try await scope.addConnectedDevice(identity, metadata: metadata, consent: true)
                                    })
                            } catch { registration.invalidate(error.localizedDescription); consent = false }
                        }
                        .buttonStyle(AuroraPrimaryButton())
                        .disabled(!consent || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || registration.busy || panel.busy || panel.hasDisplayOwner || !link.connected)
                        .accessibilityIdentifier("connected-backpack-add")
                        Text("The app reads the backpack again before saving. Repeated registration of the same ID on this account reuses its record; an ID collision does not prove that two backpacks are the same.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if registration.busy { ProgressView("Checking backpack…") }
            if let error = registration.failure ?? availabilityError {
                Text(error).foregroundStyle(.orange).accessibilityIdentifier("connected-backpack-error")
            }
        }
        .modernScene().navigationTitle("Add connected backpack")
        .onChange(of: registration.observation) { _, _ in consent = false }
        .onChange(of: consent) { _, value in
            if !value && registration.registering {
                registration.invalidate("Confirmation withdrawn. Reload My devices if a request was already sent.")
            }
        }
        .onChange(of: community.accountRevision) { _, _ in reset() }
        .onChange(of: community.config?.connectedDeviceRegistrationEnabled) { _, _ in reset() }
        .onChange(of: community.config?.unverifiedDeviceTagsEnabled) { _, _ in reset() }
        .onChange(of: link.connectionRevision) { _, _ in reset("Connection changed. Read and confirm the backpack again.") }
        .onChange(of: link.connected) { _, connected in if !connected { reset("Backpack disconnected. Read it again after reconnecting.") } }
        .onChange(of: phase) { _, value in if value != .active { reset("Registration paused. Read and confirm again when you return.") } }
        .onDisappear { reset() }
    }

    private func authorize(_ scope: AccountServiceScope) throws {
        try scope.check()
        guard available, phase == .active else {
            throw BackpackError.invalid("Registration is no longer available for this account or foreground session.")
        }
    }

    private func reset(_ reason: String? = nil) {
        registration.invalidate(reason); consent = false; nickname = ""; availabilityError = nil
    }
}
