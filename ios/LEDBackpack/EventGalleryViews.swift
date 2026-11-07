import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct EventGalleryView: View {
    @StateObject private var store = EventGalleryStore()
    let eventID: UUID
    let organizer: Bool
    var body: some View { EventGalleryContent(store: store, session: store.session, eventID: eventID, organizer: organizer) }
}

@MainActor
private struct EventGalleryContent: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @ObservedObject var store: EventGalleryStore
    @ObservedObject var session: CommunityFeatureSession
    let eventID: UUID
    let organizer: Bool
    @State private var importing = false
    @State private var importContext: UUID?
    @State private var importDraft: UUID?
    @State private var discardReview = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(organizer ? "Organizer image gallery" : "Current authorized gallery").font(.title2.bold())
                Text("Explicitly chosen still files only. No camera, PDF/video, private-library or cloud autoscan. Public/unlisted images awaiting approval are NOT published.").font(.caption)
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice = store.notice { Text(notice).foregroundStyle(.orange) }
                if store.conflict { Text("Conflict: captured asset revision/full order, file and descriptions remain local. Cancel/reload explicitly; no rebase or retry.").foregroundStyle(.orange) }
                if session.busy { ProgressView() }
                Button("Refresh current access / images (keep choices)") { store.load(id: eventID, organizer: organizer) }.disabled(session.busy)
                if let event = store.event, let gallery = store.gallery, let client = session.client, !session.denied {
                    ForEach(gallery.assets) { asset in
                        VStack(alignment: .leading, spacing: 10) {
                            GIFThumbnail(key: "event-gallery:\(client.instanceID):\(store.contextVersion):\(community.avatarPolicyRevision):\(asset.id):\(asset.revision)", cache: false) {
                                let context = store.contextVersion, policy = community.avatarPolicyRevision
                                let bytes = try await client.eventImage(asset, event: eventID)
                                try session.checked(client)
                                guard context == store.contextVersion, policy == community.avatarPolicyRevision, phase == .active else {
                                    throw CancellationError()
                                }
                                return bytes
                            }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 16))
                            Text(asset.alt).font(.headline); Text(asset.caption)
                            Text("Image revision \(asset.revision) · \(asset.approved ? "approved" : (event.visibility == "private" ? "private / unapproved for public links" : "PENDING — not published"))").font(.caption)
                            if gallery.coverAssetId == asset.id { Label("Current authorized cover", systemImage: "photo") }
                            if organizer, gallery.canReorder {
                                Button("Edit caption / alt text") { store.begin(asset) }.disabled(store.hasDraft || session.busy)
                                Button("Use as cover / review full order") {
                                    store.begin()
                                    store.order = [asset.id] + gallery.assets.map(\.id).filter { $0 != asset.id }
                                }.disabled(store.hasDraft || session.busy)
                                Button("Review removing this image", role: .destructive) { store.begin(asset); store.review(.remove(asset.id, asset.revision)) }
                                    .disabled(store.hasDraft || session.busy)
                            }
                        }.padding(16).glassPanel()
                    }
                    if organizer, gallery.canReorder {
                        Button("Stage new explicit PNG / JPEG / WebP") { store.begin() }
                            .disabled(store.hasDraft || session.busy || gallery.assets.count >= 20)
                        Button("Edit full order / cover") { store.begin() }.disabled(store.hasDraft || session.busy)
                        NavigationLink("Immutable image replacement (retire old URL)") {
                            EventImageReplacementView(event: event)
                        }.disabled(store.hasDraft || session.busy)
                    }
                    if store.hasDraft, organizer {
                        draftPanel
                        Button("Cancel draft and explicitly reload", role: .destructive) { discardReview = true }.disabled(session.busy)
                    }
                } else if !session.busy {
                    Text("Current ordinary event access is required. No cached covers, private gallery or admin bypass.")
                }
            }.padding(20)
        }.modernScene().navigationTitle("Event gallery")
            .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? "")") {
                store.clear(); session.bind(community); store.load(id: eventID, organizer: organizer)
            }
            .onChange(of: community.avatarPolicyRevision) { _, _ in
                importContext = nil; importDraft = nil; importing = false; store.clear()
                session.bind(community); store.load(id: eventID, organizer: organizer)
            }
            .onChange(of: community.config?.eventsEnabled) { _, enabled in if enabled != true { store.clear(); importing = false } }
            .onChange(of: phase) { _, state in
                store.clear(); importing = false; importContext = nil; importDraft = nil
                if state == .active { session.bind(community); store.load(id: eventID, organizer: organizer) }
            }
            .onChange(of: session.denied) { _, denied in if denied { store.clear(); importing = false } }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if !session.busy && !importing && store.intent == nil { store.load(id: eventID, organizer: organizer) }
                }
            }
            .onDisappear { if !importing && store.intent == nil { store.clear() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .webP]) { result in
                do {
                    guard let context = importContext, importDraft == store.draftVersion else { throw CancellationError() }
                    try store.stage(result.get(), context: context)
                } catch { session.run { _ in throw error } }
                importContext = nil; importDraft = nil
            }

            @MainActor
            struct EventAuthorizedCoverView: View {
                @EnvironmentObject private var community: CommunityController
                @Environment(\.scenePhase) private var phase
                @StateObject private var session = CommunityFeatureSession()
                let event: CatalogEvent
                @State private var bytes: Data?
                @State private var alt = ""
                var body: some View {
                    Group {
                        if let bytes, let image = UIImage(data: bytes) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel(alt)
                        }
                    }
                    .task(id: "\(event.id):\(event.revision):\(community.accountRevision):\(community.avatarPolicyRevision):\(phase)") {
                        bytes = nil; alt = ""; session.bind(community)
                        guard phase == .active, event.moderation?.held != true else { return }
                        load()
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(30)) } catch { return }
                            if !session.busy && !session.denied { load() }
                        }
                    }
                    .onChange(of: session.denied) { _, denied in if denied { bytes = nil; alt = "" } }
                    .onDisappear { bytes = nil; alt = ""; session.clear() }
                }
                private func load() {
                    bytes = nil; alt = ""
                    let policy = community.avatarPolicyRevision
                    session.run { client in
                        let current = try await client.event(event.id)
                        guard current.revision == event.revision, current.access.role == event.access.role, current.moderation?.held != true else { return }
                        let gallery = try await client.eventImages(event.id)
                        guard let id = gallery.coverAssetId, let asset = gallery.assets.first(where: { $0.id == id }),
                              current.visibility == "private" || asset.approved else { return }
                        let data = try await client.eventImage(asset, event: event.id)
                        try session.checked(client)
                        guard phase == .active, policy == community.avatarPolicyRevision else { return }
                        bytes = data; alt = asset.alt
                    }
                }
            }
            .sheet(item: $store.intent) { intent in
                NavigationStack {
                    Form {
                        Text("Captured event revision \(intent.event.revision), ordinary \(intent.event.access.role?.rawValue ?? "") role.")
                        Text("Captured full order: \(intent.gallery.assets.map { $0.id.uuidString }.joined(separator: ", "))").font(.caption)
                        Text("Caption: \(intent.caption)\nAlt: \(intent.alt)")
                        switch intent.action {
                        case .upload:
                            Text("Metadata-first immutable staged still, explicit permission true; max 5 MB / 20 images. Public/unlisted requires approval before publication.")
                        case .metadata(let id, let revision):
                            Text("Description edit: \(id.uuidString), expected asset revision \(revision). Changes reset public approval, not event participation.")
                        case .order(let ids):
                            Text("Exact desired full order: \(ids.map { $0.uuidString }.joined(separator: ", "))")
                            Text("First image is cover. Reordering never approves a pending image.")
                        case .remove(let id, let revision):
                            Text("Hide and durably queue removal of \(id.uuidString), captured asset revision \(revision). Server DELETE has no atomic revision/order field; native preflight checks the snapshot, but cannot promise a server compare-and-swap.")
                        }
                        Button("Explicitly confirm captured gallery action") { store.apply(intent) }.disabled(session.busy)
                        Button("Back — no write", role: .cancel) { store.intent = nil }
                    }.modernScene().navigationTitle("Local gallery review")
                }
            }
            .confirmationDialog("Discard selected image / descriptions / order?", isPresented: $discardReview) {
                Button("Discard and reload", role: .destructive) { store.discard(); store.load(id: eventID, organizer: organizer) }
            }
    }
    private var draftPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected = store.selected {
                Text("Captured image \(selected.id.uuidString) · revision \(selected.revision)").font(.caption)
                TextField("Caption (up to 500 characters)", text: $store.caption, axis: .vertical)
                TextField("Required alt text (1–500 characters)", text: $store.alt, axis: .vertical)
                Button("Review caption / alt edit") { store.review(.metadata(selected.id, selected.revision)) }
            } else {
                TextField("New image caption", text: $store.caption, axis: .vertical)
                TextField("New image required alt text", text: $store.alt, axis: .vertical)
                Toggle("I have permission to use this explicitly chosen image", isOn: $store.permission)
                if let raster = store.raster, let preview = UIImage(data: raster.preview) {
                    Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 240)
                        .accessibilityLabel(store.alt.isEmpty ? "Staged, unpublished image" : store.alt)
                }
                Button("Choose one still file, stage immutable bytes") {
                    importContext = store.contextVersion; importDraft = store.draftVersion; importing = true
                }
                Button("Review staged image upload") { store.review(.upload) }.disabled(store.raster == nil || !store.permission)
                ForEach(Array(store.order.enumerated()), id: \.element) { index, id in
                    HStack {
                        Text("\(index + 1). \(id.uuidString)").font(.caption)
                        Button("Earlier") { store.order.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Later") { store.order.swapAt(index, index + 1) }.disabled(index + 1 >= store.order.count)
                    }
                }
                Button("Review exact full order / first-image cover") { store.review(.order(store.order)) }
            }
        }.padding(16).glassPanel().disabled(store.conflict || store.acknowledged)
    }
}
