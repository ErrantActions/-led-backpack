import SwiftUI
import MapKit
import BackpackProtocol

struct OrganizerMapPin: Identifiable {
    let id, title, symbol: String
    let point: EventCoordinate
    let radius: Double
    var draggable = true
}

@MainActor
struct OrganizerMap: UIViewRepresentable {
    let pins: [OrganizerMapPin]
    let geometry: [EventCoordinate]
    let editable: Bool
    let fit: UUID
    let reducedMotion: Bool
    let tap: (EventCoordinate) -> Void
    let moved: (String, EventCoordinate) -> Void
    let selected: (String) -> Void
    let failed: (String) -> Void

    @MainActor
    final class Annotation: MKPointAnnotation {
        let key: String
        var symbol: String
        var canDrag: Bool
        init(_ pin: OrganizerMapPin) {
            key = pin.id; symbol = pin.symbol; canDrag = pin.draggable
            super.init()
            title = pin.title; subtitle = "Fixed organizer point"
            coordinate = CLLocationCoordinate2D(latitude: pin.point.latitude, longitude: pin.point.longitude)
        }
    }
    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: OrganizerMap
        var lastFit: UUID?
        var overlayKey = ""
        init(_ parent: OrganizerMap) { self.parent = parent }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is MKAnnotationView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard parent.editable, let map = gesture.view as? MKMapView else { return }
            let point = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            parent.tap(EventCoordinate(latitude: point.latitude, longitude: point.longitude))
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? Annotation else { return nil }
            let identifier = "organizer-fixed-point"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation; view.isDraggable = parent.editable && annotation.canDrag; view.canShowCallout = true
            view.glyphText = annotation.symbol
            view.markerTintColor = UIColor(annotation.key == "venue" ? Aurora.mint : Aurora.lavender)
            view.accessibilityLabel = annotation.title
            view.accessibilityHint = parent.editable && annotation.canDrag
                ? "Fixed organizer geometry. Select to edit; drag to move." : "Fixed read-only event geometry."
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let annotation = view.annotation as? Annotation { parent.selected(annotation.key) }
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard newState == .ending, parent.editable, let annotation = view.annotation as? Annotation, annotation.canDrag else { return }
            parent.moved(annotation.key, EventCoordinate(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude))
            view.setDragState(.none, animated: false)
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = UIColor(Aurora.mint).withAlphaComponent(0.7)
                renderer.fillColor = UIColor(Aurora.mint).withAlphaComponent(0.08); renderer.lineWidth = 2
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor(Aurora.lavender); renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            parent.failed("Apple Maps could not load. Your local draft is retained. \(error.localizedDescription)")
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false; map.isPitchEnabled = false; map.pointOfInterestFilter = .excludingAll
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 150, longitudeDelta: 350)), animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator; tap.cancelsTouchesInView = false
        for gesture in map.gestureRecognizers ?? [] {
            if let doubleTap = gesture as? UITapGestureRecognizer, doubleTap.numberOfTapsRequired > 1 { tap.require(toFail: doubleTap) }
        }
        map.addGestureRecognizer(tap)
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let existing = map.annotations.compactMap { $0 as? Annotation }
        let keys = Set(pins.map(\.id))
        map.removeAnnotations(existing.filter { !keys.contains($0.key) })
        for pin in pins {
            if let old = existing.first(where: { $0.key == pin.id }) {
                if map.view(for: old)?.dragState != .dragging {
                    old.coordinate = CLLocationCoordinate2D(latitude: pin.point.latitude, longitude: pin.point.longitude)
                }
                old.title = pin.title; old.symbol = pin.symbol; old.canDrag = pin.draggable
                if let view = map.view(for: old) as? MKMarkerAnnotationView {
                    view.isDraggable = editable && pin.draggable; view.glyphText = pin.symbol; view.accessibilityLabel = pin.title
                    view.accessibilityHint = editable && pin.draggable
                        ? "Fixed organizer geometry. Select to edit; drag to move." : "Fixed read-only event geometry."
                }
            } else { map.addAnnotation(Annotation(pin)) }
        }
        let key = pins.map { "\($0.id):\($0.point):\($0.radius)" }.joined() + geometry.description
        if key != coordinator.overlayKey {
            map.removeOverlays(map.overlays)
            for pin in pins where pin.radius > 0 {
                map.addOverlay(MKCircle(center: CLLocationCoordinate2D(latitude: pin.point.latitude, longitude: pin.point.longitude), radius: pin.radius))
            }
            if geometry.count > 1 {
                let coordinates = geometry.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
            }
            coordinator.overlayKey = key
        }
        if coordinator.lastFit != fit, let first = pins.first {
            let points = pins.map(\.point) + geometry
            if points.count == 1 {
                map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: first.point.latitude, longitude: first.point.longitude),
                    latitudinalMeters: max(800, first.radius * 4), longitudinalMeters: max(800, first.radius * 4)), animated: !reducedMotion)
            } else {
                let rect = points.reduce(MKMapRect.null) { result, point in
                    let position = MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                    return result.union(MKMapRect(x: position.x, y: position.y, width: 1, height: 1))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 55, left: 45, bottom: 60, right: 45), animated: !reducedMotion)
            }
            coordinator.lastFit = fit
        }
    }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) { map.delegate = nil; map.removeOverlays(map.overlays); map.removeAnnotations(map.annotations) }
}

@MainActor
final class OrganizerPlaceSearch: ObservableObject {
    struct Place: Identifiable {
        let id = UUID()
        let name: String
        let point: EventCoordinate
    }
    @Published private(set) var places: [Place] = []
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    private var request: MKLocalSearch?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func search(_ text: String) {
        cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 200 else {
            failure = "Enter a place/address of at most 200 characters."; return
        }
        let stamp = UUID(); generation = stamp; busy = true; failure = nil; places = []
        let query = MKLocalSearch.Request()
        query.naturalLanguageQuery = text
        query.resultTypes = [.address, .pointOfInterest]
        query.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 150, longitudeDelta: 350))
        let search = MKLocalSearch(request: query); request = search
        task = Task {
            do {
                let result = try await search.start()
                try Task.checkCancellation()
                guard stamp == generation else { return }
                places = result.mapItems.compactMap { item in
                    guard let location = item.placemark.location else { return nil }
                    return Place(name: item.name ?? item.placemark.title ?? "Selected place",
                        point: EventCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
                }
                if places.isEmpty { failure = "No fixed places were found. Try another address or place a point on the map." }
            } catch { if stamp == generation && !Task.isCancelled { failure = error.localizedDescription } }
            if stamp == generation { busy = false }
        }
    }
    func cancel() { request?.cancel(); request = nil; task?.cancel(); task = nil; busy = false; generation = UUID() }
}

@MainActor
struct OrganizerPlaceSearchView: View {
    @StateObject private var search = OrganizerPlaceSearch()
    @State private var query = ""
    let choose: (OrganizerPlaceSearch.Place) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search a fixed place or address", text: $query).submitLabel(.search).onSubmit { search.search(query) }
                .autocorrectionDisabled()
            Button("Search Apple Maps") { search.search(query) }.disabled(search.busy)
            if search.busy { ProgressView() }
            if let failure = search.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            ForEach(search.places) { place in
                Button { choose(place); search.cancel() } label: {
                    Label(place.name, systemImage: "mappin.and.ellipse").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
            }
        }.onDisappear { search.cancel() }
    }
}

@MainActor
struct FixedVenueMapEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var phase
    @Binding var venue: CatalogEventLocation?
    let enabled: Bool
    @State private var consent = false
    @State private var radiusMode = false
    @State private var fit = UUID()
    @State private var failure: String?
    @State private var numericLatitude = ""
    @State private var numericLongitude = ""
    @State private var numericLabel = ""
    @State private var numericRadius = ""
    private var pins: [OrganizerMapPin] {
        venue.map { [OrganizerMapPin(id: "venue", title: $0.label, symbol: "V",
            point: EventCoordinate(latitude: $0.latitude, longitude: $0.longitude), radius: $0.radiusMeters)] } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let venue { Text(venue.label).font(.headline) }
            if enabled {
                Toggle("Search places with Apple Maps", isOn: $consent)
                Text("Apple receives map views and place searches. Device GPS stays off; account details and event links aren't sent.")
                    .font(.caption).foregroundStyle(.secondary)
                if consent && phase == .active {
                    OrganizerPlaceSearchView { place in
                        do {
                            try place.point.validate()
                            venue = CatalogEventLocation(label: place.name, latitude: place.point.latitude, longitude: place.point.longitude,
                                radiusMeters: venue?.radiusMeters ?? 100)
                            fit = UUID()
                        } catch { failure = error.localizedDescription }
                    }

                    DisclosureGroup("Adjust venue area") {
                        Toggle("Tap the circle edge to change radius", isOn: $radiusMode)
                    }
                    OrganizerMap(pins: pins, geometry: [], editable: true, fit: fit, reducedMotion: reducedMotion,
                        tap: tapped, moved: { _, point in setPoint(point) }, selected: { _ in }, failed: { failure = $0 })
                        .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 22))
                    Text("Choose a search result, tap the map or drag the pin.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Fit venue") { fit = UUID() }
                }
            } else { Text("Map planning is unavailable until the server advertises its capability. Existing venue details are preserved.").font(.caption) }
            if venue != nil {
                TextField("Venue name", text: Binding(get: { venue?.label ?? "" }, set: { venue?.label = $0 }))
                Stepper("Venue area: \(Int(venue?.radiusMeters ?? 100))m",
                    value: Binding(get: { venue?.radiusMeters ?? 100 }, set: { venue?.radiusMeters = $0 }), in: 1...100000, step: 5)
            }
            if enabled {
                DisclosureGroup("Enter coordinates instead") {
                TextField("Venue name", text: $numericLabel)
                TextField("Decimal latitude (−90…90)", text: $numericLatitude).keyboardType(.numbersAndPunctuation)
                TextField("Decimal longitude (−180…180)", text: $numericLongitude).keyboardType(.numbersAndPunctuation)
                TextField("Explicit radius in meters (1…100000)", text: $numericRadius).keyboardType(.decimalPad)
                Button("Use current venue values") {
                    guard let venue else { return }
                    numericLabel = venue.label; numericLatitude = String(venue.latitude)
                    numericLongitude = String(venue.longitude); numericRadius = String(venue.radiusMeters)
                }.disabled(venue == nil)
                Button("Use this venue") {
                    do {
                        let point = try NativeEventFixedPointInput.parse(latitude: numericLatitude, longitude: numericLongitude)
                        guard let radius = Double(numericRadius) else { throw BackpackError.invalid("Enter an explicit radius.") }
                        let value = CatalogEventLocation(label: numericLabel, latitude: point.latitude, longitude: point.longitude, radiusMeters: radius)
                        try value.validate(); venue = value; fit = UUID(); failure = nil
                    } catch { failure = error.localizedDescription }
                }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func setPoint(_ point: EventCoordinate) {
        do {
            try point.validate()
            venue = CatalogEventLocation(label: venue?.label ?? "Selected venue", latitude: point.latitude, longitude: point.longitude,
                radiusMeters: venue?.radiusMeters ?? 100)
        } catch { failure = error.localizedDescription }
    }
    private func tapped(_ point: EventCoordinate) {
        if radiusMode, var current = venue {
            let center = MKMapPoint(CLLocationCoordinate2D(latitude: current.latitude, longitude: current.longitude))
            let edge = MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            let radius = center.distance(to: edge)
            guard radius.isFinite, (1...100000).contains(radius) else { failure = "Choose a circle radius between 1m and 100km."; return }
            current.radiusMeters = radius.rounded(); venue = current
        } else { setPoint(point) }
    }
}

@MainActor
struct FixedEventPlanPreview: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let event: CatalogEvent
    let route: CatalogEventRoute
    @State private var imagery = false
    @State private var fit = UUID()
    @State private var failure: String?
    private var pins: [OrganizerMapPin] {
        let venue = event.location
        return [OrganizerMapPin(id: "venue", title: venue.label, symbol: "V",
            point: EventCoordinate(latitude: venue.latitude, longitude: venue.longitude), radius: venue.radiusMeters, draggable: false)]
            + route.checkpoints.map { OrganizerMapPin(id: $0.id.uuidString, title: $0.title,
                symbol: $0.kind == .start ? "S" : $0.kind == .finish ? "F" : String($0.order + 1),
                point: $0.point, radius: $0.radiusMeters, draggable: false) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(route.published ? "Published fixed checkpoint plan" : "Plan not published").font(.subheadline.weight(.semibold))
            ForEach(route.checkpoints) { checkpoint in
                Text("\(checkpoint.order + 1). \(checkpoint.title) / \(checkpoint.kind.rawValue) / \(Int(checkpoint.radiusMeters))m").font(.caption)
            }
            ForEach(event.badges ?? []) { reward in Text("Finish reward: \(reward.title). \(reward.description)").font(.caption) }
            Text("Review these definitions before reconfirming. Progress/rewards are self-reported, not certified attendance. No progress is shared by this view.")
                .font(.caption).foregroundStyle(.secondary)
            if community.config?.eventsEnabled == true {
                Toggle("View fixed plan with Apple Maps", isOn: $imagery)
                Text("Apple Maps may fetch visible maps. No participant pins, device GPS, account token or event URL is supplied by this app.")
                    .font(.caption).foregroundStyle(.secondary)
                if imagery && phase == .active {
                    OrganizerMap(pins: pins, geometry: route.geometry, editable: false, fit: fit, reducedMotion: reducedMotion,
                        tap: { _ in }, moved: { _, _ in }, selected: { _ in }, failed: { failure = $0 })
                        .frame(height: 290).clipShape(RoundedRectangle(cornerRadius: 22))
                    Button("Fit fixed plan") { fit = UUID() }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
    }
}
