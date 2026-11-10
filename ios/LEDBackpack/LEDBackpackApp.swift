import SwiftUI
import AuthenticationServices
import BackpackProtocol

enum AppTab: Hashable { case backpack, library, create, live, social }

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab = AppTab.library
    let link: BluetoothLink
    let panel: PanelController
    let sensors: LiveSensors
    let live: LiveEngine
    let playlist: PlaylistRunner
    let drawing: DrawingLivePreview
    let batch: BatchTransferQueue
    let alerts = DisconnectAlerts()
    let community: CommunityController
    let cloudVault = CloudVaultStore()
    let phoneDisplay = PhoneDisplayController()
    let phoneOriginals = PhoneArtworkLibrary()
    let displayTargets = DisplayTargetSelection()
    let swapRecovery = SwapRecoveryStore()
    let phoneSwapGame = PhoneSwapGame()
    let friendPhoneInteractions = FriendPhoneInteractionStore()
    let scopedGlobalPhone = ScopedGlobalPhone()
    let localPairedGame = LocalPairedGame()
    let applePush = NativeApplePushCoordinator()
    let checkpointLocation = ForegroundCheckpointLocation()
    let nearbyDiscovery = NearbyDiscoveryCoordinator()
    let soloScenes = SoloSceneController()
    @Published var library: LocalLibrary?
    @Published var startupError: String?
    @Published private(set) var applyingSceneID: UUID?
    @Published private(set) var sceneStatus: String?
    private var backgrounded = false
    private var authenticatedPanelID: UUID?

    init() {
        let link = BluetoothLink()
        let panel = PanelController(link: link)
        let sensors = LiveSensors()
        self.link = link; self.panel = panel; self.sensors = sensors
        live = LiveEngine(panel: panel, sensors: sensors)
        playlist = PlaylistRunner(panel: panel)
        drawing = DrawingLivePreview(panel: panel)
        batch = BatchTransferQueue(panel: panel)
        #if DEBUG
        community = ProcessInfo.processInfo.arguments.contains("--library-ui-fixture")
            ? LibraryPreviewFixture.community() : CommunityController()
        #else
        community = CommunityController()
        #endif
        loadLibrary()
        applePush.bind(community)
        phoneSwapGame.bind(phone: phoneDisplay, targets: displayTargets, community: community)
        friendPhoneInteractions.bind(phone: phoneDisplay, targets: displayTargets, community: community)
        scopedGlobalPhone.bind(phone: phoneDisplay, targets: displayTargets, community: community)
        localPairedGame.bind(phone: phoneDisplay, targets: displayTargets)
        soloScenes.bind(phone: phoneDisplay, targets: displayTargets)
        phoneDisplay.manualPresentationWillChange = { [weak self] in
            self?.soloScenes.policyChanged()
            if self?.scopedGlobalPhone.arming == true || self?.scopedGlobalPhone.session.running == true || self?.scopedGlobalPhone.session.busy == true { self?.scopedGlobalPhone.stop("Manual PHONE presentation changed") }
            if self?.localPairedGame.arming == true || self?.localPairedGame.session.running == true || self?.localPairedGame.session.busy == true { self?.localPairedGame.stop("Manual PHONE presentation changed") }
        }
        phoneDisplay.manualSelectionWillChange = { [weak self] in
            if self?.localPairedGame.arming == true || self?.localPairedGame.session.running == true || self?.localPairedGame.session.busy == true { self?.localPairedGame.stop("Manual PHONE choice/visibility changed — local recovery retained") }
            if self?.scopedGlobalPhone.arming == true || self?.scopedGlobalPhone.session.running == true || self?.scopedGlobalPhone.session.busy == true { self?.scopedGlobalPhone.stop("Manual PHONE selection/visibility changed — scoped recovery retained") }
            self?.soloScenes.manualPhoneChange()
            if self?.phoneSwapGame.enabled == true || self?.phoneSwapGame.busy == true { self?.phoneSwapGame.stop(reason: "Manual phone change/close — original recovery retained; no overwrite") }
            if self?.friendPhoneInteractions.engine?.enabled == true || self?.friendPhoneInteractions.engine?.busy == true {
                self?.friendPhoneInteractions.stop("Manual phone change/close — original retained, no overwrite")
            }
        }
        phoneDisplay.peerPlaybackPolicyChanged = { [weak self] in
            if self?.phoneSwapGame.enabled == true || self?.phoneSwapGame.busy == true {
                self?.phoneSwapGame.stop(reason: "Phone play/pause/motion policy changed — explicit game rearm required")
            }
            if self?.localPairedGame.arming == true || self?.localPairedGame.session.running == true || self?.localPairedGame.session.busy == true { self?.localPairedGame.stop("PHONE playback policy changed — no paired resume") }
            if self?.scopedGlobalPhone.arming == true || self?.scopedGlobalPhone.session.running == true || self?.scopedGlobalPhone.session.busy == true { self?.scopedGlobalPhone.stop("PHONE playback policy changed — explicit rearm required") }
            self?.soloScenes.policyChanged()
            if self?.friendPhoneInteractions.engine?.enabled == true || self?.friendPhoneInteractions.engine?.busy == true {
                self?.friendPhoneInteractions.stop("Phone play/motion/data-saving policy changed — no silent resume")
            }
        }
        community.stopPhoneSwapGame = { [weak self] in
            self?.phoneSwapGame.stop(reason: "Account/friend permission changed")
            self?.friendPhoneInteractions.stop("Account/friend permission changed")
        }
        community.stopLocalLocationFeatures = { [weak self] in
            self?.soloScenes.stop("Global Stop all / local location context changed — no restart")
            self?.checkpointLocation.stop("Account/friend/permission changed — no restart")
            self?.live.suspendLocationFeatures()
            self?.nearbyDiscovery.stop("Account/friend/location controls changed")
            self?.phoneSwapGame.stop(reason: "Global location/friend controls stopped")
            self?.scopedGlobalPhone.stop("Global Stop all")
            self?.localPairedGame.stop("Global Stop all")
            self?.friendPhoneInteractions.stop("Global friend/location controls stopped — no restart")
        }
        checkpointLocation.stoppedForPermissionChange = { [weak self] in
            guard let self, self.community.signedIn else { return }
            let controller = self.community
            do {
                let client = try CommunityFeatureClient(controller)
                Task {
                    do { _ = try await client.stopAllServiceLocation() }
                    catch { controller.reportLocationStopFailure(error) }
                }
            } catch { controller.reportLocationStopFailure(error) }
        }
        alerts.nativeAppleActivity = { id in NativeApplePushEvents.shared.tapped(id) }
        link.onReady = { [weak self] in
            guard let self else { return }
            do {
                if let id = link.selectedID, authenticatedPanelID != id {
                    panel.password = try PanelSecrets.read(id); authenticatedPanelID = id
                }
                try await panel.refresh()
            } catch { panel.report(error) }
        }
        link.onDisconnect = { [weak self] in
            self?.live.connectionLost(); self?.playlist.connectionLost()
            self?.drawing.connectionLost(); self?.batch.connectionLost()
            self?.panel.monitorUnavailable("Disconnected. Physical display state is unknown.")
        }
        link.onLiveError = { [weak self] error in
            self?.panel.report(error)
            self?.live.connectionLost(); self?.drawing.connectionLost()
        }
        panel.previewProvider = { [weak self] slot in
            guard let self, self.link.connected, self.panel.inventoryDeviceID != nil,
                  self.panel.inventoryDeviceID == self.link.selectedID, let key = self.panel.identity?.serial,
                  let record = self.panel.slots.first(where: { $0.id == slot && $0.occupied }) else { return nil }
            return try self.library?.cachedSlot(panel: key, slot: slot, identifier: record.identifier)
        }
        link.onEstablishedDrop = { [weak self] name in
            guard let self, library?.state.preferences.disconnectAlerts == true else { return }
            do { try await alerts.disconnected(name) } catch { panel.report(error) }
        }
    }

    func loadLibrary() {
        do {
            let value: LocalLibrary
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--library-ui-fixture") { value = try LibraryPreviewFixture.make() }
            else { value = try LocalLibrary() }
            #else
            value = try LocalLibrary()
            #endif
            library = value; startupError = nil
            apply(value.state.preferences)
        } catch { startupError = error.localizedDescription }
    }

    func apply(_ value: Preferences) {
        live.preferences = value
        live.themes = library?.state.liveThemes ?? [:]
        link.autoReconnect = value.reconnect
        link.systemDisconnectAlerts = value.disconnectAlerts
        community.configure(value.effectiveCommunityURL)
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                guard applyingSceneID == nil else { throw BackpackError.invalid("Wait for the scene to finish applying.") }
                try await operation()
            } catch { panel.report(error) }
        }
    }

    func applyScene(_ scene: SavedScene) async throws {
        try scene.validate()
        guard !backgrounded, applyingSceneID == nil, link.connected, !panel.busy, !batch.running else {
            throw BackpackError.invalid("Connect first and finish the current operation before applying a scene.")
        }
        switch scene.content {
        case .live:
            guard panel.size != nil else { throw BackpackError.invalid("Refresh panel dimensions first.") }
        case .playlist(let id, let slots, _, _):
            guard panel.identity?.serial == id else {
                throw BackpackError.invalid("This playlist scene belongs to a different backpack.")
            }
            guard panel.slots.count == 60,
                  slots.allSatisfy({ slot in panel.slots.contains { $0.id == slot && $0.occupied } }) else {
                throw BackpackError.invalid("Refresh storage and confirm every scene slot still contains artwork.")
            }
        }
        applyingSceneID = scene.id
        sceneStatus = "Applying \(scene.name)..."
        defer { applyingSceneID = nil }
        do {
            await live.stop()
            await playlist.stop()
            await drawing.stop()
            guard !backgrounded, link.connected, !panel.busy, !panel.hasDisplayOwner else {
                throw BackpackError.invalid("Could not release the previous display session.")
            }
            try await panel.brightness(scene.brightness)
            switch scene.content {
            case .live(let mode, let theme, let message):
                try await live.start(mode, theme: theme, message: message)
            case .playlist(_, let slots, let durations, let repeats):
                if durations != nil {
                    let value = SavedPlaylist(name: scene.name, slots: slots, durations: durations)
                    try await playlist.start(value, repeatPlaylist: repeats)
                } else {
                    try await panel.play(list: slots)
                }
            }
            if backgrounded {
                await live.stop()
                await playlist.stop()
                throw BackpackError.invalid("Scene startup was interrupted when the app entered the background.")
            }
            sceneStatus = "Applied \(scene.name)."
        } catch {
            let detail = "Scene not applied. The previous live/timed session was stopped; brightness may have changed."
            sceneStatus = detail
            throw BackpackError.invalid("\(detail) \(error.localizedDescription)")
        }
    }

    func setBackground(_ value: Bool) {
        backgrounded = value
        drawing.setBackground(value)
        batch.setBackground(value)
        live.setBackground(value)
        if value { Task { await playlist.stop() } }
    }

    func connect(_ id: UUID) async throws {
        if authenticatedPanelID != id {
            panel.password = try PanelSecrets.read(id); authenticatedPanelID = id
        }
        if library?.state.preferences.disconnectAlerts == true {
            let granted = try await alerts.request()
            if !granted {
                panel.report(BackpackError.invalid("Notifications are disabled; connection alerts cannot be guaranteed."))
            }
        }
        try link.connect(id)
    }

    func rememberPassword() throws {
        guard let id = link.selectedID else { throw BackpackError.invalid("Connect to a panel first.") }
        try PanelSecrets.save(panel.rememberPassword ? panel.password : "", id: id)
    }
}

@main
@MainActor
struct LEDBackpackApp: App {
    @UIApplicationDelegateAdaptor(NativeApplePushAppDelegate.self) private var nativeDelegate
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let library = app.library {
                    RootView()
                        .environmentObject(app).environmentObject(app.link).environmentObject(app.panel)
                        .environmentObject(app.live).environmentObject(app.sensors).environmentObject(library)
                        .environmentObject(app.playlist)
                        .environmentObject(app.drawing).environmentObject(app.batch)
                        .environmentObject(app.community)
                        .environmentObject(app.cloudVault)
                        .environmentObject(app.phoneDisplay)
                        .environmentObject(app.phoneOriginals).environmentObject(app.displayTargets)
                        .environmentObject(app.swapRecovery)
                        .environmentObject(app.phoneSwapGame)
                        .environmentObject(app.friendPhoneInteractions)
                        .environmentObject(app.scopedGlobalPhone)
                        .environmentObject(app.localPairedGame)
                        .environmentObject(app.applePush)
                        .environmentObject(app.checkpointLocation)
                        .environmentObject(app.nearbyDiscovery)
                        .environmentObject(app.soloScenes)
                } else {
                    ContentUnavailableView {
                        Label("Library unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(app.startupError ?? "Could not load local data. Existing files have not been reset.")
                    } actions: {
                        Button("Retry") { app.loadLibrary() }
                    }
                }
            }
            .tint(Aurora.mint)
            .onChange(of: scenePhase) { _, value in
                app.link.setScanActivity(active: value == .active, backgrounded: value == .background)
                app.soloScenes.setForeground(value == .active)
                app.setBackground(value == .background)
                app.phoneDisplay.setForeground(value == .active)
                if value != .active { app.checkpointLocation.stop("Foreground left — no automatic restart") }
                if value != .active { app.nearbyDiscovery.stop("Foreground left — no automatic restart") }
                if value != .active { app.phoneSwapGame.stop(reason: "Background stopped game; recovery retained") }
                if value != .active { app.scopedGlobalPhone.stop("Foreground left — scoped PHONE stopped") }
                if value != .active { app.localPairedGame.stop("Foreground left — paired PHONE/radio/NI stopped") }
                if value != .active { app.friendPhoneInteractions.stop("Foreground left — friend radio/key/playback stopped; recovery retained") }
                if value == .background { app.cloudVault.stopWork() }
                if value == .active, let library = app.library { app.cloudVault.requestSynchronization(library) }
                if value == .active { Task { do { try await app.community.checkAppleCredentialState() } catch { app.panel.report(error) } } }
                if value == .active && app.community.nativeApplePushAvailable { app.applePush.refresh() }
            }
            .task {
                app.link.setScanActivity(active: scenePhase == .active, backgrounded: scenePhase == .background)
                app.soloScenes.setForeground(scenePhase == .active)
                app.phoneDisplay.setForeground(scenePhase == .active)
                do { try await app.community.checkAppleCredentialState() } catch { app.panel.report(error) }
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                Task { do { try await app.community.checkAppleCredentialState() } catch { app.panel.report(error) } }
            }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.applePush.bind(app.community) }
            .onReceive(app.community.$user) { user in
                app.phoneDisplay.setViewerAutomaticPlaybackAllowed(
                    user?.mediaPreferences?.permitsAnimation(reducedMotion: false, manual: false) ?? true)
            }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.checkpointLocation.stop("Account changed — no restart") }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.nearbyDiscovery.stop("Account changed — no restart") }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.phoneSwapGame.stop(reason: "Account changed — game off") }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.friendPhoneInteractions.accountChanged() }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.scopedGlobalPhone.stop("Account changed — scoped PHONE stopped") }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.localPairedGame.stop("Account context changed — local pair stopped") }
            .onReceive(app.community.$accountRevision.dropFirst()) { _ in app.soloScenes.stop("Account changed — account-free authoring retained, automation off") }
            .onReceive(app.community.$nativeIntegrityRevision.dropFirst()) { _ in app.applePush.bind(app.community) }
            .onReceive(app.displayTargets.$target.dropFirst()) { value in
                app.soloScenes.stop("Display target context changed — no automatic restart or hardware fallback")
                if value != .phone {
                    app.scopedGlobalPhone.stop("Target changed — no scoped hardware playback")
                    app.localPairedGame.stop("Target changed — paired hardware recovery unsupported")
                    app.phoneSwapGame.stop(reason: "Phone target left — no hardware exchange")
                    app.friendPhoneInteractions.stop("Phone target left — no hardware friend scene")
                }
            }
            .onReceive(NativeApplePushEvents.shared.$activity) { value in
                if let value { app.applePush.resolve(value); NativeApplePushEvents.shared.clearActivity() }
            }
            .onReceive(NativeApplePushEvents.shared.$token.dropFirst()) { value in
                if value != nil && scenePhase == .active && app.community.nativeApplePushAvailable { app.applePush.refresh() }
            }
        }
    }
}
