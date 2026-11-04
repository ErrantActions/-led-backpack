import SwiftUI
import ImageIO
import BackpackProtocol

enum CommunityLicense: String, Codable {
    case original, unspecified, cc0 = "CC0-1.0", by = "CC-BY-4.0", shareAlike = "CC-BY-SA-4.0", noncommercial = "CC-BY-NC-4.0"
}

struct CommunityUploadMetadata: Encodable {
    var title: String
    var category: String
    var tags: [String]
    var attribution: String? = nil
    var license: CommunityLicense? = nil
    var sourceUrl: String? = nil

    static func preserving(_ credit: Attribution?, title: String, category: String, tags: [String]) -> Self {
        var metadata = Self(title: title, category: category, tags: tags)
        guard let credit else { return metadata }
        metadata.attribution = credit.author
        metadata.sourceUrl = credit.source.isEmpty ? nil : credit.source
        metadata.license = CommunityLicense(rawValue: credit.license)
        if credit.license == "Original work / catalog download permission" { metadata.license = .original }
        if metadata.license == nil && !credit.license.isEmpty && credit.license != "unreviewed" {
            // Preserve unsupported source-license text without asserting a different grant.
            metadata.attribution = [credit.author, "Source license: \(credit.license)", credit.licenseURL]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return metadata
    }

    func validate() throws {
        guard (1...120).contains(title.utf16.count), title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              CommunityCategory(rawValue: category) != nil,
              (attribution?.utf16.count ?? 0) <= 500,
              tags.count <= 12, tags.allSatisfy({ (1...32).contains($0.utf16.count) &&
                  $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw BackpackError.invalid("Provide a title, category and up to 12 tags. Existing credits must fit within 500 characters.")
        }
        if let sourceUrl {
            guard sourceUrl.utf16.count <= 2000, let url = URL(string: sourceUrl),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil else { throw BackpackError.invalid("Source must be a public HTTP(S) URL without credentials.") }
        }
    }
}

struct CommunitySubmission: Decodable, Identifiable {
    let id: UUID
    let title: String
    let status: String
    let moderationReason: String
    let aiState: String
    let aiError: String?
    let visibility: String
}

enum CommunityUpload {
    static func validateGIF(_ data: Data) throws {
        guard data.count <= 5_000_000,
              ["GIF87a", "GIF89a"].contains(String(data: data.prefix(6), encoding: .ascii) ?? ""),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw BackpackError.invalid("Upload an animated GIF no larger than 5 MB.")
        }
        let count = CGImageSourceGetCount(source)
        guard (2...120).contains(count) else {
            throw BackpackError.invalid("Community uploads require 2-120 frames. Single-frame artwork can still be used locally.")
        }
        var pixels = 0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            guard (1...4096).contains(width), (1...4096).contains(height) else {
                throw BackpackError.invalid("GIF dimensions must be at most 4096 x 4096.")
            }
            pixels += width * height
            guard pixels <= 40_000_000 else { throw BackpackError.invalid("The GIF exceeds the community's decoded-pixel budget. Resize it in GIF Studio.") }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1]
            guard CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) != nil else {
                throw BackpackError.invalid("The GIF contains an unreadable frame.")
            }
        }
    }

    static func multipart(_ data: Data, metadata: CommunityUploadMetadata, boundary: String) throws -> Data {
        guard boundary.range(of: "^[A-Za-z0-9-]{16,80}$", options: .regularExpression) != nil else {
            throw BackpackError.invalid("Invalid upload boundary.")
        }
        try metadata.validate()
        let json = try JSONEncoder().encode(metadata)
        guard data.range(of: Data(boundary.utf8)) == nil, json.range(of: Data(boundary.utf8)) == nil else {
            throw BackpackError.invalid("Upload boundary collision. Try again.")
        }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
        body.append(json)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"artwork.gif\"\r\nContent-Type: image/gif\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

@MainActor
struct CommunityUploadView: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var library: LocalLibrary
    let item: SavedMedia
    @State private var title: String
    @State private var category = "memes"
    @State private var tags = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var submitted: CommunitySubmission?
    @Environment(\.dismiss) private var dismiss

    init(item: SavedMedia) {
        self.item = item
        _title = State(initialValue: item.name)
    }
    var body: some View {
        NavigationStack {
            Form {
                if let submitted {
                    Section("Saved privately") {
                        Label(submitted.title, systemImage: "checkmark.circle")
                        Text("Only you and catalog admins can access this GIF. It has not been shared or sent for AI review. Use My uploads to separately consent to sharing.")
                        NavigationLink("My uploads") { CommunityUploadsView() }
                    }
                } else {
                    if !community.signedIn {
                        NavigationLink("Sign in / create account") { CommunityAccountView() }
                    }
                    metadata
                    Section {
                        Button("Upload to private library") { upload() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!community.signedIn || busy)
                    }.disabled(busy)
                }
                if busy { ProgressView("Uploading...") }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }
            .modernScene().navigationTitle("Upload GIF")
            .toolbar { Button("Done") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
        }
    }
    private var metadata: some View {
        Section("About this GIF") {
            TextField("Title", text: $title)
            Picker("Category", selection: $category) {
                ForEach(CommunityCategory.allCases) { Text($0.label).tag($0.rawValue) }
            }
            TextField("Tags, comma separated", text: $tags)
            if let original = item.attribution {
                Text("Imported credits: \(original.author) / \(original.license)\n\(original.source)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Animated GIFs: 2-120 frames, up to 5 MB. This upload is private, but admins can access it. Public sharing requires a separate confirmation; neither action changes the backpack.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy)
    }
    private func upload() {
        guard !busy else { return }
        let metadata = CommunityUploadMetadata.preserving(item.attribution,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category, tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        busy = true; failure = nil
        Task {
            defer { busy = false }
            do {
                if community.user == nil { try await community.refreshUser() }
                guard let owner = community.user?.id, let origin = community.origin else {
                    throw BackpackError.invalid("Sign in before saving a cloud copy.")
                }
                let revision = community.accountRevision
                let uploaded = try await community.uploadGIF(library.data(item), metadata: metadata)
                submitted = uploaded
                guard community.accountRevision == revision else {
                    throw BackpackError.invalid("Cloud copy was uploaded, but the account changed before it could be linked locally.")
                }
                try library.connectCloudCopy(mediaID: item.id, itemID: uploaded.id, origin: origin, accountID: owner)
            }
            catch { failure = "\(error.localizedDescription) If the connection ended after sending, check My uploads before retrying." }
        }
    }
}

@MainActor
struct CommunityUploadsView: View {
    @EnvironmentObject private var community: CommunityController
    @State private var items: [CommunitySubmission] = []
    @State private var busy = false
    @State private var failure: String?
    @State private var selected: CommunitySubmission?
    @State private var sharing: CommunitySubmission?
    private struct Account: Equatable {
        let origin: CommunityOrigin?
        let id: UUID?
        let signedIn: Bool
    }
    private var account: Account { Account(origin: community.origin, id: community.user?.id, signedIn: community.signedIn) }
    var body: some View {
        List {
            if !community.signedIn { NavigationLink("Sign in") { CommunityAccountView() } }
            else {
                Button("Refresh uploads") { refresh() }.disabled(busy)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline)
                        Text("Visibility: \(item.visibility) / status: \(item.status) / AI: \(item.aiState)").font(.caption)
                        if !item.moderationReason.isEmpty { Text(item.moderationReason).font(.caption) }
                        if let error = item.aiError { Text(error).font(.caption).foregroundStyle(.orange) }
                        if item.visibility == "private" {
                            Button("Submit for community sharing") { sharing = item }.disabled(busy)
                        }
                        if community.user?.role == "admin" {
                            Button("Delete server upload", role: .destructive) { selected = item }.disabled(busy)
                        } else {
                            Text(community.config?.accountDeletionRetainsSharedGifs == true
                                ? "Only admins can delete individual server GIFs. This server retains approved shared work after account deletion."
                                : "Only admins can delete individual server GIFs. Account deletion removes all GIFs you contributed, including approved shared work.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if items.isEmpty && !busy && failure == nil { Text("No uploads yet. Share an animated GIF from Library > Actions.") }
            }
            if busy { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }
        .modernScene().navigationTitle("My uploads")
        .task(id: account) { items = []; if community.signedIn { refresh() } }
        .onDisappear { items = [] }
        .confirmationDialog(sharingWarning, isPresented: Binding(
            get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            Button("I have sharing rights; submit for review") {
                guard let sharing, !busy else { return }
                self.sharing = nil; busy = true; failure = nil
                Task {
                    defer { busy = false }
                    do {
                        let updated = try await community.submitUpload(sharing.id, sharingAttested: true)
                        if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
                    } catch { failure = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Delete this server upload? This does not delete your local GIF.", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            Button("Delete server upload", role: .destructive) {
                guard let selected else { return }
                self.selected = nil; busy = true; failure = nil
                Task {
                    defer { busy = false }
                    do {
                        try await community.deleteUpload(selected.id)
                        items.removeAll { $0.id == selected.id }
                    } catch { failure = error.localizedDescription }
                }
            }
        }
    }
    private func refresh() {
        guard !busy else { return }
        busy = true; failure = nil
        Task {
            defer { busy = false }
            do {
                try await community.loadConfig()
                items = try await community.myUploads()
            }
            catch { failure = error.localizedDescription }
        }
    }
    private var sharingWarning: String {
        let retention = community.config?.accountDeletionRetainsSharedGifs == true
            ? "This server retains approved shared GIFs and credits after account deletion."
            : "Deleting your account removes your contribution, even after approval. Other users' independent copies remain separate."
        return "Submit this GIF for community review? Frames may be sent to the server's AI reviewer. \(retention)"
    }
}
