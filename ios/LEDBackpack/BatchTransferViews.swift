import SwiftUI
import BackpackProtocol

@MainActor
struct BatchTransferView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var batch: BatchTransferQueue
    @State private var adding = false
    @State private var assignments: [UUID: Int] = [:]
    @State private var confirmation: BatchTransferPlan?
    @State private var loop = true
    private var queue: [QueuedMedia] { library.state.transferQueue ?? [] }
    private var loadID: String { "\(panel.inventoryDeviceID?.uuidString ?? ""):\(queue.map(\.id))" }

    var body: some View {
        List {
            Section("Send queue") {
                Text(batch.status)
                if let failure = batch.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                if batch.running {
                    if let progress = panel.progress { ProgressView(value: progress) }
                    Text("\(batch.completed.count) uploads confirmed. Keep the app open.")
                    Button("Stop batch", role: .destructive) { Task { await batch.stop() } }
                } else {
                    Button("Add local GIFs") { adding = true }.disabled(queue.count >= 60)
                    Button("Refresh backpack slots") {
                        app.run { try await panel.refreshStoredPlayback(); assignEmpty() }
                    }.disabled(!panel.link.connected || panel.busy || panel.hasDisplayOwner)
                    Button("Assign empty ordinary slots") { assignEmpty() }
                        .disabled(panel.inventoryDeviceID == nil)
                }
                InteractionExplanation("Auto-assign uses slots 2-54. Other slots are reserved; manual selection requires review.", details: "Automatic assignment uses slots 2–54. Slots 55–59 are reserved for future features; 0 and 1 retain their existing reservation. Manual selection is allowed with a warning and does not erase existing artwork by itself. Distinct GIF copies stay independent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Order and destination") {
                ForEach(queue) { entry in
                    if let media = library.state.media.first(where: { $0.id == entry.mediaID }) {
                        HStack(spacing: 12) {
                            GIFThumbnail(key: media.previewKey) { try library.data(media) }
                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel(media.name)
                            Picker("Destination slot", selection: Binding(
                                get: { assignments[entry.id] ?? -1 }, set: { assignments[entry.id] = $0 })) {
                                    Text("Choose slot").tag(-1)
                                    ForEach(0..<60, id: \.self) { slot in
                                        let current = panel.inventoryDeviceID != nil && panel.inventoryDeviceID == panel.link.selectedID
                                        let state = current ? panel.slots.first(where: { $0.id == slot }).map { $0.occupied ? "overwrite" : "empty" } ?? "unknown" : "unknown"
                                        Text("\(slot): \(state)\(slot < 2 || slot >= 55 ? " (reserved)" : "")").tag(slot)
                                    }
                                }
                        }
                    }
                }
                .onDelete { offsets in
                    let snapshot = queue
                    let ids = Set(offsets.compactMap { snapshot.indices.contains($0) ? snapshot[$0].id : nil })
                    app.run {
                        guard ids.count == offsets.count else { throw BackpackError.invalid("The queue changed. Refresh before removing entries.") }
                        try library.removeQueuedMedia(ids)
                    }
                }
                .onMove { offsets, target in
                    var entries = queue
                    entries.move(fromOffsets: offsets, toOffset: target)
                    app.run { try library.reorderQueuedMedia(entries.map(\.id)) }
                }
            }.disabled(batch.running)
            Section {
                Toggle("Start ordered backpack loop when finished", isOn: $loop)
                Button("Review and send \(queue.count) GIFs") {
                    app.run {
                        guard let size = panel.size else { throw BackpackError.invalid("Refresh panel dimensions first.") }
                        let entries = queue.map {
                            BatchTransferEntry(queuedID: $0.id, mediaID: $0.mediaID, slot: assignments[$0.id] ?? -1)
                        }
                        confirmation = try BatchTransferPlan(inventory: panel.erasePlan(), size: size,
                            entries: entries, loopWhenFinished: loop)
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(queue.isEmpty || !panel.link.connected || panel.inventoryDeviceID == nil || panel.busy || panel.hasDisplayOwner)
                InteractionExplanation("Originals stay unchanged. An interrupted transfer can leave a partial slot; refresh before retrying.", details: "GIFs are fitted to the panel without changing your local originals. All files are prepared before the first overwrite. A stopped/failed upload may leave its slot partially written; refresh and review before retrying. No automatic retry or rollback.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(batch.running)
        }
        .modernScene().navigationTitle("Send queue")
        .toolbar { EditButton().disabled(batch.running) }
        .task(id: loadID) { if !batch.running { assignEmpty() } }
        .onChange(of: batch.running) { _, value in if !value { assignEmpty() } }
        .sheet(isPresented: $adding) { BatchMediaPicker() }
        .sheet(item: $confirmation) { BatchSendConfirmation(plan: $0) }
    }
    private func assignEmpty() { assignments = BatchTransferPlan.freeAssignments(queue: queue, slots: panel.slots) }
}

@MainActor
private struct BatchSendConfirmation: View {
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var batch: BatchTransferQueue
    @Environment(\.dismiss) private var dismiss
    let plan: BatchTransferPlan
    @State private var approval = ScopedActionConfirmation<String>()
    @State private var failure: String?
    private var approvalScope: String {
        "\(plan.id):\(panel.link.selectedID?.uuidString ?? ""):\(panel.link.connected):\(panel.inventoryDeviceID?.uuidString ?? ""):\(String(describing: panel.size)):\(panel.identity?.serial ?? ""):\(panel.slots.map { "\($0.id):\($0.identifier)" }):\(library.state.transferQueue?.map(\.id) ?? [])"
    }
    var body: some View {
        NavigationStack {
            Form {
                Text("Send \(plan.entries.count) GIFs to backpack \(plan.inventory.serial)?")
                Text("Destinations: \(plan.entries.map { String($0.slot) }.joined(separator: ", "))")
                if !plan.overwrittenSlots.isEmpty {
                    Text("Permanently replaces slots: \(plan.overwrittenSlots.map(String.init).joined(separator: ", ")). Stored originals cannot be downloaded for backup.")
                        .foregroundStyle(.orange)
                    Toggle("Replace these reviewed backpack slots", isOn: Binding(
                        get: { approval.isConfirmed(for: approvalScope) },
                        set: { approval.setConfirmed($0, for: approvalScope) }))
                }
                Text("Only the captured device and inventory are authorized. Local/cloud files are retained. Backgrounding or disconnecting stops the batch; it never resumes automatically.")
                    .font(.caption)
                if let failure { Text(failure).foregroundStyle(.orange) }
                Button(plan.overwrittenSlots.isEmpty ? "Send batch" : "Overwrite and send batch",
                    role: plan.overwrittenSlots.isEmpty ? nil : .destructive) {
                        guard plan.overwrittenSlots.isEmpty || approval.consume(for: approvalScope) else { failure = "Backpack or approval changed. Review the slots again."; return }
                        do { try batch.start(plan, library: library); dismiss() }
                        catch { failure = error.localizedDescription }
                    }.disabled(batch.running || (!plan.overwrittenSlots.isEmpty && !approval.isConfirmed(for: approvalScope)))
            }
            .modernScene().navigationTitle("Confirm batch transfer")
            .safeAreaInset(edge: .bottom) {
                Button("Cancel") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                    .padding(8).background(Aurora.surface)
            }
            .onChange(of: approvalScope) { _, _ in approval.reset() }
            .onDisappear { approval.reset() }
        }
    }
}

@MainActor
private struct BatchMediaPicker: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    private var remaining: Int { 60 - (library.state.transferQueue?.count ?? 0) }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)]) {
                    ForEach(library.state.media) { media in
                        Button {
                            if selected.contains(media.id) { selected.remove(media.id) } else { selected.insert(media.id) }
                        } label: {
                            GIFThumbnail(key: media.previewKey) { try library.data(media) }
                                .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topTrailing) {
                                    if selected.contains(media.id) { Image(systemName: "checkmark.circle.fill").padding(8).foregroundStyle(Aurora.mint) }
                                }
                        }.buttonStyle(.plain).accessibilityLabel("Select \(media.name)")
                            .accessibilityAddTraits(selected.contains(media.id) ? .isSelected : [])
                    }
                }.padding(16)
            }
            .modernScene().navigationTitle("Choose GIFs (\(selected.count)/\(remaining))")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button("Add to queue") {
                        app.run {
                            try library.enqueue(library.state.media.filter { selected.contains($0.id) }.map(\.id))
                            dismiss()
                        }
                    }.buttonStyle(AuroraPrimaryButton()).disabled(selected.isEmpty || selected.count > remaining)
                    Button("Cancel") { dismiss() }.frame(minHeight: 44)
                }.padding(.horizontal, 20).padding(.vertical, 8).background(Aurora.surface)
            }
        }
    }
}
