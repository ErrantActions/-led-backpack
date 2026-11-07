import SwiftUI
import UniformTypeIdentifiers
import BackpackProtocol

@MainActor
struct PhoneDisplayLibraryView: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @EnvironmentObject private var targets: DisplayTargetSelection
    @EnvironmentObject private var recovery: SwapRecoveryStore
    let choose: (() -> Void)?
    @State private var importing = false
    @State private var selection: Task<Void, Never>?
    @State private var deleting: PhoneArtwork?
    init(choose: (() -> Void)? = nil) { self.choose = choose }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AuroraHeading(eyebrow: "Your pocket canvas", title: "Your pixels.", accent: "Anywhere.")
                StatusPill(title: "LOCAL PHONE CANVAS", symbol: "iphone")
                Text("No backpack, pairing, Bluetooth, location, account or cloud required. Artwork starts paused; press Play yourself.").foregroundStyle(.secondary)
                NavigationLink("Recovery first / Received swaps (local only)") { SwapRecoveryView() }
                NavigationLink("Offline pixel & GIF studio (local only)") { LocalPixelStudioView() }
                NavigationLink("SOLO places / journey / daylight / local event scenes") { SoloScenesView() }
                NavigationLink("Automatic PHONE GIF swap game (separate consent)") { PhoneSwapGameView() }
                NavigationLink("Offline paired calm colors / optional NI (separate consent)") { LocalPairedGameView() }
                if recovery.journal?.needsRecovery == true {
                    Label("A durable original is retained — inspect recovery before any exchange", systemImage: "arrow.uturn.backward")
                        .font(.caption).foregroundStyle(.orange)
                }
                if choose == nil {
                    Button(phone.hasArtwork ? "Open retained phone artwork" : "Open phone display") {
                        targets.target = .phone; phone.open()
                    }.buttonStyle(AuroraPrimaryButton())
                }
                Button("Import original still / GIF to this phone") { importing = true }.disabled(originals.busy)
                if let failure = phone.failure ?? originals.failure { Text(failure).foregroundStyle(.orange) }
                if originals.busy || phone.loading { ProgressView() }
                Text("Phone originals").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)]) {
                    ForEach(originals.items) { item in
                        Button { select(item) } label: {
                            GIFThumbnail(key: "phone-original:\(item.id)", cache: false) { try await originals.bytes(item) }
                                .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityLabel("Display \(item.name) on phone")
                            .contextMenu { Button("Remove this local phone copy", role: .destructive) { deleting = item } }
                    }
                }
                Text("Existing local GIF library").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)]) {
                    ForEach(library.state.media) { item in
                        Button {
                            selection?.cancel(); phone.cancelPendingSelection()
                            selection = Task {
                                do {
                                    try await phone.showLocalFile(library.phoneOriginalURL(item), mediaID: item.id)
                                    targets.target = .phone; choose?()
                                } catch { if !Task.isCancelled { phone.report(error) } }
                            }
                        } label: {
                            GIFThumbnail(key: "phone-existing:\(item.id)") {
                                let url = try library.phoneOriginalURL(item)
                                return try await Task.detached { try PhoneDisplayFileReader.read(url) }.value
                            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityLabel("Display \(item.name) on phone")
                    }
                }
                Text("Original bytes, centiseconds and repeats stay unchanged. Local phone copies are separate; no upload, global deduplication or hardware-slot write.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.modernScene().navigationTitle("Phone display")
        .task { await originals.load(); await recovery.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gif, .png, .jpeg, .webP]) { result in
            selection?.cancel()
            selection = Task {
                do { _ = try await originals.importFile(result.get()); try Task.checkCancellation() }
                catch { if !Task.isCancelled { phone.report(error) } }
            }
        }
        .confirmationDialog("Remove this local phone original?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting { Button("Remove local copy", role: .destructive) { Task { await originals.delete(deleting); self.deleting = nil } } }
        } message: { Text("Only this phone-library copy. Current display bytes, source file, hardware and cloud are not changed.") }
        .onDisappear { selection?.cancel() }
    }
    private func select(_ item: PhoneArtwork) {
        selection?.cancel(); phone.cancelPendingSelection()
        selection = Task {
            do {
                let bytes = try await originals.bytes(item); try Task.checkCancellation()
                try await phone.show(bytes, mediaID: item.id)
                targets.target = .phone; choose?()
            } catch { if !Task.isCancelled { phone.report(error) } }
        }
    }
}

@MainActor
struct PhoneDisplayView: View {
    @EnvironmentObject private var paired: LocalPairedGame
    @EnvironmentObject private var scoped: ScopedGlobalPhone
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @EnvironmentObject private var targets: DisplayTargetSelection
    @EnvironmentObject private var game: PhoneSwapGame
    @EnvironmentObject private var interactions: FriendPhoneInteractionStore
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var controls = true
    @State private var choosing = false
    @State private var soloControls = false
    @State private var importing = false
    @State private var pendingFile: PhoneArtwork?
    @State private var selection: Task<Void, Never>?
    @State private var peerReport: PeerIncidentSelection?
    @State private var reportSelectionFailure: String?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().onTapGesture(perform: toggleControls)
            if let preview = phone.preview {
                TimelineView(.animation(paused: !phone.isPlaying && phone.peerHandoff == nil)) { _ in
                    let position = phone.position()
                    GeometryReader { geometry in
                        Image(uiImage: preview.frames[position.index]).interpolation(phone.crispPixels ? .none : .high).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .overlay { if phone.pixelGrid { PhonePixelGrid(image: preview.frames[position.index]).allowsHitTesting(false) } }
                            .opacity(phone.peerHandoff?.visible(at: ProcessInfo.processInfo.systemUptime) == false ? 0 : 1)
                            .accessibilityLabel("Phone artwork")
                    }
                    .onChange(of: position.finished) { _, value in if value { phone.finishIfNeeded() } }
                }.ignoresSafeArea().onTapGesture(perform: toggleControls)
            }
            if controls || !phone.hasArtwork || phone.failure != nil {
                VStack {
                    HStack {
                        Button { phone.dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).foregroundStyle(Aurora.rose) }
                            .accessibilityLabel("Close phone display")
                        Spacer(); StatusPill(title: "ON PHONE", symbol: "iphone"); Spacer()
                        Menu {
                            Button("SOLO local scenes / arm PHONE automation") { soloControls = true }
                            Button("Local library") { phone.setVisible(false); choosing = true }
                            Button("Import original image / GIF") { phone.setVisible(false); importing = true }
                        } label: { Image(systemName: "square.grid.2x2").frame(width: 44, height: 44).foregroundStyle(Aurora.mint) }
                    }.padding(8).glassPanel(radius: 24)
                    if game.enabled || game.failure != nil {
                        Text("\(game.enabled ? "AUTO GIF GAME ACTIVE" : "GAME STOPPED / RECOVERY RETAINED") — \(game.status)").font(.caption2).foregroundStyle(.orange)
                        Button("Stop game and restore initial phone original") { Task { await game.restoreOriginal() } }
                    }
                    if let peer = game.reportablePeer, community.config?.peerIncidentReportsEnabled == true {
                        Button("Stop game / deliberately explain an incident with this peer") {
                            do {
                                peerReport = try PeerIncidentSelection(peer: peer, community: community)
                                game.stop(reason: "Selected peer report — game stopped, explicit draft retained")
                            } catch { reportSelectionFailure = error.localizedDescription }
                        }
                    }
                    if let reportSelectionFailure { Text(reportSelectionFailure).font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    if !phone.hasArtwork {
                        Text("Your screen.\nYour canvas.").font(.system(.title, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
                        Button("Choose local artwork") { phone.setVisible(false); choosing = true }.buttonStyle(AuroraPrimaryButton())
                    }
                    if let failure = phone.failure {
                        Text(failure).font(.caption).foregroundStyle(.orange)
                        Button("Keep previous artwork / dismiss error") { phone.clearFailure() }
                    }
                    ScrollView {
                        VStack(spacing: 12) {
                            Button { if phone.isPlaying { phone.pause() } else { phone.play() } } label: {
                                Label(phone.isPlaying ? "Pause" : "Play", systemImage: phone.isPlaying ? "pause.fill" : "play.fill")
                            }.buttonStyle(AuroraPrimaryButton()).disabled(!phone.animated || !phone.animationsEnabled || phone.dataSaving || phone.loading)
                            Toggle("Keep screen awake", isOn: Binding(get: { phone.keepAwake }, set: phone.setKeepAwake))
                            DisclosureGroup("Phone presentation") {
                                Toggle("Crisp nearest-neighbor pixels", isOn: $phone.crispPixels)
                                Toggle("Pixel grid when large enough", isOn: $phone.pixelGrid)
                                Toggle("Allow phone animations", isOn: Binding(get: { phone.animationsEnabled }, set: phone.setAnimationsEnabled))
                                Toggle("Data-saving / still presentation", isOn: Binding(get: { phone.dataSaving }, set: phone.setDataSaving))
                                Toggle("Opt in to phone brightness override", isOn: Binding(get: { phone.brightnessEnabled }, set: phone.setBrightnessEnabled))
                                if phone.brightnessEnabled {
                                    Slider(value: Binding(get: { phone.brightnessLevel }, set: phone.setBrightness), in: 0.1...1)
                                }
                            }.font(.caption)
                            if !phone.viewerAutomaticPlaybackAllowed {
                                Text("Saved viewer settings keep automatic phone animations still. Explicit Play remains available; local phone controls still apply.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if phone.loading { ProgressView("Preparing local pixels") }
                            Text("Awake/brightness are separate opt-ins, restored on exit, background or error. Tap artwork for a pure black canvas.").font(.caption2).foregroundStyle(.secondary)
                            if let peer = interactions.engine {
                                FriendPhoneCanvasControls(engine: peer)
                            }
                            ScopedPhoneCanvasControls(session: scoped.session, stop: { scoped.stop() }, restore: { await scoped.restore() })
                            ScopedPhoneCanvasControls(session: paired.session, stop: { paired.stop() }, restore: { await paired.restore() })
                        }.padding(18)
                    }.frame(maxHeight: 290).glassPanel(radius: 26)
                }.padding(20).foregroundStyle(.white)
            }
        }.statusBarHidden(true)
        .sheet(isPresented: $soloControls) {
            NavigationStack {
                SoloScenesView().toolbar { Button("Done") { soloControls = false } }
            }
        }
        .sheet(item: $peerReport) { selection in PeerIncidentComposeView(selection: selection) }
        .onChange(of: community.accountRevision) { _, _ in peerReport = nil; reportSelectionFailure = nil }
        .onChange(of: community.user?.role) { _, _ in peerReport = nil; reportSelectionFailure = nil }
        .onAppear { phone.setReducedMotion(reducedMotion); phone.setForeground(phase == .active); phone.setVisible(true); displayPending() }
        .onDisappear { selection?.cancel(); phone.setVisible(false); pendingFile = nil }
        .onChange(of: phase) { _, state in phone.setForeground(state == .active); displayPending() }
        .onChange(of: reducedMotion) { _, value in phone.setReducedMotion(value) }
        .onChange(of: importing) { _, value in if !value && phone.presented { phone.setVisible(true) } }
        .sheet(isPresented: $choosing, onDismiss: { if phone.presented { phone.setVisible(true) } }) {
            NavigationStack { PhoneDisplayLibraryView(choose: { choosing = false }).toolbar { Button("Done") { choosing = false } } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gif, .png, .jpeg, .webP]) { result in
            selection?.cancel(); phone.cancelPendingSelection()
            selection = Task {
                do {
                    let item = try await originals.importFile(result.get())
                    try Task.checkCancellation(); pendingFile = item; displayPending()
                } catch { if !Task.isCancelled { phone.report(error) } }
            }
        }
    }
    private func toggleControls() { withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.18)) { controls.toggle() } }
    private func displayPending() {
        guard phase == .active, let item = pendingFile else { return }
        pendingFile = nil
        // Spawn the next selection without cancelling the import task that just delivered it.
        selection = Task {
            do {
                let bytes = try await originals.bytes(item); try Task.checkCancellation()
                try await phone.show(bytes, mediaID: item.id); targets.target = .phone
            } catch { if !Task.isCancelled { phone.report(error) } }
        }
    }
}

private struct PhonePixelGrid: View {
    let image: UIImage
    var body: some View {
        GeometryReader { geometry in
            let width = image.cgImage?.width ?? 0, height = image.cgImage?.height ?? 0
            let scale = min(geometry.size.width / CGFloat(max(1, width)), geometry.size.height / CGFloat(max(1, height)))
            if scale >= 6 && width + height <= 512 {
                Canvas { context, canvas in
                    let left = (canvas.width - CGFloat(width) * scale) / 2, top = (canvas.height - CGFloat(height) * scale) / 2
                    var path = Path()
                    for x in 0...width {
                        path.move(to: CGPoint(x: left + CGFloat(x) * scale, y: top))
                        path.addLine(to: CGPoint(x: left + CGFloat(x) * scale, y: top + CGFloat(height) * scale))
                    }
                    for y in 0...height {
                        path.move(to: CGPoint(x: left, y: top + CGFloat(y) * scale))
                        path.addLine(to: CGPoint(x: left + CGFloat(width) * scale, y: top + CGFloat(y) * scale))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                }
            }
        }.accessibilityHidden(true)
    }
}
