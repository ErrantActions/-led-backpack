import Foundation
import Combine
import BackpackProtocol

struct DrawingPreviewScope: Equatable {
    let deviceID: UUID
    let serial: String
    let size: PanelSize
}

@MainActor
protocol DrawingPreviewBackend: AnyObject {
    var drawingPreviewScope: DrawingPreviewScope? { get }
    func beginLive() async throws
    func paintLive(_ frame: PixelFrame) async throws
    func endLive() async throws
    func abandonLivePreview(_ reason: String)
    func report(_ error: Error)
}

extension PanelController: DrawingPreviewBackend {
    var drawingPreviewScope: DrawingPreviewScope? {
        guard link.connected, let device = inventoryDeviceID, device == link.selectedID, let identity, let size else { return nil }
        return DrawingPreviewScope(deviceID: device, serial: identity.serial, size: size)
    }
}

@MainActor
final class DrawingLivePreview: ObservableObject {
    enum State: String { case idle = "Stopped", starting = "Starting", active = "Live drawing", stopping = "Restoring playback" }
    @Published private(set) var state = State.idle
    @Published private(set) var failure: String?
    private let panel: any DrawingPreviewBackend
    private var latest: PixelFrame?
    private var task: Task<Void, Never>?
    private var backgrounded = false
    var running: Bool { state != .idle }
    init(panel: any DrawingPreviewBackend) { self.panel = panel }

    func offer(_ frame: PixelFrame) { latest = frame }
    func start(_ frame: PixelFrame) throws {
        guard task == nil, !running, !backgrounded, let scope = panel.drawingPreviewScope,
              frame.size == scope.size, frame.rgb.count == scope.size.width * scope.size.height * 3 else {
            throw BackpackError.invalid("Connect and refresh the matching panel, stop other displays, and keep the drawing editor in the foreground.")
        }
        latest = frame; failure = nil; state = .starting
        task = Task {
            var acquired = false
            do {
                try Task.checkCancellation()
                try await panel.beginLive()
                acquired = true
                try Task.checkCancellation()
                guard !backgrounded, panel.drawingPreviewScope == scope else {
                    throw BackpackError.invalid("The drawing preview's device or foreground state changed.")
                }
                state = .active
                var sent: PixelFrame?
                while !Task.isCancelled {
                    guard !backgrounded, panel.drawingPreviewScope == scope, var frame = latest, frame.size == scope.size else {
                        throw BackpackError.invalid("The backpack or drawing dimensions changed. Live preview stopped.")
                    }
                    frame.exactLiveColors = true
                    if sent != frame {
                        try await panel.paintLive(frame)
                        sent = frame
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription; panel.report(error) }
            }
            state = .stopping
            if acquired {
                if panel.drawingPreviewScope != scope {
                    let message = "Live drawing lost its backpack connection. Stored playback restoration is unconfirmed; reconnect and choose a program."
                    panel.abandonLivePreview(message)
                    failure = message
                } else {
                    // Restoration must not inherit the canceled renderer's cancellation.
                    let restoration = Task { try await panel.endLive() }
                    do { try await restoration.value }
                    catch { failure = error.localizedDescription; panel.report(error) }
                }
            }
            latest = nil; task = nil; state = .idle
        }
    }
    func stop() async { state = task == nil ? .idle : .stopping; task?.cancel(); await task?.value }
    func connectionLost() { task?.cancel() }
    func setBackground(_ value: Bool) { backgrounded = value; if value { task?.cancel() } }
}
