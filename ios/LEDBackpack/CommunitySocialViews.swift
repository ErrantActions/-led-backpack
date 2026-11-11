import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
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
                NavigationLink { NearbyDiscoveryView() } label: {
                    FeatureRowLabel(title: "Add friends", symbol: "person.badge.plus",
                        subtitle: "Scan an invitation or share your code")
                }
                DisclosureGroup("My profile") {
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
                            if preferences?.accountAwardsEnabled == true && badgesVerified {
                                AuthorizedProfileEventBadges(badges: friend.eventBadges ?? [])
                            }
                            Menu("Manage friendship") {
                            Button("Remove friend") {
                                confirm("Remove friend", "This revokes relationship permissions. It does not erase local artwork.") { try await $0.unfriend(friend.id) }
                            }
                            Button("Block contact", role: .destructive) {
                                confirm("Block contact", "Stops friendship, requests and related permissions. Unblocking does not restore them.") { try await $0.block(friend.id) }
                            }
                            }
                            FeatureDetails("Friend permissions") {
                            Text(friend.id.uuidString.lowercased()).textSelection(.enabled)
                            Button(friend.locationFeaturesAllowed == true ? "Revoke location consent" : "Allow future location features") {
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
                    }
                    if page > 1 || friends.count == 50 { HStack {
                        Button("Previous friends") { page -= 1; load() }.disabled(page <= 1)
                        Spacer()
                        Button("Next friends") { page += 1; load() }.disabled(friends.count < 50 || page >= 10000)
                    } }
                    if friends.isEmpty && !session.busy && session.failure == nil {
                        ContentUnavailableView("No friends yet", systemImage: "person.2", description: Text("Scan a friend's invitation to connect."))
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
                    if requestPage > 1 || (requests?.inbound.count ?? 0) + (requests?.outbound.count ?? 0) == 50 { HStack {
                        Button("Previous requests") { requestPage -= 1; load() }.disabled(requestPage <= 1)
                        Spacer()
                        Button("Next requests") { requestPage += 1; load() }
                            .disabled((requests?.inbound.count ?? 0) + (requests?.outbound.count ?? 0) < 50 || requestPage >= 10000)
                    } }
                    DisclosureGroup("Request by account ID") {
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
                    }
                }.disabled(session.busy)
                Section("Privacy & permissions") {
                    NavigationLink("Blocked accounts") { CommunityBlocksView() }
                    NavigationLink("Location consent & sessions") { FriendLocationFeaturesView() }
                }
                Button("Refresh friends and profile", action: load).disabled(session.busy)
            } else {
                Text(session.failure ?? "Friends are unavailable until this server enables the social capability.")
            }
        }
        .modernScene().navigationTitle("Friends & profile").buttonStyle(.borderless)
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
    @State private var showingPhotos = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importingPhoto = false
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
    @State private var boundContext: String?
    private var context: String {
        "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.avatarPolicyRevision):\(community.config?.avatarsEnabled == true):\(community.config?.avatarApprovalMode ?? ""):\(community.config?.avatarUploadsEnabled == true)"
    }
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
                Text("Choose a photo, review it, then confirm. Nothing uploads when you choose.")
                    .font(.caption).foregroundStyle(.secondary)
                if !uploadReady && !session.busy {
                    Text("Photo uploads are unavailable until automatic screening is configured.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Choose from Photos") { preparePicker(); showingPhotos = true }
                    .buttonStyle(AuroraPrimaryButton())
                    .disabled(session.busy || importingPhoto || !uploadReady)
                    .accessibilityIdentifier("avatar-choose-photos")
                Button("Choose from Files") { preparePicker(); picking = true }
                    .disabled(session.busy || importingPhoto || !uploadReady)
                    .accessibilityIdentifier("avatar-choose-file")
                if importingPhoto { ProgressView("Preparing photo...") }
                if let selection {
                    Section("Review your photo") {
                        if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(height: 180) }
                        if owned?.cropsEnabled == true && community.config?.avatarCropsEnabled == true {
                            Toggle("Crop photo", isOn: $cropping).disabled(session.busy || importingPhoto)
                            if cropping {
                                Stepper("Left \(crop.leftPercent)%", value: $crop.leftPercent, in: 0...99)
                                Stepper("Top \(crop.topPercent)%", value: $crop.topPercent, in: 0...99)
                                Stepper("Width \(crop.widthPercent)%", value: $crop.widthPercent, in: 1...100)
                                Stepper("Height \(crop.heightPercent)%", value: $crop.heightPercent, in: 1...100)
                            }
                        }
                        Text("Public profile photo, subject to automatic screening. This is not a private backup.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("I have permission and agree to public profile use and screening", isOn: $consent)
                            .disabled(session.busy || importingPhoto).accessibilityIdentifier("avatar-public-consent")
                        FeatureDetails("Photo & GIF details") {
                            Text("The preview shows the first still. PNG/JPEG/WebP/GIF files keep their bytes; HEIC photos use a prepared JPEG copy. Crop metadata applies to the reviewed copy. GIF timing and transparency remain server-controlled. Originals are unchanged.")
                        }.disabled(session.busy || importingPhoto)
                        Button("Discard selection") { self.selection = nil; clearPreview(); consent = false }
                            .disabled(session.busy || importingPhoto)
                    }.disabled(session.busy || importingPhoto)
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
        .modernScene().navigationTitle("Profile photo")
        .safeAreaInset(edge: .bottom) {
            if let selection {
                Button(avatar == nil ? "Upload profile photo" : "Replace profile photo") { upload(selection) }
                    .buttonStyle(AuroraPrimaryButton())
                    .disabled(!consent || session.busy || importingPhoto || !uploadReady ||
                        previewSelection != selection.id || previewCrop != (cropping ? crop : nil))
                    .padding(12).background(Aurora.surface).accessibilityIdentifier("avatar-upload")
            }
        }
        .task(id: context) {
            guard boundContext != context || session.client == nil else { return }
            owned = nil; consent = false; retryVersion = nil; selection = nil; selectedPhoto = nil; clearPreview(); session.bind(community)
            boundContext = context
            if community.config?.avatarsEnabled == true { load() }
        }
        .onChange(of: crop) { _, _ in updatePreview() }
        .onChange(of: cropping) { _, _ in updatePreview() }
        .onChange(of: session.denied) { _, denied in if denied { boundContext = nil; owned = nil; consent = false; retryVersion = nil; selection = nil; clearPreview() } }
        .onDisappear { if !picking && !showingPhotos { boundContext = nil; session.clear(); owned = nil; consent = false; retryVersion = nil; selection = nil; clearPreview() } }
        .photosPicker(isPresented: $showingPhotos, selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current)
        .task(id: selectedPhoto) {
            guard let item = selectedPhoto else { return }
            importingPhoto = true
            defer { importingPhoto = false }
            do {
                guard let scope = pickerScope, session.client?.instanceID == scope else {
                    throw BackpackError.invalid("Selection account changed. Choose the photo again.")
                }
                let version = pickerVersion
                guard let photo = try await item.loadTransferable(type: NativeAvatarPhoto.self) else {
                    throw BackpackError.invalid("Could not load this photo. Try choosing its image file.")
                }
                try Task.checkCancellation()
                guard session.client?.instanceID == scope else { throw BackpackError.invalid("Selection account changed.") }
                accept(try NativeAvatarSelection(bytes: photo.bytes, expectedVersion: version, scope: scope))
            } catch {
                if Task.isCancelled { return }
                selection = nil; clearPreview(); selectionFailure = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .gif]) { result in
            if case .failure(let error) = result,
               (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSUserCancelledError { return }
            do {
                let url = try result.get()
                guard let scope = pickerScope, session.client?.instanceID == scope else { throw BackpackError.invalid("Selection account changed.") }
                let photo = try NativeAvatarPhoto.read(url: url)
                accept(try NativeAvatarSelection(bytes: photo.bytes, expectedVersion: pickerVersion, scope: scope))
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
    private func preparePicker() {
        pickerScope = session.client?.instanceID; pickerVersion = avatar?.version
        selectedPhoto = nil; selectionFailure = nil
    }
    private func accept(_ value: NativeAvatarSelection) {
        selection = value; crop = NativeAvatarCrop(); cropping = false; consent = false
        updatePreview()
    }
    private func updatePreview() {
        guard let selection else { clearPreview(); return }
        do {
            let value = cropping ? crop : nil
            preview = try selection.preview(crop: value)
            previewSelection = selection.id; previewCrop = value; selectionFailure = nil
        } catch { clearPreview(); selectionFailure = error.localizedDescription }
    }
    private func upload(_ selection: NativeAvatarSelection) {
        let value = cropping ? crop : nil
        guard consent, previewSelection == selection.id, previewCrop == value else {
            selectionFailure = "Review this photo and confirm public-profile screening before uploading."
            return
        }
        session.run(expected: selection.scope, { client in
            try await client.uploadAvatar(selection.bytes, publicConsent: consent,
                expectedVersion: selection.expectedVersion, crop: value)
        }, success: { self.selection = nil; clearPreview(); consent = false; load() })
    }
    private func clearPreview() { preview = nil; previewSelection = nil; previewCrop = nil }
}
