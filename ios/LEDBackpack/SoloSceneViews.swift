import SwiftUI
import UIKit
import BackpackProtocol

@MainActor
struct SoloScenesView: View {
    @EnvironmentObject private var solo: SoloSceneController
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var targets: DisplayTargetSelection
    @State private var addingScene = false
    @State private var addingArea = false
    @State private var addingDaylight = false
    @State private var milestoneMeters = "1000"
    @State private var milestoneScene: UUID?
    @State private var recapName = ""
    @State private var recapUnlocks: Set<UUID> = []
    @State private var resetTrip = false
    @State private var clearRecaps = false
    @State private var removingArea: SoloArea?
    @State private var editingArea: SoloArea?
    @State private var deletingScene: SoloScene?
    @State private var restoring = false
    @State private var localError: String?
    var body: some View {
        List {
            privacy
            consent
            areas
            journey
            DisclosureGroup("Scenes & playlists") { scenes }
            DisclosureGroup("Daylight plans") { daylight }
            DisclosureGroup("My badges") { collection }
            DisclosureGroup("Private recaps") { recaps }
        }
        .navigationTitle("SOLO local scenes").modernScene().buttonStyle(.borderless)
        .task { await solo.load() }
        .sheet(isPresented: $addingScene) { NavigationStack { SoloSceneComposer() } }
        .sheet(isPresented: $addingArea) { NavigationStack { SoloAreaEditor() } }
        .sheet(item: $editingArea) { area in NavigationStack { SoloAreaEditor(original: area) } }
        .sheet(isPresented: $addingDaylight) { NavigationStack { SoloDaylightEditor() } }
        .confirmationDialog("Reset approximate trip and one-shot milestones?", isPresented: $resetTrip) {
            Button("Reset trip locally", role: .destructive) { solo.resetTrip() }
        } message: { Text("Does not delete saved recaps or badges. No distance will be invented on restart.") }
        .confirmationDialog("Clear all distance-only recaps on this device?", isPresented: $clearRecaps) {
            Button("Delete all local recaps", role: .destructive) { perform { try await solo.edit { $0.recaps.removeAll() } } }
        }
        .confirmationDialog("Restore the first exact PHONE original?", isPresented: $restoring) {
            Button("Stop SOLO and restore / acknowledge original") { Task { await solo.restore() } }
        } message: { Text("Restores retained bytes, playhead and presentation policy only on PHONE. A missing, uncertain or other-owner journal is never overwritten or reported as success.") }
        .confirmationDialog("Delete this fixed local target?", isPresented: Binding(get: { removingArea != nil }, set: { if !$0 { removingArea = nil } })) {
            if let value = removingArea {
                Button("Delete fixed target", role: .destructive) {
                    perform { try await solo.edit { $0.areas.removeAll { $0.id == value.id } }; removingArea = nil }
                }
            }
        } message: { Text("Own local badges remain independently removable. No server attendance or grants exist.") }
        .confirmationDialog("Delete this local scene copy?", isPresented: Binding(get: { deletingScene != nil }, set: { if !$0 { deletingScene = nil } })) {
            if let scene = deletingScene {
                Button("Delete selected scene", role: .destructive) {
                    perform {
                        try await solo.edit { value in
                            guard !value.areas.contains(where: { $0.sceneID == scene.id }),
                                  !value.milestones.contains(where: { $0.sceneID == scene.id }),
                                  !value.daylight.contains(where: { $0.sunriseSceneID == scene.id || $0.sunsetSceneID == scene.id }) else {
                                throw BackpackError.invalid("Remove this scene's area, milestone and daylight bindings first. Previous state retained.")
                            }
                            value.scenes.removeAll { $0.id == scene.id }
                        }
                        deletingScene = nil
                    }
                }
            }
        }
    }
    private var privacy: some View {
        Section {
            HStack {
                Text("My adventures").font(.title2.bold())
                Spacer()
                StatusPill(title: solo.sensing ? "GPS on" : "GPS off", symbol: "location")
            }
            Text("Private places and milestones. Nothing is published.").font(.subheadline).foregroundStyle(.secondary)
            if let error = localError ?? solo.failure { Text(error).foregroundStyle(.orange) }
            if solo.busy { ProgressView() }
            if !solo.loaded {
                Button("Reload local state") { Task { await solo.load() } }.disabled(solo.busy)
            }
            if !solo.loaded { Text("Reload before editing or starting automation.").foregroundStyle(.orange) }
            FeatureDetails("Status & privacy") {
                Button("Reload local state") { Task { await solo.load() } }.disabled(solo.busy)
                Text(solo.status)
                Text("Fixed places stay on this device. No route, location history, check-in or badge is published.")
                Text("GPS offers are approximate, not attendance or safety proof. No speed, chase or leaderboard objectives.")
                Text("Phone only. Unknown backpack originals cannot be restored automatically.")
            }
        }
    }
    private var consent: some View {
        Section("Start playing") {
            Text("GPS stays on-device. Phone animation is a separate choice.").font(.caption)
            Toggle("Use foreground GPS", isOn: Binding(get: { solo.sensingConsent }, set: solo.setSensingConsent))
            Button("Allow location") { solo.requestPermission() }
                .disabled(!solo.sensingConsent)
                .accessibilityLabel("Request When-In-Use location permission deliberately")
            Button("Start GPS") { solo.startSensing() }.buttonStyle(AuroraPrimaryButton())
                .disabled(!solo.sensingConsent || !solo.loaded || solo.sensing)
            DisclosureGroup("Phone animation") {
            Toggle("Animate my phone automatically", isOn: Binding(get: { solo.automationConsent }, set: solo.setAutomationConsent))
            Text("Your original is saved before any automatic change. Open the phone player first.")
                .font(.caption)
            Button(solo.armed ? "Phone automation on" : "Start phone automation") { Task { await solo.arm() } }
                .disabled(solo.armed || !solo.automationConsent || solo.busy)
                .accessibilityLabel(solo.armed ? "PHONE automation is armed" : "Capture durable original and arm PHONE")
            }
            if targets.target != .phone {
                Text("Select the phone target first.").foregroundStyle(.orange)
            }
            if solo.sensing || solo.armed || solo.trip.running {
                Button("Stop playing", role: .destructive) { solo.stop() }
            }
            Button("Restore my original") { restoring = true }
        }
    }
    private var scenes: some View {
        Group {
            Button("Create scene") { addingScene = true }
            ForEach(solo.archive.scenes) { scene in
                VStack(alignment: .leading) {
                    Text(scene.name).font(.headline)
                    Text("\(scene.items.count) local items · \(Int(scene.interval)) s playlist interval · \(scene.repeatPlaylist ? "repeat" : "one pass")")
                        .font(.caption)
                    Button("Preview first GIF") { perform { try await solo.previewManually(scene.id) } }
                    Menu("Scene actions") {
                        Button("Play on my phone") { solo.playScene(scene.id) }.disabled(!solo.armed)
                        Button("Delete scene", role: .destructive) { deletingScene = scene }
                    }
                    FeatureDetails("GIFs & credits") {
                        ForEach(scene.items) { item in
                            Text("Scene artwork").accessibilityLabel(item.name)
                            if let credit = item.attribution { Text("\(credit.author) · \(credit.license) · \(credit.source)") }
                        }
                        Text("Manual preview does not record a visit.")
                    }
                }
            }
            if let offer = solo.offer, let scene = solo.archive.scenes.first(where: { $0.id == offer }) {
                Text("Offered locally: \(scene.name)").foregroundStyle(.cyan)
                Button("Play offered scene") { solo.playScene(scene.id) }.disabled(!solo.armed)
            }
        }
    }
    private var areas: some View {
        Section("My places") {
            Button { addingArea = true } label: { FeatureRowLabel(title: "Add a place", symbol: "plus.circle") }
                .disabled(solo.archive.scenes.isEmpty)
            if solo.archive.scenes.isEmpty { Text("Create a scene under Scenes & playlists first.").font(.caption).foregroundStyle(.secondary) }
            ForEach(solo.archive.areas) { area in
                VStack(alignment: .leading) {
                    Text("\(area.name) · \(area.kind.rawValue)").font(.headline)
                    Text(solo.areaStates[area.id]?.rawValue ?? "Not sensing").font(.caption)
                    Button("Offer scene") { solo.offerScene(area.sceneID) }
                    Menu("Manage") {
                        Button("Edit place") { editingArea = area }
                        if area.kind == .adventure {
                            Button("Record badge manually — not GPS verified") { perform { try await solo.unlock(area, manual: true) } }
                                .disabled(solo.archive.unlocks.contains { $0.id == area.id })
                        }
                        Button("Delete place", role: .destructive) { removingArea = area }
                    }
                    FeatureDetails("Place details") {
                        Text("Fixed \(area.center.latitude.formatted()), \(area.center.longitude.formatted())")
                        Text("Radius \(Int(area.radius))m · dwell \(Int(area.dwell))s · cooldown \(Int(area.cooldown))s")
                        Text("This is a private local target, not certified attendance or a server media grant.")
                    }
                }
            }
        }
    }
    private var journey: some View {
        Section("My journey") {
            Text("\(Int(solo.trip.meters)) m").font(.largeTitle.bold()).foregroundStyle(Aurora.mint)
            Text(solo.trip.running ? "Measuring approximate distance" : "Paused").font(.caption).foregroundStyle(.secondary)
            HStack {
                if solo.trip.running {
                    Button("Pause") { solo.pauseTrip() }
                    Button("Stop") { solo.stopTrip() }
                } else {
                    Button("Start / resume") { do { try solo.startTrip() } catch { localError = error.localizedDescription } }
                    if solo.trip.meters > 0 { Button("Stop") { solo.stopTrip() } }
                }
            }.buttonStyle(.bordered)
            DisclosureGroup("Milestones & reset") {
                Text("Approximate distance only. Gaps and jumps are discarded; no route or speed is recorded.").font(.caption)
                Button("Reset journey", role: .destructive) { resetTrip = true }
                TextField("Milestone meters", text: $milestoneMeters).keyboardType(.decimalPad)
                scenePicker("Celebration scene", selection: $milestoneScene)
                Button("Add milestone") {
                perform {
                    guard let meters = Double(milestoneMeters), let scene = milestoneScene else { throw BackpackError.invalid("Enter a distance and explicitly choose a local celebration.") }
                    let value = SoloMilestone(meters: meters, sceneID: scene)
                    try await solo.edit { $0.milestones.append(value) }
                }
            }
                ForEach(solo.archive.milestones) { item in
                HStack {
                    Text("\(Int(item.meters)) m · \(solo.archive.scenes.first { $0.id == item.sceneID }?.name ?? "Unavailable")")
                    Spacer()
                    Button("Remove", role: .destructive) { perform { try await solo.edit { $0.milestones.removeAll { $0.id == item.id } } } }
                }
            }
            }
        }
    }
    private var daylight: some View {
        Group {
            Button("Add daylight plan") { addingDaylight = true }.disabled(solo.archive.scenes.isEmpty)
            Text(solo.daylightDescription).font(.caption)
            ForEach(solo.archive.daylight) { plan in
                VStack(alignment: .leading) {
                    Text(plan.name).font(.headline)
                    Text("\(plan.timeZoneID) · capped \(Int(plan.duration)) s · \(plan.brightness.map { "PHONE brightness \(Int($0 * 100))%" } ?? "no brightness override")").font(.caption)
                    Button("Schedule on my phone") {
                        do { try solo.scheduleDaylight(plan.id) } catch { localError = error.localizedDescription }
                    }.disabled(!solo.armed)
                    Menu("Plan actions") {
                        Button("Preview sunrise") { solo.playScene(plan.sunriseSceneID, brightness: plan.brightness, duration: plan.duration) }.disabled(!solo.armed)
                        Button("Preview sunset") { solo.playScene(plan.sunsetSceneID, brightness: plan.brightness, duration: plan.duration) }.disabled(!solo.armed)
                        Button("Delete plan", role: .destructive) { perform { try await solo.edit { $0.daylight.removeAll { $0.id == plan.id } } } }
                    }
                }
            }
            InteractionExplanation("Uses your chosen point/time zone and device clock, not weather or continuous GPS. Missed events never replay.", details: "Calculation uses your explicit point/time zone and device clock, not weather or continuous GPS. Polar/unavailable cases have no guessed event. Missed/background events never replay. PHONE presentation expires; brightness is separately optional, capped and reversible.").font(.caption)
        }
    }
    private var collection: some View {
        Group {
            ForEach(solo.archive.unlocks) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(item.manual ? "Manually recorded, not sensed" : "Approximate foreground local eligibility; not certified").font(.caption)
                    Button("Offer artwork") { solo.offerScene(item.sceneID) }
                    Menu("Badge actions") {
                        Button("Delete badge", role: .destructive) { perform { try await solo.edit { $0.unlocks.removeAll { $0.id == item.id } } } }
                    }
                }
            }
            Text("Only own local choices. Not an event award, public check-in, server permission or historical encounter/GPS timeline.").font(.caption)
        }
    }
    private var recaps: some View {
        Group {
            Toggle("Save recaps on this device", isOn: $solo.recapConsent)
            TextField("Recap name", text: $recapName)
            ForEach(solo.archive.unlocks) { item in
                Toggle("Include selected summary: \(item.name)", isOn: Binding(
                    get: { recapUnlocks.contains(item.id) },
                    set: { if $0 { recapUnlocks.insert(item.id) } else { recapUnlocks.remove(item.id) } }))
            }
            Button("Save recap") {
                let name = recapName, selected = recapUnlocks
                perform { try await solo.saveRecap(name: name, selectedUnlocks: selected) }
            }
                .disabled(!solo.recapConsent || solo.trip.running)
            InteractionExplanation("Stop and reload to edit. Recaps contain approximate distance and local unlock names, not coordinates or encounter history.", details: "Stop SOLO and reload to edit/save. Recaps contain only approximate total distance and selected local unlock names, not coordinates, dates of encounters, maps, route or automatic sharing.").font(.caption)
            ForEach(solo.archive.recaps) { recap in
                VStack(alignment: .leading) {
                    Text("\(recap.name) · \(Int(recap.approximateMeters)) approximate meters")
                    ForEach(Array(recap.summaries.enumerated()), id: \.offset) { _, summary in Text(summary).font(.caption) }
                    Button("Delete this recap", role: .destructive) { perform { try await solo.edit { $0.recaps.removeAll { $0.id == recap.id } } } }
                }
            }
            Button("Clear all private recaps", role: .destructive) { clearRecaps = true }.disabled(solo.archive.recaps.isEmpty)
        }
    }
    private func scenePicker(_ name: String, selection: Binding<UUID?>) -> some View {
        Picker(name, selection: selection) {
            Text("Choose explicitly").tag(UUID?.none)
            ForEach(solo.archive.scenes) { Text($0.name).tag(Optional($0.id)) }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action(); localError = nil } catch { if !Task.isCancelled { localError = error.localizedDescription } } }
    }
}

@MainActor
private struct SoloSceneComposer: View {
    @EnvironmentObject private var solo: SoloSceneController
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: [UUID] = []
    @State private var interval = "60"
    @State private var repeats = false
    @State private var colorScene = false
    @State private var color = Color.orange
    @State private var error: String?
    @State private var saving = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        Form {
            TextField("Scene name", text: $name)
            Toggle("Use a solid color", isOn: $colorScene)
            if colorScene {
                ColorPicker("Chosen color", selection: $color, supportsOpacity: false)
            } else {
                Text("Choose GIFs in playback order. Only selected copies are read when you Save.").font(.caption)
                ForEach(originals.items) { item in
                    Button {
                        if selected.contains(item.id) { selected.removeAll { $0 == item.id } }
                        else if selected.count < 12 { selected.append(item.id) }
                    } label: {
                        HStack {
                            GIFThumbnail(key: "solo-original:\(item.id)", cache: false) { try await originals.bytes(item) }
                                .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 12))
                            Spacer()
                            if let index = selected.firstIndex(of: item.id) { Text("\(index + 1)").foregroundStyle(.cyan) }
                        }.accessibilityLabel("Select \(item.name)")
                    }
                }
                TextField("Interval (seconds)", text: $interval).keyboardType(.decimalPad)
                Toggle("Repeat while playing", isOn: $repeats)
            }
            Text("Copies and credits stay on this device. Original timing stays unchanged.").font(.caption)
            if let error = error ?? originals.failure { Text(error).foregroundStyle(.orange) }
            Button("Save scene", action: save).disabled(saving).buttonStyle(AuroraPrimaryButton())
            if saving { ProgressView() }
        }
        .navigationTitle("Own local scene")
        .toolbar { Button("Cancel") { operation?.cancel(); dismiss() } }
        .task { await originals.load() }
        .onDisappear { operation?.cancel() }
    }
    private func save() {
        let capturedName = name, ids = selected, intervalText = interval, repeating = repeats, solid = colorScene
        let components = UIColor(color).cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components
        let chosen = originals.items.filter { ids.contains($0.id) }
        saving = true
        operation = Task {
            defer { saving = false }
            do {
                try SoloBounds.name(capturedName)
                var items: [SoloSceneItem] = []
                if solid {
                    guard let components, components.count >= 3 else { throw BackpackError.invalid("Could not read the chosen local color. Previous scene remains intact.") }
                    let rgba = components.prefix(3).map { UInt8((max(0, min(1, $0)) * 255).rounded()) } + [UInt8(255)]
                    let bytes = try await LocalPixelWork.run {
                        let art = LocalPixelArtwork(width: 8, height: 8, frames: [LocalPixelFrame(rgba: Array(repeating: rgba, count: 64).flatMap { $0 })])
                        return try LocalPixelCodec.png(art, frame: 0)
                    }
                    items = [SoloSceneItem(id: UUID(), name: capturedName, bytes: bytes, attribution: nil)]
                } else {
                    guard !ids.isEmpty, chosen.count == ids.count else { throw BackpackError.invalid("Explicitly select 1…12 existing owned phone originals.") }
                    for item in chosen {
                        let bytes = try await originals.bytes(item)
                        try Task.checkCancellation()
                        items.append(SoloSceneItem(id: UUID(), name: item.name, bytes: bytes, attribution: item.attribution))
                    }
                }
                let seconds: Double
                if solid { seconds = 60 }
                else {
                    guard let parsed = Double(intervalText) else { throw BackpackError.invalid("Enter a numeric playlist interval.") }
                    seconds = parsed
                }
                let scene = SoloScene(name: capturedName, items: items, interval: seconds, repeatPlaylist: repeating && !solid)
                try Task.checkCancellation()
                try await solo.edit { $0.scenes.append(scene) }
                dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
private struct SoloAreaEditor: View {
    @EnvironmentObject private var solo: SoloSceneController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let original: SoloArea?
    @State private var name: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var radius: String
    @State private var dwell: String
    @State private var hysteresis: String
    @State private var cooldown: String
    @State private var sceneID: UUID?
    @State private var kind: SoloAreaKind
    @State private var badge: String
    @State private var error: String?
    @State private var saving = false
    @State private var operation: Task<Void, Never>?
    @State private var captureConsent = false
    @State private var capturing = false
    @State private var captureNotice: String?
    @State private var draftGeneration = UUID()
    init(original: SoloArea? = nil) {
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _latitude = State(initialValue: original.map { String($0.center.latitude) } ?? "")
        _longitude = State(initialValue: original.map { String($0.center.longitude) } ?? "")
        _radius = State(initialValue: original.map { String($0.radius) } ?? "150")
        _dwell = State(initialValue: original.map { String($0.dwell) } ?? "20")
        _hysteresis = State(initialValue: original.map { String($0.hysteresis) } ?? "10")
        _cooldown = State(initialValue: original.map { String($0.cooldown) } ?? "300")
        _sceneID = State(initialValue: original?.sceneID)
        _kind = State(initialValue: original?.kind ?? .place)
        _badge = State(initialValue: original?.badge ?? "")
    }
    var body: some View {
        Form {
            TextField("Place name", text: $name)
            Picker("Type", selection: $kind) {
                Text("Place").tag(SoloAreaKind.place)
                Text("Adventure").tag(SoloAreaKind.adventure)
                Text("Personal event").tag(SoloAreaKind.event)
            }
            Section("Fixed point") {
                Toggle("Use one GPS fix for this private draft", isOn: $captureConsent)
                    .disabled(saving)
                Text("Stop playing first. This private point is saved only when you choose Save.").font(.caption)
                Button("Allow location") {
                    do {
                        try solo.requestFixedPointPermission(consent: captureConsent)
                        captureNotice = "OS permission requested separately. After granting, press Capture explicitly."
                    } catch { self.error = error.localizedDescription }
                }.disabled(!captureConsent || capturing || saving || solo.busy || solo.sensing || solo.armed || phase != .active)
                Button("Use current point", action: capturePoint)
                    .disabled(!captureConsent || capturing || saving || solo.busy || solo.sensing || solo.armed || phase != .active)
                if capturing { ProgressView("Waiting for a fresh, accurate fixed point") }
                if capturing { Button("Cancel capture", role: .destructive) { cancelDraftOperation() } }
                if let captureNotice { Text(captureNotice).font(.caption) }
            }
            DisclosureGroup("Enter coordinates manually") {
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
            }
            TextField("Radius (meters)", text: $radius).keyboardType(.decimalPad)
            DisclosureGroup("Advanced limits") {
                TextField("Dwell (seconds)", text: $dwell).keyboardType(.decimalPad)
                TextField("Hysteresis (meters)", text: $hysteresis).keyboardType(.decimalPad)
                TextField("Cooldown (seconds)", text: $cooldown).keyboardType(.decimalPad)
                Text("GPS is approximate. These private targets don't certify attendance or grant cloud artwork access.").font(.caption)
            }
            Picker("Scene", selection: $sceneID) {
                Text("Choose scene").tag(UUID?.none)
                ForEach(solo.archive.scenes) { Text($0.name).tag(Optional($0.id)) }
            }
            if kind == .adventure { TextField("Private badge name", text: $badge) }
            if let error { Text(error).foregroundStyle(.orange) }
            Button("Save place", action: save)
                .disabled(saving || capturing || !solo.loaded || solo.busy || solo.sensing || solo.armed)
                .buttonStyle(AuroraPrimaryButton())
        }
        .navigationTitle(original == nil ? "New fixed area" : "Edit fixed area")
        .toolbar { Button("Cancel") { operation?.cancel(); dismiss() } }
        .onDisappear { cancelDraftOperation() }
        .onChange(of: phase) { _, value in if value != .active { captureConsent = false; cancelDraftOperation() } }
        .onChange(of: captureConsent) { _, value in if !value && capturing { cancelDraftOperation() } }
    }
    private func cancelDraftOperation() {
        draftGeneration = UUID(); operation?.cancel(); operation = nil; capturing = false; saving = false
    }
    private func capturePoint() {
        guard captureConsent, phase == .active, !capturing, !saving else {
            error = "Explicit active foreground capture consent is required."; return
        }
        let stamp = UUID(); draftGeneration = stamp; capturing = true; error = nil; captureNotice = nil
        operation = Task {
            defer { if draftGeneration == stamp { capturing = false } }
            do {
                let point = try await solo.captureFixedPoint(consent: captureConsent)
                try Task.checkCancellation()
                guard draftGeneration == stamp, captureConsent, phase == .active else { throw CancellationError() }
                latitude = String(point.latitude); longitude = String(point.longitude)
                captureNotice = "Fresh point copied into this private draft. No area, visit, badge or route was saved; review and Save deliberately."
            } catch { if draftGeneration == stamp && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func save() {
        guard let lat = Double(latitude), let lon = Double(longitude), let r = Double(radius),
              let d = Double(dwell), let h = Double(hysteresis), let c = Double(cooldown), let sceneID else {
            error = "Enter all numeric bounds and deliberately choose a local scene. Previous state retained."; return
        }
        let area = SoloArea(id: original?.id ?? UUID(), name: name, center: SoloPoint(latitude: lat, longitude: lon),
            radius: r, dwell: d, hysteresis: h, cooldown: c, sceneID: sceneID, kind: kind, badge: kind == .adventure ? badge : nil)
        let stamp = UUID(); draftGeneration = stamp; saving = true
        operation = Task {
            defer { if draftGeneration == stamp { saving = false } }
            do {
                try await solo.edit { value in
                    if let original {
                        guard let index = value.areas.firstIndex(where: { $0.id == original.id }) else { throw BackpackError.invalid("Fixed target was removed; reload first.") }
                        value.areas[index] = area
                    } else { value.areas.append(area) }
                }
                try Task.checkCancellation()
                guard draftGeneration == stamp else { throw CancellationError() }
                dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
private struct SoloDaylightEditor: View {
    @EnvironmentObject private var solo: SoloSceneController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var zone = ""
    @State private var sunrise: UUID?
    @State private var sunset: UUID?
    @State private var brightnessEnabled = false
    @State private var brightness = 0.3
    @State private var seconds = 60.0
    @State private var calculation = "Enter an explicit point and time zone; no guessed fallback"
    @State private var error: String?
    @State private var saving = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        Form {
            TextField("Named local palette schedule", text: $name)
            TextField("Explicit coarse/fixed latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
            TextField("Explicit coarse/fixed longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
            TextField("Explicit time zone, e.g. America/Chicago", text: $zone).textInputAutocapitalization(.never).autocorrectionDisabled()
            palette("Chosen sunrise palette", selection: $sunrise)
            palette("Chosen sunset palette", selection: $sunset)
            Stepper("Foreground presentation cap: \(Int(seconds)) seconds", value: $seconds, in: 10...300, step: 10)
            Toggle("Separately opt in to capped PHONE brightness", isOn: $brightnessEnabled)
            if brightnessEnabled { Slider(value: $brightness, in: 0.1...0.6); Text("PHONE \(Int(brightness * 100))% — not authored dimming, system max or backpack control") }
            Button("Calculate today's approximate solar events locally") {
                do {
                    let plan = try captured()
                    switch SoloSolar.calculate(day: Date(), point: plan.point, timeZoneID: plan.timeZoneID) {
                    case .events(let rise, let set): calculation = "Approximate sunrise \(rise.formatted()) / sunset \(set.formatted()), zone \(plan.timeZoneID)"
                    case .polarDay: calculation = "Polar day — no sunrise/sunset today; choose manual preview"
                    case .polarNight: calculation = "Polar night — no sunrise/sunset today; choose manual preview"
                    case .unavailable: calculation = "Unavailable date/zone/point — no guessed events; choose manual preview"
                    }
                } catch { self.error = error.localizedDescription }
            }
            Text(calculation).font(.caption)
            InteractionExplanation("Foreground schedule, off by default. Uses your chosen point/time zone; no weather service, continuous GPS or missed-event replay.", details: "No weather/API/model or continuous GPS dependency. Device clock and explicitly supplied point/time zone only. Schedules are foreground-only, default off and never replay missed events.")
            if let error { Text(error).foregroundStyle(.orange) }
            Button("Save explicit local daylight plan") {
                do {
                    let plan = try captured(); saving = true
                    operation = Task {
                        defer { saving = false }
                        do { try await solo.edit { $0.daylight.append(plan) }; dismiss() }
                        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
                } catch { self.error = error.localizedDescription }
            }.disabled(saving)
        }
        .navigationTitle("Sunrise / sunset")
        .toolbar { Button("Cancel") { operation?.cancel(); dismiss() } }
        .onDisappear { operation?.cancel() }
    }
    private func palette(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("Choose explicitly").tag(UUID?.none)
            ForEach(solo.archive.scenes) { Text($0.name).tag(Optional($0.id)) }
        }
    }
    private func captured() throws -> SoloDaylightPlan {
        guard let lat = Double(latitude), let lon = Double(longitude), let sunrise, let sunset else {
            throw BackpackError.invalid("Supply an explicit numeric point, time zone and both own local palettes.")
        }
        let value = SoloDaylightPlan(name: name, point: SoloPoint(latitude: lat, longitude: lon), timeZoneID: zone,
            sunriseSceneID: sunrise, sunsetSceneID: sunset, brightness: brightnessEnabled ? brightness : nil, duration: seconds)
        try value.validate(); return value
    }
}
