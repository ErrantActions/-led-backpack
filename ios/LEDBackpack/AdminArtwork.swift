import Foundation
import BackpackProtocol

enum ArtworkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cleanup, upscale, redraw
    var id: String { rawValue }
}
enum ArtworkBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, transparent
    var id: String { rawValue }
}
struct NativeArtworkSettings: Codable, Equatable, Sendable {
    var mode = ArtworkMode.cleanup
    var background = ArtworkBackground.black
    var removeBackground = false
    var tolerance = 16
    var prompt = ""
    func validated(redraw: Bool) throws -> Self {
        guard (0...64).contains(tolerance), prompt.utf16.count <= 1000, mode != .redraw || redraw else {
            throw BackpackError.invalid("Tolerance must be 0–64 and prompt ≤1000 UTF16 units. AI redraw requires its independently advertised provider capability.")
        }
        var value = self; value.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}
enum NativeArtworkStatus: String, Decodable, Equatable {
    case staging, queued, running, completed, failed, cancelled
}
struct NativeArtworkJob: Decodable, Identifiable, Equatable {
    let id: UUID
    let sourceItemId, parentJobId: UUID?
    let status: NativeArtworkStatus
    let settings: NativeArtworkSettings
    let error: String?
    let createdAt, updatedAt, expiresAt: String
    let inputBytes, resultBytes: Int
    let inputUrl, resultUrl: URL?
    var active: Bool { [.staging,.queued,.running].contains(status) }
    func validate(origin: CommunityOrigin) throws {
        guard try settings.validated(redraw: true) == settings else { throw BackpackError.invalid("Artwork settings are not server-normalized.") }
        let start = try CatalogEventTime.parse(createdAt), updated = try CatalogEventTime.parse(updatedAt)
        let end = try CatalogEventTime.parse(expiresAt)
        guard updated >= start, updated <= end, abs(end.timeIntervalSince(start) - 86400) < 0.001,
              (0...5_000_000).contains(inputBytes), (0...5_000_000).contains(resultBytes),
              (error?.utf16.count ?? 0) <= 4000,
              status != .completed || (resultBytes > 0 && resultUrl != nil),
              resultUrl == nil || status == .completed,
              inputUrl == nil || (inputBytes > 0 && status != .staging && status != .cancelled) else {
            throw BackpackError.invalid("Invalid artwork job status, retention, sizes or media availability.")
        }
        for (url, name) in [(inputUrl,"input.gif"),(resultUrl,"result.gif")] {
            if let url { guard url == (try canonical(name, origin: origin)) else { throw BackpackError.invalid("Artwork media must use the exact current owned-job endpoint; foreign/query/path aliases rejected.") } }
        }
    }
    func canonical(_ name: String, origin: CommunityOrigin) throws -> URL {
        guard ["input.gif","result.gif"].contains(name) else { throw BackpackError.invalid("Unknown artwork media kind.") }
        return try origin.api("admin/artwork/\(id.uuidString.lowercased())/\(name)")
    }
}
enum NativeArtworkSource: Equatable {
    case community(UUID)
    case result(UUID)
    func body(settings: NativeArtworkSettings) throws -> Data {
        struct Body: Encodable { let sourceItemId, sourceJobId: String?; let settings: NativeArtworkSettings }
        switch self {
        case .community(let id): return try JSONEncoder().encode(Body(sourceItemId: id.uuidString.lowercased(), sourceJobId: nil, settings: settings))
        case .result(let id): return try JSONEncoder().encode(Body(sourceItemId: nil, sourceJobId: id.uuidString.lowercased(), settings: settings))
        }
    }
}
struct NativeArtworkUpload: Sendable {
    let data: Data
    let preview: GIFPreview
    static func prepare(_ url: URL) throws -> Self {
        let bytes = try PhoneDisplayFileReader.read(url)
        return try inspect(bytes)
    }
    static func inspect(_ bytes: Data) throws -> Self {
        try CommunityUpload.validateGIF(bytes)
        return Self(data: bytes, preview: try GIFPreviewDecoder.phoneDisplay(bytes))
    }
    func multipart(settings: NativeArtworkSettings, boundary: String) throws -> Data {
        let metadata = try JSONEncoder().encode(settings)
        guard boundary.range(of: "^[A-Za-z0-9-]{16,80}$", options: .regularExpression) != nil,
              data.range(of: Data(boundary.utf8)) == nil, metadata.range(of: Data(boundary.utf8)) == nil else {
            throw BackpackError.invalid("Invalid/colliding artwork multipart boundary; no upload was sent.")
        }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"artwork.gif\"\r\nContent-Type: image/gif\r\n\r\n".utf8))
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
@MainActor
extension AccountServiceScope {
    private func checkArtwork() throws {
        try check()
        guard admin, capability == .artwork else { throw BackpackError.invalid("Only the current global-admin artwork scope grants owned jobs, never private libraries.") }
    }
    func artworkJobs() async throws -> [NativeArtworkJob] {
        try checkArtwork()
        struct List: Decodable { let jobs: [NativeArtworkJob] }
        let value = try await send(List.self, "admin/artwork").jobs
        guard value.count <= 20, Set(value.map(\.id)).count == value.count else { throw BackpackError.invalid("Artwork owned-job list exceeds its bound or repeats identities.") }
        for job in value { try job.validate(origin: origin) }
        return value
    }
    func artworkJob(_ id: UUID) async throws -> NativeArtworkJob {
        try checkArtwork()
        struct Reply: Decodable { let job: NativeArtworkJob }
        let value = try await send(Reply.self, "admin/artwork/\(id.uuidString.lowercased())").job
        try value.validate(origin: origin)
        guard value.id == id else { throw BackpackError.invalid("Artwork job response belongs to another selection.") }
        return value
    }
    func createArtwork(source: NativeArtworkSource?, upload: NativeArtworkUpload?, settings: NativeArtworkSettings) async throws -> NativeArtworkJob {
        try checkArtwork()
        let settings = try settings.validated(redraw: community.config?.aiArtworkRedrawEnabled == true)
        guard (source != nil) != (upload != nil) else { throw BackpackError.invalid("Choose exactly one current named community item, owned completed result or explicit local GIF.") }
        struct Reply: Decodable { let job: NativeArtworkJob }
        let value: NativeArtworkJob
        if let source {
            if case .result(let id) = source {
                let parent = try await artworkJob(id)
                guard parent.status == .completed, parent.resultUrl != nil else { throw BackpackError.invalid("Only a current completed owned result can be branched.") }
            }
            value = try await send(Reply.self, "admin/artwork", method: "POST", body: source.body(settings: settings), expectedStatus: 202).job
        } else if let upload {
            let boundary = "Artwork-\(UUID().uuidString)"
            let worker = Task.detached {
                if settings.mode == .redraw {
                    guard try GIFStructure.inspect(upload.data).frames.count <= 16 else { throw BackpackError.invalid("AI redraw supports at most16 frames; the original is not truncated.") }
                }
                return try upload.multipart(settings: settings, boundary: boundary)
            }
            let body = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            value = try await send(Reply.self, "admin/artwork/upload", method: "POST", body: body,
                contentType: "multipart/form-data; boundary=\(boundary)", expectedStatus: 202).job
        } else { throw BackpackError.invalid("Artwork source was lost.") }
        try checkArtwork(); try value.validate(origin: origin)
        guard settings.mode != .redraw || community.config?.aiArtworkRedrawEnabled == true else { throw BackpackError.invalid("AI redraw became unavailable during submission; reconcile owned jobs, do not replay.") }
        guard value.settings == settings else { throw BackpackError.invalid("Artwork receipt settings changed; reload owned jobs before any further action. No automatic retry.") }
        switch source {
        case .some(.community(let id)): guard value.sourceItemId == id else { throw BackpackError.invalid("Artwork receipt changed community source.") }
        case .some(.result(let id)): guard value.parentJobId == id else { throw BackpackError.invalid("Artwork branch did not retain the selected owned parent.") }
        case nil: guard value.sourceItemId == nil, value.parentJobId == nil else { throw BackpackError.invalid("Local artwork upload receipt has an unexpected source association.") }
        }
        return value
    }
    func artworkMedia(_ selected: NativeArtworkJob, input: Bool) async throws -> NativeArtworkUpload {
        try selected.validate(origin: origin)
        let before = try await artworkJob(selected.id)
        guard before == selected, input ? before.inputUrl != nil : before.resultUrl != nil else { throw BackpackError.invalid("Artwork job/media changed; explicitly reload the selected job.") }
        let size = input ? before.inputBytes : before.resultBytes
        let data = try await bytes("admin/artwork/\(selected.id.uuidString.lowercased())/\(input ? "input.gif" : "result.gif")", maxBytes: size)
        guard data.count == size else { throw BackpackError.invalid("Artwork media length differs from its owned-job descriptor.") }
        let worker = Task.detached {
            let value = try NativeArtworkUpload.inspect(data)
            if !input {
                let header = [UInt8](data.prefix(10))
                guard (Int(header[6]) | (Int(header[7]) << 8)) == 64,
                      (Int(header[8]) | (Int(header[9]) << 8)) == 64 else { throw BackpackError.invalid("Artwork result is not the promised 64×64 canvas.") }
            }
            return value
        }
        let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        let after = try await artworkJob(selected.id)
        guard after == before else { throw BackpackError.invalid("Artwork access/status changed after I/O; no stale media retained.") }
        return value
    }
    func removeArtwork(_ selected: NativeArtworkJob) async throws {
        let current = try await artworkJob(selected.id)
        guard current == selected else { throw BackpackError.invalid("Artwork selection changed before cancel/remove. Reload; no invented revision-CAS or retry.") }
        let value = try await send(CommunityMessage.self, "admin/artwork/\(selected.id.uuidString.lowercased())", method: "DELETE")
        guard value.message == "Artwork job cancelled/removed; source GIF is unchanged" else { throw BackpackError.invalid("Artwork removal was not acknowledged; reconcile owned jobs.") }
    }
    func artworkCatalog(_ query: String, page: Int) async throws -> CommunityPage {
        try checkArtwork()
        guard query.utf16.count <= 120, (1...10000).contains(page) else { throw BackpackError.invalid("Invalid artwork source search/page.") }
        let value = try await send(CommunityPage.self, "items", query: [.init(name: "q", value: query),
            .init(name: "page", value: String(page)), .init(name: "limit", value: "24")])
        guard value.page == page, value.limit == 24, value.total >= 0, value.items.count <= 24,
              Set(value.items.map(\.id)).count == value.items.count else { throw BackpackError.invalid("Invalid current community artwork picker page.") }
        return value
    }
}
