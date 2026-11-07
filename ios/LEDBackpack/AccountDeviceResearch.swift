import SwiftUI
import BackpackProtocol

struct GenericResearchTarget: Decodable, Identifiable {
    let id: UUID
    let model, hardwareRevision, firmwareVersion, kind: String
    let reportCount: Int?
    func validate() throws {
        try GenericResearchMetadata(model: model, hardwareRevision: hardwareRevision, firmwareVersion: firmwareVersion, kind: kind).validate()
        guard reportCount == nil || (reportCount ?? -1) >= 0 else { throw BackpackError.invalid("Invalid aggregate report counter.") }
    }
}
struct GenericResearchPage: Decodable {
    let targets: [GenericResearchTarget]
    let total: Int
    let reportsAreUniqueDevices, hardwareVerified, provenanceStored: Bool
    func validate(admin: Bool) throws {
        guard total >= 0, targets.count <= 50, Set(targets.map(\.id)).count == targets.count,
              !reportsAreUniqueDevices, !hardwareVerified, !provenanceStored else { throw BackpackError.invalid("Unsupported research provenance/count assertion.") }
        for target in targets {
            try target.validate()
            guard admin ? target.reportCount != nil : target.reportCount == nil else { throw BackpackError.invalid("Only admin research pages may carry required aggregate counters.") }
        }
    }
}
struct GenericResearchMetadata: Encodable {
    var model = ""
    var hardwareRevision = ""
    var firmwareVersion = ""
    var kind = "unknown"
    let sanitizedAttested = true
    func validate() throws {
        guard [model, hardwareRevision, firmwareVersion].allSatisfy({
            $0.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,63}$", options: .regularExpression) != nil &&
                $0 == $0.trimmingCharacters(in: .whitespaces)
        }), ["stock", "custom", "unknown"].contains(kind) else {
            throw BackpackError.invalid("Use only generic curated model/hardware/version labels (1…64 ASCII letters, numbers, spaces or ._()+-). Never include unique identifiers or provenance.")
        }
    }
}
struct GenericResearchObservation: Encodable {
    let targetId: UUID
    let consent: Bool
    private enum CodingKeys: String, CodingKey { case targetId, consent }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(targetId.uuidString.lowercased(), forKey: .targetId)
        try values.encode(consent, forKey: .consent)
    }
}
struct GenericResearchReceipt: Decodable { let accepted, counted: Bool }

@MainActor
extension AccountServiceScope {
    func research(offset: Int) async throws -> GenericResearchPage {
        guard (0...5000).contains(offset) else { throw BackpackError.invalid("Invalid research page.") }
        let value = try await send(GenericResearchPage.self, admin ? "admin/device-research" : "device-research/targets",
            query: [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(offset))])
        try value.validate(admin: admin); return value
    }
    func observeResearch(_ target: GenericResearchTarget, consent: Bool) async throws -> GenericResearchReceipt {
        guard !admin, consent else { throw BackpackError.invalid("This report requires a deliberate default-off opt-in.") }
        try target.validate()
        let value = try await send(GenericResearchReceipt.self, "device-research/observations", method: "POST",
            body: JSONEncoder().encode(GenericResearchObservation(targetId: target.id, consent: true)))
        guard value.accepted else { throw BackpackError.invalid("Research submission was not accepted.") }
        return value
    }
}

@MainActor
struct DeviceResearchView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = AccountServiceSession()
    var admin = false
    @State private var page: GenericResearchPage?
    @State private var offset = 0
    @State private var selected: UUID?
    @State private var consent = false
    @State private var metadata = GenericResearchMetadata()
    @State private var sanitized = false
    @State private var pendingDelete: GenericResearchTarget?
    var body: some View {
        Form {
            Text("Explicit default-off research: select only a curated GENERIC combination. Reports are not unique devices/installs and do not verify hardware. No BLE/MAC/serial/IP/account/location/source/time is in the submission or stored connection history. Authentication still processes the request. No raw device strings are collected.")
                .font(.caption)
            if session.scope != nil {
                if admin {
                    Section("Curate a generic target — no raw telemetry") {
                        TextField("Generic model", text: $metadata.model)
                        TextField("Generic hardware revision", text: $metadata.hardwareRevision)
                        TextField("Generic firmware version", text: $metadata.firmwareVersion)
                        Picker("Kind", selection: $metadata.kind) {
                            Text("Unknown").tag("unknown"); Text("Stock").tag("stock"); Text("Custom").tag("custom")
                        }
                        Toggle("I independently reviewed these labels: generic only, no unique identifiers or provenance", isOn: $sanitized)
                        Button("Create curated combination") {
                            session.run { scope in
                                guard sanitized else { throw BackpackError.invalid("Independent sanitization attestation is required.") }
                                try metadata.validate()
                                struct Result: Decodable { let id: UUID }
                                _ = try await scope.send(Result.self, "admin/device-research", method: "POST", body: JSONEncoder().encode(metadata))
                                try await reload(scope); metadata = GenericResearchMetadata(); sanitized = false
                                return "Curated combination created; no observation was submitted."
                            }
                        }.disabled(!sanitized)
                    }
                }
                if let page {
                    Section("Curated targets (\(page.total))") {
                        if page.targets.isEmpty { Text("No curated targets. Unknown/raw strings cannot be uploaded instead.") }
                        if !admin {
                            Picker("Combination", selection: $selected) {
                                Text("Choose deliberately").tag(Optional<UUID>.none)
                                ForEach(page.targets) { target in Text(label(target)).tag(Optional(target.id)) }
                            }
                            Toggle("I consent to one unlinkable aggregate report for this exact curated combination", isOn: $consent)
                            Text("Only {targetId, consent:true} is sent. Once counted, an individual report cannot be retrieved or withdrawn. At most 16 combinations/account per 24-hour volatile dedup window; counts may repeat after a day/restart. No automatic submission.")
                                .font(.caption)
                            Button("Submit selected combination once") {
                                session.run { scope in
                                    guard let selected, let target = page.targets.first(where: { $0.id == selected }) else { throw BackpackError.invalid("Choose a currently displayed curated target.") }
                                    let receipt = try await scope.observeResearch(target, consent: consent)
                                    consent = false; self.selected = nil
                                    return receipt.counted ? "Aggregate report counted (not a verified device)." : "Accepted but not counted again in the current dedup window."
                                }
                            }.disabled(!consent || selected == nil)
                        } else {
                            ForEach(page.targets) { target in
                                Text(label(target))
                                if let count = target.reportCount { Text("\(count) self-reports — not devices").font(.caption) }
                                Button("Delete entire combination/count", role: .destructive) { pendingDelete = target }
                            }
                        }
                    }
                    HStack {
                        Button("Previous") { offset = max(0, offset - 50); load() }.disabled(offset == 0)
                        Button("Next") { offset += 50; load() }.disabled(offset + page.targets.count >= page.total || offset >= 5000)
                    }
                }
                Button("Reload curated targets") { load() }
            } else { Text("Research is not advertised by this current server/account. No telemetry or provider is activated.") }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let message = session.message { Text(message) }
        }.disabled(session.busy).navigationTitle(admin ? "Curated research admin" : "Optional model research")
            .task(id: "\(community.accountRevision):\(community.user?.role ?? ""):\(community.config?.deviceResearchEnabled == true)") {
                page = nil; selected = nil; consent = false; sanitized = false; pendingDelete = nil
                session.bind(community, .research, admin: admin); load()
            }
            .onChange(of: selected) { _, _ in consent = false }
            .onDisappear { session.clear(); page = nil; selected = nil; consent = false; sanitized = false; pendingDelete = nil }
            .confirmationDialog("Delete the entire curated combination and aggregate count?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                    if let target = pendingDelete {
                        Button("Delete \(label(target))", role: .destructive) {
                            pendingDelete = nil
                            session.run { scope in
                                guard scope.admin else { throw BackpackError.invalid("Current admin required.") }
                                struct Result: Decodable { let deleted: Bool }
                                let result = try await scope.send(Result.self, "admin/device-research/\(target.id.uuidString.lowercased())", method: "DELETE")
                                guard result.deleted else { throw BackpackError.invalid("Combination deletion was not confirmed.") }
                                try await reload(scope); return "Curated combination and aggregate removed."
                            }
                        }
                    }
                }
    }
    private func label(_ target: GenericResearchTarget) -> String { "\(target.model) / \(target.hardwareRevision) / \(target.firmwareVersion) / \(target.kind)" }
    private func reload(_ scope: AccountServiceScope) async throws {
        page = nil; selected = nil; consent = false
        let value = try await scope.research(offset: offset); try session.checked(scope); page = value
    }
    private func load() { session.run { scope in try await reload(scope); return nil } }
}
