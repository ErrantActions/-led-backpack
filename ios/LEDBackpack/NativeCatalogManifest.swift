import Foundation
import BackpackProtocol

enum NativeCatalogDownloadIntegrity: Equatable {
    case manifestSHA256
    case checksumUnavailable
    var message: String {
        switch self {
        case .manifestSHA256:
            return "SHA-256 matched the current trusted API manifest. Transfer integrity only — not authorship, safety, compatibility or permanent permission."
        case .checksumUnavailable:
            return "Checksum unavailable on this server. Only recorded-file authorization, byte length, GIF dimensions/frames and decode bounds were checked; this is not checksum-verified."
        }
    }
}

struct NativeCatalogDownload {
    let data: Data
    let integrity: NativeCatalogDownloadIntegrity
}

struct NativeCatalogDownloadManifest: Decodable {
    struct File: Decodable, Equatable {
        enum Kind: String, Decodable { case original, variant }
        let kind: Kind
        let name: String
        let url: URL
        let width, height, frameCount, byteSize: Int
        let sha256: String
        var descriptor: NativeCatalogFile {
            NativeCatalogFile(url: url, width: width, height: height, frameCount: frameCount,
                byteSize: byteSize, sha256: sha256, original: kind == .original)
        }
        var recordedDescriptor: NativeCatalogFile {
            NativeCatalogFile(url: url, width: width, height: height, frameCount: frameCount,
                byteSize: byteSize, sha256: nil, original: kind == .original)
        }
        func validate(itemID: UUID, origin: CommunityOrigin) throws {
            try NativeCatalogDescriptorPolicy.validate(recordedDescriptor, itemID: itemID, origin: origin)
            let expected = kind == .original ? "original.gif" : "\(width)x\(height).gif"
            guard name == expected, sha256.utf8.count == 64,
                  sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw BackpackError.invalid("Manifest name or lowercase SHA-256 is invalid.")
            }
        }
    }
    let version: Int
    let itemId: UUID
    let integrityOnly: Bool
    let serverTimeISO: String
    let files: [File]

    func selectedFile(item: CommunityItem, selected: NativeCatalogFile, origin: CommunityOrigin) throws -> File {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: serverTimeISO)
        if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: serverTimeISO) }
        guard version == 1, integrityOnly, itemId == item.id, date != nil,
              (1...6).contains(files.count), files.count == item.recordedFiles.count,
              files.filter({ $0.kind == .original }).count == 1,
              Set(files.map(\.name)).count == files.count,
              Set(files.map(\.url)).count == files.count else {
            throw BackpackError.invalid("Invalid manifest version/item/time, original, file count or uniqueness.")
        }
        for file in files {
            try file.validate(itemID: itemId, origin: origin)
            guard item.recordedFiles.contains(file.recordedDescriptor) else {
                throw BackpackError.invalid("Manifest contains a file not in the current original/export descriptors.")
            }
        }
        guard let match = files.first(where: { $0.recordedDescriptor == selected }) else {
            throw BackpackError.invalid("The captured original/export is missing or changed in the manifest.")
        }
        return match
    }
}

enum NativeCatalogDescriptorPolicy {
    static func validate(_ file: NativeCatalogFile, itemID: UUID, origin: CommunityOrigin) throws {
        guard (1...4096).contains(file.width), (1...4096).contains(file.height),
              (1...120).contains(file.frameCount), file.width * file.height <= 40_000_000 / file.frameCount,
              let size = file.byteSize, (1...5_000_000).contains(size) else {
            throw BackpackError.invalid("Catalog descriptor exceeds source byte/dimension/frame/decoded-pixel bounds.")
        }
        let name = file.original ? "original.gif" : "\(file.width)x\(file.height).gif"
        let path = "/media/\(itemID.uuidString.lowercased())/\(name)"
        guard origin.contains(file.url), file.url.query == nil, file.url.fragment == nil,
              !file.url.absoluteString.contains("%"), !file.url.absoluteString.contains("\\"),
              file.url.path == path,
              file.url.absoluteString == origin.url.absoluteString + path else {
            throw BackpackError.invalid("Catalog file must use its exact configured-origin media path/name without aliases.")
        }
    }
}

@MainActor
extension CommunityController {
    func downloadCatalogFile(itemID: UUID, file: NativeCatalogFile) async throws -> NativeCatalogDownload {
        guard let server = origin else { throw BackpackError.invalid("No catalog is configured.") }
        let epoch = accountRevision, policy = avatarPolicyRevision, account = user?.id, login = signedIn
        let manifestEnabled = config?.catalogDownloadManifestEnabled == true
        func checkCapture() throws {
            try Task.checkCancellation()
            guard origin == server, accountRevision == epoch, avatarPolicyRevision == policy, !avatarPolicyChanging,
                  user?.id == account, signedIn == login,
                  (config?.catalogDownloadManifestEnabled == true) == manifestEnabled else {
                throw BackpackError.invalid("Catalog account, mature/viewer policy or manifest capability changed. Discarding the download; reload explicitly.")
            }
        }
        func manifest() async throws -> NativeCatalogDownloadManifest {
            try checkCapture()
            let response = try await request("items/\(itemID.uuidString.lowercased())/download-manifest",
                authenticated: login, maxBytes: 65_536, expectedAccountRevision: epoch, expectedAccountID: account)
            try checkCapture()
            return try JSONDecoder().decode(NativeCatalogDownloadManifest.self, from: response.data)
        }
        try checkCapture()
        try NativeCatalogDescriptorPolicy.validate(file, itemID: itemID, origin: server)
        let before = try await currentCatalogItem(itemID)
        try checkCapture()
        guard before.recordedFiles.contains(file) else { throw BackpackError.invalid("The captured recorded file is no longer current or authorized.") }
        let capturedManifestFile: NativeCatalogDownloadManifest.File?
        if manifestEnabled {
            capturedManifestFile = try await manifest().selectedFile(item: before, selected: file, origin: server)
        } else { capturedManifestFile = nil }
        try checkCapture()
        let expected = capturedManifestFile?.descriptor ?? file
        guard let size = expected.byteSize else { throw BackpackError.invalid("Missing exact per-file byte count.") }
        let bytes = try await download(expected.url, expectedAccountRevision: epoch, maxBytes: size)
        try checkCapture()
        try expected.verify(bytes)
        let after = try await currentCatalogItem(itemID)
        try checkCapture()
        guard after.recordedFiles.contains(file) else { throw BackpackError.invalid("Catalog access or selected file changed after I/O.") }
        if let capturedManifestFile {
            let latest = try await manifest().selectedFile(item: after, selected: file, origin: server)
            guard latest == capturedManifestFile else {
                throw BackpackError.invalid("Current manifest checksum/descriptor changed after download. Nothing was accepted; reload without silent retry.")
            }
        }
        try checkCapture()
        return NativeCatalogDownload(data: bytes, integrity: manifestEnabled ? .manifestSHA256 : .checksumUnavailable)
    }
}
