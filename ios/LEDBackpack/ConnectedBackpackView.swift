import SwiftUI
import BackpackProtocol

@MainActor
struct ConnectedBackpackPanel: View {
    var onRegistered: (AccountDevice) -> Void = { _ in }
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.scenePhase) private var phase
    @StateObject private var registration = ConnectedBackpackRegistration()
    @State private var avatarScope: AccountServiceScope?
    @State private var avatarEpoch = UUID()
    @State private var conversationID: UUID?
    @State private var availabilityError: String?

    private var available: Bool {
        community.signedIn && community.config?.unverifiedDeviceTagsEnabled == true
            && community.config?.connectedDeviceRegistrationEnabled == true
            && (community.config?.connectedDeviceRegistrationVersion ?? 0) >= 2
    }
    private var context: String {
        "\(community.accountRevision):\(community.avatarPolicyRevision):\(available):\(community.config?.deviceRecoveryEnabled == true):\(link.connectionRevision):\(link.connected):\(phase)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !community.signedIn {
                NavigationLink("Sign in to manage your backpacks") { CommunityAccountView() }
            } else if !available {
                Text("Device adoption is unavailable on this server.")
                Button("Refresh availability") {
                    Task {
                        do { try await community.loadConfig(); availabilityError = nil }
                        catch { availabilityError = error.localizedDescription }
                    }
                }
            } else {
                if let device = registration.registered {
                    Label("\(device.nickname) is in My devices", systemImage: "checkmark.circle.fill")
                } else if let review = registration.registryReview {
                    switch review.lookup.status {
                    case .available:
                        Label("Ready to adopt", systemImage: "backpack")
                        if let identity = registration.observation?.identity {
                            Text("\(identity.model) · \(identity.matrix.id)").font(.subheadline)
                        }
                        Text("Saves this connection privately to your account. The device ID is mutable and is not ownership proof.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Adopt this backpack") { adopt() }
                            .buttonStyle(AuroraPrimaryButton())
                            .disabled(registration.busy || !link.connected || panel.busy || panel.hasDisplayOwner)
                            .accessibilityIdentifier("connected-backpack-add")
                    case .owned:
                        if let device = review.lookup.device {
                            Label("\(device.nickname) is already in My devices", systemImage: "checkmark.circle")
                        }
                    case .registeredElsewhere:
                        Text("Already adopted").font(.headline)
                        if let recovery = review.lookup.recovery, let scope = avatarScope {
                            HStack {
                                if recovery.owner.avatarPreviewUrl != nil {
                                    GIFThumbnail(key: "device-recovery:\(avatarEpoch)", cache: false) {
                                        guard let data = try await scope.recoveryAvatar(review) else {
                                            throw BackpackError.invalid("The recovery avatar is no longer available.")
                                        }
                                        return data
                                    }.frame(width: 56, height: 56).clipShape(Circle())
                                }
                                Text(recovery.owner.displayName).font(.headline)
                            }
                            Button(registration.pendingContact == nil ? "I found your device" : "Retry found-device message") {
                                contact()
                            }.disabled(registration.busy || !link.connected || panel.busy || panel.hasDisplayOwner)
                            Text("Sends one introduction. You can exchange recovery replies if this person responds, without becoming friends.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Found-device contact is unavailable for this backpack.")
                                .font(.subheadline)
                        }
                    case .ambiguous:
                        Text("This ID matches more than one account.")
                        Text("We cannot safely identify one person or adopt this connection. No account details are shared.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if !link.connected {
                    Text("Connect a backpack on the Backpack tab to check it here.")
                } else if !registration.busy {
                    Text("Check the connected backpack to see whether it is already adopted.")
                }
                if registration.busy { ProgressView("Checking backpack…") }
                Button(registration.observation == nil ? "Check connected backpack" : "Check again") { check() }
                    .disabled(!link.connected || panel.busy || panel.hasDisplayOwner || registration.busy)
                    .accessibilityIdentifier("connected-backpack-read")
                if registration.pendingContact != nil {
                    Button("Clear pending introduction", role: .destructive) { registration.discardPendingContact() }
                        .disabled(registration.busy)
                    Text("Clearing local delivery state does not recall a message already received.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Device details") {
                    if let identity = registration.observation?.identity {
                        LabeledContent("Vendor ID", value: identity.vendorDeviceId).privacySensitive()
                        LabeledContent("Model", value: identity.model)
                        LabeledContent("Firmware", value: identity.firmware)
                        LabeledContent("Panel", value: identity.matrix.id)
                    }
                    Text("Checks read device information only. No scanning, display changes, ID writes or firmware writes.")
                        .font(.caption)
                }
            }
            if let error = registration.failure ?? availabilityError {
                Text(error).foregroundStyle(.orange).accessibilityIdentifier("connected-backpack-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: context) {
            reset()
            if available, phase == .active, link.connected, !panel.busy, !panel.hasDisplayOwner { check() }
        }
        .onChange(of: registration.registered?.id) { _, _ in
            if let device = registration.registered { onRegistered(device) }
        }
        .onChange(of: registration.contactConversationID) { _, value in
            if let value { conversationID = value }
        }
        .onChange(of: community.accountRevision) { _, _ in conversationID = nil }
        .navigationDestination(item: $conversationID) { DeviceRecoveryThreadView(id: $0) }
        .onDisappear { reset() }
    }

    private func authorize(_ scope: AccountServiceScope) throws {
        try scope.checkDeviceRegistry()
        guard available, phase == .active else {
            throw BackpackError.invalid("This account or foreground session changed. Check the backpack again.")
        }
    }
    private func check() {
        do {
            let scope = try AccountServiceScope(community, capability: .devices)
            avatarScope = scope; avatarEpoch = UUID(); availabilityError = nil
            registration.read(using: PanelConnectedBackpackReader(panel: panel, link: link),
                registryLookup: { try await scope.lookupConnectedDevice($0, consent: true) },
                authorize: { try authorize(scope) })
        } catch { registration.invalidate(error.localizedDescription); avatarScope = nil }
    }
    private func adopt() {
        do {
            let scope = try AccountServiceScope(community, capability: .devices)
            registration.register(nickname: "My backpack", consent: true,
                using: PanelConnectedBackpackReader(panel: panel, link: link),
                authorize: { try authorize(scope) },
                submit: { try await scope.addConnectedDevice($0, metadata: $1, consent: true) })
        } catch { registration.invalidate(error.localizedDescription) }
    }
    private func contact() {
        do {
            let scope = try AccountServiceScope(community, capability: .devices)
            registration.contactOwner(using: PanelConnectedBackpackReader(panel: panel, link: link),
                scope: scope, authorize: { try authorize(scope) })
        } catch { registration.invalidate(error.localizedDescription) }
    }
    private func reset() {
        registration.invalidate(); avatarScope = nil; avatarEpoch = UUID(); availabilityError = nil
    }
}
