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
            scenes
            areas
            journey
            daylight
            collection
            recaps
        }
        .navigationTitle("SOLO local scenes").modernScene()
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
        Section("Device-local / account-free · SOURCE ONLY") {
            Text("Home/work fixed areas and processing remain on this device. No live location, name, route, proximity history, check-in or badge is published. No web tiles, location search, weather or AI service is used.")
            Text("Approximate foreground offers, not a certified radius, attendance proof or continuous/background service. No speed, traffic, chase or leaderboard objectives. PHONE only; unknown backpack contents and transport are unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            Text(solo.status)
            if let error = localError ?? solo.failure { Text(error).foregroundStyle(.orange) }
            if solo.busy { ProgressView() }
            Button("Reload owned local state / recovery status") { Task { await solo.load() } }.disabled(solo.busy)
            if !solo.loaded { Text("State must load reliably before any edit or automation; existing storage is never reset on an error.").foregroundStyle(.orange) }
        }
    }
    private var consent: some View {
        Section("Independent foreground consents · off by default") {
            Toggle("Enable local foreground sensing (not PHONE automation)", isOn: Binding(get: { solo.sensingConsent }, set: solo.setSensingConsent))
            Button("Request When-In-Use location permission deliberately") { solo.requestPermission() }
                .disabled(!solo.sensingConsent)
            Button("Start sensing my saved fixed areas / trip") { solo.startSensing() }
                .disabled(!solo.sensingConsent || !solo.loaded || solo.sensing)
            Toggle("Allow automatic owned local PHONE scenes", isOn: Binding(get: { solo.automationConsent }, set: solo.setAutomationConsent))
            Text("Arming requires a selected original open in the PHONE player and no other owner. The first exact original must be durably saved before any change. Local saved/manual motion and data-saving policies still apply.")
                .font(.caption)
            Button(solo.armed ? "PHONE automation is armed" : "Capture durable original and arm PHONE") { Task { await solo.arm() } }
                .disabled(solo.armed || !solo.automationConsent || solo.busy)
            if targets.target != .phone {
                Text("PHONE is not selected. No automatic target switch or hardware fallback.").foregroundStyle(.orange)
            }
            Button("Stop all SOLO sensing / schedules / PHONE changes", role: .destructive) { solo.stop() }
            Button("Explicit original restore and acknowledgment") { restoring = true }
            Text("Stop releases presentation/brightness leases and retains the original; it never silently restores/rearms or discards recovery. Background, denial, account/target/context changes also stop it.").font(.caption)
        }
    }
    private var scenes: some View {
        Section("Explicit own local scene copies / playlists") {
            Button("Choose copies or author a color scene") { addingScene = true }
            ForEach(solo.archive.scenes) { scene in
                VStack(alignment: .leading) {
                    Text(scene.name).font(.headline)
                    Text("\(scene.items.count) local items · \(Int(scene.interval)) s playlist interval · \(scene.repeatPlaylist ? "repeat" : "one pass")")
                        .font(.caption)
                    ForEach(scene.items) { item in
                        Text(item.name).font(.caption)
                        if let credit = item.attribution { Text("\(credit.author) · \(credit.license) · \(credit.source)").font(.caption2) }
                    }
                    Button("Manual first-item preview — no measured visit") { perform { try await solo.previewManually(scene.id) } }
                    Button("Play this local scene on armed PHONE") { solo.playScene(scene.id) }.disabled(!solo.armed)
                    Button("Delete scene copy", role: .destructive) { deletingScene = scene }
                }
            }
            if let offer = solo.offer, let scene = solo.archive.scenes.first(where: { $0.id == offer }) {
                Text("Offered locally: \(scene.name)").foregroundStyle(.cyan)
                Button("Accept offered scene on armed PHONE") { solo.playScene(scene.id) }.disabled(!solo.armed)
            }
        }
    }
    private var areas: some View {
        Section("Places / own adventure targets / personal event areas") {
            Button("Add a named fixed area (numeric / offline)") { addingArea = true }.disabled(solo.archive.scenes.isEmpty)
            ForEach(solo.archive.areas) { area in
                VStack(alignment: .leading) {
                    Text("\(area.name) · \(area.kind.rawValue)").font(.headline)
                    Text("Fixed \(area.center.latitude.formatted()), \(area.center.longitude.formatted()); radius \(Int(area.radius)) m; dwell \(Int(area.dwell)) s; hysteresis \(Int(area.hysteresis)) m; cooldown \(Int(area.cooldown)) s").font(.caption)
                    Text(solo.areaStates[area.id]?.rawValue ?? "Not sensing").font(.caption)
                    Button("Offer chosen local scene manually") { solo.offerScene(area.sceneID) }
                    if area.kind == .adventure {
                        Button("Record my own badge manually (not sensed)") {
                            perform { try await solo.unlock(area, manual: true) }
                        }.disabled(solo.archive.unlocks.contains { $0.id == area.id })
                    }
                    Button("Edit fixed target") { editingArea = area }
                    Button("Delete fixed target", role: .destructive) { removingArea = area }
                }
            }
            Text("Event areas here are personally entered fixed geometry and your own selected local copies, usable without friends/cloud. No live event authorization is imported; private/event-exclusive server metadata cannot unlock media or become offline permission.").font(.caption)
        }
    }
    private var journey: some View {
        Section("Approximate on-device trip · never a route") {
            Text("\(Int(solo.trip.meters)) approximate meters · \(solo.trip.running ? "measuring" : "paused/stopped")")
            Text("Fresh full-accuracy samples only. Noise, stale fixes, gaps and jumps do not earn measured progress. Pause/resume drops the gap. A selected milestone is one-shot per reset with a local cooldown.").font(.caption)
            Button("Start / resume trip measurement explicitly") { do { try solo.startTrip() } catch { localError = error.localizedDescription } }
            Button("Pause trip (discard gap)") { solo.pauseTrip() }
            Button("Stop trip") { solo.stopTrip() }
            Button("Reset distance / one-shot milestone state", role: .destructive) { resetTrip = true }
            TextField("Milestone approximate meters (100…1,000,000)", text: $milestoneMeters).keyboardType(.decimalPad)
            scenePicker("Chosen local celebration", selection: $milestoneScene)
            Button("Add selected trip milestone") {
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
    private var daylight: some View {
        Section("Local approximate sunrise / sunset palettes") {
            Button("Choose fixed/coarse point, time zone and palettes") { addingDaylight = true }.disabled(solo.archive.scenes.isEmpty)
            Text(solo.daylightDescription).font(.caption)
            ForEach(solo.archive.daylight) { plan in
                VStack(alignment: .leading) {
                    Text(plan.name).font(.headline)
                    Text("\(plan.timeZoneID) · capped \(Int(plan.duration)) s · \(plan.brightness.map { "PHONE brightness \(Int($0 * 100))%" } ?? "no brightness override")").font(.caption)
                    Button("Schedule while foreground / explicitly armed") {
                        do { try solo.scheduleDaylight(plan.id) } catch { localError = error.localizedDescription }
                    }.disabled(!solo.armed)
                    Button("Preview chosen sunrise palette on armed PHONE") { solo.playScene(plan.sunriseSceneID, brightness: plan.brightness, duration: plan.duration) }.disabled(!solo.armed)
                    Button("Preview chosen sunset palette on armed PHONE") { solo.playScene(plan.sunsetSceneID, brightness: plan.brightness, duration: plan.duration) }.disabled(!solo.armed)
                    Button("Delete daylight plan", role: .destructive) { perform { try await solo.edit { $0.daylight.removeAll { $0.id == plan.id } } } }
                }
            }
            Text("Calculation uses your explicit point/time zone and device clock, not weather or continuous GPS. Polar/unavailable cases have no guessed event. Missed/background events never replay. PHONE presentation expires; brightness is separately optional, capped and reversible.").font(.caption)
        }
    }
    private var collection: some View {
        Section("Own local adventure badges / artwork unlocks") {
            ForEach(solo.archive.unlocks) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(item.manual ? "Manually recorded, not sensed" : "Approximate foreground local eligibility; not certified").font(.caption)
                    Button("Offer my selected unlocked local artwork") { solo.offerScene(item.sceneID) }
                    Button("Delete this local badge", role: .destructive) { perform { try await solo.edit { $0.unlocks.removeAll { $0.id == item.id } } } }
                }
            }
            Text("Only own local choices. Not an event award, public check-in, server permission or historical encounter/GPS timeline.").font(.caption)
        }
    }
    private var recaps: some View {
        Section("Optional private distance-only recap") {
            Toggle("Opt in to saving a private recap on this device", isOn: $solo.recapConsent)
            TextField("Local recap name", text: $recapName)
            ForEach(solo.archive.unlocks) { item in
                Toggle("Include selected summary: \(item.name)", isOn: Binding(
                    get: { recapUnlocks.contains(item.id) },
                    set: { if $0 { recapUnlocks.insert(item.id) } else { recapUnlocks.remove(item.id) } }))
            }
            Button("Save stopped trip distance and chosen unlock summaries") {
                let name = recapName, selected = recapUnlocks
                perform { try await solo.saveRecap(name: name, selectedUnlocks: selected) }
            }
                .disabled(!solo.recapConsent || solo.trip.running)
            Text("Stop SOLO and reload to edit/save. Recaps contain only approximate total distance and selected local unlock names, not coordinates, dates of encounters, maps, route or automatic sharing.").font(.caption)
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
            TextField("Scene / playlist name", text: $name)
            Toggle("Author a local solid-color palette instead", isOn: $colorScene)
            if colorScene {
                ColorPicker("Chosen color", selection: $color, supportsOpacity: false)
            } else {
                Text("Deliberately choose local phone originals in playback order. No private library scan or server reference import. Only selected bytes are read at Save.")
                ForEach(originals.items) { item in
                    Button {
                        if selected.contains(item.id) { selected.removeAll { $0 == item.id } }
                        else if selected.count < 12 { selected.append(item.id) }
                    } label: {
                        HStack {
                            Text(item.name)
                            Spacer()
                            if let index = selected.firstIndex(of: item.id) { Text("\(index + 1)").foregroundStyle(.cyan) }
                        }
                    }
                }
                TextField("Playlist interval seconds (10…3600)", text: $interval).keyboardType(.decimalPad)
                Toggle("Repeat chosen playlist while foreground / armed", isOn: $repeats)
            }
            Text("Copies remain account-free and on device, with attribution. Authored GIF delays/repeats are never changed. Only existing local originals may be selected; protected event metadata grants nothing.")
            if let error = error ?? originals.failure { Text(error).foregroundStyle(.orange) }
            Button("Save explicit local scene copies", action: save).disabled(saving)
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
            Text("Purposeful offline numeric alternative: enter fixed geometry yourself. No map tiles, search, reverse geocoding or location upload.")
            TextField("Private area / target name", text: $name)
            Picker("Local purpose", selection: $kind) {
                Text("Place preset (home/work stays on device)").tag(SoloAreaKind.place)
                Text("Own adventure badge / artwork target").tag(SoloAreaKind.adventure)
                Text("Personal fixed event area (not attendance)").tag(SoloAreaKind.event)
            }
            TextField("Fixed latitude −90…90", text: $latitude).keyboardType(.numbersAndPunctuation)
            TextField("Fixed longitude −180…180", text: $longitude).keyboardType(.numbersAndPunctuation)
            TextField("Radius meters 50…5000", text: $radius).keyboardType(.decimalPad)
            TextField("Reliable dwell seconds 10…600", text: $dwell).keyboardType(.decimalPad)
            TextField("Entry/exit hysteresis meters 5…200", text: $hysteresis).keyboardType(.decimalPad)
            TextField("Reentry cooldown seconds 60…86400", text: $cooldown).keyboardType(.decimalPad)
            Picker("Explicit owned local scene", selection: $sceneID) {
                Text("Choose explicitly").tag(UUID?.none)
                ForEach(solo.archive.scenes) { Text($0.name).tag(Optional($0.id)) }
            }
            if kind == .adventure { TextField("Own local badge name", text: $badge) }
            Text("Starting foreground sensing explicitly evaluates saved targets. Offers are approximate; automatic PHONE changes require separate arming. Event areas neither import protected media nor certify attendance. Own badges never unlock cloud permissions.")
            if let error { Text(error).foregroundStyle(.orange) }
            Button("Save fixed local target", action: save).disabled(saving)
        }
        .navigationTitle(original == nil ? "New fixed area" : "Edit fixed area")
        .toolbar { Button("Cancel") { operation?.cancel(); dismiss() } }
        .onDisappear { operation?.cancel() }
    }
    private func save() {
        guard let lat = Double(latitude), let lon = Double(longitude), let r = Double(radius),
              let d = Double(dwell), let h = Double(hysteresis), let c = Double(cooldown), let sceneID else {
            error = "Enter all numeric bounds and deliberately choose a local scene. Previous state retained."; return
        }
        let area = SoloArea(id: original?.id ?? UUID(), name: name, center: SoloPoint(latitude: lat, longitude: lon),
            radius: r, dwell: d, hysteresis: h, cooldown: c, sceneID: sceneID, kind: kind, badge: kind == .adventure ? badge : nil)
        saving = true
        operation = Task {
            defer { saving = false }
            do {
                try await solo.edit { value in
                    if let original {
                        guard let index = value.areas.firstIndex(where: { $0.id == original.id }) else { throw BackpackError.invalid("Fixed target was removed; reload first.") }
                        value.areas[index] = area
                    } else { value.areas.append(area) }
                }
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
            Text("No weather/API/model or continuous GPS dependency. Device clock and explicitly supplied point/time zone only. Schedules are foreground-only, default off and never replay missed events.")
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
