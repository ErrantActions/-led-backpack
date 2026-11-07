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
                Text("Offline paired calm colors").font(.title2.bold())
                Text("No account/cloud/server required. Two deliberately compared ephemeral keys, generated colors only; your private original/GIF/library is NOT sent. No friendship, profile, location, encounter record, verified identity/proximity/safety or anti-relay claim.").font(.caption)
                Text(game.status)
                if let failure = game.failure ?? failure { Text(failure).foregroundStyle(.orange) }
                Button("Create fresh two-minute local pairing code") { compared = false; consent = false; game.prepareCode() }.disabled(game.arming)
                if let code = game.code {
                    if let qr { Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxHeight: 240).accessibilityLabel("Explicit local ephemeral pairing QR") }
                    ShareLink("Share this ephemeral local pair code", item: code)
                    Text(code).font(.caption2).textSelection(.enabled).lineLimit(4)
                    Text("Each device must import the OTHER device's code, then compare every displayed group out of band. Copied QR codes are not physical proximity proof. Codes/keys are volatile and expire, never a service login or friendship.").font(.caption)
                }
                TextField("Paste the other device's local pair code", text: $entered, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Decode explicit peer code") { compared = false; consent = false; game.acceptCode(entered); entered = "" }
                Button("Scan explicit local-pair QR (camera permission)") { scanning = true }
                if let comparison = game.comparison {
                    Text(comparison).font(.title3.monospaced()).textSelection(.enabled)
                    Toggle("Both devices display these exact four groups; I compared them", isOn: $compared)
                }
                Picker("Same public gentle preset on both devices", selection: $preset) { ForEach(FriendScenePreset.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Both people are stationary; noncontact only, no chasing/traffic use", isOn: $stationary)
                Toggle("Use supported NI coarse-range hints (both devices must choose the same)", isOn: $useRange)
                Text("Optional NI is separately consented, foreground-only and initialized only when explicitly starting this paired NI mode. Unsupported/denied/uncertain ranging stops; explicitly choose manual mode with a new pairing instead of automatic fallback. No exact distance/direction/map is displayed or saved. Stable relative range cannot prove either person is stationary.").font(.caption)
                Toggle("I enable this paired calm-color game and automatic PHONE display", isOn: $consent)
                Text("This consent covers only a generated complementary color scene after both devices' authenticated ready/acknowledgments and recoverable original. It does NOT enable the online GIF game, friend discovery or media sharing.").font(.caption)
                LocalPairStartControls(game: game, radio: game.radio, compared: compared, consent: consent,
                    stationary: stationary, useRange: useRange, preset: preset)
                LocalRangeStatus(ranging: game.ranging)
                ScopedPhoneCanvasControls(session: game.session, stop: { game.stop() }, restore: { await game.restore() })
                NavigationLink("Recovery first / Received swaps") { SwapRecoveryView() }
                Text("One foreground PHONE controller; unknown hardware recovery is unsupported. Stop/background/lock/permission/key expiry clears radio/NI/keys and retains the first original. Never silently renew/replay; restore first, then respect the retained recovery cooldown before a new pair. Both-display application is not atomic; receipt loss is uncertain.").font(.caption)
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
            Text(radio.status).font(.caption)
            Button("Prepare this local-pair Bluetooth purpose") { game.prepareBluetooth() }
                .disabled(game.arming || game.session.running)
            Button("Start compared stationary PHONE game") {
                game.start(consent: consent, compared: compared, stationary: stationary, useRange: useRange, preset: preset)
            }.disabled(!radio.ready || game.comparison == nil || !compared || !consent || !stationary || game.arming || game.session.running)
            Button("Stop local pairing / sensing", role: .destructive) { game.stop() }
        }
    }
}
@MainActor
private struct LocalRangeStatus: View {
    @ObservedObject var ranging: LocalNearbyInteraction
    var body: some View { Text(ranging.status).font(.caption) }
}
