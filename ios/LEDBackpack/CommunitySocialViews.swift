import SwiftUI
import UniformTypeIdentifiers
import BackpackProtocol

@MainActor
struct CommunitySocialView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = CommunityFeatureSession()
    @State private var preferences: SocialPreferences?
    @State private var friends: [SocialPerson] = []
    @State private var requests: SocialRequestsPage?
    @State private var name = ""
    @State private var discoverable = false
    @State private var allowRequests = false
    @State private var profileDirty = false
    @State private var target = ""
    @State private var token = ""
    @State private var invite: SocialInvite?
    @State private var page = 1
    @State private var requestPage = 1
    @State private var pending: Action?
    private struct Action {
        let label, detail: String
        let scope: UUID
        let work: @MainActor (CommunityFeatureClient) async throws -> Void
    }
    var body: some View {
        Form {
            if community.config?.socialEnabled == true && community.signedIn && !session.denied &&
                session.client?.accountID == community.user?.id {
                if session.busy { ProgressView() }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                Section("Your profile") {
                    if let preferences, let client = session.client {
                        CommunityProfileAvatar(person: preferences.profile, client: client).frame(width: 72, height: 72)
                        Text(preferences.profile.id.uuidString.lowercased()).font(.caption).textSelection(.enabled)
                    }
                    TextField("Display name", text: Binding(get: { name }, set: { name = $0; profileDirty = true }))
                    Toggle("Allow profile discovery", isOn: Binding(get: { discoverable }, set: { discoverable = $0; profileDirty = true }))
                    Toggle("Allow friend requests", isOn: Binding(get: { allowRequests }, set: { allowRequests = $0; profileDirty = true }))
                    Text("Discovery consent is not GPS permission. This screen does not scan for people or show live locations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save profile preferences") {
                        let newName = name, visible = discoverable, allowed = allowRequests
                        session.run({ client in try await client.saveProfile(name: newName, discoverable: visible, requests: allowed) },
                            success: { profileDirty = false; load() })
                    }.disabled(preferences == nil)
                    if community.config?.avatarsEnabled == true { NavigationLink("My profile avatar") { CommunityAvatarView() } }
                }.disabled(session.busy)
                Section("Friends") {
                    ForEach(friends) { friend in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if let client = session.client {
                                    CommunityProfileAvatar(person: friend, client: client).frame(width: 48, height: 48)
                                }
                                Text(friend.displayName)
                            }
                            Text(friend.id.uuidString.lowercased()).font(.caption).textSelection(.enabled)
                            Button("Remove friend") {
                                confirm("Remove friend", "This revokes relationship permissions. It does not erase local artwork.") { try await $0.unfriend(friend.id) }
                            }
                            Button("Block contact", role: .destructive) {
                                confirm("Block contact", "Stops friendship, requests and related permissions. Unblocking does not restore them.") { try await $0.block(friend.id) }
                            }
                            Button(friend.locationFeaturesAllowed == true ? "Revoke future location-feature consent" : "Allow future location features for this friend") {
                                confirm("Change future-feature consent", "This does not turn on GPS, nearby discovery or a live-user map. Mutual permission requires both friends.") {
                                    try await $0.futureLocation(friend.id, enabled: friend.locationFeaturesAllowed != true)
                                }
                            }
                            Text(friend.mutualLocationFeaturesAllowed == true ? "Future-feature consent is mutual." : "No mutual future-location-feature consent.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Previous friends") { page -= 1; load() }.disabled(page <= 1)
                        Spacer()
                        Button("Next friends") { page += 1; load() }.disabled(friends.count < 50 || page >= 10000)
                    }
                }.disabled(session.busy)
                Section("Friend requests") {
                    ForEach(requests?.inbound ?? []) { request in
                        Text("From \(request.senderId.uuidString.lowercased())").font(.caption)
                        HStack {
                            Button("Accept") { confirm("Accept request", "Create this friendship?") { try await $0.respond(request.id, accept: true) } }
                            Button("Decline") { confirm("Decline request", "Decline this pending request?") { try await $0.respond(request.id, accept: false) } }
                        }
                    }
                    ForEach(requests?.outbound ?? []) { request in
                        Text("Pending request to \(request.recipientId.uuidString.lowercased())").font(.caption)
                    }
                    HStack {
                        Button("Previous requests") { requestPage -= 1; load() }.disabled(requestPage <= 1)
                        Spacer()
                        Button("Next requests") { requestPage += 1; load() }
                            .disabled((requests?.inbound.count ?? 0) + (requests?.outbound.count ?? 0) < 50 || requestPage >= 10000)
                    }
                    TextField("Account UUID", text: $target).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Send friend request") {
                        let text = target
                        session.run({ client in
                            guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                throw BackpackError.invalid("Enter an account UUID.")
                            }
                            try await client.requestFriend(id)
                        }, success: { target = ""; load() })
                    }
                }.disabled(session.busy)
                Section("Single-use friend invite") {
                    Text("Invites expire after 15 minutes. Redeeming sends a request; it never creates a friendship automatically.")
                        .font(.caption)
                    Button("Create invite") {
                        session.run { client in
                            let value = try await client.createInvite(); try session.checked(client); invite = value
                        }
                    }
                    if let invite {
                        Text("Expires \(invite.expires.formatted())").font(.caption)
                        ShareLink("Share with intended person", item: invite.token)
                        Button("Revoke this invite", role: .destructive) {
                            confirm("Revoke invite", "Make this invitation unusable?") { try await $0.revokeInvite(invite.id) }
                        }
                    }
                    SecureField("Invite token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Redeem invite") {
                        let value = token
                        session.run({ client in try await client.redeem(value) }, success: { token = ""; load() })
                    }
                }.disabled(session.busy)
                NavigationLink("Blocked accounts") { CommunityBlocksView() }
                Button("Refresh friends and profile", action: load).disabled(session.busy)
            } else {
                Text(session.failure ?? "Friends are unavailable until this server enables the social capability.")
            }
        }
        .modernScene().navigationTitle("Friends & profile")
        .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.config?.socialEnabled == true)") {
            clear(); page = 1; requestPage = 1; session.bind(community)
            if community.config?.socialEnabled == true { load() }
        }
        .onChange(of: session.denied) { _, value in if value { clear() } }
        .onDisappear { session.clear(); clear() }
        .alert("Confirm social action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending) { value in
                Button(value.label) { session.run(expected: value.scope, value.work, success: { invite = nil; load() }) }
                Button("Cancel", role: .cancel) {}
            } message: { Text($0.detail) }
    }
    private func confirm(_ label: String, _ detail: String, work: @escaping @MainActor (CommunityFeatureClient) async throws -> Void) {
        guard let client = session.client else {
            session.run { _ in throw BackpackError.invalid("Refresh social access before confirming an action.") }; return
        }
        pending = Action(label: label, detail: detail, scope: client.instanceID, work: work)
    }
    private func load() {
        session.run { client in
            let profile = try await client.preferences()
            let list = try await client.friends(page: page)
            let pending = try await client.requests(page: requestPage)
            try session.checked(client)
            preferences = profile; friends = list.friends; requests = pending
            if !profileDirty {
                name = profile.profile.displayName; discoverable = profile.discoverable; allowRequests = profile.allowRequests
            }
        }
    }
    private func clear() { preferences = nil; friends = []; requests = nil; invite = nil; token = ""; pending = nil; name = ""; target = ""; profileDirty = false }
}

@MainActor
struct CommunityProfileAvatar: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let person: SocialPerson
    let client: CommunityFeatureClient
    @State private var manual = false
    var body: some View {
        VStack {
            if community.config?.avatarsEnabled == true, let preview = person.avatarPreviewUrl {
                let url = person.avatarAnimated == true && (!reducedMotion || manual) ? (person.avatarUrl ?? preview) : preview
                GIFThumbnail(key: "avatar:\(client.instanceID):\(url)", cache: false) { try await client.avatarMedia(url) }
                    .clipShape(Circle())
                if reducedMotion && person.avatarAnimated == true {
                    Button(manual ? "Pause avatar" : "Play avatar") { manual.toggle() }.font(.caption2)
                }
            } else { Text(String(person.displayName.prefix(1))).font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary, in: Circle()) }
        }.accessibilityLabel("\(person.displayName) avatar")
    }
}

@MainActor
struct CommunityAvatarView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = CommunityFeatureSession()
    @State private var avatar: SocialAvatar?
    @State private var consent = false
    @State private var picking = false
    @State private var pickerScope: UUID?
    @State private var deleting = false
    @State private var deleteScope: UUID?
    var body: some View {
        Form {
            if community.config?.avatarsEnabled == true && community.signedIn && !session.denied &&
                session.client?.accountID == community.user?.id {
                if let client = session.client, let avatar {
                    CommunityProfileAvatar(person: SocialPerson(id: avatar.userId,
                        displayName: community.user?.displayName ?? "Your profile", avatarUrl: avatar.avatarUrl,
                        avatarPreviewUrl: avatar.avatarPreviewUrl, avatarAnimated: avatar.avatarAnimated),
                        client: client).frame(width: 128, height: 128)
                    LabeledContent("Review status", value: avatar.status)
                }
                if avatar == nil && !session.busy { Text("Default profile avatar") }
                Toggle("I consent to upload this public-profile avatar for admin review", isOn: $consent)
                Text("This is not private cloud backup. PNG/JPEG/WebP stills or GIFs, up to 5 MB. Other people see it only after approval and profile authorization.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Choose avatar image or GIF") { pickerScope = session.client?.instanceID; picking = true }
                    .disabled(!consent || session.busy || session.client == nil)
                Button("Refresh avatar", action: load).disabled(session.busy)
                Button("Remove avatar", role: .destructive) {
                    deleteScope = session.client?.instanceID; deleting = true
                }.disabled(avatar == nil || session.busy)
                if session.busy { ProgressView() }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            } else { Text(session.failure ?? "Avatars are not enabled by this server.") }
        }
        .modernScene().navigationTitle("Profile avatar")
        .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.config?.avatarsEnabled == true)") {
            avatar = nil; consent = false; session.bind(community)
            if community.config?.avatarsEnabled == true { load() }
        }
        .onChange(of: session.denied) { _, denied in if denied { avatar = nil; consent = false } }
        .onDisappear { if !picking { session.clear(); avatar = nil; consent = false } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .gif]) { result in
            session.run(expected: pickerScope, { client in
                let url = try result.get()
                guard url.isFileURL else { throw BackpackError.invalid("Choose a local image file for the avatar.") }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, (1...5_000_000).contains(size), consent else {
                    throw BackpackError.invalid("Choose a nonempty image up to 5 MB and confirm public-profile consent.")
                }
                try await client.uploadAvatar(Data(contentsOf: url), publicConsent: consent)
            }, success: { consent = false; load() })
        }
        .confirmationDialog("Remove your profile avatar?", isPresented: $deleting) {
            Button("Remove avatar", role: .destructive) {
                session.run(expected: deleteScope, { try await $0.removeAvatar() }, success: load)
            }
        }
    }
    private func load() {
        session.run { client in let value = try await client.avatar(); try session.checked(client); avatar = value }
    }
}
