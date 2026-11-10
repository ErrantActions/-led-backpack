import SwiftUI

@MainActor
struct BackpackMonitor: View {
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Now on backpack", systemImage: "display").font(.headline)
                Spacer()
                Text(link.connected ? "EXPECTED OUTPUT" : "OFFLINE").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let image = panel.monitorImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 18))
            } else if let data = panel.monitorGIF {
                AnimatedPreview(data: data).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                ContentUnavailableView("No readable pixels", systemImage: "eye.slash",
                    description: Text("Live frames sent by this app and its cached uploads can be previewed here."))
            }
            Text(panel.monitorCaption).font(.caption).foregroundStyle(.secondary)
            Text(BackpackPlaybackStatus.caption(panel.playback)).font(.caption.monospaced())
            Button("Read now-playing status") { Task { do { try await panel.refreshPlaybackStatus() } catch { panel.report(error) } } }
                .disabled(!link.connected || panel.busy || panel.hasDisplayOwner)
            FeatureDetails("What this preview can show") {
                Text("Expected output, not a camera or live screen readback. Timing, unknown stored artwork and changes made elsewhere may differ.")
            }
        }.padding(20).glassPanel()
        .task(id: "\(link.connected)-\(scenePhase)") {
            guard link.connected, scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                    if link.connected && !panel.busy && !panel.hasDisplayOwner { try await panel.refreshPlaybackStatus() }
                } catch {
                    if !Task.isCancelled { panel.report(error) }
                    return
                }
            }
        }
    }
}
