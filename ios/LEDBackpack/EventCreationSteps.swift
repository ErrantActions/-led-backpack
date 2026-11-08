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
                Label("Saved", systemImage: "checkmark.circle")
                Text("Creating an event does not start GPS or invite anyone.").font(.caption)
            }
            NavigationLink("Open event") { CommunityEventDetailView(id: event.id) }
                .buttonStyle(AuroraPrimaryButton())
            DisclosureGroup("Add a route & checkpoints") {
                NavigationLink("Place start/finish gates and ride/game checkpoints") {
                    EventRoutePlannerView(original: event, saved: { routeSaved = true })
                }.disabled(!event.access.canManageRoute || event.cancelled)
                if routeSaved { Text("Route save acknowledged. Open the event to review its current plan and participation rules.").font(.caption) }
                Text("Choose start and destination, shape the route, then place checkpoints. Review before saving.").font(.caption)
            }
        }.navigationTitle("Event ready")
    }
}
