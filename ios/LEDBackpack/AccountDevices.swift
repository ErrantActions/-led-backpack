import SwiftUI
import CoreImage.CIFilterBuiltins
import BackpackProtocol

struct AccountDevice: Decodable, Identifiable {
    let id: UUID
    let revision: Int
    let nickname, model: String
    let matrix: NativeMatrixSize?
    let ownerCardEnabled, transferPending: Bool
    let claimStatus: String
    let physicalOwnershipVerified, hardwareIdentityVerified, flashingCompatibilityVerified: Bool
    let connection: AccountDeviceConnection?
    func validate() throws {
        guard revision >= 1, claimStatus == "unverified-tag",
              !physicalOwnershipVerified, !hardwareIdentityVerified, !flashingCompatibilityVerified else {
            throw BackpackError.invalid("Unsupported device ownership claim.")
        }
        try AccountDeviceMetadata(nickname: nickname, model: model, matrix: matrix).validate()
        try connection?.validate()
    }
}
struct AccountDeviceMetadata: Encodable {
    var nickname, model: String
    var matrix: NativeMatrixSize?
    private enum CodingKeys: String, CodingKey { case nickname, model, matrix }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nickname, forKey: .nickname); try values.encode(model, forKey: .model)
        if let matrix { try values.encode(matrix, forKey: .matrix) } else { try values.encodeNil(forKey: .matrix) }
    }
    func validate() throws {
        for value in [nickname, model] {
            guard (1...80).contains(value.utf16.count), value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw BackpackError.invalid("Use generic private labels of 1…80 characters without controls; no hardware identifiers.")
            }
        }
        try matrix?.validate()
    }
}
struct AccountDevicePage: Decodable { let devices: [AccountDevice] }
struct AccountDeviceResult: Decodable { let device: AccountDevice }
struct AccountDeviceTransfer: Decodable, Identifiable {
    let device: AccountDevice
    let from: SocialPerson
    var id: UUID { device.id }
}
struct AccountDeviceTransfers: Decodable { let transfers: [AccountDeviceTransfer] }
struct AccountDeviceTag: Decodable {
    let device: AccountDevice
    let tagUrl: URL
    let tagIsPhysicalOwnershipProof: Bool
}
struct AccountDeviceCard: Decodable {
    struct Owner: Decodable {
        let id: UUID
        let displayName: String
        let canRequestFriendship: Bool
        let avatarUrl, avatarPreviewUrl: URL?
        let avatarAnimated, avatarMature, avatarMasked: Bool?
        let avatarScope: Scope?
    }
    struct Scope: Decodable { let kind, token: String }
    let owner: Owner
    let claimStatus: String
    let physicalOwnershipVerified, hardwareIdentityVerified, deviceMetadataIncluded, friendshipCreated: Bool
    func validate(token: String) throws {
        guard claimStatus == "unverified-tag", !physicalOwnershipVerified, !hardwareIdentityVerified,
              !deviceMetadataIncluded, !friendshipCreated,
              (owner.avatarUrl == nil) == (owner.avatarPreviewUrl == nil),
              owner.avatarScope == nil || (owner.avatarScope?.kind == "device-tag" && owner.avatarScope?.token == token) else {
            throw BackpackError.invalid("Invalid minimal scoped owner card.")
        }
        guard owner.avatarUrl == nil || owner.avatarScope != nil else { throw BackpackError.invalid("Scoped avatar authorization is missing.") }
    }
}
enum AccountDeviceTagLink {
    static func token(_ input: String, origin: CommunityOrigin) throws -> String {
        if NearbyTokenPolicy.valid(input) { return input }
        guard let parts = URLComponents(string: input), let url = parts.url,
              origin.contains(url), parts.percentEncodedPath == "/device-card", parts.query == nil,
              let fragment = parts.percentEncodedFragment, fragment.hasPrefix("tag="),
              parts.fragment == fragment else { throw BackpackError.invalid("Use this server's /device-card#tag=TOKEN link or canonical random token.") }
        let token = String(fragment.dropFirst(4))
        guard NearbyTokenPolicy.valid(token) else { throw BackpackError.invalid("A readable device identifier/hash is not an ownership proof or tag token.") }
        return token
    }
}

@MainActor
extension AccountServiceScope {
    func devices() async throws -> [AccountDevice] {
        let value = try await send(AccountDevicePage.self, "devices").devices
        guard value.count <= 20, Set(value.map(\.id)).count == value.count else { throw BackpackError.invalid("Invalid device list.") }
        for device in value { try device.validate() }
        return value
    }
    func incomingDevices() async throws -> [AccountDeviceTransfer] {
        let value = try await send(AccountDeviceTransfers.self, "devices/transfers").transfers
        guard value.count <= 50, Set(value.map(\.id)).count == value.count else { throw BackpackError.invalid("Invalid transfer list.") }
        for transfer in value {
            try transfer.device.validate()
            guard transfer.device.transferPending, transfer.device.connection == nil else {
                throw BackpackError.invalid("Invalid private transfer payload or transfer is no longer pending.")
            }
        }
        return value
    }
    func addDevice(_ metadata: AccountDeviceMetadata) async throws {
        try metadata.validate()
        let result = try await send(AccountDeviceResult.self, "devices", method: "POST", body: JSONEncoder().encode(metadata))
        try result.device.validate()
        guard !result.device.ownerCardEnabled, !result.device.transferPending else { throw BackpackError.invalid("New label unexpectedly enabled sharing.") }
    }
    func editDevice(_ device: AccountDevice, metadata: AccountDeviceMetadata) async throws {
        try device.validate(); try metadata.validate()
        guard !device.transferPending else { throw BackpackError.invalid("Cancel the pending transfer before editing.") }
        struct Body: Encodable { let expectedRevision: Int; let device: AccountDeviceMetadata }
        let value = try await send(AccountDeviceResult.self, "devices/\(device.id.uuidString.lowercased())", method: "PATCH",
            body: JSONEncoder().encode(Body(expectedRevision: device.revision, device: metadata))).device
        try value.validate()
        guard value.id == device.id, value.nickname == metadata.nickname, value.model == metadata.model,
              value.matrix == metadata.matrix else { throw BackpackError.invalid("Device-label edit receipt did not match the captured request.") }
    }
    func changeDevice(_ device: AccountDevice, action: String, recipient: UUID? = nil) async throws -> AccountDeviceTag? {
        try device.validate()
        struct Revision: Encodable { let expectedRevision: Int }
        struct Consent: Encodable { let expectedRevision: Int; let consent = true; let recipientId: String? }
        let base = "devices/\(device.id.uuidString.lowercased())"
        if action == "tag" {
            let result = try await send(AccountDeviceTag.self, base + "/tag", method: "POST",
                body: JSONEncoder().encode(Consent(expectedRevision: device.revision, recipientId: nil)))
            try result.device.validate()
            _ = try AccountDeviceTagLink.token(result.tagUrl.absoluteString, origin: origin)
            guard result.device.id == device.id, result.device.revision > device.revision,
                  result.device.ownerCardEnabled, !result.tagIsPhysicalOwnershipProof else { throw BackpackError.invalid("Invalid revocable tag receipt.") }
            return result
        }
        let path: String, method: String, body: Data
        switch action {
        case "revoke": path = base + "/tag"; method = "DELETE"; body = try JSONEncoder().encode(Revision(expectedRevision: device.revision))
        case "cancel": path = base + "/transfer"; method = "DELETE"; body = try JSONEncoder().encode(Revision(expectedRevision: device.revision))
        case "remove": path = base; method = "DELETE"; body = try JSONEncoder().encode(Revision(expectedRevision: device.revision))
        case "transfer":
            guard let recipient, recipient != accountID, !device.transferPending else { throw BackpackError.invalid("Select a current accepted friend.") }
            path = base + "/transfer"; method = "POST"
            body = try JSONEncoder().encode(Consent(expectedRevision: device.revision, recipientId: recipient.uuidString.lowercased()))
        default: throw BackpackError.invalid("Unsupported label action.")
        }
        if action == "remove" {
            struct Result: Decodable { let removed, localArtworkChanged: Bool }
            let result = try await send(Result.self, path, method: method, body: body)
            guard result.removed, !result.localArtworkChanged else { throw BackpackError.invalid("Unlink/local-artwork receipt was not confirmed.") }
        } else {
            let result = try await send(AccountDeviceResult.self, path, method: method, body: body).device
            try result.validate()
            guard result.id == device.id, !result.ownerCardEnabled,
                  result.transferPending == (action == "transfer") else {
                throw BackpackError.invalid("Tag revocation or transfer receipt changed. Reload labels and offers.")
            }
        }
        return nil
    }
    func respondDevice(_ transfer: AccountDeviceTransfer, accept: Bool) async throws {
        try transfer.device.validate()
        struct Body: Encodable { let expectedRevision: Int; let accept: Bool }
        struct Result: Decodable { let accepted, ownerCardEnabled, physicalOwnershipVerified: Bool }
        let value = try await send(Result.self, "devices/transfers/\(transfer.id.uuidString.lowercased())", method: "POST",
            body: JSONEncoder().encode(Body(expectedRevision: transfer.device.revision, accept: accept)))
        guard value.accepted == accept, !value.ownerCardEnabled, !value.physicalOwnershipVerified else {
            throw BackpackError.invalid("Transfer receipt did not confirm this unverified-label decision.")
        }
    }
    func deviceCard(_ token: String) async throws -> AccountDeviceCard {
        guard NearbyTokenPolicy.valid(token) else { throw BackpackError.invalid("Invalid opaque tag.") }
        struct Body: Encodable { let token: String }
        let value = try await send(AccountDeviceCard.self, "devices/lookup", method: "POST", body: JSONEncoder().encode(Body(token: token)))
        try value.validate(token: token); return value
    }
    func deviceAvatar(_ url: URL, owner: UUID, token: String) async throws -> Data {
        guard community.config?.avatarsEnabled == true else { throw BackpackError.invalid("Avatars are unavailable.") }
        let client = try CommunityFeatureClient(community)
        let resolved = try client.resolvedAvatarURL(url)
        let parts = resolved.path.split(separator: "/")
        guard parts[4] == Substring(owner.uuidString.lowercased()) else { throw BackpackError.invalid("Owner-card avatar mismatch.") }
        _ = try await deviceCard(token)
        let result = try await bytes(parts.dropFirst(2).joined(separator: "/"), maxBytes: 5_000_000, tag: token)
        _ = try await deviceCard(token)
        return result
    }
}

@MainActor
struct AccountDevicesView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = AccountServiceSession()
    @State private var devices: [AccountDevice] = []
    @State private var incoming: [AccountDeviceTransfer] = []
    @State private var friends: [SocialPerson] = []
    @State private var friendPage = 1
    @State private var editing: AccountDevice?
    @State private var recipient: UUID?
    @State private var tag: AccountDeviceTag?
    @State private var qr: CGImage?
    @State private var pending: DeviceAction?
    private struct DeviceAction {
        let device: AccountDevice
        let action: String
        let recipient: UUID?
        let revision: UUID
    }
    private var identity: String { "\(community.accountRevision):\(community.avatarPolicyRevision):\(community.config?.unverifiedDeviceTagsEnabled == true)" }
    var body: some View {
        Form {
            NavigationLink("Add connected backpack") { ConnectedBackpackView() }
            Text("Device details come from your connected backpack. Account records are not verified ownership.")
                .font(.caption)
            if session.scope != nil {
                Section("My devices (\(devices.count)/20)") {
                    if devices.isEmpty { Text("No backpacks yet. Connect one to add it.") }
                    ForEach(devices) { device in
                        VStack(alignment: .leading) {
                            Text(device.nickname).font(.headline)
                            Text("\(device.model) · \(device.matrix?.id ?? "unknown matrix") · unverified · revision \(device.revision)").font(.caption)
                            if let connection = device.connection {
                                DisclosureGroup("Private connected ID") {
                                    LabeledContent("Vendor ID", value: connection.vendorDeviceId)
                                    Text("Mutable ID, not ownership proof. Other accounts may associate the same ID independently. Unlink removes this account's record; transfer moves only the label and drops the private ID.")
                                        .font(.caption)
                                }
                            }
                            if !device.transferPending {
                                Button("Rename") { editing = device }
                                Button(device.ownerCardEnabled ? "Replace/revoke old QR and share owner" : "Issue unverified owner QR") { confirm(device, "tag") }
                                if device.ownerCardEnabled { Button("Revoke owner card", role: .destructive) { confirm(device, "revoke") } }
                                Button("Offer transfer to selected friend") { confirm(device, "transfer") }.disabled(recipient == nil)
                            } else { Button("Cancel pending transfer") { confirm(device, "cancel") } }
                            Button("Unlink label and revoke tags", role: .destructive) { confirm(device, "remove") }
                        }
                    }
                }
                Section("Transfer recipient — accepted friends only") {
                    Picker("Friend", selection: $recipient) {
                        Text("Choose deliberately").tag(Optional<UUID>.none)
                        ForEach(friends) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Text("The recipient receives this private label's model/matrix/nickname and must accept. Existing tags revoke immediately and never return after decline/cancel.")
                        .font(.caption)
                    Text("Connected vendor IDs are never sent with transfer offers. Accepting a transfer drops the old private binding; the recipient must explicitly read and register the backpack.")
                        .font(.caption)
                    HStack {
                        Button("Previous friends") { friendPage = max(1, friendPage - 1); loadFriends() }.disabled(friendPage == 1)
                        Text("Page \(friendPage)")
                        Button("Next friends") { friendPage += 1; loadFriends() }.disabled(friends.count < 50 || friendPage >= 10000)
                    }
                }
                Section("Incoming offers") {
                    if incoming.isEmpty { Text("No incoming transfers.") }
                    ForEach(incoming) { transfer in
                        Text("\(transfer.device.nickname) — from \(transfer.from.displayName)")
                        Button("Accept unverified label") { confirm(transfer.device, "accept") }
                        Button("Decline", role: .destructive) { confirm(transfer.device, "decline") }
                    }
                }
                if let tag {
                    Section("New revocable QR (returned once)") {
                        Text("Unverified owner card, not ownership proof. Copies/screenshots cannot be recalled.")
                        if let qr { Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit().frame(height: 220) }
                        ShareLink("Share this unverified tag", item: tag.tagUrl)
                        Button("Hide local tag") { self.tag = nil; qr = nil }
                    }
                }
                NavigationLink("Read a deliberately shared unverified owner card") { AccountDeviceCardView() }
                Button("Reload labels and offers") { load() }
            } else { Text("Device tags are unavailable on this server or account.") }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let message = session.message { Text(message) }
        }.disabled(session.busy).navigationTitle("My devices")
            .task(id: identity) { clear(); session.bind(community, .devices); load() }
            .onDisappear { if editing == nil { session.clear(); clear() } }
            .sheet(item: $editing, onDismiss: {
                if session.scope == nil { session.bind(community, .devices) }
                load()
            }) { device in
                NavigationStack { AccountDeviceEditView(device: device, revision: community.accountRevision) }
            }
            .confirmationDialog("Confirm explicit unverified label action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let pending {
                    Button("\(pending.action.capitalized) \(pending.device.nickname)", role: pending.action == "remove" ? .destructive : nil) {
                        self.pending = nil; tag = nil; qr = nil
                        session.run { scope in
                            guard scope.revision == pending.revision else { throw BackpackError.invalid("Captured account changed.") }
                            if pending.action == "accept" || pending.action == "decline" {
                                guard let transfer = incoming.first(where: { $0.id == pending.device.id && $0.device.revision == pending.device.revision }) else { throw BackpackError.invalid("Offer changed.") }
                                try await scope.respondDevice(transfer, accept: pending.action == "accept")
                            } else {
                                tag = try await scope.changeDevice(pending.device, action: pending.action, recipient: pending.recipient)
                                if let tag {
                                    let generator = CIFilter.qrCodeGenerator(); generator.message = Data(tag.tagUrl.absoluteString.utf8)
                                    if let image = generator.outputImage { qr = CIContext().createCGImage(image, from: image.extent) }
                                }
                            }
                            try await reload(scope); return "Action received. Only the service association changed."
                        }
                    }
                }
            } message: { Text("Captured device revision and selected recipient only. A conflict requires reload; no silent retry, physical claim or hardware operation.") }
    }
    private func confirm(_ device: AccountDevice, _ action: String) {
        pending = DeviceAction(device: device, action: action, recipient: recipient, revision: community.accountRevision)
    }
    private func clear() { devices = []; incoming = []; friends = []; friendPage = 1; recipient = nil; pending = nil; tag = nil; qr = nil; editing = nil }
    private func reload(_ scope: AccountServiceScope) async throws {
        devices = []; incoming = []; friends = []; friendPage = 1; recipient = nil
        let labels = try await scope.devices(), offers = try await scope.incomingDevices()
        let accepted: [SocialPerson]
        if community.config?.socialEnabled == true {
            let client = try CommunityFeatureClient(community)
            accepted = try await client.friends(page: 1).friends
        } else { accepted = [] }
        try session.checked(scope); devices = labels; incoming = offers; friends = accepted
    }
    private func load() { session.run { scope in try await reload(scope); return nil } }
    private func loadFriends() {
        friends = []; recipient = nil; pending = nil
        session.run { scope in
            let result = try await CommunityFeatureClient(community).friends(page: friendPage)
            try session.checked(scope); friends = result.friends; return nil
        }
    }
}

@MainActor
struct AccountDeviceEditView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = AccountServiceSession()
    let device: AccountDevice
    let revision: UUID
    @State private var nickname = ""
    var body: some View {
        Form {
            TextField("Nickname", text: $nickname)
            LabeledContent("Model", value: device.model)
            LabeledContent("Panel", value: device.matrix?.id ?? "Unknown")
            Button("Save") {
                session.run { scope in
                    guard scope.revision == revision else { throw BackpackError.invalid("Captured account changed; reopen the label.") }
                    try await scope.editDevice(device, metadata: AccountDeviceMetadata(nickname: nickname,
                        model: device.model, matrix: device.matrix))
                    try session.checked(scope); dismiss(); return nil
                }
            }.disabled(session.scope == nil)
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
        }.disabled(session.busy).navigationTitle("Rename backpack")
            .task(id: community.accountRevision) {
                session.bind(community, .devices)
                guard community.accountRevision == revision else { session.clear(); return }
                nickname = device.nickname
            }
            .onDisappear { session.clear() }
            .toolbar { Button("Cancel") { dismiss() } }
    }
}

@MainActor
struct AccountDeviceCardView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @StateObject private var session = AccountServiceSession()
    @State private var input = ""
    @State private var token: String?
    @State private var card: AccountDeviceCard?
    @State private var manual = false
    var body: some View {
        Form {
            Text("Unverified tag copied/shared by an owner, not a physical ownership proof or directory. No email, device metadata, location or private artwork is available.")
            TextField("Paste configured-server tag link", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Explicitly read this owner card") {
                card = nil; token = nil; manual = false
                session.run { scope in
                    let value = try AccountDeviceTagLink.token(input, origin: scope.origin)
                    let result = try await scope.deviceCard(value); try session.checked(scope)
                    token = value; card = result; input = ""; return nil
                }
            }
            if let card, let token, let scope = session.scope {
                Text(card.owner.displayName).font(.headline)
                if card.owner.avatarMasked != true, card.owner.avatarMature != true || community.user?.allowMature == true,
                   let preview = card.owner.avatarPreviewUrl {
                    let animate = community.user?.mediaPreferences?.permitsAnimation(reducedMotion: reducedMotion, manual: manual) ?? (!reducedMotion || manual)
                    let url = card.owner.avatarAnimated == true && animate ? (card.owner.avatarUrl ?? preview) : preview
                    GIFThumbnail(key: "device-card:\(scope.revision):\(community.avatarPolicyRevision):\(url)", cache: false) {
                        try await scope.deviceAvatar(url, owner: card.owner.id, token: token)
                    }.frame(width: 100, height: 100).clipShape(Circle())
                    if card.owner.avatarAnimated == true { Button(manual ? "Pause avatar" : "Play avatar") { manual.toggle() } }
                }
                if card.owner.canRequestFriendship {
                    Button("Request friendship (separate consent)") {
                        session.run { scope in
                            let current = try await scope.deviceCard(token)
                            guard current.owner.id == card.owner.id, current.owner.canRequestFriendship else { throw BackpackError.invalid("Card/request permission revoked.") }
                            try await CommunityFeatureClient(community).requestFriend(card.owner.id)
                            return "Request sent; friendship still requires acceptance."
                        }
                    }
                }
            }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let message = session.message { Text(message) }
        }.navigationTitle("Unverified owner card")
            .task(id: "\(community.accountRevision):\(community.avatarPolicyRevision):\(phase)") {
                card = nil; token = nil; manual = false; input = ""
                session.bind(community, .devices)
            }
            .task(id: token) {
                guard let token else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        guard phase == .active, let scope = session.scope else { card = nil; return }
                        let current = try await scope.deviceCard(token); try session.checked(scope)
                        guard self.token == token else { return }; card = current
                    } catch { card = nil; self.token = nil; manual = false; return }
                }
            }
            .onDisappear { session.clear(); card = nil; token = nil; manual = false; input = "" }
    }
}
