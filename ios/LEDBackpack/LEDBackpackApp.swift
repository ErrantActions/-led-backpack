import SwiftUI
import BackpackProtocol

@MainActor
final class AppModel: ObservableObject {
    let link: BluetoothLink
    let panel: PanelController
    let sensors: LiveSensors
    let live: LiveEngine
    let playlist: PlaylistRunner
    let alerts = DisconnectAlerts()
    @Published var library: LocalLibrary?
    @Published var startupError: String?
    private var authenticatedPanelID: UUID?

    init() {
        let link = BluetoothLink()
        let panel = PanelController(link: link)
        let sensors = LiveSensors()
        self.link = link; self.panel = panel; self.sensors = sensors
        live = LiveEngine(panel: panel, sensors: sensors)
        playlist = PlaylistRunner(panel: panel)
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
            self?.panel.monitorUnavailable("Disconnected. Physical display state is unknown.")
        }
        panel.previewProvider = { [weak self] slot in
            guard let self, let key = self.panel.identity?.serial,
                  let record = self.panel.slots.first(where: { $0.id == slot }) else { return nil }
            return try self.library?.cachedSlot(panel: key, slot: slot, identifier: record.identifier)
        }
        link.onEstablishedDrop = { [weak self] name in
            guard let self, library?.state.preferences.disconnectAlerts == true else { return }
            do { try await alerts.disconnected(name) } catch { panel.report(error) }
        }
    }

    func loadLibrary() {
        do {
            let value = try LocalLibrary()
            library = value; startupError = nil
            apply(value.state.preferences)
        } catch { startupError = error.localizedDescription }
    }

    func apply(_ value: Preferences) {
        live.preferences = value
        live.themes = library?.state.liveThemes ?? [:]
        link.autoReconnect = value.reconnect
        link.systemDisconnectAlerts = value.disconnectAlerts
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() } catch { panel.report(error) }
        }
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
                app.live.setBackground(value == .background)
                if value == .background { Task { await app.playlist.stop() } }
            }
        }
    }
}
