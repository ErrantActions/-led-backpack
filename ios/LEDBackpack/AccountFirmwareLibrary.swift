import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import BackpackProtocol

struct AccountFirmware: Decodable, Identifiable {
    let id: UUID
    let revision: Int
    let device, deviceName, hardwareRevision, version, kind, title, releaseNotes: String
    let tags: [String]
    let sourceUrl: String
    let sha256: String
    let byteSize: Int
    let published: Bool
    let createdAtISO: String
    let downloadUrl: URL
    let compatibilityVerified, signatureVerified, flashingSupportedByBackend: Bool
    func validate(admin: Bool) throws {
        guard revision >= 1, (1...16 * 1024 * 1024).contains(byteSize),
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              ["stock", "custom"].contains(kind), admin || published,
              !compatibilityVerified, !signatureVerified, !flashingSupportedByBackend else {
            throw BackpackError.invalid("Unsupported firmware manifest or unavailable draft.")
        }
    }
    func verify(_ data: Data) throws {
        guard data.count == byteSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw BackpackError.invalid("Firmware size/checksum mismatch. Discarding binary.")
        }
    }
}
struct AccountFirmwarePage: Decodable {
    let firmware: [AccountFirmware]
    let total: Int
    let hasMore: Bool
    let versionOrdering: String
    let automaticUpdateSelection: Bool
}
struct AccountFirmwareResult: Decodable { let firmware: AccountFirmware }

struct AccountFirmwareMetadata: Encodable {
    var device = ""
    var deviceName = ""
    var hardwareRevision = ""
    var version = ""
    var kind = "custom"
    var title = ""
    var releaseNotes = ""
    var tags: [String] = []
    var sourceUrl = ""
    let permissionAttested = true
    func validate() throws {
        guard device.range(of: "^[a-z0-9][a-z0-9-]{0,79}$", options: .regularExpression) != nil,
              [deviceName, hardwareRevision, version].allSatisfy({ (1...100).contains($0.utf16.count) &&
                $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              (1...160).contains(title.utf16.count), title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              releaseNotes.utf16.count <= 4000,
              ["stock", "custom"].contains(kind), tags.count <= 12, Set(tags).count == tags.count,
              tags.allSatisfy({ $0.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil && !["stock", "custom"].contains($0) }) else {
            throw BackpackError.invalid("Provide bounded generic firmware metadata and at most 12 lowercase slug tags (not stock/custom).")
        }
        if !sourceUrl.isEmpty {
            guard sourceUrl.count <= 2000, let url = URL(string: sourceUrl), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil else { throw BackpackError.invalid("Source must be a credential-free HTTPS URL.") }
        }
    }
}
struct AccountFirmwareFilter: Equatable {
    var device = ""
    var hardwareRevision = ""
    var version = ""
    var kind = ""
    var tag = ""
    func query(offset: Int) throws -> [URLQueryItem] {
        guard (0...10000).contains(offset),
              [device, hardwareRevision, version, tag].allSatisfy({ $0.count <= 100 }),
              ["", "stock", "custom"].contains(kind) else { throw BackpackError.invalid("Invalid exact firmware filters/page.") }
        return [("device", device), ("hardwareRevision", hardwareRevision), ("version", version), ("kind", kind), ("tag", tag)]
            .filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) } +
            [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "24")]
    }
}

@MainActor
extension AccountServiceScope {
    private var firmwarePath: String { admin ? "admin/firmware" : "firmware" }
    func firmware(filter: AccountFirmwareFilter, offset: Int) async throws -> AccountFirmwarePage {
        let value = try await send(AccountFirmwarePage.self, firmwarePath, query: filter.query(offset: offset))
        guard value.total >= 0, value.firmware.count <= 24, Set(value.firmware.map(\.id)).count == value.firmware.count,
              value.versionOrdering == "newest-upload-first", !value.automaticUpdateSelection else { throw BackpackError.invalid("Invalid firmware pagination or automatic-update assertion.") }
        for item in value.firmware { try item.validate(admin: admin) }
        return value
    }
    func downloadFirmware(_ item: AccountFirmware) async throws -> Data {
        try item.validate(admin: admin)
        let path = "\(firmwarePath)/\(item.id.uuidString.lowercased())"
        let before = try await send(AccountFirmwareResult.self, path).firmware
        try before.validate(admin: admin)
        guard before.id == item.id, before.revision == item.revision, before.sha256 == item.sha256,
              before.byteSize == item.byteSize, before.device == item.device, before.hardwareRevision == item.hardwareRevision,
              before.version == item.version, before.kind == item.kind else { throw BackpackError.invalid("Firmware selection changed. Reload; never rebase a download.") }
        let canonical = try origin.api(path + "/download", query: [URLQueryItem(name: "expectedRevision", value: String(item.revision))])
        guard let resolved = URL(string: before.downloadUrl.relativeString, relativeTo: origin.url)?.absoluteURL,
              resolved == canonical else { throw BackpackError.invalid("Firmware download must use the authorized canonical revision route.") }
        let data = try await bytes(path + "/download", query: [URLQueryItem(name: "expectedRevision", value: String(item.revision))],
            maxBytes: item.byteSize)
        try item.verify(data)
        let after = try await send(AccountFirmwareResult.self, path).firmware
        try after.validate(admin: admin)
        guard after.id == item.id, after.revision == item.revision, after.sha256 == item.sha256 else { throw BackpackError.invalid("Firmware access/revision changed after download.") }
        return data
    }
    func publishFirmware(_ item: AccountFirmware, published: Bool, attested: Bool) async throws {
        guard admin, !published || attested else { throw BackpackError.invalid("Current admin target declaration is required to publish; it is not verification.") }
        try item.validate(admin: true)
        struct Body: Encodable { let expectedRevision: Int; let published, compatibilityAttested: Bool }
        let value = try await send(AccountFirmwareResult.self, "\(firmwarePath)/\(item.id.uuidString.lowercased())",
            method: "PATCH", body: JSONEncoder().encode(Body(expectedRevision: item.revision,
                published: published, compatibilityAttested: attested))).firmware
        try value.validate(admin: true)
        guard value.id == item.id, value.published == published else { throw BackpackError.invalid("Publication receipt did not match this release.") }
    }
    func uploadFirmware(_ data: Data, metadata: AccountFirmwareMetadata) async throws {
        try check(); try metadata.validate()
        guard admin, let advertised = community.config?.firmwareMaxUploadBytes,
              advertised > 0, !data.isEmpty, data.count <= min(advertised, 16 * 1024 * 1024) else {
            throw BackpackError.invalid("Admin .bin uploads are unavailable or exceed the advertised byte budget.")
        }
        let boundary = "Firmware-\(UUID().uuidString)"
        guard data.range(of: Data(boundary.utf8)) == nil else { throw BackpackError.invalid("Multipart collision; choose the file again.") }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
        body.append(try JSONEncoder().encode(metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"firmware.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let value = try await send(AccountFirmwareResult.self, firmwarePath, method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)").firmware
        try value.validate(admin: true)
        guard !value.published else { throw BackpackError.invalid("An upload must create a draft, never publish automatically.") }
        try value.verify(data)
    }
}

@MainActor
struct FirmwareLibraryView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = AccountServiceSession()
    var admin = false
    @State private var filter = AccountFirmwareFilter()
    @State private var applied = AccountFirmwareFilter()
    @State private var page: AccountFirmwarePage?
    @State private var offset = 0
    @State private var pending: AccountFirmware?
    @State private var action = ""
    @State private var attested = false
    @State private var document: BinaryDocument?
    @State private var exporting = false
    @State private var downloadName = "firmware.bin"
    private var identity: String { "\(community.accountRevision):\(community.user?.role ?? ""):\(community.config?.firmwareCatalogEnabled == true):\(community.avatarPolicyRevision)" }
    var body: some View {
        Form {
            Text("Download/research library only. SHA-256 checks bytes, not authenticity. Generic stock/custom metadata and admin declarations do NOT certify target compatibility, signature or safety. Flashing, automatic recommendations and device commands are unavailable.")
                .font(.caption)
            if session.scope != nil {
                Section("Exact filters — not connected-device detection") {
                    TextField("Device/model slug", text: $filter.device)
                    TextField("Hardware revision", text: $filter.hardwareRevision)
                    TextField("Firmware version", text: $filter.version)
                    Picker("Kind", selection: $filter.kind) { Text("Both").tag(""); Text("Stock").tag("stock"); Text("Custom").tag("custom") }
                    TextField("Exact tag", text: $filter.tag)
                    Button("Apply / search") { applied = filter; offset = 0; load() }
                }
                if admin { NavigationLink("Upload immutable .bin draft") { FirmwareDraftUploadView() } }
                if let page {
                    Section("Newest upload first (\(page.total))") {
                        if page.firmware.isEmpty { Text("No currently authorized releases match.") }
                        ForEach(page.firmware) { release in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(release.title).font(.headline)
                                Text("\(release.deviceName) · \(release.hardwareRevision) · \(release.version) · \(release.kind)")
                                Text(release.published ? "Published metadata — unverified" : "Admin-only draft — unverified").font(.caption)
                                Text(release.releaseNotes)
                                Text("\(release.byteSize) bytes · SHA-256 \(release.sha256)").font(.caption).textSelection(.enabled)
                                Button("Download exact .bin; do not flash") { pending = release; action = "download"; attested = false }
                                if admin {
                                    Button(release.published ? "Withdraw publication" : "Review and publish draft") {
                                        pending = release; action = "publication"; attested = false
                                    }
                                    Button("Delete release and bytes", role: .destructive) { pending = release; action = "delete"; attested = false }
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Previous") { offset = max(0, offset - 24); load() }.disabled(offset == 0)
                        Button("Next") { offset += 24; load() }.disabled(!page.hasMore || offset > 9976)
                    }
                }
                Button("Reload current authorized releases") { load() }
            } else { Text("Firmware storage is not advertised for this current account/server. No live activation is implied.") }
            if let pending {
                Section("Confirm captured release revision \(pending.revision)") {
                    Text("\(pending.title) · \(action)")
                    if action == "publication" && !pending.published {
                        Toggle("I explicitly declare this generic target; this is not authenticity or compatibility verification", isOn: $attested)
                    }
                    Button("Confirm \(action)", role: action == "delete" ? .destructive : nil) { execute(pending) }
                        .disabled(action == "publication" && !pending.published && !attested)
                    Button("Cancel") { self.pending = nil; attested = false }
                }
            }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let message = session.message { Text(message) }
        }.disabled(session.busy).navigationTitle(admin ? "Admin firmware" : "Firmware library")
            .task(id: identity) { page = nil; pending = nil; document = nil; exporting = false; attested = false; session.bind(community, .firmware, admin: admin); load() }
            .onDisappear { session.clear(); page = nil; document = nil; pending = nil }
            .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: downloadName) { _ in document = nil }
    }
    private func load() {
        page = nil; pending = nil
        session.run { scope in let result = try await scope.firmware(filter: applied, offset: offset); try session.checked(scope); page = result; return nil }
    }
    private func execute(_ release: AccountFirmware) {
        let selectedAction = action, declaration = attested
        pending = nil; document = nil
        session.run { scope in
            switch selectedAction {
            case "download":
                let bytes = try await scope.downloadFirmware(release); try session.checked(scope)
                document = BinaryDocument(data: bytes); downloadName = "\(release.id.uuidString.lowercased()).bin"; exporting = true
                return "Size and checksum matched. Authenticity/compatibility remain unverified. Do not execute or flash."
            case "publication": try await scope.publishFirmware(release, published: !release.published, attested: declaration)
            case "delete":
                guard scope.admin else { throw BackpackError.invalid("Admin required.") }
                struct Body: Encodable { let expectedRevision: Int }
                struct Result: Decodable { let deleted: Bool }
                let result = try await scope.send(Result.self, "admin/firmware/\(release.id.uuidString.lowercased())", method: "DELETE",
                    body: JSONEncoder().encode(Body(expectedRevision: release.revision)))
                guard result.deleted else { throw BackpackError.invalid("Firmware deletion was not confirmed.") }
            default: throw BackpackError.invalid("Unsupported action.")
            }
            let result = try await scope.firmware(filter: applied, offset: offset); try session.checked(scope); page = result
            return "Captured revision updated; no hardware operation."
        }
    }
}

@MainActor
struct FirmwareDraftUploadView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = AccountServiceSession()
    @State private var metadata = AccountFirmwareMetadata()
    @State private var tagText = ""
    @State private var consent = false
    @State private var picking = false
    @State private var bytes: Data?
    @State private var fileRevision: UUID?
    @State private var failure: String?
    var body: some View {
        Form {
            Text("Admin-only immutable draft; no automatic publication or overwrite. A distinct device/hardware/version/kind tuple is required. Upload rights do not establish firmware authenticity.")
            TextField("Lowercase device slug", text: $metadata.device)
            TextField("Generic device name", text: $metadata.deviceName)
            TextField("Hardware revision", text: $metadata.hardwareRevision)
            TextField("Firmware version", text: $metadata.version)
            Picker("Kind", selection: $metadata.kind) { Text("Stock").tag("stock"); Text("Custom").tag("custom") }
            TextField("Title", text: $metadata.title)
            TextField("Release notes", text: $metadata.releaseNotes, axis: .vertical)
            TextField("Comma-separated lowercase tags", text: $tagText)
            TextField("Optional HTTPS source", text: $metadata.sourceUrl)
            Toggle("I have permission to store/share this binary", isOn: $consent)
            Button("Choose one .bin (never execute)") { fileRevision = community.accountRevision; picking = true }
            if let bytes { Text("Immutable file snapshot: \(bytes.count) bytes") }
            Button("Create draft from selected bytes") {
                session.run { scope in
                    guard consent, fileRevision == scope.revision, let bytes else { throw BackpackError.invalid("Choose a current-account file and explicitly attest permission.") }
                    var value = metadata; value.tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    try await scope.uploadFirmware(bytes, metadata: value); try session.checked(scope)
                    self.bytes = nil; consent = false
                    return "Draft created; publication requires a separate target declaration. No flashing is available."
                }
            }.disabled(bytes == nil || !consent || session.scope == nil)
            if session.busy { ProgressView() }
            if let failure = failure ?? session.failure { Text(failure).foregroundStyle(.orange) }
            if let message = session.message { Text(message) }
        }.disabled(session.busy).navigationTitle("Firmware draft")
            .task(id: "\(community.accountRevision):\(community.user?.role ?? ""):\(community.config?.firmwareCatalogEnabled == true)") {
                bytes = nil; consent = false; session.bind(community, .firmware, admin: true)
            }
            .onDisappear { if !picking { bytes = nil; consent = false; session.clear() } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
                do {
                    let url = try result.get()
                    guard fileRevision == community.accountRevision, url.isFileURL, url.pathExtension.lowercased() == "bin",
                          let maxBytes = community.config?.firmwareMaxUploadBytes, maxBytes > 0 else { throw BackpackError.invalid("Select a current authorized .bin file.") }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let data = try handle.read(upToCount: min(maxBytes, 16 * 1024 * 1024) + 1) ?? Data()
                    guard !data.isEmpty, data.count <= min(maxBytes, 16 * 1024 * 1024) else { throw BackpackError.invalid("Empty/oversized .bin; no bytes uploaded.") }
                    bytes = data; failure = nil
                } catch { bytes = nil; failure = error.localizedDescription }
            }
    }
}
