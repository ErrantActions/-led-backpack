import Foundation
import BackpackProtocol

struct SoloPoint: Codable, Equatable, Sendable {
    let latitude, longitude: Double
    func validate() throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { throw BackpackError.invalid("Enter valid fixed latitude / longitude. Nothing was changed.") }
    }
    func distance(to other: Self) -> Double {
        let r = Double.pi / 180
        let a = sin((other.latitude - latitude) * r / 2)
        let b = sin((other.longitude - longitude) * r / 2)
        let h = a * a + cos(latitude * r) * cos(other.latitude * r) * b * b
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}

struct SoloFix: Sendable {
    let point: SoloPoint
    let accuracy: Double
    let timestamp: Date
    func usable(at now: Date) -> Bool {
        (try? point.validate()) != nil && accuracy.isFinite && (0.1...25).contains(accuracy) &&
            (0...5).contains(now.timeIntervalSince(timestamp))
    }
}

struct SoloSceneItem: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let bytes: Data
    let attribution: Attribution?
    // This is a deliberately captured local copy, never a server identifier or permission.
    func validate() throws {
        try SoloBounds.name(name)
        guard (1...5_000_000).contains(bytes.count) else { throw BackpackError.invalid("A scene requires actual owned local bytes, up to 5 MB.") }
        _ = try GIFPreviewDecoder.phoneDisplay(bytes)
        if let attribution {
            guard [attribution.source, attribution.author, attribution.license, attribution.licenseURL].allSatisfy({ $0.utf16.count <= 2048 }) else {
                throw BackpackError.invalid("Scene attribution exceeds its local budget.")
            }
        }
    }
}
struct SoloScene: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var items: [SoloSceneItem]
    // A playlist changes items only at this explicitly authored interval; GIF timing is unchanged.
    var interval: Double = 60
    var repeatPlaylist = false
    func validate() throws {
        try SoloBounds.name(name)
        guard (1...12).contains(items.count), Set(items.map(\.id)).count == items.count,
              interval.isFinite, (10...3600).contains(interval) else {
            throw BackpackError.invalid("Choose 1…12 local copies and a playlist interval of 10…3600 seconds.")
        }
        for item in items { try item.validate() }
    }
}
enum SoloAreaKind: String, Codable, CaseIterable, Sendable { case place, adventure, event }
struct SoloArea: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var center: SoloPoint
    var radius: Double
    var dwell: Double
    var hysteresis: Double
    var cooldown: Double
    var sceneID: UUID
    var kind: SoloAreaKind
    var badge: String?
    func validate() throws {
        try SoloBounds.name(name); try center.validate()
        guard radius.isFinite, (50...5000).contains(radius), dwell.isFinite, (10...600).contains(dwell),
              hysteresis.isFinite, (5...200).contains(hysteresis), hysteresis < radius / 2,
              cooldown.isFinite, (60...86400).contains(cooldown),
              kind == .adventure || badge == nil else { throw BackpackError.invalid("Area bounds: radius 50…5000 m, dwell 10…600 s, hysteresis 5…200 m below half-radius, cooldown 60…86400 s.") }
        if let badge { try SoloBounds.name(badge) }
    }
}
enum SoloAreaResult: String { case unavailable, outside, dwelling, inside, cooldown, entered }
struct SoloAreaEvaluator {
    private var dwellStart: Double?
    private var previous: Double?
    private var inside = false
    private var lastEntry: Double?
    mutating func discardSample() { dwellStart = nil; previous = nil }
    mutating func restartSession() {
        discardSample()
        inside = false
    }
    mutating func evaluate(area: SoloArea, fix: SoloFix, now: Date, uptime: Double) -> SoloAreaResult {
        guard (try? area.validate()) != nil, fix.usable(at: now), uptime.isFinite,
              previous == nil || uptime >= previous! else { discardSample(); return .unavailable }
        if let previous, uptime - previous > 5 { dwellStart = nil }
        previous = uptime
        let distance = area.center.distance(to: fix.point)
        if inside {
            if distance - fix.accuracy >= area.radius + area.hysteresis {
                inside = false; dwellStart = nil; return .outside
            }
            return .inside
        }
        guard distance + fix.accuracy <= area.radius - area.hysteresis else { dwellStart = nil; return .outside }
        if let lastEntry, uptime - lastEntry < area.cooldown { dwellStart = nil; return .cooldown }
        if dwellStart == nil { dwellStart = uptime }
        guard let dwellStart, uptime - dwellStart >= area.dwell else { return .dwelling }
        inside = true; lastEntry = uptime; self.dwellStart = nil; return .entered
    }
}

struct SoloMilestone: Codable, Identifiable, Sendable {
    var id = UUID()
    var meters: Double
    var sceneID: UUID
}
struct SoloTrip {
    private(set) var meters = 0.0
    private(set) var running = false
    private(set) var fired: Set<UUID> = []
    private var anchor: SoloFix?
    private var lastCelebration: Date?
    mutating func start() { running = true; anchor = nil }
    mutating func pause() { running = false; anchor = nil }
    mutating func discardSample() { anchor = nil }
    mutating func reset() { self = Self() }
    mutating func sample(_ fix: SoloFix, now: Date, milestones: [SoloMilestone]) -> [SoloMilestone] {
        guard running, fix.usable(at: now) else { anchor = nil; return [] }
        guard let previous = anchor else { anchor = fix; return [] }
        let elapsed = fix.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { anchor = nil; return [] }
        guard elapsed <= 10 else { anchor = fix; return [] }
        let delta = previous.point.distance(to: fix.point)
        // Ignore noise and large discontinuities; no pace or speed objective is computed.
        guard delta > max(previous.accuracy, fix.accuracy), delta <= 100 else {
            if delta > 100 { anchor = fix }
            return []
        }
        meters += max(0, delta - max(previous.accuracy, fix.accuracy))
        anchor = fix
        guard lastCelebration == nil || now.timeIntervalSince(lastCelebration!) >= 60 else { return [] }
        let due = milestones.filter { $0.meters <= meters && !fired.contains($0.id) }.sorted { $0.meters < $1.meters }
        guard let next = due.first else { return [] }
        fired.insert(next.id); lastCelebration = now
        return [next]
    }
}
struct SoloUnlock: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let sceneID: UUID
    let manual: Bool
}
struct SoloRecap: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let approximateMeters: Double
    let summaries: [String]
    // No coordinate, sample, route, time series or server receipt belongs in this type.
}
struct SoloDaylightPlan: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var point: SoloPoint
    var timeZoneID: String
    var sunriseSceneID: UUID
    var sunsetSceneID: UUID
    var brightness: Double?
    var duration: Double = 60
    func validate() throws {
        try SoloBounds.name(name); try point.validate()
        guard TimeZone(identifier: timeZoneID) != nil, duration.isFinite, (10...300).contains(duration),
              brightness == nil || (brightness!.isFinite && (0.1...0.6).contains(brightness!)) else {
            throw BackpackError.invalid("Choose an explicit time zone, a 10…300 second window and optional PHONE brightness 10…60%. No system maximum or authored dimming change.")
        }
    }
}
enum SoloBounds {
    static func name(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf16.count <= 120 else {
            throw BackpackError.invalid("Enter a nonempty local name up to 120 UTF-16 units.")
        }
    }
}
struct SoloArchive: Codable, Sendable {
    var schema = 1
    var scenes: [SoloScene] = []
    var areas: [SoloArea] = []
    var milestones: [SoloMilestone] = []
    var daylight: [SoloDaylightPlan] = []
    var unlocks: [SoloUnlock] = []
    var recaps: [SoloRecap] = []
    func validate() throws {
        guard schema == 1, scenes.count <= 20, areas.count <= 30, milestones.count <= 20,
              daylight.count <= 10, unlocks.count <= 50, recaps.count <= 30,
              Set(scenes.map(\.id)).count == scenes.count, Set(areas.map(\.id)).count == areas.count,
              Set(milestones.map(\.id)).count == milestones.count,
              Set(daylight.map(\.id)).count == daylight.count, Set(unlocks.map(\.id)).count == unlocks.count,
              Set(recaps.map(\.id)).count == recaps.count,
              scenes.flatMap(\.items).reduce(0, { $0 + $1.bytes.count }) <= 40_000_000 else {
            throw BackpackError.invalid("Local scenes storage is full or invalid (20 scenes / 40 MB, 30 areas, 20 milestones, 10 daylight plans, 50 badges, 30 recaps). Delete explicitly; nothing is evicted.")
        }
        let ids = Set(scenes.map(\.id))
        for scene in scenes { try scene.validate() }
        for area in areas { try area.validate(); guard ids.contains(area.sceneID) else { throw BackpackError.invalid("Area scene is missing.") } }
        for milestone in milestones {
            guard milestone.meters.isFinite, (100...1_000_000).contains(milestone.meters), ids.contains(milestone.sceneID) else {
                throw BackpackError.invalid("Milestones require a selected local scene and 100…1,000,000 approximate meters.")
            }
        }
        for plan in daylight {
            try plan.validate()
            guard ids.contains(plan.sunriseSceneID), ids.contains(plan.sunsetSceneID) else { throw BackpackError.invalid("Daylight palette scene is missing.") }
        }
        for unlock in unlocks { try SoloBounds.name(unlock.name) }
        for recap in recaps {
            try SoloBounds.name(recap.name)
            guard recap.approximateMeters.isFinite, (0...100_000_000).contains(recap.approximateMeters),
                  recap.summaries.count <= 50 else { throw BackpackError.invalid("Invalid bounded distance-only recap.") }
            for summary in recap.summaries { try SoloBounds.name(summary) }
        }
    }
}
