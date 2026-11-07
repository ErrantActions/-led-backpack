import Foundation
import MapKit
import Combine
import BackpackProtocol

enum EventRoadMode: String, CaseIterable, Identifiable {
    case driving, walking
    var id: String { rawValue }
    var transport: MKDirectionsTransportType { self == .driving ? .automobile : .walking }
}
struct EventRouteProjection {
    let point: EventCoordinate
    let distance, along: Double
}
enum EventRoadGeometry {
    static func nearest(_ point: EventCoordinate, to line: [EventCoordinate]) throws -> EventRouteProjection {
        try point.validate()
        guard (2...12_000).contains(line.count) else { throw BackpackError.invalid("Generate a bounded road route before placing a checkpoint or reshaping it.") }
        let target = mapPoint(point)
        var best: EventRouteProjection?
        var travelled = 0.0
        for index in 1..<line.count {
            try line[index - 1].validate(); try line[index].validate()
            let a = mapPoint(line[index - 1]), b = mapPoint(line[index])
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let fraction = length == 0 ? 0 : max(0, min(1, ((target.x - a.x) * dx + (target.y - a.y) * dy) / length))
            let projected = MKMapPoint(x: a.x + fraction * dx, y: a.y + fraction * dy)
            let coordinate = projected.coordinate
            let distance = target.distance(to: projected)
            let value = EventRouteProjection(point: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                distance: distance, along: travelled + a.distance(to: projected))
            if best == nil || distance < best!.distance { best = value }
            travelled += a.distance(to: b)
        }
        guard let best, best.distance.isFinite, best.along.isFinite else { throw BackpackError.invalid("Route projection is unavailable for this map geometry.") }
        return best
    }
    static func mapPoint(_ point: EventCoordinate) -> MKMapPoint {
        MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
    }
    static func bounded(_ points: [EventCoordinate], tolerance: Double = 10) throws -> [EventCoordinate] {
        guard (2...12_000).contains(points.count), tolerance.isFinite, (0...25).contains(tolerance) else {
            throw BackpackError.invalid("Road geometry exceeds its processing bounds.")
        }
        for point in points { try point.validate() }
        var keep: Set<Int> = [0, points.count - 1]
        var stack = [(0,points.count - 1)]
        while let (start,end) = stack.popLast() {
            try Task.checkCancellation()
            guard end > start + 1 else { continue }
            var farthest = tolerance, index: Int?
            for current in (start + 1)..<end {
                let distance = try nearest(points[current], to: [points[start],points[end]]).distance
                if distance > farthest { farthest = distance; index = current }
            }
            if let index {
                keep.insert(index)
                guard keep.count <= 200 else { throw BackpackError.invalid("This road route needs more than200 saved guide points at10m accuracy. Use a shorter route or split the event; no route is silently truncated.") }
                stack.append((start,index)); stack.append((index,end))
            }
        }
        return keep.sorted().map { points[$0] }
    }
}
struct EventRoadWaypoint: Identifiable, Equatable {
    let id: UUID
    var point: EventCoordinate
}
struct EventRoadResult {
    let full, saved: [EventCoordinate]
    let meters, seconds: Double
}
@MainActor
final class EventRoadRouteStore: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var result: EventRoadResult?
    @Published private(set) var waypoints: [EventRoadWaypoint] = []
    @Published private(set) var failure: String?
    @Published private(set) var needsRegeneration = false
    private var request: MKDirections?
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    func cancel() { epoch = UUID(); request?.cancel(); request = nil; task?.cancel(); task = nil; busy = false }
    func clear() { cancel(); result = nil; waypoints = []; failure = nil; needsRegeneration = false }
    func endpointsChanged() {
        let wasGenerated = result != nil || needsRegeneration
        cancel(); failure = nil; needsRegeneration = wasGenerated
    }
    func addShapingPoint(_ point: EventCoordinate) throws {
        guard !busy, waypoints.count < 8, let result else { throw BackpackError.invalid("Generate the route first; at most8 draggable shaping points.") }
        let projected = try EventRoadGeometry.nearest(point, to: result.full)
        guard projected.distance <= 100 else { throw BackpackError.invalid("Tap the blue route to add a shaping handle, then drag that handle to the road you want.") }
        let index = try waypoints.firstIndex { try EventRoadGeometry.nearest($0.point, to: result.full).along > projected.along } ?? waypoints.count
        waypoints.insert(.init(id: UUID(), point: projected.point), at: index)
    }
    func moveShapingPoint(_ id: UUID, to point: EventCoordinate) throws {
        try point.validate()
        guard !busy, let index = waypoints.firstIndex(where: { $0.id == id }) else { throw BackpackError.invalid("That shaping handle is no longer available.") }
        waypoints[index].point = point; needsRegeneration = true
    }
    func removeShapingPoint(_ id: UUID) {
        guard !busy else { return }
        waypoints.removeAll { $0.id == id }; needsRegeneration = true
    }
    func generate(start: EventCoordinate, end: EventCoordinate, mode: EventRoadMode,
        authorized: @escaping @MainActor () throws -> Void, apply: @escaping @MainActor (EventRoadResult) throws -> Void) {
        cancel(); busy = true; failure = nil; needsRegeneration = true
        let stamp = epoch, routePoints = [start] + waypoints.map(\.point) + [end]
        task = Task {
            defer { if epoch == stamp { busy = false; request = nil } }
            do {
                try authorized()
                guard routePoints.count <= 10, start != end || waypoints.contains(where: { $0.point != start }) else {
                    throw BackpackError.invalid("Choose distinct start/destination places, or a loop with an explicit shaping point. At most8 shaping points.")
                }
                for point in routePoints { try point.validate() }
                var full: [EventCoordinate] = [], meters = 0.0, seconds = 0.0
                for index in 1..<routePoints.count {
                    try Task.checkCancellation(); try authorized()
                    guard epoch == stamp else { throw CancellationError() }
                    let options = MKDirections.Request()
                    options.source = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: routePoints[index - 1].latitude, longitude: routePoints[index - 1].longitude)))
                    options.destination = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: routePoints[index].latitude, longitude: routePoints[index].longitude)))
                    options.transportType = mode.transport; options.requestsAlternateRoutes = false
                    let directions = MKDirections(request: options); request = directions
                    let response = try await directions.calculate()
                    try Task.checkCancellation(); try authorized()
                    guard epoch == stamp, let route = response.routes.first else { throw BackpackError.invalid("Apple Maps returned no usable route. Prior draft remains unchanged.") }
                    guard route.polyline.pointCount >= 2, route.polyline.pointCount + full.count <= 12_000,
                          route.distance.isFinite, route.distance >= 0,
                          route.expectedTravelTime.isFinite, route.expectedTravelTime >= 0 else { throw BackpackError.invalid("Apple route exceeds its bounded geometry/timing policy.") }
                    let coordinates = route.polyline.points()
                    for n in 0..<route.polyline.pointCount {
                        let coordinate = coordinates[n].coordinate
                        let point = EventCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        if full.last != point { full.append(point) }
                    }
                    meters += route.distance; seconds += route.expectedTravelTime
                }
                let captured = full
                let worker = Task.detached { try EventRoadGeometry.bounded(captured) }
                let saved = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try authorized()
                guard epoch == stamp else { throw CancellationError() }
                let value = EventRoadResult(full: full, saved: saved, meters: meters, seconds: seconds)
                try apply(value)
                result = value; needsRegeneration = false
            } catch {
                if epoch == stamp && !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
