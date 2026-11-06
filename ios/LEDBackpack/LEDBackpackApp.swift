import SwiftUI
import AuthenticationServices
import BackpackProtocol

enum AppTab: Hashable { case backpack, library, create, live }

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
            .preferredColorScheme(.dark)
            .tint(.cyan)
            .onChange(of: scenePhase) { _, value in
                app.setBackground(value == .background)
                app.phoneDisplay.setForeground(value == .active)
                if value == .background { app.cloudVault.stopWork() }
                if value == .active, let library = app.library { app.cloudVault.requestSynchronization(library) }
                if value == .active { Task { do { try await app.community.checkAppleCredentialState() } catch { app.panel.report(error) } } }
            }
            .task {
                app.phoneDisplay.setForeground(scenePhase == .active)
                do { try await app.community.checkAppleCredentialState() } catch { app.panel.report(error) }
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                Task { do { try await app.community.checkAppleCredentialState() } catch { app.panel.report(error) } }
            }
        }
    }
}
