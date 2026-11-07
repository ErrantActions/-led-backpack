import SwiftUI
import BackpackProtocol

enum EventCreationStep: Int, CaseIterable, Identifiable {
    case basics, time, venue, review
    var id: Int { rawValue }
    var title: String { ["Basics","Time","Venue","Review"][rawValue] }
    func canAdvance(title: String, startChosen: Bool, endChosen: Bool, start: Date, end: Date,
        zone: String, venue: CatalogEventLocation?, venueConfirmed: Bool) -> Bool {
        switch self {
        case .basics: return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf16.count <= 160
        case .time: return startChosen && endChosen && end > start && TimeZone(identifier: zone) != nil
        case .venue: return venueConfirmed && venue.map { (try? $0.validate()) != nil } == true
        case .review: return false
        }
    }
}
@MainActor
struct EventCreationNextSteps: View {
    let event: CatalogEvent
    @State private var routeSaved = false
    var body: some View {
        List {
            Section("Event created") {
                Text(event.title).font(.title2.bold())
                Text("The event is saved. Routes, checkpoints, invitations and game choices are separate reviewed actions—not automatic GPS grants or publication.").font(.caption)
            }
            Section("Shape the experience") {
                NavigationLink("Place start/finish gates and ride/game checkpoints") {
                    EventRoutePlannerView(original: event, saved: { routeSaved = true })
                }.disabled(!event.access.canManageRoute || event.cancelled)
                if routeSaved { Text("Route save acknowledged. Open the event to review its current plan and participation rules.").font(.caption) }
                Text("Pick start and destination, generate a driving/walking road route, drag shaping handles to choose different roads, then tap the route to drop checkpoints. Review the exact plan before saving. Route previews are not live navigation, safety certification or saved participant tracks.").font(.caption)
                NavigationLink("Open event / invite friends / manage participants") { CommunityEventDetailView(id: event.id) }
            }
        }.navigationTitle("Next: gates & checkpoints")
    }
}
