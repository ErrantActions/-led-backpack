import SwiftUI
import UniformTypeIdentifiers
import BackpackProtocol

@MainActor
struct PhoneDisplayLibraryView: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var phone: PhoneDisplayController
    let choose: (() -> Void)?
    init(choose: (() -> Void)? = nil) { self.choose = choose }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AuroraHeading(eyebrow: "Your pocket canvas", title: "Your pixels.", accent: "Anywhere.")
                HStack(spacing: 16) {
                    StatusPill(title: "PHONE CANVAS", symbol: "iphone")
                    Spacer(minLength: 0)
                    PixelArtwork().frame(width: 76, height: 76).padding(10).glassPanel(radius: 22)
                        .rotationEffect(.degrees(-5)).shadow(color: Aurora.lavender.opacity(0.16), radius: 16, y: 8)
                        .accessibilityHidden(true)
                }
                Text("Your phone is a display. No backpack, Bluetooth connection, account or cloud is required.")
                    .foregroundStyle(.secondary)
                if choose == nil {
                    Button(phone.hasArtwork ? "Resume phone display" : "Open phone display") { phone.open() }
                        .buttonStyle(AuroraPrimaryButton())
                }
                Text("The full-screen phone display can also open a local PNG/JPEG/WebP or GIF file.")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure = phone.failure { Text(failure).foregroundStyle(.orange) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)]) {
                    ForEach(library.state.media) { item in
                        Button {
                            do { try phone.show(library.data(item), mediaID: item.id); choose?() }
                            catch { phone.report(error) }
                        } label: {
                            GIFThumbnail(key: "phone-library:\(item.id)") { try library.data(item) }
                                .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityLabel("Display \(item.name) on phone")
                    }
                }
                if library.state.media.isEmpty { Text("Import or create artwork in Library/Create, or open a local image file.") }
            }.padding(20)
        }
        .modernScene().navigationTitle("Phone display")
    }
}

@MainActor
struct PhoneDisplayView: View {
    @EnvironmentObject private var phone: PhoneDisplayController
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var controls = true
    @State private var choosing = false
    @State private var importing = false
    @State private var pendingFile: Data?
    private func toggleControls() {
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.18)) { controls.toggle() }
    }
    private func displayPendingFile() {
        guard phase == .active, let pendingFile else { return }
        do { try phone.show(pendingFile); self.pendingFile = nil }
        catch { self.pendingFile = nil; phone.report(error) }
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().onTapGesture(perform: toggleControls)
            if let preview = phone.preview {
                TimelineView(.animation(paused: !phone.isPlaying)) { _ in
                    let position = phone.position()
                    GeometryReader { geometry in
                        Image(uiImage: preview.frames[position.index]).interpolation(.none).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .accessibilityLabel("Phone artwork")
                    }
                    .onChange(of: position.finished) { _, finished in if finished { phone.finishIfNeeded() } }
                }.ignoresSafeArea().onTapGesture(perform: toggleControls)
            }
            if !phone.hasArtwork {
                VStack(spacing: 18) {
                    Image(systemName: "play.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(Aurora.spectrum)
                    Text("Your screen.\nYour canvas.").font(.system(.title, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
                    Button("Choose local artwork") { phone.setVisible(false); choosing = true }
                        .buttonStyle(AuroraPrimaryButton()).frame(maxWidth: 280)
                }.padding(24).foregroundStyle(.white)
            }
            if controls || !phone.hasArtwork || phone.failure != nil {
                VStack {
                    HStack {
                        Button { phone.dismiss() } label: {
                            Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Aurora.rose).frame(width: 44, height: 44)
                        }.accessibilityLabel("Close phone display")
                        Spacer()
                        StatusPill(title: "ON PHONE", symbol: "iphone")
                        Spacer()
                        Menu {
                            Button("Local library") { phone.setVisible(false); choosing = true }
                            Button("Open image / GIF file") { phone.setVisible(false); importing = true }
                        } label: {
                            Image(systemName: "square.grid.2x2").foregroundStyle(Aurora.mint).frame(width: 44, height: 44)
                        }.accessibilityLabel("Choose phone artwork")
                    }.padding(8).glassPanel(radius: 24)
                    Spacer()
                    if let failure = phone.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                    VStack(spacing: 14) {
                        Button { if phone.isPlaying { phone.pause() } else { phone.play() } } label: {
                            Label(phone.isPlaying ? "Pause" : "Play", systemImage: phone.isPlaying ? "pause.fill" : "play.fill")
                        }.buttonStyle(AuroraPrimaryButton()).disabled(!phone.animated)
                        Toggle("Keep screen awake", isOn: Binding(get: { phone.keepAwake }, set: phone.setKeepAwake))
                            .font(.subheadline).tint(Aurora.mint)
                        Text("Tap artwork for a pure canvas. Phone only; brightness unchanged.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    }.padding(18).glassPanel(radius: 26)
                }.padding(20).foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            phone.setReducedMotion(reducedMotion); phone.setForeground(phase == .active); phone.setVisible(true)
            displayPendingFile()
        }
        .onDisappear { phone.setVisible(false); pendingFile = nil }
        .onChange(of: phase) { _, value in phone.setForeground(value == .active); displayPendingFile() }
        .onChange(of: reducedMotion) { _, value in phone.setReducedMotion(value) }
        .onChange(of: importing) { _, value in if !value && phone.presented { phone.setVisible(true) } }
        .sheet(isPresented: $choosing, onDismiss: { if phone.presented { phone.setVisible(true) } }) {
            NavigationStack {
                PhoneDisplayLibraryView(choose: { choosing = false })
                    .toolbar { Button("Done") { choosing = false } }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gif, .png, .jpeg, .webP]) { result in
            do {
                let url = try result.get()
                pendingFile = try PhoneDisplayFileReader.read(url)
                displayPendingFile()
            } catch { phone.report(error) }
            if phone.presented { phone.setVisible(true) }
        }
    }
}
