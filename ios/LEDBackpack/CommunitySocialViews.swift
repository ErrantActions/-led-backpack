import SwiftUI
import UniformTypeIdentifiers
import BackpackProtocol

@MainActor
struct CommunitySocialView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
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
    @State private var badgesVerified = false
    @State private var locationRevision: Int?
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
                        if preferences.accountAwardsEnabled == true && badgesVerified {
                            AuthorizedProfileEventBadges(badges: preferences.profile.eventBadges ?? [])
                            NavigationLink("My private event badges / profile choices") { EventAwardListView() }
                        }
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
                            if preferences?.accountAwardsEnabled == true && badgesVerified {
                                AuthorizedProfileEventBadges(badges: friend.eventBadges ?? [])
                            }
                            Button("Remove friend") {
                                confirm("Remove friend", "This revokes relationship permissions. It does not erase local artwork.") { try await $0.unfriend(friend.id) }
                            }
                            Button("Block contact", role: .destructive) {
                                confirm("Block contact", "Stops friendship, requests and related permissions. Unblocking does not restore them.") { try await $0.block(friend.id) }
                            }
                            Button(friend.locationFeaturesAllowed == true ? "Revoke future location-feature consent" : "Allow future location features for this friend") {
                                let capturedRevision = locationRevision
                                confirm("Change future-feature consent", "This does not turn on GPS, nearby discovery or a live-user map. Mutual permission requires both friends.") {
                                    try await $0.futureLocation(friend.id, enabled: friend.locationFeaturesAllowed != true, expectedControlsRevision: capturedRevision)
                                }
                            }
                            .disabled(friend.locationFeaturesAllowed != true && locationRevision == nil && preferences?.socialLocationGlobalStopEnabled == true)
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
                    NavigationLink("My friend QR / Scan / Manual invite preview") { FriendInviteQRView() }
                    Text("Locally generated, revocable 15-minute links. Scanning/entry only previews a minimal authenticated inviter; a request needs another explicit action.").font(.caption)
                }
                NavigationLink("Blocked accounts") { CommunityBlocksView() }
                NavigationLink("Location-powered consent & timed sessions") { FriendLocationFeaturesView() }
                if community.config?.nearbyDiscoveryEnabled == true {
                    NavigationLink("Add friends / Look for friends") { NearbyDiscoveryView() }
                }
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
        .task(id: "\(phase):\(community.accountRevision)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !session.busy && pending == nil { load() }
            }
        }
        .onChange(of: phase) { _, value in
            badgesVerified = false
            if value == .active && !session.busy { load() }
        }
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
        badgesVerified = false
        session.run { client in
            let profile = try await client.preferences()
            let list = try await client.friends(page: page)
            let pending = try await client.requests(page: requestPage)
            try session.checked(client)
            preferences = profile; friends = list.friends; requests = pending
            locationRevision = list.locationControlsRevision ?? profile.locationControlsRevision
            badgesVerified = phase == .active
            if !profileDirty {
                name = profile.profile.displayName; discoverable = profile.discoverable; allowRequests = profile.allowRequests
            }
        }
    }
    private func clear() { preferences = nil; friends = []; requests = nil; invite = nil; token = ""; pending = nil; name = ""; target = ""; profileDirty = false; badgesVerified = false }
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
            if !community.avatarPolicyChanging, community.config?.avatarsEnabled == true, person.avatarMasked != true,
               (person.avatarMature != true || community.user?.allowMature == true), let preview = person.avatarPreviewUrl {
                let permitted = community.user?.mediaPreferences?.permitsAnimation(reducedMotion: reducedMotion, manual: manual) ?? (!reducedMotion || manual)
                let url = person.avatarAnimated == true && permitted ? (person.avatarUrl ?? preview) : preview
                GIFThumbnail(key: "avatar:\(client.instanceID):\(community.avatarPolicyRevision):\(url)", cache: false) { try await client.avatarMedia(url) }
                    .clipShape(Circle())
                if person.avatarAnimated == true && (reducedMotion || community.user?.mediaPreferences?.animationsEnabled == false || community.user?.mediaPreferences?.dataSaving == true) {
                    Button(manual ? "Pause avatar" : "Play avatar") { manual.toggle() }.font(.caption2)
                }
            } else { Text(String(person.displayName.prefix(1))).font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary, in: Circle()) }
        }.accessibilityLabel("\(person.displayName) avatar")
            .onChange(of: community.avatarPolicyRevision) { _, _ in manual = false }
            .onChange(of: community.user?.mediaPreferences) { _, _ in manual = false }
    }
}

@MainActor
struct CommunityAvatarView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = CommunityFeatureSession()
    @State private var owned: OwnedAvatarState?
    private var avatar: SocialAvatar? { owned?.avatar }
    @State private var consent = false
    @State private var picking = false
    @State private var pickerScope: UUID?
    @State private var pickerVersion: UUID?
    @State private var deleting = false
    @State private var deleteScope: UUID?
    @State private var deleteVersion: UUID?
    @State private var retryVersion: UUID?
    @State private var retryScope: UUID?
    @State private var selection: NativeAvatarSelection?
    @State private var crop = NativeAvatarCrop()
    @State private var cropping = false
    @State private var preview: CGImage?
    @State private var previewSelection: UUID?
    @State private var previewCrop: NativeAvatarCrop?
    @State private var selectionFailure: String?
    private var uploadReady: Bool {
        session.client?.automaticAvatarUploads == true && owned?.approvalMode == "ai" && owned?.uploadsEnabled == true
    }
    var body: some View {
        Form {
            if community.config?.avatarsEnabled == true && community.signedIn && !session.denied &&
                session.client?.accountID == community.user?.id {
                if let client = session.client, let avatar {
                    CommunityProfileAvatar(person: SocialPerson(id: avatar.userId,
                        displayName: community.user?.displayName ?? "Your profile", avatarUrl: avatar.avatarUrl,
                        avatarPreviewUrl: avatar.avatarPreviewUrl, avatarAnimated: avatar.avatarAnimated,
                        avatarMature: avatar.avatarMature, avatarMasked: avatar.avatarMasked),
                        client: client).frame(width: 128, height: 128)
                    LabeledContent("Review status", value: avatar.status)
                    if avatar.approvalMode == "ai" {
                        LabeledContent("Automatic screening", value: avatar.aiState ?? "Unavailable")
                        if let error = avatar.aiError, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    if avatar.avatarMasked == true { Text("Mature avatar hidden by your content preference.").font(.caption) }
                    if avatar.status == "pending", avatar.aiState == "failed" {
                        Button("Retry this avatar's screening") {
                            retryVersion = avatar.version; retryScope = session.client?.instanceID
                        }.disabled(session.busy || !uploadReady)
                    }
                }
                if avatar == nil && !session.busy { Text("Default profile avatar") }
                Toggle("I have permission and consent to automatic public-profile screening", isOn: $consent)
                Text("This is not private cloud backup. PNG/JPEG/WebP stills or GIFs, up to 5 MB. Allowed art publishes after automatic screening; uncertain/mature art is filtered by content preferences and prohibited imagery is blocked.")
                    .font(.caption).foregroundStyle(.secondary)
                if !uploadReady { Text("Uploads/retry are unavailable until this server advertises configured automatic screening. There is no manual-approval fallback.").font(.caption).foregroundStyle(.secondary) }
                Button("Choose avatar image or GIF") { pickerScope = session.client?.instanceID; pickerVersion = avatar?.version; picking = true }
                    .disabled(!consent || session.busy || !uploadReady)
                if let selection {
                    Section("Selected file — not uploaded") {
                        Text("Preview is the oriented first still only. Original immutable bytes and crop metadata are sent; every-frame timing, repeat and transparency remain server-controlled. No local original is rewritten.")
                            .font(.caption)
                        if owned?.cropsEnabled == true && community.config?.avatarCropsEnabled == true {
                            Toggle("Purposeful percentage crop", isOn: $cropping)
                            if cropping {
                                Stepper("Left \(crop.leftPercent)%", value: $crop.leftPercent, in: 0...99)
                                Stepper("Top \(crop.topPercent)%", value: $crop.topPercent, in: 0...99)
                                Stepper("Width \(crop.widthPercent)%", value: $crop.widthPercent, in: 1...100)
                                Stepper("Height \(crop.heightPercent)%", value: $crop.heightPercent, in: 1...100)
                            }
                        }
                        Button("Preview this exact file and crop") {
                            do {
                                let value = cropping ? crop : nil
                                preview = try selection.preview(crop: value)
                                previewSelection = selection.id; previewCrop = value; selectionFailure = nil
                            } catch { clearPreview(); selectionFailure = error.localizedDescription }
                        }
                        if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(height: 180) }
                        Button(avatar == nil ? "Upload previewed avatar" : "Replace avatar with previewed file") {
                            let selectedCrop = cropping ? crop : nil
                            guard previewSelection == selection.id, previewCrop == selectedCrop else { return }
                            session.run(expected: selection.scope, { client in
                                try await client.uploadAvatar(selection.bytes, publicConsent: consent,
                                    expectedVersion: selection.expectedVersion, crop: selectedCrop)
                            }, success: { self.selection = nil; clearPreview(); consent = false; load() })
                        }.disabled(!consent || session.busy || !uploadReady || previewSelection != selection.id || previewCrop != (cropping ? crop : nil))
                        Button("Discard selection") { self.selection = nil; clearPreview() }
                    }
                }
                if let selectionFailure { Text(selectionFailure).foregroundStyle(.orange) }
                if let mature = community.user?.allowMature {
                    Toggle("Show mature avatars and community content", isOn: Binding(get: { community.user?.allowMature ?? mature },
                        set: { allowed in session.run { try await $0.setMaturePreference(allowed) } }))
                        .disabled(session.busy || community.avatarPolicyChanging)
                }
                Button("Refresh avatar", action: load).disabled(session.busy)
                Button("Remove avatar", role: .destructive) {
                    deleteScope = session.client?.instanceID; deleteVersion = avatar?.version; deleting = true
                }.disabled(avatar == nil || session.busy)
                if session.busy { ProgressView() }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            } else { Text(session.failure ?? "Avatars are not enabled by this server.") }
        }
        .modernScene().navigationTitle("Profile avatar")
        .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.avatarPolicyRevision):\(community.config?.avatarsEnabled == true):\(community.config?.avatarApprovalMode ?? ""):\(community.config?.avatarUploadsEnabled == true)") {
            owned = nil; consent = false; retryVersion = nil; selection = nil; clearPreview(); session.bind(community)
            if community.config?.avatarsEnabled == true { load() }
        }
        .onChange(of: crop) { _, _ in clearPreview() }
        .onChange(of: cropping) { _, _ in clearPreview() }
        .onChange(of: session.denied) { _, denied in if denied { owned = nil; consent = false; retryVersion = nil; selection = nil; clearPreview() } }
        .onDisappear { if !picking { session.clear(); owned = nil; consent = false; retryVersion = nil; selection = nil; clearPreview() } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .gif]) { result in
            do {
                let url = try result.get()
                guard let scope = pickerScope, session.client?.instanceID == scope else { throw BackpackError.invalid("Selection account changed.") }
                selection = try NativeAvatarSelection(url: url, expectedVersion: pickerVersion, scope: scope)
                crop = NativeAvatarCrop(); cropping = false; clearPreview(); selectionFailure = nil
            } catch { selection = nil; clearPreview(); selectionFailure = error.localizedDescription }
        }
        .confirmationDialog("Remove your profile avatar?", isPresented: $deleting) {
            Button("Remove avatar", role: .destructive) {
                let version = deleteVersion
                session.run(expected: deleteScope, { client in
                    guard try await client.ownedAvatar().avatar?.version == version else { throw BackpackError.invalid("Avatar changed. Refresh before removing it.") }
                    try await client.removeAvatar()
                }, success: { selection = nil; clearPreview(); load() })
            }
        }
        .confirmationDialog("Retry the displayed failed avatar?", isPresented: Binding(get: { retryVersion != nil },
            set: { if !$0 { retryVersion = nil } })) {
                if let version = retryVersion {
                    Button("Retry this version") {
                        session.run(expected: retryScope, { try await $0.retryAvatar(expectedVersion: version) },
                            success: { retryVersion = nil; load() })
                    }
                }
            } message: { Text("A replaced or no-longer-failed avatar is not retried automatically. Refresh on conflict.") }
    }
    private func load() {
        session.run { client in let value = try await client.ownedAvatar(); try session.checked(client); owned = value }
    }
    private func clearPreview() { preview = nil; previewSelection = nil; previewCrop = nil }
}
