import SwiftUI
import Combine
import BackpackProtocol

enum SocialFeature {
    case friends, invites, nearby, friendSessions, events, playlists, messages, messageRequests
    case activity, gifSwap, avatar, badges, deviceCards, notifications, appleAlerts
    case eventReports, messageReports, peerReports
    func available(_ config: CommunityConfig?, signedIn: Bool) -> Bool {
        guard signedIn else { return false }
        switch self {
        case .friends, .invites: return config?.socialEnabled == true
        case .nearby: return config?.socialEnabled == true && config?.nearbyDiscoveryEnabled == true
        case .friendSessions: return config?.socialEnabled == true && config?.friendSessionsAvailable == true
        case .events: return config?.eventsEnabled == true
        case .playlists: return config?.playlistsEnabled == true
        case .messages: return config?.messagingEnabled == true
        case .messageRequests: return config?.messagingEnabled == true && config?.chatMessageRequestsEnabled == true
        case .activity: return config?.notificationsEnabled == true
        case .gifSwap: return config?.gifSwapPresenceEnabled == true
        case .avatar: return config?.avatarsEnabled == true
        case .badges: return config?.socialEnabled == true
        case .deviceCards: return config?.unverifiedDeviceTagsEnabled == true
        case .notifications: return config?.notificationPreferencesEnabled == true
        case .appleAlerts: return config?.applePushEnabled == true
        case .eventReports: return config?.eventReportsEnabled == true
        case .messageReports: return config?.chatReportsEnabled == true
        case .peerReports: return config?.peerIncidentReportsEnabled == true || config?.peerIncidentWithdrawalEnabled == true
        }
    }
}
@MainActor
struct SocialTabView: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var app: AppModel
    @State private var gallery = false
    @State private var refreshing = false
    @State private var failure: String?
    @State private var pendingEditor: SocialGalleryCopy?
    @State private var editor: SocialGalleryCopy?
    private struct SocialGalleryCopy: Identifiable {
        let id = UUID()
        let data: Data
        let credit: Attribution
        let category: String?
        let title: String
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Friends, events, messages and games").font(.title2.bold())
                    if !community.signedIn {
                        NavigationLink("Sign in for friends, events and messaging") { CommunityAccountView() }
                        Text("Community GIF browsing, local Favorites and offline paired play do not require an account.").font(.caption)
                    } else {
                        NavigationLink("Account / sign out / privacy settings") { CommunityAccountView() }
                    }
                    Text("Browsing never enables GPS, Bluetooth discovery, sharing or a game. Every feature retains its own current service/account/permission and explicit consent checks.").font(.caption)
                    if refreshing { ProgressView("Refreshing service availability") }
                    if let failure { Text(failure).foregroundStyle(.orange) }
                    Button("Refresh actual service capabilities") { Task { await refresh() } }.disabled(refreshing)
                }
                communitySection
                friendsSection
                communicationSection
                eventsSection
                gamesSection
                privacySection
            }.modernScene().navigationTitle("Social")
                .task(id: community.accountRevision) { await refresh() }
                .sheet(isPresented: $gallery, onDismiss: {
                    if let copy = pendingEditor { pendingEditor = nil; editor = copy }
                }) {
                    CommunityGallery { data, credit, category, title in
                        pendingEditor = .init(data: data, credit: credit, category: category, title: title)
                        gallery = false
                    }
                }
                .sheet(item: $editor) { copy in
                    MediaEditor(data: copy.data, attribution: copy.credit, category: copy.category, initialName: copy.title)
                }
                .onChange(of: community.accountRevision) { _, _ in gallery = false; editor = nil; pendingEditor = nil; failure = nil }
                .onChange(of: community.avatarPolicyRevision) { _, _ in editor = nil; pendingEditor = nil }
                .onReceive(app.$selectedTab.dropFirst()) { tab in
                    if tab == .social { gallery = false; editor = nil; pendingEditor = nil }
                }
        }
    }
    private var communitySection: some View {
        Section("Community artwork") {
            Button { gallery = true } label: { Label("Community GIF gallery", systemImage: "square.grid.3x3") }
            NavigationLink("My Favorites") { CommunityFavoritesView() }
            NavigationLink("My community uploads / review status") { CommunityUploadsView() }.disabled(!community.signedIn)
        }
    }
    private var friendsSection: some View {
        Section("Friends & profile") {
            SocialLink("Friends / requests / profile", feature: .friends) { CommunitySocialView() }
            SocialLink("My friend QR / Scan / invite preview", feature: .invites) { FriendInviteQRView() }
            SocialLink("Nearby discovery / add friends", feature: .nearby) { NearbyDiscoveryView() }
            SocialLink("Accepted-friend greetings / duet / pass sessions", feature: .friendSessions) { FriendLocationFeaturesView() }
            SocialLink("Profile avatar", feature: .avatar) { CommunityAvatarView() }
            SocialLink("Private event badges / profile choices", feature: .badges) { EventAwardListView() }
            SocialLink("Device cards / accepted-friend transfers (unverified)", feature: .deviceCards) { AccountDevicesView() }
        }
    }
    private var communicationSection: some View {
        Section("Messages & activity") {
            SocialLink("Messages / groups / event conversations", feature: .messages) { CommunityMessagesView() }
            SocialLink("Nonfriend message requests", feature: .messageRequests) { CommunityMessageRequestsView() }
            SocialLink("Activity inbox", feature: .activity) { CommunityActivityView() }
            SocialLink("Notifications / event reminders", feature: .notifications) { CommunityNotificationSettingsView() }
            SocialLink("Apple device alerts", feature: .appleAlerts) { NativeApplePushView() }
        }
    }
    private var eventsSection: some View {
        Section("Events & shared experiences") {
            SocialLink("Events / create / rides / GPS hunts", feature: .events) { CommunityEventsView() }
            SocialLink("Private playlists / public snapshots", feature: .playlists) { OwnerPlaylistsView() }
            Text("Event tools include current invitations, organizers, route/checkpoints, private hunt/co-op, guestbook, recap and reviewed display plans. Participation and sharing remain separate.").font(.caption)
        }
    }
    private var gamesSection: some View {
        Section("Games & exchanges — separate opt-ins") {
            NavigationLink("GPS & nearby games") { GPSGamesView() }
            SocialLink("Automatic PHONE GIF swap / Found Users", feature: .gifSwap) { PhoneSwapGameView() }
            NavigationLink("Offline paired calm colors / optional NI") { LocalPairedGameView() }
            NavigationLink("Received swaps / original recovery") { SwapRecoveryView() }
            Text("PHONE swap is built; actual two-phone proof remains separate. Unknown backpack originals cannot be safely recovered for automatic hardware swaps.").font(.caption)
        }
    }
    private var privacySection: some View {
        Section("Safety & own reports") {
            NavigationLink("Blocked accounts") { CommunityBlocksView() }.disabled(!community.signedIn)
            SocialLink("My event reports / withdrawal", feature: .eventReports) { OwnEventReportsView() }
            SocialLink("My message incidents", feature: .messageReports) { MessageIncidentListView() }
            SocialLink("My peer incidents / keyless withdrawal receipts", feature: .peerReports) { PeerIncidentOwnerView() }
            if community.isAdmin {
                NavigationLink("Administration / incident review") { CommunityAdminView() }
            }
        }
    }
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do { try await community.loadConfig(); try Task.checkCancellation(); failure = nil }
        catch { if !(error is CancellationError) { failure = error.localizedDescription } }
    }
}
@MainActor
private struct SocialLink<Destination: View>: View {
    @EnvironmentObject private var community: CommunityController
    let title: String
    let feature: SocialFeature
    let destination: () -> Destination
    init(_ title: String, feature: SocialFeature, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title; self.feature = feature; self.destination = destination
    }
    var body: some View {
        let enabled = feature.available(community.config, signedIn: community.signedIn)
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if !enabled { Text(community.signedIn ? "Unavailable" : "Sign in").font(.caption).foregroundStyle(.secondary) }
            }
        }.disabled(!enabled)
            .accessibilityIdentifier("social-link-\(title)")
    }
}
