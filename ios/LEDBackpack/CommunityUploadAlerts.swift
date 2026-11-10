import SwiftUI
import BackpackProtocol

struct ContentBlindUploadAlert: Decodable, Identifiable {
    let id, userId: UUID
    let displayName, reason: String
    let attempts, invalid, duplicates, rate: Int
    let createdAt, blockedUntil: String
    let reviewedAt, releasedAt: String?
    let active: Bool
    func validate() throws {
        guard [attempts, invalid, duplicates, rate].allSatisfy({ $0 >= 0 }),
              Self.date(createdAt) != nil, Self.date(blockedUntil) != nil,
              reviewedAt == nil || Self.date(reviewedAt ?? "") != nil,
              releasedAt == nil || Self.date(releasedAt ?? "") != nil else { throw BackpackError.invalid("Invalid content-blind alert counters/state.") }
    }
    static func date(_ value: String) -> Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime]; return format.date(from: value)
    }
}
struct ContentBlindUploadAlertsPage: Decodable {
    let alerts: [ContentBlindUploadAlert]
    let page, limit, total: Int
    func validate(page: Int) throws {
        guard self.page == page, limit == 24, total >= 0, alerts.count <= 24,
              Set(alerts.map(\.id)).count == alerts.count else { throw BackpackError.invalid("Invalid alert page.") }
        for alert in alerts { try alert.validate() }
    }
}

@MainActor
struct CommunityUploadAlertsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = AccountServiceSession()
    @State private var page: ContentBlindUploadAlertsPage?
    @State private var number = 1
    @State private var pending: ContentBlindUploadAlert?
    @State private var action = ""
    var body: some View {
        Form {
            InteractionExplanation("Upload indicators are not proof of abuse. Holds affect uploads, not account access; acknowledging does not release a hold.", details: "Content-blind counters are indicators, not proof of abuse. No private names, thumbnails, hashes, ciphertext, keys or content scans. Holds affect uploads only; login/download/recovery/deletion remain available. Acknowledge does NOT release. Admin ZIP imports remain exempt.")
                .font(.caption)
            if session.scope != nil {
                if let page {
                    Section("Alerts (\(page.total))") {
                        if page.alerts.isEmpty { Text("No upload-abuse alerts.") }
                        ForEach(page.alerts) { alert in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(alert.displayName).font(.headline)
                                Text(alert.reason)
                                Text("\(alert.attempts) attempts · \(alert.invalid) invalid · \(alert.duplicates) duplicates · \(alert.rate) rate/quota").font(.caption)
                                Text(alert.active ? "Upload hold until \(alert.blockedUntil)" : "No active hold")
                                Text(alert.reviewedAt == nil ? "Not acknowledged" : "Acknowledged (not release)").font(.caption)
                                Button("Acknowledge alert only") { pending = alert; action = "acknowledge" }
                                if alert.active { Button("Explicitly release this account's upload holds") { pending = alert; action = "release" } }
                            }
                        }
                        HStack {
                            Button("Previous") { number = max(1, number - 1); load() }.disabled(number == 1)
                            Button("Next") { number += 1; load() }.disabled(number * 24 >= page.total)
                        }
                    }
                }
                Button("Refresh content-blind alerts") { load() }
            } else { Text("Upload-abuse monitoring is not advertised for this current admin/server.") }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let message = session.message { Text(message) }
        }.disabled(session.busy).navigationTitle("Upload holds and alerts")
            .task(id: "\(community.accountRevision):\(community.user?.role ?? ""):\(community.config?.uploadAbuseMonitoringEnabled == true):\(phase)") {
                page = nil; pending = nil; session.bind(community, .alerts, admin: true)
                guard phase == .active else { session.clear(); return }
                load()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    if phase == .active && !session.busy && pending == nil { load() }
                }
            }
            .onDisappear { session.clear(); page = nil; pending = nil }
            .confirmationDialog("Confirm \(action) for this exact alert?", isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                    if let alert = pending {
                        Button("\(action.capitalized) \(alert.displayName)") {
                            let selectedAction = action; pending = nil
                            session.run { scope in
                                guard ["acknowledge", "release"].contains(selectedAction),
                                      page?.alerts.contains(where: { $0.id == alert.id && $0.userId == alert.userId &&
                                        $0.blockedUntil == alert.blockedUntil && $0.active == alert.active &&
                                        $0.reviewedAt == alert.reviewedAt && $0.releasedAt == alert.releasedAt }) == true else {
                                    throw BackpackError.invalid("Displayed alert changed. Reload before acting.")
                                }
                                let current = try await fetch(scope)
                                guard current.alerts.contains(where: { $0.id == alert.id && $0.userId == alert.userId &&
                                    $0.blockedUntil == alert.blockedUntil && $0.active == alert.active &&
                                    $0.reviewedAt == alert.reviewedAt && $0.releasedAt == alert.releasedAt }) else {
                                    page = nil; throw BackpackError.invalid("Current hold/alert changed. No action submitted.")
                                }
                                struct Body: Encodable { let action: String }
                                _ = try await scope.bytes("admin/upload-alerts/\(alert.id.uuidString.lowercased())",
                                    method: "PATCH", body: JSONEncoder().encode(Body(action: selectedAction)))
                                let result = try await fetch(scope); try session.checked(scope); page = result
                                guard let updated = result.alerts.first(where: { $0.id == alert.id }),
                                      updated.reviewedAt != nil,
                                      selectedAction != "release" || (updated.releasedAt != nil && !updated.active) else {
                                    throw BackpackError.invalid("The current receipt could not be reconciled on this page. Reload instead of repeating the action.")
                                }
                                return selectedAction == "release" ? "Release receipt received; refreshed current hold state." : "Acknowledged only; the upload hold was not released."
                            }
                        }
                    }
                } message: { Text("Release clears this account's upload holds, not just this row. Acknowledge never releases. Changed alerts require fresh review.") }
    }
    private func fetch(_ scope: AccountServiceScope) async throws -> ContentBlindUploadAlertsPage {
        let value = try await scope.send(ContentBlindUploadAlertsPage.self, "admin/upload-alerts",
            query: [URLQueryItem(name: "page", value: String(number)), URLQueryItem(name: "limit", value: "24")])
        try value.validate(page: number); return value
    }
    private func load() {
        page = nil; pending = nil
        session.run { scope in let value = try await fetch(scope); try session.checked(scope); page = value; return nil }
    }
}
