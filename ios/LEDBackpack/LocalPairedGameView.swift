import SwiftUI
import CoreImage.CIFilterBuiltins
import BackpackProtocol

@MainActor
struct LocalPairedGameView: View {
    @EnvironmentObject private var game: LocalPairedGame
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @State private var entered = ""
    @State private var compared = false
    @State private var consent = false
    @State private var stationary = false
    @State private var useRange = false
    @State private var preset = FriendScenePreset.aurora
    @State private var scanning = false
    @State private var qr: UIImage?
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pair & play").font(.title2.bold())
                Text("Offline calm colors. Your private GIFs are never sent.").font(.subheadline).foregroundStyle(.secondary)
                if let failure = game.failure ?? failure { Text(failure).foregroundStyle(.orange) }
                if game.code == nil {
                    Button("Create pairing code") { compared = false; consent = false; game.prepareCode() }.disabled(game.arming)
                        .buttonStyle(AuroraPrimaryButton())
                }
                if let code = game.code {
                    if let qr { Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxHeight: 240).accessibilityLabel("Explicit local ephemeral pairing QR") }
                    ShareLink("Share code", item: code)
                    FeatureDetails("Code options") {
                        Text(code).font(.caption2).textSelection(.enabled)
                        Button("Create a new code") { compared = false; consent = false; game.prepareCode() }
                            .disabled(game.arming || game.session.running)
                    }
                }
                Button("Scan partner's code") { scanning = true }
                DisclosureGroup("Paste a code instead") {
                    TextField("Partner's code", text: $entered, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Use code") { compared = false; consent = false; game.acceptCode(entered); entered = "" }
                }
                if let comparison = game.comparison {
                    Text(comparison).font(.title3.monospaced()).textSelection(.enabled)
                    Toggle("I compared all four groups on both phones", isOn: $compared)
                }
                if game.comparison != nil {
                Picker("Same preset on both phones", selection: $preset) { ForEach(FriendScenePreset.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("We are stationary and playing without contact", isOn: $stationary)
                Toggle("Use optional phone ranging on both devices", isOn: $useRange)
                Text("Ranging needs supported phones and separate OS consent. If unavailable, stop and choose manual pairing—never automatic fallback.").font(.caption)
                Toggle("Allow this color game to animate my phone", isOn: $consent)
                Text("Your original is retained. This shares generated colors only, not your GIFs, account, location or friendship.").font(.caption)
                LocalPairStartControls(game: game, radio: game.radio, compared: compared, consent: consent,
                    stationary: stationary, useRange: useRange, preset: preset)
                }
                LocalRangeStatus(ranging: game.ranging)
                ScopedPhoneCanvasControls(session: game.session, stop: { game.stop() }, restore: { await game.restore() })
                NavigationLink("Recovery first / Received swaps") { SwapRecoveryView() }
                FeatureDetails("Pairing status & support") {
                    Text(game.status)
                    Text("Codes expire in two minutes. Compare both phones; copied codes do not prove proximity or identity.")
                    Text("Ranging measures phones, not backpacks or guaranteed meters. Stay stationary; no chase or traffic play.")
                    Text("Background, permission loss or expiry stops play. Original recovery remains; no silent restart or guaranteed simultaneous display.")
                }
            }.padding(20)
        }.navigationTitle("Local pair game").modernScene()
        .sheet(isPresented: $scanning) {
            FriendInviteCamera { outcome in
                scanning = false; compared = false; consent = false
                switch outcome {
                case .success(let text): game.acceptCode(text)
                case .failure(let error): failure = error.localizedDescription
                }
            }
        }
        .task(id: game.code) {
            qr = nil
            guard let text = game.code else { return }
            do {
                let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
                guard let image = filter.outputImage, image.extent.width <= 256,
                      let cg = CIContext().createCGImage(image.transformed(by: .init(scaleX: 6, y: 6)), from: image.extent.applying(.init(scaleX: 6, y: 6))) else {
                    throw BackpackError.invalid("Local QR rendering unavailable; manual code remains available.")
                }
                qr = UIImage(cgImage: cg)
            } catch { failure = error.localizedDescription }
        }
        .onChange(of: phase) { _, value in if value != .active { scanning = false; game.stop("Foreground left — no local pair/NI restart"); reset() } }
        .onChange(of: community.accountRevision) { _, _ in game.stop("Account context changed — offline key discarded"); reset() }
        .onChange(of: preset) { _, _ in consent = false }
        .onChange(of: useRange) { _, _ in consent = false }
        .onChange(of: consent) { _, value in if !value && (game.arming || game.session.running) { game.stop("Local game consent withdrawn — no restart") } }
        .onChange(of: compared) { _, value in if !value && (game.arming || game.session.running) { game.stop("Compared-key approval withdrawn") } }
        .onChange(of: stationary) { _, value in if !value && (game.arming || game.session.running) { game.stop("Stationary/noncontact approval withdrawn") } }
        .onDisappear { scanning = false; entered = ""; if !phone.presented { game.stop(); reset() } }
    }
    private func reset() { compared = false; consent = false; stationary = false; qr = nil; entered = "" }
}
@MainActor
private struct LocalPairStartControls: View {
    @ObservedObject var game: LocalPairedGame
    @ObservedObject var radio: PhoneSwapRadio
    let compared, consent, stationary, useRange: Bool
    let preset: FriendScenePreset
    var body: some View {
        VStack {
            if !radio.ready {
            Button("Enable Bluetooth") { game.prepareBluetooth() }
                .disabled(game.arming || game.session.running)
                .accessibilityLabel("Prepare this local-pair Bluetooth purpose")
            }
            if !game.session.running {
            Button("Start color game") {
                game.start(consent: consent, compared: compared, stationary: stationary, useRange: useRange, preset: preset)
            }.disabled(!radio.ready || game.comparison == nil || !compared || !consent || !stationary || game.arming || game.session.running)
                .buttonStyle(AuroraPrimaryButton())
                .accessibilityLabel("Start compared stationary PHONE game")
            }
            if game.arming || game.session.running {
                Button("Stop game", role: .destructive) { game.stop() }
            }
            FeatureDetails("Bluetooth status") { Text(radio.status) }
        }
    }
}
@MainActor
private struct LocalRangeStatus: View {
    @ObservedObject var ranging: LocalNearbyInteraction
    var body: some View { Text(ranging.status).font(.caption) }
}
