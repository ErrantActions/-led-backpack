import SwiftUI
import ImageIO
import CryptoKit
import BackpackProtocol

struct NativeMatrixSize: Hashable, Codable, Identifiable {
    let width, height: Int
    var id: String { "\(width)x\(height)" }
    static let advertised = [16, 32, 48, 64].map { NativeMatrixSize(width: $0, height: $0) }
    static let legacy = NativeMatrixSize(width: 96, height: 128)
    func validate() throws {
        guard (1...4096).contains(width), (1...4096).contains(height) else { throw BackpackError.invalid("Matrix dimensions must be 1…4096.") }
    }
}
struct NativeMatrixFilter: Equatable {
    enum Mode: String, CaseIterable { case native, available }
    enum Match: String, CaseIterable { case any, all }
    var sizes: Set<NativeMatrixSize> = []
    var mode = Mode.native
    var match = Match.any
    func query() throws -> [URLQueryItem] {
        guard sizes.count <= 16 else { throw BackpackError.invalid("Select at most 16 exact sizes.") }
        for size in sizes { try size.validate() }
        return sizes.isEmpty ? [] : [
            URLQueryItem(name: "panelSizes", value: sizes.map(\.id).sorted().joined(separator: ",")),
            URLQueryItem(name: "sizeMode", value: mode.rawValue),
            URLQueryItem(name: "sizeMatch", value: match.rawValue)]
    }
}

struct NativeMatrixFilterControls: View {
    @Binding var filter: NativeMatrixFilter
    @State private var width = "32"
    @State private var height = "48"
    @State private var failure: String?
    var body: some View {
        DisclosureGroup("Exact size filters (\(filter.sizes.count))") {
            Picker("Match files", selection: $filter.mode) {
                Text("Exact original / native").tag(NativeMatrixFilter.Mode.native)
                Text("Original or recorded export").tag(NativeMatrixFilter.Mode.available)
            }
            Picker("Selected sizes", selection: $filter.match) {
                Text("Any").tag(NativeMatrixFilter.Match.any); Text("All").tag(NativeMatrixFilter.Match.all)
            }
            ForEach(NativeMatrixSize.advertised + [.legacy]) { size in
                Toggle(size.id + (size == .legacy ? " (legacy export)" : " (advertised)"),
                    isOn: Binding(get: { filter.sizes.contains(size) }, set: { enabled in
                        if enabled { if filter.sizes.count < 16 { filter.sizes.insert(size) } }
                        else { filter.sizes.remove(size) }
                    }))
            }
            HStack {
                TextField("Width", text: $width).keyboardType(.numberPad)
                Text("×"); TextField("Height", text: $height).keyboardType(.numberPad)
                Button("Add exact rectangle") {
                    do {
                        guard let w = Int(width), let h = Int(height), filter.sizes.count < 16 else { throw BackpackError.invalid("Use integer dimensions; maximum 16 sizes.") }
                        let size = NativeMatrixSize(width: w, height: h); try size.validate(); filter.sizes.insert(size); failure = nil
                    } catch { failure = error.localizedDescription }
                }
            }
            Text(filter.sizes.map(\.id).sorted().joined(separator: ", ")).font(.caption)
            Button("Clear size selection") { filter.sizes = [] }
            if let failure { Text(failure).foregroundStyle(.orange) }
            Text("No rotation or resize is labeled native. All-native with different sizes correctly has no matches. Advertised sizes do not certify hardware support.")
                .font(.caption)
        }
    }
}

struct NativeCatalogFile: Equatable, Identifiable {
    let url: URL
    let width, height, frameCount: Int
    let byteSize: Int?
    let sha256: String?
    let original: Bool
    var id: URL { url }
    var label: String { "\(width)x\(height) — \(original ? "exact original / native" : "recorded export")" }
    func verify(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 5_000_000, byteSize == nil || byteSize == data.count else {
            throw BackpackError.invalid("File size differs from the current per-file manifest.")
        }
        if let sha256 {
            guard sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
                throw BackpackError.invalid("Catalog file checksum mismatch.")
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif",
              CGImageSourceGetCount(source) == frameCount,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              properties[kCGImagePropertyPixelWidth as String] as? Int == width,
              properties[kCGImagePropertyPixelHeight as String] as? Int == height else {
            throw BackpackError.invalid("GIF format, original dimensions or frame count differs from the manifest.")
        }
        guard (1...4096).contains(width), (1...4096).contains(height),
              (1...120).contains(frameCount), width * height <= 40_000_000 / frameCount else {
            throw BackpackError.invalid("GIF structure or pre-decode pixel budget differs from the bounded descriptor.")
        }
        let structure = try GIFStructure.inspect(data)
        guard structure.frames.count == frameCount else { throw BackpackError.invalid("GIF image descriptors and decoded frame count differ.") }
        let raw = [UInt8](data)
        func littleEndian(_ offset: Int) -> Int { Int(raw[offset]) | (Int(raw[offset + 1]) << 8) }
        for frame in structure.frames {
            let offset = frame.imageOffset
            guard offset >= 0, offset <= raw.count - 10 else { throw BackpackError.invalid("Incomplete GIF image rectangle.") }
            let left = littleEndian(offset + 1), top = littleEndian(offset + 3)
            let frameWidth = littleEndian(offset + 5), frameHeight = littleEndian(offset + 7)
            guard frameWidth > 0, frameHeight > 0, left + frameWidth <= width, top + frameHeight <= height else {
                throw BackpackError.invalid("GIF frame rectangle exceeds its declared canvas before decoding.")
            }
        }
        for index in 0..<frameCount {
            try autoreleasepool {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                      properties[kCGImagePropertyPixelWidth as String] as? Int == width,
                      properties[kCGImagePropertyPixelHeight as String] as? Int == height,
                      let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary),
                      image.width == width, image.height == height else {
                    throw BackpackError.invalid("A GIF frame could not be decoded at its declared dimensions.")
                }
            }
        }
        try GIFPreviewDecoder.validateOriginal(data)
    }
}

extension CommunityItem {
    var recordedFiles: [NativeCatalogFile] {
        [NativeCatalogFile(url: gifUrl, width: width, height: height, frameCount: frameCount,
            byteSize: byteSize, sha256: nil, original: true)] +
        variants.map { NativeCatalogFile(url: $0.url, width: $0.width, height: $0.height,
            frameCount: $0.frameCount, byteSize: $0.byteSize, sha256: nil, original: false) }
    }
}

@MainActor
extension CommunityController {
    func contributorAvatar(_ url: URL, itemID: UUID, uploaderID: UUID) async throws -> Data {
        let epoch = accountRevision, policy = avatarPolicyRevision
        guard config?.avatarsEnabled == true, let origin, !avatarPolicyChanging else { throw BackpackError.invalid("Contributor avatars are unavailable.") }
        let resolved = try CommunityFeatureClient.resolvedAvatarURL(url, origin: origin)
        let before = try await currentCatalogItem(itemID)
        guard before.uploader.id == uploaderID, before.uploader.avatarMasked != true,
              before.uploader.avatarMature != true || user?.allowMature == true,
              before.uploader.avatarUrl == url || before.uploader.avatarPreviewUrl == url,
              resolved.path.split(separator: "/")[4] == Substring(uploaderID.uuidString.lowercased()) else {
            throw BackpackError.invalid("No current approved contributor-avatar grant.")
        }
        let path = resolved.path.split(separator: "/").dropFirst(2).joined(separator: "/")
        let bytes = try await request(path, authenticated: signedIn, maxBytes: 5_000_000, expectedAccountRevision: epoch).data
        let after = try await currentCatalogItem(itemID)
        guard epoch == accountRevision, policy == avatarPolicyRevision, self.origin == origin, !avatarPolicyChanging,
              after.uploader.id == uploaderID, after.uploader.avatarMasked != true,
              after.uploader.avatarUrl == url || after.uploader.avatarPreviewUrl == url else {
            throw BackpackError.invalid("Contributor publication/avatar/version grant changed.")
        }
        return bytes
    }
    func currentCatalogItem(_ id: UUID) async throws -> CommunityItem {
        struct Result: Decodable { let item: CommunityItem }
        let value = try JSONDecoder().decode(Result.self,
            from: await request("items/\(id.uuidString.lowercased())", authenticated: signedIn, expectedAccountRevision: accountRevision).data).item
        guard value.id == id else { throw BackpackError.invalid("Catalog item changed.") }
        return value
    }

}

@MainActor
struct CatalogContributorAvatar: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let item: CommunityItem
    @State private var manual = false
    var body: some View {
        VStack {
            if community.config?.avatarsEnabled == true, !community.avatarPolicyChanging,
               item.uploader.avatarMasked != true,
               item.uploader.avatarMature != true || community.user?.allowMature == true,
               let id = item.uploader.id, let preview = item.uploader.avatarPreviewUrl {
                let animate = community.user?.mediaPreferences?.permitsAnimation(reducedMotion: reducedMotion, manual: manual) ?? (!reducedMotion || manual)
                let url = item.uploader.avatarAnimated == true && animate ? (item.uploader.avatarUrl ?? preview) : preview
                GIFThumbnail(key: "contributor:\(community.accountRevision):\(community.avatarPolicyRevision):\(url)", cache: false) {
                    try await community.contributorAvatar(url, itemID: item.id, uploaderID: id)
                }.clipShape(Circle())
                if item.uploader.avatarAnimated == true { Button(manual ? "Pause avatar" : "Play avatar") { manual.toggle() }.font(.caption2) }
            } else { Image(systemName: "person.crop.circle").resizable().scaledToFit() }
        }.onChange(of: community.avatarPolicyRevision) { _, _ in manual = false }
            .accessibilityLabel("Contributor artwork avatar — no private profile grant")
    }
}
