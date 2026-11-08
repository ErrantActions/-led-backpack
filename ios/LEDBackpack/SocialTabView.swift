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
enum SocialPrimaryRoute: String, CaseIterable, Identifiable, Hashable {
    case friends, messages, events, games
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var feature: SocialFeature? {
        switch self {
        case .friends: return .friends
        case .messages: return .messages
        case .events: return .events
        case .games: return nil
        }
    }
    var symbol: String {
        switch self {
        case .friends: return "person.2"
        case .messages: return "bubble.left.and.bubble.right"
        case .events: return "calendar"
        case .games: return "gamecontroller"
        }
    }
    var subtitle: String {
        switch self {
        case .friends: return "Your people"
        case .messages: return "Chats & groups"
        case .events: return "Meet up & explore"
        case .games: return "GPS & nearby play"
        }
    }
    func available(_ config: CommunityConfig?, signedIn: Bool) -> Bool {
        feature?.available(config, signedIn: signedIn) ?? true
    }
}
private extension SocialFeature {
        var title: String {
            switch self {
            case .friends: return "Friends"
            case .invites: return "Invite or scan"
            case .nearby: return "Nearby people"
            case .friendSessions: return "Play with a friend"
            case .events: return "Events"
            case .playlists: return "Shared playlists"
            case .messages: return "Messages"
            case .messageRequests: return "Message requests"
            case .activity: return "Activity"
            case .gifSwap: return "GIF swap"
            case .avatar: return "Avatar"
            case .badges: return "My badges"
            case .deviceCards: return "Device cards"
            case .notifications: return "Notifications"
            case .appleAlerts: return "Device alerts"
            case .eventReports: return "Event reports"
            case .messageReports: return "Message reports"
            case .peerReports: return "Peer reports"
            }
        }
        var symbol: String {
            switch self {
            case .friends, .invites, .nearby: return "person.2"
            case .friendSessions, .gifSwap: return "gamecontroller"
            case .events: return "calendar"
            case .playlists: return "rectangle.stack"
            case .messages, .messageRequests: return "bubble.left.and.bubble.right"
            case .avatar: return "person.crop.circle"
            case .badges: return "rosette"
            case .deviceCards: return "iphone"
            case .notifications, .appleAlerts: return "bell"
            case .activity: return "tray"
            case .eventReports, .messageReports, .peerReports: return "flag"
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
    @State private var primaryRoute: SocialPrimaryRoute?
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
                    if !community.signedIn {
                        NavigationLink { CommunityAccountView() } label: {
                            FeatureRowLabel(title: "Sign in", symbol: "person.crop.circle", subtitle: "Friends, messages and events")
                        }.accessibilityLabel("Sign in for friends, events and messaging")
                    } else {
                        NavigationLink { CommunityAccountView() } label: {
                            FeatureRowLabel(title: community.user?.displayName ?? "Account", symbol: "person.crop.circle", subtitle: "Account & privacy")
                        }
                    }
                    if refreshing { ProgressView() }
                    if let failure { Text(failure).foregroundStyle(.orange) }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(SocialPrimaryRoute.allCases) { route in
                            let enabled = route.available(community.config, signedIn: community.signedIn)
                            Button { primaryRoute = route } label: {
                                FeatureCardLabel(title: route.title,
                                    subtitle: enabled ? route.subtitle : community.signedIn ? "Unavailable" : "Sign in",
                                    symbol: route.symbol)
                            }.buttonStyle(.borderless).disabled(!enabled)
                                .accessibilityIdentifier("social-primary-\(route.rawValue)")
                                .accessibilityLabel(route.title)
                        }
                    }.listRowBackground(Color.clear)
                }
                communitySection
                friendsSection
                communicationSection
                eventsSection
                gamesSection
                privacySection
                Section {
                    FeatureDetails("Availability & privacy") {
                        Text("Browsing does not start GPS, Bluetooth or sharing. Each feature asks for its own consent.")
                        Text("Public GIFs, local Favorites and offline pairing work without an account.")
                        Button("Refresh availability") { Task { await refresh() } }.disabled(refreshing)
                    }
                }
            }.modernScene().navigationTitle("Social")
                .task(id: community.accountRevision) { await refresh() }
                .navigationDestination(item: $primaryRoute) { route in
                    switch route {
                    case .friends: CommunitySocialView()
                    case .messages: CommunityMessagesView()
                    case .events: CommunityEventsView()
                    case .games: GPSGamesView()
                    }
                }
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
                .onChange(of: community.accountRevision) { _, _ in primaryRoute = nil; gallery = false; editor = nil; pendingEditor = nil; failure = nil }
                .onChange(of: community.avatarPolicyRevision) { _, _ in editor = nil; pendingEditor = nil }
                .onReceive(app.$selectedTab.dropFirst()) { tab in
                    if tab == .social { gallery = false; editor = nil; pendingEditor = nil }
                }
        }
    }
    private var communitySection: some View {
        Section("Artwork") {
            Button { gallery = true } label: { FeatureRowLabel(title: "Community GIFs", symbol: "square.grid.3x3") }
                .accessibilityLabel("Community GIF gallery")
            NavigationLink { CommunityFavoritesView() } label: { FeatureRowLabel(title: "Favorites", symbol: "heart") }
            NavigationLink { CommunityUploadsView() } label: { FeatureRowLabel(title: "My uploads", symbol: "square.and.arrow.up") }
                .disabled(!community.signedIn)
        }
    }
    private var friendsSection: some View {
        Section("People") {
            SocialLink("Add friends / QR / nearby", feature: .invites) { NearbyDiscoveryView() }
            SocialLink("Accepted-friend greetings / duet / pass sessions", feature: .friendSessions) { FriendLocationFeaturesView() }
            DisclosureGroup("Profile & devices") {
                SocialLink("Profile avatar", feature: .avatar) { CommunityAvatarView() }
                SocialLink("Private event badges / profile choices", feature: .badges) { EventAwardListView() }
                SocialLink("Device cards / accepted-friend transfers (unverified)", feature: .deviceCards) { AccountDevicesView() }
            }
        }
    }
    private var communicationSection: some View {
        Section("Inbox") {
            SocialLink("Nonfriend message requests", feature: .messageRequests) { CommunityMessageRequestsView() }
            SocialLink("Activity inbox", feature: .activity) { CommunityActivityView() }
            DisclosureGroup("Alerts & reminders") {
                SocialLink("Notifications / event reminders", feature: .notifications) { CommunityNotificationSettingsView() }
                SocialLink("Apple device alerts", feature: .appleAlerts) { NativeApplePushView() }
            }
        }
    }
    private var eventsSection: some View {
        Section("Share") {
            SocialLink("Private playlists / public snapshots", feature: .playlists) { OwnerPlaylistsView() }
        }
    }
    private var gamesSection: some View {
        Section("Nearby play") {
            SocialLink("Automatic PHONE GIF swap / Found Users", feature: .gifSwap) { PhoneSwapGameView() }
            NavigationLink { LocalPairedGameView() } label: { FeatureRowLabel(title: "Pair offline", symbol: "qrcode", subtitle: "Calm colors & optional ranging") }
            NavigationLink { SwapRecoveryView() } label: { FeatureRowLabel(title: "Received & recovery", symbol: "arrow.uturn.backward") }
        }
    }
    private var privacySection: some View {
        Section {
            DisclosureGroup("Safety & reports") {
                NavigationLink("Blocked accounts") { CommunityBlocksView() }.disabled(!community.signedIn)
                SocialLink("My event reports / withdrawal", feature: .eventReports) { OwnEventReportsView() }
                SocialLink("My message incidents", feature: .messageReports) { MessageIncidentListView() }
                SocialLink("My peer incidents / keyless withdrawal receipts", feature: .peerReports) { PeerIncidentOwnerView() }
            }
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
    let card: Bool
    let subtitle: String?
    let destination: () -> Destination
    init(_ title: String, feature: SocialFeature, card: Bool = false, subtitle: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title; self.feature = feature; self.card = card; self.subtitle = subtitle; self.destination = destination
    }
    var body: some View {
        let enabled = feature.available(community.config, signedIn: community.signedIn)
        NavigationLink {
            destination()
        } label: {
            if card {
                FeatureCardLabel(title: feature.title, subtitle: enabled ? (subtitle ?? "") : community.signedIn ? "Unavailable" : "Sign in",
                    symbol: feature.symbol)
            } else {
                FeatureRowLabel(title: feature.title, symbol: feature.symbol,
                    subtitle: enabled ? subtitle : community.signedIn ? "Unavailable" : "Sign in")
            }
        }.disabled(!enabled)
            .accessibilityLabel(title)
            .accessibilityHint(enabled ? "" : community.signedIn ? "Unavailable on this service" : "Sign in to use this feature")
            .accessibilityIdentifier("social-link-\(title)")
    }
}
