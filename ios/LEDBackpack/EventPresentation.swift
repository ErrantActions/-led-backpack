import SwiftUI
import BackpackProtocol

struct EventScheduleSummary {
    let day, month, date, time: String

    init(startsAtISO: String, endsAtISO: String, timezone: String, locale: Locale = .current) throws {
        let start = try CatalogEventTime.parse(startsAtISO)
        let end = try CatalogEventTime.parse(endsAtISO)
        guard let zone = TimeZone(identifier: timezone), end > start else {
            throw BackpackError.invalid("Review the event's time zone and schedule.")
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        func format(_ value: Date, _ template: String) -> String {
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: value)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        day = format(start, "d")
        month = format(start, "MMM")
        date = format(start, "EEEE MMMM d y")
        let startZone = zone.abbreviation(for: start) ?? timezone
        let endZone = zone.abbreviation(for: end) ?? timezone
        let endTemplate = calendar.isDate(start, inSameDayAs: end) ? "jm" : "EEE MMM d y jm"
        time = "\(format(start, "jm")) \(startZone) - \(format(end, endTemplate)) \(endZone)"
    }

    init(event: CatalogEvent) throws {
        try self.init(startsAtISO: event.startsAtISO, endsAtISO: event.endsAtISO, timezone: event.timezone)
    }
}

extension CatalogEventList {
    var title: String {
        switch self {
        case .accessible: return "Explore"
        case .mine: return "Yours"
        case .invitations: return "Invites"
        }
    }
    var emptyMessage: String {
        switch self {
        case .accessible: return "Create a plan or come back for more."
        case .mine: return "Your events will appear here."
        case .invitations: return "New invitations will appear here."
        }
    }
}

@MainActor
struct EventDiscoveryEntryLabel: View {
    var available: Bool
    var signedIn: Bool
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "calendar")
                .font(.largeTitle).foregroundStyle(Aurora.mint)
                .frame(width: 56, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Events").font(.title2.bold()).foregroundStyle(Aurora.ink)
                Text(available ? "Explore. Get invited. Make a plan." : signedIn ? "Unavailable on this server" : "Sign in to join in")
                    .font(.subheadline).foregroundStyle(Aurora.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").foregroundStyle(Aurora.mint).accessibilityHidden(true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Aurora.lavenderSurface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Aurora.lavender.opacity(0.35)))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct EventInvitationPoster: View {
    let title: String
    var kind: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: kind == "group-ride" ? "bicycle" : "sparkles")
                    .font(.system(size: 44, weight: .light))
                Spacer()
                Image(systemName: "sparkle").font(.title2)
            }.foregroundStyle(Aurora.mint).accessibilityHidden(true)
            Text(title).font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(Aurora.ink).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 26).fill(Aurora.lavenderSurface)
                Circle().fill(Aurora.rose.opacity(0.12)).frame(width: 160, height: 160).offset(x: 50, y: -55)
                Circle().strokeBorder(Aurora.mint.opacity(0.22), lineWidth: 18)
                    .frame(width: 190, height: 190).offset(x: 10, y: 25)
            }.clipShape(RoundedRectangle(cornerRadius: 26)).accessibilityHidden(true)
        }
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Aurora.lavender.opacity(0.3)))
    }
}

@MainActor
struct EventScheduleView: View {
    let startsAtISO, endsAtISO, timezone: String
    init(event: CatalogEvent) {
        startsAtISO = event.startsAtISO; endsAtISO = event.endsAtISO; timezone = event.timezone
    }
    init(input: CatalogEventInput) {
        startsAtISO = input.startsAtISO; endsAtISO = input.endsAtISO; timezone = input.timezone
    }
    var body: some View {
        switch Result(catching: { try EventScheduleSummary(startsAtISO: startsAtISO, endsAtISO: endsAtISO, timezone: timezone) }) {
        case .success(let summary):
            FeatureRowLabel(title: summary.date, symbol: "calendar", subtitle: summary.time, tint: Aurora.lavender)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

@MainActor
struct EventInvitationCard: View {
    let value: TimedCatalogEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                dateBadge
                VStack(alignment: .leading, spacing: 7) {
                    Text(value.event.title).font(.title3.bold()).foregroundStyle(Aurora.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(value.event.location.label, systemImage: "mappin")
                        .font(.subheadline).foregroundStyle(Aurora.supporting)
                    if let host = value.event.organizers.first {
                        Text("Hosted by \(host.displayName)").font(.caption).foregroundStyle(Aurora.supporting)
                    }
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(minLength: 0); visibility }
                VStack(alignment: .leading, spacing: 8) { status; visibility }
            }
            EventInvitationDeadlineView(event: value.event)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(AuroraSurface(radius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
    private var status: some View {
        Group {
            if value.event.moderation?.held == true {
                StatusPill(title: "On hold", symbol: "lock", color: Aurora.rose)
            } else if value.event.cancelled {
                StatusPill(title: "Cancelled", symbol: "calendar.badge.exclamationmark", color: Aurora.rose)
            } else if value.event.requiresReconfirmation == true {
                StatusPill(title: "Review changes", symbol: "exclamationmark.triangle", color: Aurora.rose)
            } else if value.event.rsvpStatus == .going {
                StatusPill(title: "Going", symbol: "checkmark", color: Aurora.mint)
            } else {
                Text(value.event.status == .inProgress ? "Happening now" : value.event.status == .ended ? "Ended" : "Coming up")
                    .font(.caption.weight(.semibold)).foregroundStyle(Aurora.lavender)
            }
        }
    }
    private var visibility: some View {
        Label(value.event.visibility.capitalized, systemImage: value.event.visibility == "private" ? "lock" : "link")
            .font(.caption).foregroundStyle(Aurora.supporting)
    }
    @ViewBuilder private var dateBadge: some View {
        switch Result(catching: { try EventScheduleSummary(event: value.event) }) {
        case .success(let summary):
            VStack(spacing: 2) {
                Text(summary.month.uppercased()).font(.caption.weight(.bold))
                Text(summary.day).font(.system(.title, design: .rounded, weight: .bold))
            }
            .foregroundStyle(Aurora.lavender).padding(12)
            .background(Aurora.lavenderSurface, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.date + ", " + summary.time)
        case .failure(let error):
            Text(error.localizedDescription).font(.caption).foregroundStyle(.orange)
        }
    }
}
