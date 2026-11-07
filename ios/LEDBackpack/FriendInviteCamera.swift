import SwiftUI
import AVFoundation
import BackpackProtocol

struct FriendCameraPolicy {
    private(set) var armed = false
    mutating func arm(explicitScan: Bool, foreground: Bool, usageDescription: String?, authorized: Bool) throws {
        armed = false
        guard explicitScan, foreground, authorized, let usageDescription,
              !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackpackError.invalid("Camera scanning unavailable, denied or not explicitly authorized. Manual link/token input remains available.")
        }
        armed = true
    }
    mutating func stop() { armed = false }
}
private final class FriendCameraWorker: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "catalog.friend.qr-camera")
    private let lock = NSLock()
    private var allowed = true
    private func enabled() -> Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func configure(delegate: AVCaptureMetadataOutputObjectsDelegate, failure: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            guard enabled() else { return }
            do {
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                      let camera = AVCaptureDevice.default(for: .video) else { throw BackpackError.invalid("Camera unavailable or permission withdrawn; use manual invitation input.") }
                let input = try AVCaptureDeviceInput(device: camera), output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration(); throw BackpackError.invalid("Camera QR metadata is unsupported; use manual input.")
                }
                session.addInput(input); session.addOutput(output)
                output.setMetadataObjectsDelegate(delegate, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    session.commitConfiguration(); throw BackpackError.invalid("QR decoding is unavailable; manual input remains available.")
                }
                output.metadataObjectTypes = [.qr]; session.commitConfiguration()
                guard enabled(), AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
                session.startRunning()
                if !enabled() { session.stopRunning() }
            } catch { failure(error.localizedDescription) }
        }
    }
    func stop() {
        lock.lock(); allowed = false; lock.unlock()
        queue.async { [self] in
            session.stopRunning()
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
    }
}
@MainActor
struct FriendInviteCamera: UIViewControllerRepresentable {
    let completed: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(completed: completed) }
    func updateUIViewController(_ controller: Controller, context: Context) {}
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }

    final class Controller: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let completed: (Result<String, Error>) -> Void
        private let worker = FriendCameraWorker()
        private var preview: AVCaptureVideoPreviewLayer?
        private var permission: Task<Void, Never>?
        private var monitoring: Task<Void, Never>?
        private var finished = false
        private var policy = FriendCameraPolicy()
        init(completed: @escaping (Result<String, Error>) -> Void) { self.completed = completed; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { return nil }
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: worker.session); layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer); preview = layer
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard permission == nil, !finished else { return }
            permission = Task {
                guard let text = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    finish(.failure(BackpackError.invalid("Camera usage declaration is missing. No permission request was made; enter the link/token manually."))); return
                }
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                guard status != .denied && status != .restricted else {
                    finish(.failure(BackpackError.invalid("Camera denied/restricted. Enable it in Settings if desired, or use manual invitation input."))); return
                }
                let allowed: Bool
                if status == .authorized { allowed = true }
                else { allowed = await AVCaptureDevice.requestAccess(for: .video) }
                guard !Task.isCancelled, !finished, viewIfLoaded?.window != nil else { return }
                do {
                    try policy.arm(explicitScan: true, foreground: UIApplication.shared.applicationState == .active, usageDescription: text, authorized: allowed)
                    worker.configure(delegate: self) { [weak self] message in
                        Task { @MainActor in self?.finish(.failure(BackpackError.invalid(message))) }
                    }
                    monitoring = Task { [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
                            guard let self else { return }
                            if UIApplication.shared.applicationState != .active || AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                                finish(.failure(BackpackError.invalid("Camera stopped after background/permission change. Press Scan explicitly to start again."))); return
                            }
                        }
                    }
                } catch { finish(.failure(error)) }
            }
        }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
        func stop() { finished = true; policy.stop(); permission?.cancel(); monitoring?.cancel(); worker.stop() }
        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let raw = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            Task { @MainActor [weak self] in
                guard let self, self.policy.armed else { return }
                guard raw.utf8.count <= 2400 else { self.finish(.failure(BackpackError.invalid("QR payload is too large for a friend invitation."))); return }
                self.finish(.success(raw))
            }
        }
        private func finish(_ result: Result<String, Error>) {
            guard !finished else { return }
            stop(); completed(result)
        }
    }
}
