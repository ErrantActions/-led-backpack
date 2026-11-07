import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AdminArtworkView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = AdminArtworkStore()
    @State private var settings = NativeArtworkSettings()
    @State private var consent = false
    @State private var picking = false
    @State private var query = ""
    @State private var page = 1
    @State private var removal: NativeArtworkJob?
    @State private var document: BinaryDocument?
    @State private var exporting = false
    @State private var exportFailure: String?
    @State private var exportingInput = false
    private var scopeID: String { "\(community.accountRevision)|\(community.user?.role ?? "")|\(community.avatarPolicyRevision)|\(community.config?.artworkToolsEnabled == true)|\(community.config?.aiArtworkRedrawEnabled == true)|\(phase)" }
    var body: some View {
        Form {
            if community.isAdmin && community.config?.artworkToolsEnabled == true {
                Section("Owned 64×64 artwork previews") {
                    Text("Cleanup/upscale are deterministic processing, NOT AI. Explicit input creates a private owned 24-hour preview job. No private cloud scan, overwrite, publication, device action or provider provisioning.")
                    Text("Media URLs are current authorized routes, not permanent public links. Input/result fetches recheck access before/after I/O. No checksum manifest or atomic revision-CAS is invented.").font(.caption)
                    Text("One active job;10 submissions/hour;5 MB input/output,1–120 source frames,40 million decoded pixels. AI redraw accepts at most16 frames, never silently truncates. Owned jobs expire after24 hours.").font(.caption)
                    if store.busy { ProgressView() }
                    if let failure = store.failure ?? exportFailure { Text(failure).foregroundStyle(.orange) }
                    if let message = store.message { Text(message).font(.caption) }
                    Button("Reload current owned jobs") { store.reload() }.disabled(store.busy)
                    if store.uncertainSubmission {
                        Button("Reconcile uncertain submission — do not replay") { store.reconcileSubmission() }.disabled(store.busy)
                    }
                }
                sourceControls
                settingsControls
                Section("Latest 20 jobs — not a permanent archive") {
                    if store.jobs.isEmpty && !store.busy && store.failure == nil { Text("No current owned jobs loaded.") }
                    ForEach(store.jobs) { job in
                        Button("\(job.settings.mode.rawValue) — \(job.status.rawValue) — \(job.createdAt)") { store.open(job.id) }
                            .disabled(store.busy)
                    }
                    Button("Undo selection only (up to 10, session-local)") { store.undoSelection() }.disabled(store.busy || !store.canUndoSelection)
                }
                if let job = store.selected { detail(job) }
            } else {
                Text("Artwork tools require the current global-admin role and actual artworkToolsEnabled capability. Missing/false remains unavailable.")
            }
        }.navigationTitle("Admin artwork studio")
        .task(id: scopeID) {
            consent = false; removal = nil; document = nil; exporting = false; exportFailure = nil
            guard phase == .active else { store.clear(); return }
            store.bind(community)
            if community.isAdmin && community.config?.artworkToolsEnabled == true { store.reload() }
        }
        .task(id: scopeID + ":poll") {
            guard phase == .active, community.isAdmin, community.config?.artworkToolsEnabled == true else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                if !store.busy && !picking && !exporting { store.reload() }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.gif]) { result in consent = false; store.chooseFile(result) }
        .fileExporter(isPresented: $exporting, document: document, contentType: .gif,
            defaultFilename: exportingInput ? "artwork-input.gif" : "artwork-result-64x64.gif") { outcome in
                document = nil
                if case .failure(let error) = outcome { exportFailure = error.localizedDescription }
            }
        .confirmationDialog("Cancel/remove this exact owned preview?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            if let removal { Button("Cancel/remove preview only", role: .destructive) { store.remove(removal); self.removal = nil; consent = false } }
        } message: { Text("No rollback/overwrite/publication. Downloaded copies are not recalled; remote provider assets can have separate retention. Changed/expired selections require explicit reload.") }
        .onChange(of: settings) { _, _ in consent = false }
        .onDisappear { store.clear(); consent = false; document = nil; removal = nil }
    }
    private var sourceControls: some View {
        Section("Choose one explicit source") {
            Text(store.sourceName).font(.caption)
            Button("Choose immutable local GIF input") { consent = false; picking = true }.disabled(store.busy)
            if let upload = store.upload { ArtworkComparison(input: upload.preview, result: nil).id(store.sourceName + String(upload.data.count)) }
            TextField("Approved community title/tag search", text: $query)
            Button("Search named current community sources") { consent = false; page = 1; store.search(query, page: page) }.disabled(store.busy)
            if let catalog = store.catalog {
                ForEach(catalog.items) { item in
                    Button("\(item.title) (\(item.width)×\(item.height))") { consent = false; store.chooseCommunity(item) }.disabled(store.busy)
                }
                HStack {
                    Button("Previous") { page -= 1; store.search(query, page: page) }.disabled(store.busy || page <= 1)
                    Spacer()
                    Button("Next") { page += 1; store.search(query, page: page) }.disabled(store.busy || page * catalog.limit >= catalog.total || page >= 10000)
                }
            }
        }
    }
    private var settingsControls: some View {
        Section("Captured processing settings") {
            Picker("Mode", selection: $settings.mode) {
                Text("Deterministic cleanup").tag(ArtworkMode.cleanup)
                Text("Deterministic upscale").tag(ArtworkMode.upscale)
                if community.config?.aiArtworkRedrawEnabled == true { Text("Optional AI redraw").tag(ArtworkMode.redraw) }
            }
            if community.config?.aiArtworkRedrawEnabled != true { Text("AI redraw provider unavailable. No native model installation or fake AI resizing fallback.").font(.caption) }
            Picker("Background", selection: $settings.background) { ForEach(ArtworkBackground.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Remove border-connected matching background", isOn: $settings.removeBackground)
            Stepper("Tolerance \(settings.tolerance)", value: $settings.tolerance, in: 0...64)
            TextField("Optional redraw prompt (≤1000 UTF16 units)", text: $settings.prompt, axis: .vertical)
            Text("Processing may remove intentional edge-connected pixels. GIF alpha is binary. AI redraw can alter text/characters/flicker and provider assets may survive cancellation; inspect the retained input/result before any separate download/publication.").font(.caption)
            Toggle("I consent to processing only this explicit source with these settings", isOn: $consent)
            Button("Create new private preview job") { store.submit(settings, consent: consent); consent = false }
                .disabled(!consent || store.busy || store.uncertainSubmission || (store.source == nil && store.upload == nil) || (settings.mode == .redraw && community.config?.aiArtworkRedrawEnabled != true))
        }
    }
    private func detail(_ job: NativeArtworkJob) -> some View {
        Section("Selected owned job") {
            Text(job.id.uuidString).font(.caption).textSelection(.enabled)
            Text("\(job.status.rawValue) — \(job.settings.mode.rawValue)")
            Text("Expires \(job.expiresAt). Server-enforced deadline; device-clock estimates are not authoritative.").font(.caption)
            if let error = job.error { Text(error).foregroundStyle(.orange) }
            if let parent = job.parentJobId { Text("Branch of \(parent.uuidString); independent snapshot, not undo/overwrite.").font(.caption) }
            Button("Refresh selected status") { store.open(job.id, remember: false) }.disabled(store.busy)
            if job.inputUrl != nil {
                Button("Load authorized retained input — paused") { store.loadMedia(input: true) }.disabled(store.busy)
                Button("Export input after fresh authorization") { export(input: true) }.disabled(store.busy)
            } else { Text("Retained input unavailable for this legacy/staging/cancelled job; never reconstruct it from a hash.").font(.caption) }
            if job.resultUrl != nil {
                Button("Load authorized result — paused") { store.loadMedia(input: false) }.disabled(store.busy)
                Button("Export result after fresh authorization") { export(input: false) }.disabled(store.busy)
                Button("Use owned result as a new independent branch source") { consent = false; store.chooseResult() }.disabled(store.busy)
            }
            ArtworkComparison(input: store.input?.preview, result: store.result?.preview).id(job.id.uuidString + job.updatedAt)
            Button(job.active ? "Review cancel active preview" : "Review remove retained preview", role: .destructive) { removal = job }.disabled(store.busy)
        }
    }
    private func export(input: Bool) {
        let context = store.context
        exportFailure = nil
        Task {
            do {
                let bytes = try await store.export(input: input)
                guard context == store.context, phase == .active else { throw CancellationError() }
                document = BinaryDocument(data: bytes); exportingInput = input; exporting = true
            } catch { if context == store.context && !(error is CancellationError) { exportFailure = error.localizedDescription } }
        }
    }
}

@MainActor
private struct ArtworkComparison: View {
    let input, result: GIFPreview?
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var playing = false
    @State private var clock = PhonePlaybackClock()
    @State private var failure: String?
    var body: some View {
        VStack {
            TimelineView(.animation(paused: !playing)) { _ in
                HStack {
                    frame(input, label: "Retained input")
                    frame(result, label: "Owned result")
                }
            }
            Button(playing ? "Pause comparisons" : "Play comparisons explicitly") {
                do {
                    if playing { pause() } else { try clock.reset(); clock.start(); playing = true }
                } catch { failure = error.localizedDescription; pause() }
            }.disabled(!allowed || !((input?.duration ?? 0) > 0 || (result?.duration ?? 0) > 0))
            if let failure { Text(failure).foregroundStyle(.orange) }
            Text("Paused/manual local comparisons, not calibrated synchronization, hardware playback or permanent access. No awake/brightness lease. Current role/source access is refreshed while foreground.").font(.caption)
        }
        .onDisappear { pause() }
        .onChange(of: phase) { _, _ in pause() }
        .onChange(of: reducedMotion) { _, _ in pause() }
        .onChange(of: phone.animationsEnabled) { _, _ in pause() }
        .onChange(of: phone.dataSaving) { _, _ in pause() }
        .onChange(of: community.avatarPolicyRevision) { _, _ in pause() }
        .onChange(of: input.map { ObjectIdentifier($0) }) { _, _ in pause() }
        .onChange(of: result.map { ObjectIdentifier($0) }) { _, _ in pause() }
    }
    private var allowed: Bool { phase == .active && !reducedMotion && phone.animationsEnabled && !phone.dataSaving }
    private func pause() { clock.pause(); playing = false }
    private func frame(_ value: GIFPreview?, label: String) -> some View {
        VStack {
            Text(label).font(.caption)
            if let value {
                let elapsed = clock.elapsed()
                let finished = value.duration > 0 && value.cycles.map { elapsed >= value.duration * Double($0) } == true
                Image(uiImage: value.frames[finished ? value.frames.count - 1 : value.frameIndex(at: elapsed)])
                    .resizable().interpolation(.none).scaledToFit().frame(height: 130).background(.black)
            } else { Text("Not loaded").font(.caption) }
        }.frame(maxWidth: .infinity)
    }
}
