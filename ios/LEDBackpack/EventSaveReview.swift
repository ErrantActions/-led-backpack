import SwiftUI
import BackpackProtocol

enum NativeEventFixedPointInput {
    static func parse(latitude: String, longitude: String) throws -> EventCoordinate {
        guard let latitude = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let longitude = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BackpackError.invalid("Enter explicit decimal latitude and longitude; no coordinates are inferred.")
        }
        let point = EventCoordinate(latitude: latitude, longitude: longitude)
        try point.validate(); return point
    }
}

struct NativeEventDefinitionReview: Identifiable {
    let id = UUID()
    let input: CatalogEventInput
    let bytes: Data
    let scope: UUID
    let retainsMembership: Bool
    init(input: CatalogEventInput, original: CatalogEvent?, scope: UUID) throws {
        try input.validate()
        self.input = input; self.scope = scope
        bytes = try JSONEncoder().encode(input)
        retainsMembership = ["public", "unlisted"].contains(original?.visibility ?? "") && input.visibility == "private"
    }
    func matches(_ input: CatalogEventInput?) -> Bool {
        guard let input, let other = try? JSONEncoder().encode(input) else { return false }
        return NativeEventReviewEquality.equal(bytes, other)
    }
}
enum NativeEventReviewEquality {
    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        let decoder = JSONDecoder()
        guard let a = try? decoder.decode(Value.self, from: lhs), let b = try? decoder.decode(Value.self, from: rhs) else { return false }
        return a == b
    }
    private indirect enum Value: Decodable, Equatable {
        case object([String: Value]), array([Value]), string(String), number(Double), boolean(Bool), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .boolean(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode([String: Value].self) { self = .object(v) }
            else { self = .array(try c.decode([Value].self)) }
        }
    }
}
struct NativeEventRouteReview: Identifiable {
    let id = UUID()
    let draft: EventRouteDraft
    let bytes: Data
    init(_ draft: EventRouteDraft) throws {
        try draft.body.normalized().validate()
        self.draft = draft; bytes = try JSONEncoder().encode(draft.body.normalized())
    }
    func matches(_ current: EventRouteDraft?) -> Bool {
        guard let current, current.original.id == draft.original.id,
              let other = try? JSONEncoder().encode(current.body.normalized()) else { return false }
        return NativeEventReviewEquality.equal(bytes, other)
    }
}

@MainActor
struct EventDefinitionReviewView: View {
    let captured: NativeEventDefinitionReview
    var busy = false
    let back: () -> Void
    let confirm: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(alignment: .leading, spacing: 22) {
                let input = captured.input
                EventInvitationPoster(title: input.title, kind: input.kind)
                VStack(alignment: .leading, spacing: 18) {
                    EventScheduleView(input: input)
                    FeatureRowLabel(title: input.location.label, symbol: "mappin.and.ellipse")
                    LabeledContent("Audience", value: input.visibility == "unlisted" ? "Anyone with the link" : input.visibility.capitalized)
                    LabeledContent("Capacity", value: String(input.capacity))
                }.padding(18).background(AuroraSurface())
                if !input.description.isEmpty {
                    DisclosureGroup("About this event") { Text(input.description) }
                }
                FeatureDetails("Exact saved fields") {
                    Text(input.expectedRevision.map { "Captured event revision \($0)" } ?? "Create new event")
                    Text(input.title); Text(input.description)
                    Text("Kind: \(input.kind ?? "omitted / existing unchanged")")
                    Text("\(input.startsAtISO) – \(input.endsAtISO)")
                    Text("IANA timezone: \(input.timezone)")
                    Text("Visibility: \(input.visibility) · capacity \(input.capacity)")
                    Text("Link-readable consent: \(input.unlistedLinkConsent == true ? "explicitly given" : "not added")")
                    Text("Fixed venue: \(input.location.label)")
                    Text("\(input.location.latitude), \(input.location.longitude) · radius \(input.location.radiusMeters)m")
                }
                if input.visibility != "private" {
                    Label(input.visibility == "unlisted" ?
                        "Anyone with the link can see the details and venue. This is not private." :
                        "Public details and the venue are visible to everyone.", systemImage: "eye")
                        .font(.subheadline)
                }
                if captured.retainsMembership {
                    Label("Existing invitations and memberships stay active.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Changing to private doesn't remove people or earlier copies.").font(.caption)
                }
                Text("No invites sent. No GPS or progress sharing started.").font(.caption).foregroundStyle(.secondary)
              }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if busy { ProgressView("Saving event") }
                    Button(captured.input.expectedRevision == nil ? "Create event" : "Save changes", action: confirm)
                        .buttonStyle(AuroraPrimaryButton()).disabled(busy)
                        .accessibilityIdentifier("event-save")
                    Button("Back to editing", role: .cancel, action: back).frame(minHeight: 44).disabled(busy)
                }.padding(.horizontal, 20).padding(.vertical, 12).background(Aurora.surface)
            }
            .modernScene().navigationTitle("Your invitation").navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
        }
    }
}

@MainActor
struct EventRouteReviewView: View {
    let captured: NativeEventRouteReview
    let back: () -> Void
    let confirm: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                let draft = captured.draft, event = draft.original
                Section(event.title) {
                    Text("\(draft.body.normalized().checkpoints.count) checkpoints · \(draft.body.geometry.count) guide points")
                    Text(draft.published ? "Published route" : "Unpublished draft")
                }
                FeatureDetails("Exact route & artwork") {
                    Text("Event context (NOT saved): \(event.title)")
                    Text("\(event.startsAtISO) – \(event.endsAtISO) / \(event.timezone)")
                    Text("\(event.visibility) · fixed venue \(event.location.label): \(event.location.latitude), \(event.location.longitude), \(event.location.radiusMeters)m")
                    Text("Published \(draft.published ? "yes" : "no") · ordered stages, required start/finish; optional intermediates may be skipped")
                    ForEach(draft.body.normalized().checkpoints) { checkpoint in
                        Text("\(checkpoint.order + 1). \(checkpoint.kind.rawValue) · \(checkpoint.title) · ID \(checkpoint.id.uuidString)")
                        Text("\(checkpoint.latitude), \(checkpoint.longitude), radius \(checkpoint.radiusMeters)m · \(checkpoint.optional == true ? "OPTIONAL" : "required")")
                        Text(artwork(checkpoint.gifItemId, checkpoint.exclusiveGifId)).font(.caption)
                    }
                    ForEach(Array(draft.body.geometry.enumerated()), id: \.offset) { index, point in
                        Text("Fixed guide \(index + 1): \(point.latitude), \(point.longitude)")
                    }
                    ForEach(draft.body.normalized().badges) { badge in
                        Text("Finish reward \(badge.title): \(badge.description)")
                        Text(artwork(badge.gifItemId, badge.exclusiveGifId)).font(.caption)
                    }
                }
                Text("Saves this route only. No schedule, GPS or participation changes. Existing recipients can retain earlier copies.").font(.caption)
                Button("Save reviewed route", action: confirm).buttonStyle(AuroraPrimaryButton())
                Button("Back — no write", role: .cancel, action: back)
            }.modernScene().navigationTitle("Review route").buttonStyle(.borderless)
        }
    }
    private func artwork(_ community: UUID?, _ exclusive: UUID?) -> String {
        if let community { return "Current authorized community artwork \(community.uuidString)" }
        if let exclusive { return "Current authorized event-exclusive artwork \(exclusive.uuidString)" }
        return "Artwork: none"
    }
}
