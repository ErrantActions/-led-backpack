import SwiftUI
import BackpackProtocol

@MainActor
struct BackpackStorageView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var panel: PanelController
    @State private var erasing: BackpackErasePlan?
    @State private var selected: Slot?
    @State private var selectionPlan: BackpackErasePlan?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On your backpack").font(.title3.weight(.semibold))
            if panel.inventoryDeviceID != nil && panel.inventoryDeviceID == panel.link.selectedID {
                Text("\(panel.slots.filter(\.occupied).count) / 60 slots occupied").font(.caption)
            } else {
                Text("Refresh to read this backpack's storage.").font(.caption).foregroundStyle(.secondary)
            }
            if let date = panel.inventoryReadAt { Text("Inventory read \(date.formatted(date: .omitted, time: .standard))").font(.caption2) }
            FeatureDetails("About slot previews") {
                Text("Thumbnails use matching originals cached on this iPhone. Unknown artwork is not an empty slot.")
            }
            Button("Refresh slots and playback") { app.run { try await panel.refreshStoredPlayback() } }
            if let progress = panel.progress { ProgressView(value: progress) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(panel.slots) { slot in
                    Button {
                        app.run { selectionPlan = try panel.erasePlan(); selected = slot }
                    } label: {
                        VStack(spacing: 5) {
                            StoredSlotThumbnail(slot: slot).aspectRatio(1, contentMode: .fit)
                            Text("Slot \(slot.id)").font(.caption)
                            Text(BackpackPlaybackStatus.reportedSlot(panel.playback) == slot.id ? "Playing" :
                                (slot.occupied ? "Stored" : "Empty")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            NavigationLink("Playlists") { PlaylistCollection() }
            DisclosureGroup("Erase stored artwork") {
                Text("Not a factory reset. Local/cloud GIFs, Bluetooth settings and the backpack password are retained.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Erase all backpack slots", role: .destructive) {
                    app.run { erasing = try panel.erasePlan() }
                }.disabled(!panel.slots.contains(where: \.occupied))
            }
        }.padding(20).glassPanel().disabled(panel.busy || panel.hasDisplayOwner)
        .sheet(item: $erasing) { EraseBackpackView(plan: $0) }
        .sheet(item: $selected) { slot in
            if let selectionPlan { StoredSlotDetail(slot: slot, plan: selectionPlan) }
        }
    }
}

@MainActor
struct StoredSlotThumbnail: View {
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    let slot: Slot
    private var cached: Bool {
        guard let serial = panel.identity?.serial else { return false }
        return library.state.slotPreviews?.contains { link in
            link.panel == serial && link.slot == slot.id && link.identifier == slot.identifier &&
            library.state.media.contains(where: { $0.id == link.mediaID })
        } == true
    }
    var body: some View {
        Group {
            if slot.occupied && cached, let serial = panel.identity?.serial {
                GIFThumbnail(key: "slot:\(serial):\(slot.id):\(slot.identifier)", cache: false) {
                    guard let data = try library.cachedSlot(panel: serial, slot: slot.id, identifier: slot.identifier) else {
                        throw BackpackError.invalid("The matching original is no longer cached.")
                    }
                    return data
                }
            } else {
                ZStack {
                    Color.black
                    Image(systemName: slot.occupied ? "photo.badge.questionmark" : "square.dashed")
                        .foregroundStyle(.secondary)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct StoredSlotDetail: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var panel: PanelController
    @Environment(\.dismiss) private var dismiss
    let slot: Slot
    let plan: BackpackErasePlan
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                StoredSlotThumbnail(slot: slot).frame(height: 240)
                LabeledContent("Slot", value: String(slot.id))
                LabeledContent("State", value: slot.occupied ? "Occupied" : "Empty")
                FeatureDetails("Slot identifier & preview") {
                    Text("Identifier: \(slot.identifier.map { String(format: "%02x", $0) }.joined())")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("An unknown thumbnail means this phone has no matching original, not that the slot is empty.")
                }
                if slot.occupied {
                    Button("Play this slot") {
                        app.run {
                            try plan.validate(deviceID: panel.link.selectedID, serial: panel.identity?.serial, records: panel.slots)
                            try await panel.play(slot: slot.id)
                        }
                    }.buttonStyle(AuroraPrimaryButton())
                    DisclosureGroup("Delete stored artwork") {
                        Button("Delete this backpack slot", role: .destructive) { deleting = true }
                    }
                }
            }.disabled(panel.busy || panel.hasDisplayOwner)
                .modernScene().navigationTitle("Backpack slot \(slot.id)")
                .safeAreaInset(edge: .bottom) {
                    Button("Done") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(panel.busy).padding(8).background(Aurora.surface)
                }
                .interactiveDismissDisabled(panel.busy)
                .confirmationDialog("Permanently erase slot \(slot.id)?", isPresented: $deleting) {
                    Button("Erase slot \(slot.id)", role: .destructive) {
                        app.run {
                            try plan.validate(deviceID: panel.link.selectedID, serial: panel.identity?.serial, records: panel.slots)
                            try await panel.delete(slot: slot.id); dismiss()
                        }
                    }
                } message: { Text("Stored bytes cannot be downloaded for backup. Local and cloud copies are not deleted.") }
        }
    }
}

@MainActor
struct EraseBackpackView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let plan: BackpackErasePlan
    @State private var allowErase = false
    var body: some View {
        NavigationStack {
            Form {
                Text("Erase \(plan.occupied.count) stored programs?").font(.headline)
                LabeledContent("Backpack", value: plan.serial)
                Text("This cannot be undone. Interrupted erases may be partial. Local and cloud GIFs are kept.")
                    .font(.caption)
                Toggle("Allow erase", isOn: $allowErase)
                    .disabled(panel.busy)
                    .accessibilityIdentifier("allow-backpack-erase")
                if let progress = panel.progress { ProgressView("Erasing backpack slots...", value: progress) }
                Button("Erase all stored artwork", role: .destructive) {
                    guard allowErase else {
                        panel.report(BackpackError.invalid("Enable Allow erase before erasing backpack artwork."))
                        return
                    }
                    allowErase = false
                    app.run { try await panel.eraseAll(plan); dismiss() }
                }
                .disabled(!allowErase || panel.busy || panel.hasDisplayOwner || !link.connected)
                .accessibilityIdentifier("erase-backpack-action")
            }.modernScene().navigationTitle("Erase backpack")
                .safeAreaInset(edge: .bottom) {
                    Button("Cancel") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(panel.busy).padding(8).background(Aurora.surface)
                        .accessibilityIdentifier("erase-backpack-cancel")
                }
                .interactiveDismissDisabled(panel.busy)
                .onChange(of: link.connectionRevision) { _, _ in allowErase = false }
                .onChange(of: panel.slots) { _, _ in allowErase = false }
                .onChange(of: phase) { _, value in if value != .active { allowErase = false } }
                .onDisappear { allowErase = false }
        }
    }
}
