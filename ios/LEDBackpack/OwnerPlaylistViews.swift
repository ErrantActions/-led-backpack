import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins
import BackpackProtocol

@MainActor
final class NativeOwnerPlaylistStore: ObservableObject {
    @Published private(set) var original: NativeOwnerPlaylist?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var needsReload = false
    @Published private(set) var picker: NativePlaylistPickerPage?
    @Published private(set) var knownItems: [UUID: NativePlaylistItem] = [:]
    @Published private(set) var receipts: [NativePublishedPlaylistReceipt] = []
    @Published private(set) var preview: NativePlaylistPreviewRequest?
    @Published private(set) var previewFromSchedule = false
    @Published private(set) var scheduleState = NativeForegroundScheduleState()
    @Published var content = NativePlaylistContent()
    @Published var publishDraft = NativePlaylistPublishDraft()
    @Published var previewConsent = false
    @Published var scheduleConsent = false
    private(set) var selectedID: UUID?
    private(set) var client: CommunityFeatureClient?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    init(id: UUID?) { selectedID = id }
    func bind(_ community: CommunityController) {
        clear()
        do { client = try .init(community); try client?.check(.playlists) }
        catch { failure = error.localizedDescription }
    }
    func clear() {
        operation?.cancel(); operation = nil; generation = UUID(); client = nil; busy = false
        original = nil; content = .init(); publishDraft = .init(); knownItems = [:]; picker = nil; receipts = []
        failure = nil; needsReload = false; stop()
    }
    func stop() { preview = nil; previewFromSchedule = false; scheduleState.stop(); previewConsent = false; scheduleConsent = false }
    func edited() { stop(); publishDraft.consent = false }
    func accepted(_ client: CommunityFeatureClient, ticket: UUID) throws {
        try Task.checkCancellation(); try client.check(.playlists)
        guard self.client === client, generation == ticket else { throw BackpackError.invalid("Late private playlist response discarded.") }
    }
    private func work(_ body: @escaping @MainActor (CommunityFeatureClient, UUID) async throws -> Void) {
        guard let client, !busy else { return }
        operation?.cancel(); let ticket = UUID(); generation = ticket; busy = true; failure = nil
        operation = Task {
            do { try await body(client, ticket); try accepted(client, ticket: ticket); busy = false }
            catch {
                guard generation == ticket, !Task.isCancelled else { return }
                busy = false; stop(); publishDraft.consent = false
                if let failure = error as? CommunityFailure {
                    if failure.status == 409 { needsReload = true }
                    if [401, 403, 404, 410].contains(failure.status) {
                        original = nil; content = .init(); publishDraft = .init(); picker = nil; knownItems = [:]; receipts = []; needsReload = true
                    }
                }
                failure = error.localizedDescription
            }
        }
    }
    func reload() {
        stop(); publishDraft = .init(); picker = nil
        guard let selectedID else { original = nil; content = .init(); knownItems = [:]; needsReload = false; return }
        work { client, ticket in
            let result = try await client.ownerPlaylist(selectedID); try self.accepted(client, ticket: ticket)
            self.apply(result)
        }
    }
    private func apply(_ value: NativeOwnerPlaylist) {
        selectedID = value.id; original = value; content = value.content; needsReload = false; knownItems = [:]
        for entry in value.hydratedEntries { if let item = entry.item { knownItems[item.id] = item } }
        preview = nil; previewConsent = false; scheduleConsent = false; publishDraft.consent = false
    }
    func search(_ query: String, more: Bool = false) {
        let after = more ? picker?.nextAfter : nil
        work { client, ticket in
            let value = try await client.playlistItems(query: query, after: after)
            try self.accepted(client, ticket: ticket); self.picker = value
            for item in value.items { self.knownItems[item.id] = item }
        }
    }
    func add(_ item: NativePlaylistItem) {
        guard !busy, content.entries.count < 100, picker?.items.contains(where: { $0.id == item.id }) == true else { return }
        knownItems[item.id] = item; content.entries.append(.init(itemId: item.id, durationMilliseconds: 10000)); edited()
    }
    func save() {
        guard !needsReload else { failure = "Reload/discard conflict before saving. Your draft was not overwritten."; return }
        let draft = content, previous = original
        stop(); publishDraft.consent = false; needsReload = true
        work { client, ticket in
            let id = try await client.saveOwnerPlaylist(draft, original: previous)
            try self.accepted(client, ticket: ticket)
            self.selectedID = id
            let value = try await client.ownerPlaylist(id); try self.accepted(client, ticket: ticket)
            self.apply(value)
        }
    }
    func publish() {
        guard let original, content == original.content, !needsReload else {
            failure = "Save and reload the current private playlist before publishing a separate snapshot."; return
        }
        let draft = publishDraft; publishDraft.consent = false; stop()
        work { client, ticket in
            let result = try await client.publishOwnerPlaylist(original, draft: draft)
            try self.accepted(client, ticket: ticket)
            self.receipts.insert(result, at: 0); self.publishDraft = .init()
        }
    }
    func revoke() {
        guard let original, !needsReload else { return }; stop(); publishDraft.consent = false
        work { client, ticket in
            try await client.revokeOwnerPlaylistShares(original); try self.accepted(client, ticket: ticket)
            self.receipts = []
        }
    }
    func delete() {
        guard let original, !needsReload else { return }; stop()
        work { client, ticket in
            try await client.deleteOwnerPlaylist(original); try self.accepted(client, ticket: ticket)
            self.original = nil; self.selectedID = nil; self.content = .init(); self.publishDraft = .init()
            self.picker = nil; self.knownItems = [:]; self.receipts = []
        }
    }
    func startPreview(scheduled: Bool = false) {
        guard let original, previewConsent, !needsReload, original.content == content else {
            failure = "Save/reload first and explicitly choose a foreground preview."; return
        }
        previewConsent = false
        work { client, ticket in
            let requestStarted = ContinuousClock().now
            let current = try await client.ownerPlaylist(original.id); try self.accepted(client, ticket: ticket)
            guard current.revision == original.revision, current.content == original.content,
                  current.hydratedEntries.allSatisfy(\.available) else { throw BackpackError.invalid("Playlist/reference revisions changed. Reload; no source preview started.") }
            let request = NativePlaylistPreviewRequest(accountID: client.accountID, accountEpoch: client.revision,
                playlistID: current.id, revision: current.revision, content: current.content.publicReferences,
                hydratedEntries: current.hydratedEntries, requestStarted: requestStarted)
            guard !request.expired else { throw BackpackError.invalid("The source preview read arrived too late. Choose a fresh preview explicitly.") }
            self.previewFromSchedule = scheduled; self.preview = request
        }
    }
    func armSchedule() {
        guard scheduleConsent, let original, original.content == content, !needsReload, content.schedule?.enabled == true else {
            failure = "Save an enabled schedule first, then separately consent to foreground-only arming."; return
        }
        scheduleState.arm(explicitConsent: true); scheduleConsent = false
    }
    func foregroundTick(at date: Date) {
        if preview?.expired == true { preview = nil }
        guard !busy, !needsReload, original?.content == content else { return }
        if scheduleState.due(schedule: content.schedule, at: date, foreground: true) {
            previewConsent = true; startPreview(scheduled: true)
        }
    }
}

@MainActor
struct OwnerPlaylistsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var value: NativeOwnerPlaylistPage?
    @State private var page = 1
    var body: some View {
        List {
            Text("Owner-only private text/schedule encrypted by the server, not end-to-end encryption. Only currently public community GIF references; no cloud/chat/event-exclusive imports.").font(.caption)
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if community.config?.playlistsEnabled == true {
                NavigationLink("Create private playlist") { OwnerPlaylistEditor(id: nil) }
                Button("Reload my playlists", action: load).disabled(session.busy)
                if let value {
                    if value.playlists.isEmpty { Text("No private playlists on this page.") }
                    ForEach(value.playlists) { playlist in
                        NavigationLink { OwnerPlaylistEditor(id: playlist.id) } label: {
                            VStack(alignment: .leading) {
                                Text(playlist.title)
                                Text("\(playlist.entryCount) public references / revision \(playlist.revision)").font(.caption)
                            }
                        }
                    }
                    HStack {
                        Button("Previous") { page -= 1; load() }.disabled(page == 1)
                        Button("Next") { page += 1; load() }.disabled(!value.hasMore || page >= 5)
                    }.disabled(session.busy)
                }
            } else { Text("Playlists unavailable on this server. Native source does not enable encryption/services.") }
        }.navigationTitle("My private playlists").modernScene()
        .task(id: "\(community.accountRevision):\(community.config?.playlistsEnabled == true)") { value = nil; page = 1; session.bind(community); load() }
        .onChange(of: session.denied) { _, denied in if denied { value = nil } }
        .onChange(of: phase) { _, state in value = nil; session.clear(); if state == .active { session.bind(community); load() } }
        .onDisappear { value = nil; session.clear() }
    }
    private func load() {
        value = nil; let selected = page
        session.run { client in
            let result = try await client.ownerPlaylists(page: selected); try session.checked(client)
            guard selected == page else { return }; value = result
        }
    }
}

@MainActor
struct OwnerPlaylistEditor: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var globalPhone: ScopedGlobalPhone
    @Environment(\.scenePhase) private var phase
    @StateObject private var model: NativeOwnerPlaylistStore
    @State private var query = ""
    @State private var qrReceipt: NativePublishedPlaylistReceipt?
    @State private var globalScheduleConsent = false
    var onPreview: (@MainActor (NativePlaylistPreviewRequest?) -> Void)?
    init(id: UUID?, onPreview: (@MainActor (NativePlaylistPreviewRequest?) -> Void)? = nil) {
        _model = StateObject(wrappedValue: NativeOwnerPlaylistStore(id: id)); self.onPreview = onPreview
    }
    var body: some View {
        Form {
            Section {
                if model.busy { ProgressView() }
                if let failure = model.failure { Text(failure).foregroundStyle(.orange) }
                if model.needsReload { Text("Conflict/access changed. Draft retained where permitted; confirmation invalidated. Reload deliberately, no silent overwrite/retry.").foregroundStyle(.orange) }
                Button("Reload / cancel unsaved changes") { qrReceipt = nil; model.reload() }.disabled(model.busy)
                Text("Private text and schedule stay private. Saving is not foreground/background execution, physical playback or synchronization.").font(.caption)
            }
            Group {
                privateContent
                artworkPicker
                schedule
                preview
                publishing
            }.disabled(model.busy || model.needsReload || model.client?.playlistsAvailable != true)
            Section("Public snapshot receipts created in this open editor") {
                InteractionExplanation("Published snapshots have separate IDs. Revoke removes all snapshots, including older ones; no share list is invented.", details: "These are separate published IDs, not private playlist IDs. No all-shares management endpoint is documented; reopening does not invent a server share list. Revoke below removes all snapshots, including older ones.").font(.caption)
                if model.receipts.isEmpty { Text("No share receipts in this session.") }
                ForEach(model.receipts) { receipt in
                    VStack(alignment: .leading) {
                        Text("Public snapshot; paused preview").font(.headline)
                        Text("Expiry \(receipt.expiresAtISO)").font(.caption)
                        Text("Expiry display uses local time only; server rechecks expiry/current artwork on access. Copies already seen/downloaded cannot be recalled.").font(.caption)
                        if let end = try? CatalogEventTime.parse(receipt.expiresAtISO), end > Date() {
                            ShareLink("Share this public snapshot link", item: receipt.url)
                            Button("Local QR / paused share preview") { qrReceipt = receipt }
                        } else { Text("Expired locally; do not share. No consent was extended.") }
                    }
                }
            }
        }.navigationTitle("Private playlist studio").modernScene()
        .task(id: "\(community.accountRevision):\(community.config?.playlistsEnabled == true)") {
            qrReceipt = nil; query = ""; model.bind(community); model.reload()
        }
        .task(id: "\(phase):\(community.accountRevision)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation() } catch { return }
                if phase == .active { model.foregroundTick(at: Date()) }
            }
        }
        .onChange(of: model.content) { _, _ in globalScheduleConsent = false; model.edited(); qrReceipt = nil; onPreview?(nil) }
        .onChange(of: model.publishDraft.title) { _, _ in model.publishDraft.consent = false }
        .onChange(of: model.publishDraft.description) { _, _ in model.publishDraft.consent = false }
        .onChange(of: model.publishDraft.expiresInHours) { _, _ in model.publishDraft.consent = false }
        .onChange(of: model.preview?.id) { _, _ in
            onPreview?(model.preview)
            if globalScheduleConsent, model.previewFromSchedule, let request = model.preview, let client = model.client {
                globalScheduleConsent = false
                globalPhone.start(.playlist(request), client: client, consent: true)
            }
        }
        .onChange(of: qrReceipt?.id) { _, value in if value != nil { model.stop(); onPreview?(nil) } }
        .onChange(of: phase) { _, state in
            globalScheduleConsent = false; onPreview?(nil); qrReceipt = nil; query = ""; model.clear()
            if state == .active { model.bind(community); model.reload() }
        }
        .onDisappear { globalScheduleConsent = false; onPreview?(nil); qrReceipt = nil; query = ""; model.clear() }
        .sheet(item: $qrReceipt) { receipt in NativePlaylistShareQRView(receipt: receipt) }
    }
    private var privateContent: some View {
        Section("Private draft") {
            TextField("Private title", text: $model.content.title)
            TextField("Private notes / description", text: $model.content.description, axis: .vertical)
            Picker("Order", selection: $model.content.order) {
                ForEach(NativePlaylistOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            ForEach(model.content.entries.indices, id: \.self) { index in
                let entry = model.content.entries[index]
                VStack(alignment: .leading) {
                    Text(model.knownItems[entry.itemId] == nil ? "Unavailable public reference (metadata withheld)" : "Playlist artwork")
                        .accessibilityLabel(model.knownItems[entry.itemId]?.title ?? "Unavailable artwork")
                    Stepper("Duration \(entry.durationMilliseconds)ms", value: $model.content.entries[index].durationMilliseconds, in: 1000...600000, step: 1000)
                    HStack {
                        Button("Earlier") { model.content.entries.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Later") { model.content.entries.swapAt(index, index + 1) }.disabled(index + 1 == model.content.entries.count)
                        Button("Remove", role: .destructive) { model.content.entries.remove(at: index) }
                    }
                }
            }
            if model.content.entries.isEmpty { Text("Choose at least one available public GIF below.") }
            Button("Save captured private revision") { model.save() }
            if model.original != nil {
                Button("Delete private playlist and revoke shares", role: .destructive) { qrReceipt = nil; model.delete() }
            }
        }
    }
    private var artworkPicker: some View {
        Section("Current authorized public GIF selector") {
            TextField("Search public artwork", text: $query)
            Button("Search / reload public choices") { model.search(query) }
            if let picker = model.picker {
                if picker.items.isEmpty { Text("No currently permitted public GIFs match this search.") }
                ForEach(picker.items) { item in
                    Button { model.add(item) } label: {
                        GIFThumbnail(key: "playlist-choice:\(community.accountRevision):\(item.id)", cache: false, animationAllowed: false) {
                            try await community.download(item.previewUrl)
                        }.frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("Add \(item.title)")
                        .disabled(model.content.entries.count >= 100)
                }
                Button("Next public choices") { model.search(query, more: true) }.disabled(!picker.hasMore)
            }
            Text("This picker does not grant private cloud/chat/event-exclusive access. References are reauthorized by the server on save/share/preview.").font(.caption)
        }
    }
    private var schedule: some View {
        Section("Private schedule metadata / local foreground arming") {
            Toggle("Save a private schedule", isOn: Binding(get: { model.content.schedule != nil },
                set: { model.content.schedule = $0 ? .init() : nil }))
            if model.content.schedule != nil {
                Toggle("Schedule metadata enabled", isOn: Binding(get: { model.content.schedule?.enabled == true },
                    set: { model.content.schedule?.enabled = $0 }))
                TextField("Local time HH:MM", text: Binding(get: { model.content.schedule?.time ?? "" },
                    set: { model.content.schedule?.time = $0 })).keyboardType(.numbersAndPunctuation)
                Picker("Schedule timezone", selection: Binding(get: { model.content.schedule?.timezone ?? "UTC" },
                    set: { model.content.schedule?.timezone = $0 })) {
                    ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                ForEach(0..<7, id: \.self) { day in
                    Toggle(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day], isOn: Binding(
                        get: { model.content.schedule?.days.contains(day) == true }, set: { selected in
                            model.content.schedule?.days.removeAll { $0 == day }
                            if selected { model.content.schedule?.days.append(day) }
                        }))
                }
                Toggle("I explicitly arm this saved schedule while this editor is visible", isOn: $model.scheduleConsent)
                Toggle("Also start ONE main-PHONE window at the next due foreground occurrence", isOn: $globalScheduleConsent)
                Button("Arm foreground source schedule") { model.armSchedule() }.disabled(!model.scheduleConsent)
                Text(model.scheduleState.armed ? "Foreground armed; a due minute prepares an authorized source. The separate one-shot main-PHONE opt-in, if chosen, starts only its current fixed lease." : "Schedule not armed.")
            }
            InteractionExplanation("Foreground schedule only. Leaving, backgrounding or account changes disarm future windows; missed events never replay.", details: "No background task, server job, catch-up execution, physical transport or synchronization. Opening the main PHONE leaves this editor and disarms future occurrences. Its already approved current window can finish; further windows require explicit rearm. Leaving/backgrounding/account changes disarm. Repeated local-clock minutes do not retrigger within this arming session.").font(.caption)
        }
    }
    private var preview: some View {
        Section("Own paused source preview") {
            Toggle("I explicitly choose a foreground source preview", isOn: $model.previewConsent)
            Button("Start authorized source preview") { model.startPreview() }.disabled(!model.previewConsent)
            Button("Stop preview / disarm now") { globalScheduleConsent = false; globalPhone.stop(); model.stop(); onPreview?(nil) }
            if let request = model.preview {
                InteractionExplanation("Source preview is capped at 30 seconds. Main-phone playback needs separate consent; no LED transport or physical sync.",
                    details: "Source preview ready / \(request.content.order.rawValue), capped at30 seconds. Isolated playback and separately consented main-PHONE playback are available; no LED transport or physical sync.").font(.caption)
                ForEach(Array(request.hydratedEntries.enumerated()), id: \.offset) { _, entry in
                    Text(entry.item.map { _ in "Artwork · \(entry.durationMilliseconds)ms" } ?? "Artwork unavailable")
                        .accessibilityLabel(entry.item.map { "\($0.title), \(entry.durationMilliseconds)ms" } ?? "Artwork unavailable")
                }
                if let client = model.client { NativeScopedPhonePreviewView(source: .playlist(request), client: client) }
            } else { Text("Paused. This editor never downloads artwork or silently starts phone/backpack playback.") }
        }
    }
    private var publishing: some View {
        Section("Separate explicitly public immutable snapshot") {
            TextField("Public title (never autofilled from private title)", text: $model.publishDraft.title)
            TextField("Public description", text: $model.publishDraft.description, axis: .vertical)
            Stepper("Expiry \(model.publishDraft.expiresInHours) hours", value: $model.publishDraft.expiresInHours, in: 1...168)
            Toggle("I explicitly consent to publishing this text and current public references", isOn: $model.publishDraft.consent)
            Button("Publish separate public snapshot") { model.publish() }.disabled(!model.publishDraft.consent || model.original == nil)
            Button("Revoke ALL snapshots of this playlist", role: .destructive) { qrReceipt = nil; model.revoke() }.disabled(model.original == nil)
            InteractionExplanation("Publishing excludes private title, notes and schedule. Revocation cannot recall copies; chat uses published snapshots only.", details: "Private title, notes and schedule are not sent in the publish body. Revocation does not recall copies. Published snapshot IDs alone may be used by the later authorized chat-card picker; private playlist IDs must never be chat references.").font(.caption)
        }
    }
}

@MainActor
struct NativePlaylistShareQRView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var community: CommunityController
    let receipt: NativePublishedPlaylistReceipt
    @State private var png: Data?
    @State private var snapshot: NativePublicPlaylistSnapshot?
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 16) {
            Text("Public playlist / paused").font(.headline)
            Text("Expiry \(receipt.expiresAtISO)").font(.caption)
            if let snapshot {
                Text(snapshot.title)
                Text(snapshot.description).font(.caption)
                Text("Paused / \(snapshot.order.rawValue)")
                ForEach(Array(snapshot.entries.enumerated()), id: \.offset) { _, entry in
                    Text(entry.item.map { _ in "Artwork · \(entry.durationMilliseconds)ms" } ?? "Artwork unavailable; metadata withheld.")
                        .accessibilityLabel(entry.item.map { "\($0.title), \(entry.durationMilliseconds)ms" } ?? "Artwork unavailable")
                }
            }
            if let png, let image = UIImage(data: png) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 280)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            Text("Local QR generation only. No network QR service, automatic playback or private text/schedule.").font(.caption)
            Button("Close") { dismiss() }
        }.padding()
        .task(id: community.accountRevision) {
            let epoch = community.accountRevision
            do {
                guard let origin = community.origin else { throw BackpackError.invalid("Catalog changed.") }
                try receipt.validate(origin: origin)
                let expires = try CatalogEventTime.parse(receipt.expiresAtISO)
                guard expires > Date() else { throw BackpackError.invalid("Expired public snapshot.") }
                let client = try CommunityFeatureClient(community)
                let current = try await client.publishedPlaylistSnapshot(receipt)
                try Task.checkCancellation(); try client.check(.playlists)
                guard epoch == community.accountRevision, phase == .active, Date() < expires else { return }
                snapshot = current
                let url = receipt.url.absoluteString
                let worker = Task.detached {
                    try Task.checkCancellation()
                    let filter = CIFilter.qrCodeGenerator()
                    filter.message = Data(url.utf8); filter.correctionLevel = "M"
                    let scale = CGAffineTransform(scaleX: 8, y: 8)
                    guard let image = filter.outputImage?.transformed(by: scale),
                          let cg = CIContext().createCGImage(image, from: image.extent),
                          let data = UIImage(cgImage: cg).pngData() else { throw BackpackError.invalid("Local QR rendering unavailable.") }
                    try Task.checkCancellation(); return data
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard epoch == community.accountRevision, phase == .active, Date() < expires else { return }
                png = result
                try await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow))); try Task.checkCancellation()
                png = nil; snapshot = nil; failure = "Expired locally. Server authorization remains authoritative."
            } catch { if !Task.isCancelled && epoch == community.accountRevision { png = nil; snapshot = nil; failure = error.localizedDescription } }
        }
        .onChange(of: phase) { _, state in if state != .active { png = nil; snapshot = nil; dismiss() } }
        .onChange(of: community.accountRevision) { _, _ in png = nil; snapshot = nil; dismiss() }
        .onDisappear { png = nil; snapshot = nil }
    }
}
