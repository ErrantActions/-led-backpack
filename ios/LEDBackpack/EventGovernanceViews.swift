import SwiftUI
import BackpackProtocol

@MainActor
struct EventOwnerToolsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    let eventID: UUID
    let transferred: (CatalogEvent?) -> Void
    @State private var event: CatalogEvent?
    @State private var roster: NativeEventRoster?
    @State private var page = 1
    @State private var auditPage = 1
    @State private var audit: NativeEventOwnershipPage?
    @State private var formerRole = NativeFormerOwnerRole.coorganizer
    @State private var pending: Choice?
    @State private var retainedChoice: Choice?
    @State private var needsReload = false
    @State private var notice: String?
    private struct Choice {
        let event: CatalogEvent
        let person: CatalogEvent.Organizer
        let action: CommunityFeatureClient.OrganizerAction
        let formerRole: NativeFormerOwnerRole?
        let scope: UUID
    }
    var body: some View {
        Form {
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let notice { Text(notice) }
            if session.busy { ProgressView() }
            Button("Explicitly reload owner role / revision") { pending = nil; load() }.disabled(session.busy)
            if needsReload { Text("Conflict: choices are retained. Reload explicitly before selecting or submitting again.") }
            if let retainedChoice {
                Text("Retained choice: \(retainedChoice.action.label), \(retainedChoice.person.displayName), revision \(retainedChoice.event.revision). A reload never rebases it; select again deliberately.").font(.caption)
            }
            if let event, let client = session.client, event.access.role == .owner {
                Text("Current event owner · revision \(event.revision)")
                if let roster {
                    Section("Add named co-organizer from current permitted roster") {
                        ForEach(roster.participants.filter { $0.eventRole == nil }, id: \.user.id) { row in
                            Button("Review adding \(row.user.displayName)") {
                                capture(event, .init(id: row.user.id, displayName: row.user.displayName, eventRole: .coorganizer), .addOrganizer)
                            }.disabled(needsReload || session.busy || event.cancelled)
                        }
                        HStack {
                            Button("Previous roster") { page -= 1; load() }.disabled(page == 1)
                            Button("Next roster") { page += 1; load() }.disabled(page * 24 >= roster.total || page >= 10000)
                        }.disabled(session.busy || needsReload || event.cancelled)
                    }
                }
                Section("Existing named co-organizers") {
                    if client.eventOwnershipAuditAvailable && event.settings?.formerOwnerRoleChoiceEnabled == true {
                        Picker("After ownership transfer, my organizer role", selection: $formerRole) {
                            Text("Explicitly retain co-organizer role").tag(NativeFormerOwnerRole.coorganizer)
                            Text("Explicitly relinquish all management").tag(NativeFormerOwnerRole.none)
                        }
                    } else { Text("When the ownership receipt contract is advertised but role choice is absent, omission retains co-organizer status. Undeployed ownership receipt/audit controls are not enabled on older live servers.") }
                    ForEach(event.organizers.filter { $0.eventRole == .coorganizer }) { person in
                        Text(person.displayName).font(.headline)
                        Button("Review removing \(person.displayName)'s co-organizer role") { capture(event, person, .removeOrganizer) }
                        Button("Review transferring ownership to \(person.displayName)") { capture(event, person, .transferOwnership) }
                            .disabled(!client.eventOwnershipAuditAvailable)
                    }
                    Text("Global administration never substitutes for current event ownership. Removing management does not invent or remove independent membership.").font(.caption)
                }.disabled(session.busy || needsReload)
                if client.eventOwnershipAuditAvailable && event.settings?.ownershipAuditEnabled == true {
                    Section("Current-owner-only ownership history") {
                        Button("Load audit page \(auditPage)") { loadAudit(event) }.disabled(session.busy || needsReload)
                        if let audit {
                            ForEach(audit.entries) { entry in
                                Text("\(entry.fromUserId?.uuidString ?? "Anonymized") → \(entry.toUserId?.uuidString ?? "Anonymized")")
                                    .font(.caption).textSelection(.enabled)
                                Text("\(entry.reason) · \(entry.formerOwnerRole.rawValue) · revision \(entry.eventRevision) · \(entry.occurredAtISO)").font(.caption)
                            }
                            HStack {
                                Button("Previous audit") { auditPage -= 1; loadAudit(event) }.disabled(auditPage == 1)
                                Button("Next audit") { auditPage += 1; loadAudit(event) }.disabled(!audit.hasMore || auditPage >= 10000)
                            }.disabled(session.busy)
                        }
                        Text("Opaque/anonymized references are not resolved through private profile lookups.").font(.caption)
                    }
                }
            }
        }.modernScene().navigationTitle("Event owner")
            .task(id: community.accountRevision) { purge(); session.bind(community); load() }
            .onChange(of: community.user?.id) { _, _ in purge(); session.clear() }
            .onChange(of: community.config?.eventsEnabled) { _, enabled in if enabled != true { purge(); session.clear() } }
            .onChange(of: community.config?.eventOwnershipAuditEnabled) { _, _ in audit = nil; pending = nil; retainedChoice = nil }
            .onChange(of: phase) { _, state in
                purge(); session.clear()
                if state == .active { session.bind(community); load() }
            }
            .onChange(of: session.denied) { _, denied in if denied { purge() } }
            .onDisappear { purge(); session.clear() }
            .alert("Confirm captured owner action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { choice in
                Button(choice.action.label, role: choice.action == .addOrganizer ? nil : .destructive) { apply(choice) }
                    .disabled(needsReload)
                Button("Back", role: .cancel) { pending = nil }
            } message: { choice in
                Text("\(choice.action.label): \(choice.person.displayName), revision \(choice.event.revision). \(choice.action == .transferOwnership ? (choice.formerRole == NativeFormerOwnerRole.none ? "Explicitly relinquish ALL management. The event may become inaccessible; only server-confirmed independent RSVP/invitation remains." : "Explicitly retain co-organizer management (legacy omission has the same effect).") : "Event-scoped role only.")")
            }
    }
    private func capture(_ event: CatalogEvent, _ person: CatalogEvent.Organizer, _ action: CommunityFeatureClient.OrganizerAction) {
        guard let client = session.client else { return }
        pending = Choice(event: event, person: person, action: action,
            formerRole: client.eventOwnershipAuditAvailable && event.settings?.formerOwnerRoleChoiceEnabled == true ? formerRole : nil,
            scope: client.instanceID)
        retainedChoice = pending
    }
    private func load() {
        audit = nil; roster = nil
        session.run { client in
            do {
                let current = try await client.event(eventID)
                try client.checkEventOwner(current)
                var rows: NativeEventRoster?
                if current.moderation?.held != true { rows = try await client.participantRoster(current, page: page) }
                try session.checked(client); event = current; roster = rows; needsReload = false
            } catch { event = nil; roster = nil; audit = nil; throw error }
        }
    }
    private func loadAudit(_ event: CatalogEvent) {
        audit = nil
        let requested = auditPage
        session.run { client in
            let current = try await client.event(eventID)
            try client.checkEventOwner(current)
            guard current.revision == event.revision else { needsReload = true; throw BackpackError.invalid("Owner revision changed; explicitly reload.") }
            let result = try await client.ownershipAudit(current, page: requested)
            try session.checked(client); guard auditPage == requested else { return }; audit = result
        }
    }
    private func apply(_ choice: Choice) {
        session.run(expected: choice.scope) { client in
            do {
                let current = try await client.event(eventID)
                try client.checkEventOwner(current)
                guard current.revision == choice.event.revision else { throw CommunityFailure(status: 409, code: "event_revision_conflict", message: "Owner revision changed; explicitly reload.") }
                if choice.action == .transferOwnership {
                    let receipt = try await client.transferEventOwnership(choice.event, target: choice.person.id, formerRole: choice.formerRole)
                    try session.checked(client)
                    purge()
                    notice = "Transfer acknowledged. Membership retained: \(receipt.membershipRetained). No cached former-owner authority remains."
                    transferred(receipt.event) // Never attempt to read a now-inaccessible event after a successful transfer.
                } else {
                    try await client.organize(choice.event, target: choice.person.id, action: choice.action)
                    try session.checked(client); pending = nil; load()
                }
            } catch {
                needsReload = true; audit = nil; roster = nil; event = nil; pending = nil
                throw error
            }
        }
    }
    private func purge() { event = nil; roster = nil; audit = nil; pending = nil; retainedChoice = nil; needsReload = false }
}

@MainActor
struct EventReportComposerView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let event: CatalogEvent
    @State private var category: NativeEventReportCategory?
    @State private var details = ""
    @State private var consent = false
    @State private var intent: NativeEventReportIntent?
    @State private var notice: String?
    @State private var needsReload = false
    var body: some View {
        Form {
            Text("Only your deliberately typed category/explanation and event/revision identifiers are sent. Nothing copies title, venue, roster, chat, GIF, screenshot, scan or GPS. Server-managed encrypted explanation, not E2EE; retained up to 30 days.").font(.caption)
            Picker("Choose report category", selection: $category) {
                Text("Choose…").tag(Optional<NativeEventReportCategory>.none)
                ForEach(NativeEventReportCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            TextField("Deliberately type details (1–1000 characters)", text: $details, axis: .vertical)
            Toggle("I consent to send this typed report", isOn: $consent)
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let notice { Text(notice) }
            Text("Captured event revision \(event.revision). Conflicts retain this draft; close and explicitly reload the event before resubmitting.").font(.caption)
            Button("Review typed report") {
                do { intent = try NativeEventReportIntent(event: event, category: category, details: details, consent: consent) }
                catch { notice = error.localizedDescription }
            }.disabled(session.busy || session.denied || needsReload || session.client?.eventReportsAvailable != true)
        }.modernScene().navigationTitle("Report event")
            .task { session.bind(community) }
            .onChange(of: category) { _, _ in intent = nil }
            .onChange(of: details) { _, _ in intent = nil }
            .onChange(of: consent) { _, _ in intent = nil }
            .onChange(of: community.accountRevision) { _, _ in category = nil; details = ""; consent = false; intent = nil; session.clear(); dismiss() }
            .onChange(of: session.denied) { _, denied in if denied { category = nil; details = ""; consent = false; intent = nil; dismiss() } }
            .onChange(of: community.config?.eventReportsEnabled) { _, enabled in
                if enabled != true { category = nil; details = ""; consent = false; intent = nil; session.clear(); dismiss() }
            }
            .onDisappear { intent = nil; session.clear() }
            .confirmationDialog("Send only the captured typed report?", isPresented: Binding(get: { intent != nil }, set: { if !$0 { intent = nil } })) {
                if let captured = intent {
                    Button("Explicitly submit report") {
                        session.run { client in
                            do {
                                _ = try await client.submitEventReport(captured); try session.checked(client)
                                intent = nil; dismiss()
                            } catch {
                                if let failure = error as? CommunityFailure, failure.status == 409 { needsReload = true }
                                intent = nil; throw error
                            }
                        }
                    }
                }
            } message: { Text("Category: \(category?.rawValue ?? "")\n\(details)\nRevision \(event.revision). No automatic attachments or event content.") }
    }
}

@MainActor
struct OwnEventReportsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var reports: [NativeOwnEventReport] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var pending: NativeOwnEventReport?
    @State private var needsReload = false
    var body: some View {
        Form {
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            Text("Own reports contain no staff notes or cached private event detail. Withdrawal does not release a hold; expiry or account erasure never releases it either.").font(.caption)
            ForEach(reports) { report in
                Text(report.eventId.uuidString).font(.caption)
                Text("\(report.category.rawValue): \(report.details)")
                Text("Reported revision \(report.reportedEventRevision) · report revision \(report.revision) · expiry \(report.expiresAtISO)").font(.caption)
                Button("Review withdrawal") { pending = report }.disabled(session.busy || needsReload)
            }
            HStack {
                Button("Previous") { page -= 1; load() }.disabled(page == 1)
                Button("Next") { page += 1; load() }.disabled(!hasMore || page >= 10000)
            }.disabled(session.busy)
            Button("Explicitly refresh own reports") { pending = nil; load() }.disabled(session.busy)
            if needsReload { Text("Withdrawal conflict: refresh explicitly before using a new captured report revision.") }
        }.modernScene().navigationTitle("My event reports")
            .task(id: "\(community.accountRevision):\(community.config?.eventReportsEnabled == true)") {
                reports = []; pending = nil; session.bind(community)
                if community.config?.eventReportsEnabled == true { load() }
            }
            .task(id: "\(reports.map(\.expiresAtISO)):\(phase)") {
                guard phase == .active else { return }
                do {
                    guard let next = try reports.map({ try CatalogEventTime.parse($0.expiresAtISO).timeIntervalSinceNow }).filter({ $0 > 0 }).min() else { return }
                    try await Task.sleep(for: .seconds(next)); try Task.checkCancellation(); reports = []; load()
                } catch { }
            }
            .onChange(of: phase) { _, state in reports = []; pending = nil; if state == .active { load() } }
            .onChange(of: session.denied) { _, denied in if denied { reports = []; pending = nil } }
            .onDisappear { reports = []; pending = nil; session.clear() }
            .alert("Withdraw captured report?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { report in
                Button("Withdraw", role: .destructive) {
                    session.run {
                        client in
                        do { try await client.withdrawEventReport(report); try session.checked(client); pending = nil }
                        catch { needsReload = true; throw error }
                    } success: { load() }
                }
                Button("Back", role: .cancel) {}
            } message: { report in Text("Report revision \(report.revision). No current event view is required. Administrator moderation remains unchanged.") }
    }
    private func load() {
        reports = []; let requested = page
        session.run { client in
            let value = try await client.ownEventReports(page: requested)
            try session.checked(client); guard requested == page else { return }
            reports = try value.reports.filter { try !$0.expired(at: Date()) }; hasMore = value.hasMore; needsReload = false
        }
    }
}

@MainActor
struct EventModerationView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    let holdsOnly: Bool
    @State private var cases: [NativeStaffEventReport] = []
    @State private var holds: [NativeEventReviewContext] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var selected: NativeStaffEventReport?
    @State private var note = ""
    @State private var action = NativeEventReviewAction.resolve
    @State private var intent: NativeEventCaseIntent?
    @State private var release: NativeEventReviewContext?
    @State private var needsReload = false
    var body: some View {
        Form {
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if community.isAdmin && !session.denied {
                Text("Case authority is NOT event membership. Private context exposes only opaque metadata and moderation. Never fetch private rosters, media, profiles or conversations.").font(.caption)
                Button("Explicitly reload current cases / moderation") { intent = nil; release = nil; load() }.disabled(session.busy)
                if needsReload { Text("Conflict: typed note and action retained, but captured revisions must be explicitly reloaded.").foregroundStyle(.orange) }
                ForEach(cases) { report in
                    Section(report.own.category.rawValue) {
                        Text(report.own.details).textSelection(.enabled)
                        reviewContext(report.context)
                        if let review = report.review { Text("Staff \(review.action.rawValue): \(review.note)").textSelection(.enabled) }
                        Text("Report \(report.own.revision) · reported event \(report.own.reportedEventRevision) · expires \(report.own.expiresAtISO)").font(.caption)
                        Button("Select current case for typed review") { selected = report; intent = nil }
                    }
                }
                ForEach(holds) { context in
                    Section("Existing hold") {
                        reviewContext(context)
                        Button("Review release only") { release = context }.disabled(session.busy || needsReload)
                    }
                }
                if let selected, !holdsOnly {
                    Section("Deliberately typed review") {
                        Text("Report \(selected.own.revision) · event \(selected.context.revision) · ACTUAL moderation \(selected.context.moderation.revision)")
                        Picker("Action", selection: $action) { ForEach(NativeEventReviewAction.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        TextField("Typed note (1–1000 characters)", text: $note, axis: .vertical)
                        Button("Review captured action / literal note") {
                            do { intent = try NativeEventCaseIntent(report: selected, action: action, note: note) }
                            catch { session.run { _ in throw error } }
                        }.disabled(session.busy || needsReload)
                    }
                }
                Text("Release never restores progress, prior public badge claims or participation consent. Resolve, report withdrawal, thirty-day expiry and erasure do not automatically release enforcement.").font(.caption)
                HStack {
                    Button("Previous") { page -= 1; load() }.disabled(page == 1)
                    Button("Next") { page += 1; load() }.disabled(!hasMore || page >= 10000)
                }.disabled(session.busy || selected != nil || needsReload)
            } else { Text("Current global-admin authority is required.") }
        }.modernScene().navigationTitle(holdsOnly ? "Held events" : "Event reports")
            .task(id: "\(community.accountRevision):\(community.isAdmin):\(available)") {
                purge(); session.bind(community)
                if community.isAdmin && available { load() }
            }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if !session.busy && selected == nil && intent == nil && release == nil && !needsReload { load() }
                }
            }
            .task(id: "\(cases.map { $0.own.expiresAtISO }):\(phase)") {
                guard phase == .active else { return }
                do {
                    guard let next = try cases.map({ try CatalogEventTime.parse($0.own.expiresAtISO).timeIntervalSinceNow }).filter({ $0 > 0 }).min() else { return }
                    try await Task.sleep(for: .seconds(next)); try Task.checkCancellation()
                    cases = []; selected = nil; intent = nil; load()
                } catch { }
            }
            .onChange(of: note) { _, _ in intent = nil }
            .onChange(of: action) { _, _ in intent = nil }
            .onChange(of: phase) { _, state in purge(); session.clear(); if state == .active { session.bind(community); load() } }
            .onChange(of: session.denied) { _, denied in if denied { purge() } }
            .onDisappear { purge(); session.clear() }
            .confirmationDialog("Apply captured case action?", isPresented: Binding(get: { intent != nil }, set: { if !$0 { intent = nil } })) {
                if let captured = intent {
                    Button("Explicitly apply \(action.rawValue)") {
                        session.run { client in
                            do {
                                _ = try await client.reviewEventReport(captured); try session.checked(client)
                                selected = nil; intent = nil; note = ""; load()
                            } catch { intent = nil; needsReload = true; cases = []; holds = []; selected = nil; throw error }
                        }
                    }
                }
            } message: { Text("Literal typed note: \(note). Uses the displayed report/event/moderation revisions, including actual moderation 0 for a first hold.") }
            .alert("Release existing hold?", isPresented: Binding(get: { release != nil }, set: { if !$0 { release = nil } }), presenting: release) { context in
                Button("Explicitly release") {
                    session.run { client in
                        do { _ = try await client.releaseHeldEvent(context); try session.checked(client); release = nil; load() }
                        catch { release = nil; needsReload = true; holds = []; cases = []; throw error }
                    }
                }
                Button("Back", role: .cancel) {}
            } message: { context in Text("Event revision \(context.revision), moderation \(context.moderation.revision). Release only, without report/decryption, progress restoration or consent bypass.") }
    }
    @ViewBuilder private func reviewContext(_ context: NativeEventReviewContext) -> some View {
        Text("Opaque event \(context.id.uuidString) · revision \(context.revision) · \(context.visibility) · moderation \(context.moderation.revision) / \(context.moderation.held ? "held" : "not held")").font(.caption)
        if context.contentWithheld { Label("Private content withheld", systemImage: "lock") }
        else if let definition = context.definition {
            Text(definition.title); Text(definition.description)
            Text("\(definition.startsAtISO) – \(definition.endsAtISO) / \(definition.timezone)")
            Text("\(definition.location.label): \(definition.location.latitude), \(definition.location.longitude), radius \(definition.location.radiusMeters)m")
        }
    }
    private func load() {
        // Drop formerly-public context before each read, including a public-to-private transition.
        cases = []; holds = []; selected = nil; let requested = page
        session.run { client in
            guard client.eventAdministrator else { purge(); throw BackpackError.invalid("Current administrator authority is required.") }
            if holdsOnly {
                let value = try await client.heldEvents(page: requested)
                try session.checked(client); guard page == requested else { return }; holds = value.events; hasMore = value.hasMore
            } else {
                let value = try await client.staffEventReports(page: requested)
                try session.checked(client); guard page == requested else { return }
                cases = try value.reports.filter { try !$0.own.expired(at: Date()) }; hasMore = value.hasMore
            }
            needsReload = false
        }
    }
    private func purge() { cases = []; holds = []; selected = nil; note = ""; intent = nil; release = nil; needsReload = false }
    private var available: Bool {
        holdsOnly ? (community.config?.eventModerationEnabled ?? (community.config?.eventReportsEnabled == true)) :
            community.config?.eventReportsEnabled == true
    }
}
