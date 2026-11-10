import SwiftUI
import CoreImage.CIFilterBuiltins
@preconcurrency import AVFoundation
import BackpackProtocol

@MainActor
struct CloudVaultAdoptionView: View {
    @EnvironmentObject private var vault: CloudVaultStore
    @EnvironmentObject private var community: CommunityController
    @State private var failure: String?
    @State private var image: UIImage?
    var body: some View {
        Form {
            Text("Sign in to the same account on both devices. An already unlocked trusted device scans this public code and explicitly approves it. No password or library key is in the QR.")
            if let adoption = vault.adoption {
                if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxHeight: 300).padding().background(.white) }
                LabeledContent("Account", value: community.user?.email ?? adoption.accountId)
                LabeledContent("Server", value: adoption.origin)
                LabeledContent("Status", value: adoption.state)
                Text("Expires \(adoption.expiresAt)").font(.caption)
                if adoption.state == "completed" { Label("Library unlocked on this device", systemImage: "checkmark.shield") }
                else {
                    Text("Keep this screen open. A code expires after two minutes; generate a new one if it expires.").font(.caption)
                }
            }
            Button("Generate a new public QR") {
                image = nil; failure = nil
                vault.run {
                    if vault.adoption != nil { try await vault.cancelAdoption() }
                    try await vault.createAdoption(label: UIDevice.current.model)
                }
            }.buttonStyle(AuroraPrimaryButton())
                .disabled(!vault.canAdopt || vault.busy || ["pending", "approved"].contains(vault.adoption?.state ?? ""))
            if vault.busy { ProgressView(vault.progress.isEmpty ? "Preparing trusted device…" : vault.progress) }
            if let failure = failure ?? vault.failure { Text(failure).foregroundStyle(.orange) }
        }
        .modernScene().navigationTitle("Adopt this device")
        .safeAreaInset(edge: .bottom) {
            if let adoption = vault.adoption, adoption.state != "completed" {
                Button("Cancel adoption", role: .destructive) {
                    vault.run { try await vault.cancelAdoption(); image = nil }
                }.frame(maxWidth: .infinity).padding().background(.bar).disabled(vault.busy)
            }
        }
        .task(id: vault.adoption?.pairingId) {
            guard let adoption = vault.adoption, vault.canAdopt, adoption.state == "pending" else { return }
            do {
                let filter = CIFilter.qrCodeGenerator()
                filter.message = try CloudVaultWire.json(adoption.qr)
                filter.correctionLevel = "M"
                guard let output = filter.outputImage,
                      let raster = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
                        from: output.extent.applying(CGAffineTransform(scaleX: 6, y: 6))) else {
                    throw BackpackError.invalid("Could not render the public adoption QR.")
                }
                image = UIImage(cgImage: raster)
                while vault.canAdopt && vault.adoption?.pairingId == adoption.pairingId &&
                    ["pending", "approved"].contains(vault.adoption?.state ?? "") {
                    try await Task.sleep(for: .seconds(2))
                    try await vault.pollAdoption()
                }
            } catch is CancellationError {
                image = nil
            } catch { failure = error.localizedDescription; image = nil }
        }
        .onChange(of: community.accountRevision) { _, _ in image = nil }
        .onDisappear { image = nil }
    }
}

@MainActor
struct CloudVaultAdoptionApprovalView: View {
    @EnvironmentObject private var vault: CloudVaultStore
    @EnvironmentObject private var community: CommunityController
    @State private var scanning = false
    @State private var failure: String?
    @State private var approving = false
    var body: some View {
        Form {
            Text("Approve only a device physically in your possession. Both devices must be signed in to this same account. Scanning alone never releases the library key.")
            Button("Scan another device's adoption QR") { scanning = true }
                .buttonStyle(AuroraPrimaryButton())
                .disabled(!vault.canAdopt || vault.locked || vault.busy)
            if let adoption = vault.scannedAdoption {
                LabeledContent("Server", value: adoption.origin)
                LabeledContent("Account", value: community.user?.email ?? adoption.accountId)
                LabeledContent("Device", value: adoption.label)
                LabeledContent("Pair", value: adoption.pairingId)
                Text("Compare this server/account and pairing identifier with the requesting device before approving.").font(.caption)
                if adoption.state == "pending" {
                    Button("Review and approve this device") { approving = true }
                        .disabled(vault.busy || vault.locked)
                } else { Text("Adoption: \(adoption.state)") }
            }
            if let failure = failure ?? vault.failure { Text(failure).foregroundStyle(.orange) }
            if vault.busy { ProgressView(vault.progress.isEmpty ? "Checking trusted device…" : vault.progress) }
        }
        .modernScene().navigationTitle("Approve trusted device")
        .sheet(isPresented: $scanning) {
            NavigationStack {
                CloudVaultQRScanner { result in
                    scanning = false
                    switch result {
                    case .success(let text): vault.run { try await vault.inspectQR(text) }
                    case .failure(let error): failure = error.localizedDescription
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan public adoption QR")
                .toolbar { Button("Cancel") { scanning = false } }
                .safeAreaInset(edge: .bottom) {
                    Button("Cancel scan", role: .cancel) { scanning = false }
                        .frame(maxWidth: .infinity).padding().background(.bar)
                }
            }
        }
        .confirmationDialog("Release this library key to the displayed device?", isPresented: $approving, titleVisibility: .visible) {
            Button("Approve this same-account device") { vault.run { try await vault.approveAdoption() } }
        } message: { Text("The approval binds the requesting device's recipient key, challenge and complete encrypted HPKE box. Do not approve unsolicited codes.") }
        .onChange(of: community.accountRevision) { _, _ in scanning = false; approving = false }
    }
}

@MainActor
private struct CloudVaultQRScanner: UIViewControllerRepresentable {
    let completed: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> Scanner { Scanner(completed: completed) }
    func updateUIViewController(_ controller: Scanner, context: Context) {}

    final class Scanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "catalog.cloud.qr-camera")
        private let completed: (Result<String, Error>) -> Void
        private var preview: AVCaptureVideoPreviewLayer?
        private var permission: Task<Void, Never>?
        private var finished = false
        init(completed: @escaping (Result<String, Error>) -> Void) {
            self.completed = completed
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { return nil }
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer); preview = layer
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            permission = Task {
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled, viewIfLoaded?.window != nil else { return }
                guard allowed else { finish(.failure(BackpackError.invalid("Allow camera access in iOS Settings to scan a trusted device's public QR."))); return }
                let session = self.session, delegate = self
                queue.async {
                    do {
                        guard let device = AVCaptureDevice.default(for: .video) else { throw BackpackError.invalid("This device has no available camera.") }
                        let input = try AVCaptureDeviceInput(device: device)
                        let output = AVCaptureMetadataOutput()
                        session.beginConfiguration()
                        guard session.canAddInput(input), session.canAddOutput(output) else {
                            session.commitConfiguration()
                            throw BackpackError.invalid("The camera cannot scan QR metadata.")
                        }
                        session.addInput(input); session.addOutput(output)
                        output.setMetadataObjectsDelegate(delegate, queue: .main)
                        guard output.availableMetadataObjectTypes.contains(.qr) else {
                            session.commitConfiguration()
                            throw BackpackError.invalid("QR scanning is unavailable on this camera.")
                        }
                        output.metadataObjectTypes = [.qr]
                        session.commitConfiguration(); session.startRunning()
                    } catch { Task { @MainActor in delegate.finish(.failure(error)) } }
                }
            }
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated); permission?.cancel(); finished = true
            let session = self.session
            queue.async { session.stopRunning() }
        }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            finish(.success(value))
        }
        private func finish(_ result: Result<String, Error>) {
            guard !finished else { return }
            finished = true
            let session = self.session; queue.async { session.stopRunning() }
            completed(result)
        }
    }
}
