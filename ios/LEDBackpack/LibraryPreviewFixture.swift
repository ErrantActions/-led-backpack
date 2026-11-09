#if DEBUG
import Foundation
import SwiftUI
import BackpackProtocol

@MainActor
struct FeatureActionIsolationFixture: View {
    @State private var primary = 0
    @State private var secondary = 0
    var body: some View {
        Form {
            FeatureDetails("Fixture actions") {
                Button("Primary fixture action") { primary += 1 }
                Button("Secondary fixture action") { secondary += 1 }
            }
            Text("Primary: \(primary)")
            Text("Secondary: \(secondary)")
        }.navigationTitle("Action isolation")
    }
}

private actor LibraryPreviewTransport: CommunityTransport {
    private let social: Bool
    private let paging: Bool
    init(social: Bool = false, paging: Bool = false) { self.social = social; self.paging = paging }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/api/v1/config" {
            return .init(status: 200, data: try JSONSerialization.data(withJSONObject: [
                "requireEmailVerification": false, "passwordRecoveryAvailable": false, "privateLibraryEnabled": true,
                "accountDeletionRetainsSharedGifs": false, "appleSignInEnabled": true,
                "socialEnabled": social, "messagingEnabled": social, "eventsEnabled": social, "nearbyDiscoveryEnabled": social,
                "unverifiedDeviceTagsEnabled": social, "connectedDeviceRegistrationEnabled": social,
                "connectedDeviceRegistrationVersion": 2, "deviceRecoveryEnabled": false]))
        }
        if request.httpMethod == "POST", path == "/api/v1/auth/login",
           let body = request.httpBody, let values = try JSONSerialization.jsonObject(with: body) as? [String: String],
           values["email"] == "ui@example.invalid", values["password"] == "fixture-password", values["transport"] == "bearer" {
            return CommunityResponse(status: 200, data: Data("""
            {"user":{"id":"\(LibraryPreviewFixture.owner)","email":"ui@example.invalid","displayName":"UI Rider","role":"user","verified":true,
            "authMethods":{"apple":false,"password":true,"appleOnly":false}},
            "token":"ui-preview-only-not-a-real-session","expiresAt":"2099-01-01T00:00:00.000Z"}
            """.utf8))
        }
        if request.httpMethod == "GET" {
            let ids = paging ? (1...30).map { String(format: "cccccccc-1234-4567-89ab-%012d", $0) } :
                ["cccccccc-1234-4567-89ab-abcdefabcdef", "dddddddd-1234-4567-89ab-abcdefabcdef"]
            let gif = Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,0,0,0,255,255,255,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
            let items: [[String: Any]] = ids.enumerated().map { index, id in
                ["id":id,"title":"Public fixture \(index + 1)","category":"pixel-art","tags":[],
                 "displayAttribution":"Generated test artwork","license":"original","pageUrl":"https://catalog.example/items/\(id)",
                 "gifUrl":"https://catalog.example/media/\(id)/original.gif","previewUrl":"https://catalog.example/media/\(id)/preview.png",
                 "width":1,"height":1,"frameCount":1,"byteSize":gif.count,"variants":[],
                 "uploader":["id":LibraryPreviewFixture.owner,"displayName":"Fixture author"],"likeCount":0]
            }
            if path == "/api/v1/items" {
                guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let text = components.queryItems?.first(where: { $0.name == "page" })?.value,
                      let page = Int(text), (1...10000).contains(page) else {
                    throw BackpackError.invalid("Invalid generated gallery page request.")
                }
                let start = min(items.count, max(0, (page - 1) * 24)), end = min(items.count, start + 24)
                return .init(status: 200, data: try JSONSerialization.data(withJSONObject: [
                    "items": Array(items[start..<end]), "page": page, "limit": 24, "total": items.count]))
            }
            if let index = ids.firstIndex(where: { path == "/api/v1/items/\($0)" }) {
                return .init(status: 200, data: try JSONSerialization.data(withJSONObject: ["item":items[index]]))
            }
            if ids.contains(where: { path == "/media/\($0)/original.gif" || path == "/media/\($0)/preview.png" }) {
                return .init(status: 200, data: gif)
            }
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer ui-preview-only-not-a-real-session" else {
            throw BackpackError.invalid("This UI preview only accepts its generated test account, never real credentials.")
        }
        if request.httpMethod == "GET", path == "/api/v1/auth/me" {
            return CommunityResponse(status: 200, data: Data("""
            {"user":{"id":"\(LibraryPreviewFixture.owner)","email":"ui@example.invalid","displayName":"UI Rider","role":"user","verified":true,
            "authMethods":{"apple":false,"password":true,"appleOnly":false}}}
            """.utf8))
        }
        if social, request.httpMethod == "GET" {
            switch path {
            case "/api/v1/devices":
                return .init(status: 200, data: Data(#"{"devices":[]}"#.utf8))
            case "/api/v1/devices/transfers":
                return .init(status: 200, data: Data(#"{"transfers":[]}"#.utf8))
            case "/api/v1/social/me":
                return .init(status: 200, data: Data("""
                {"profile":{"id":"\(LibraryPreviewFixture.owner)","displayName":"UI Rider"},
                "discoverable":false,"allowRequests":true,"messagingEnabled":true,"encryption":"server-managed"}
                """.utf8))
            case "/api/v1/social/friends":
                return .init(status: 200, data: Data(#"{"friends":[],"page":1,"limit":50}"#.utf8))
            case "/api/v1/social/requests":
                return .init(status: 200, data: Data(#"{"inbound":[],"outbound":[],"page":1,"limit":50}"#.utf8))
            case "/api/v1/social/conversations":
                return .init(status: 200, data: Data(#"{"conversations":[],"page":1,"limit":24}"#.utf8))
            case "/api/v1/events":
                return .init(status: 200, data: Data(#"{"events":[],"offset":0,"limit":50,"serverTime":"2026-11-08T18:00:00.000Z"}"#.utf8))
            default: break
            }
        }
        if request.httpMethod == "GET", path == "/api/v1/me/items" {
            let items = [("Night ride", LibraryPreviewFixture.linkedItem), ("Cloud demo", LibraryPreviewFixture.remoteItem)]
                .map { entry in
                    let title = entry.0, id = entry.1
                    return """
                    {"id":"\(id)","title":"\(title)","category":"pixel-art","tags":[],"displayAttribution":"Generated UI artwork",
                    "license":"original","licenseUrl":null,"sourceUrl":null,"pageUrl":"https://catalog.example/items/\(id)",
                    "gifUrl":"https://catalog.example/media/\(id)/original.gif","previewUrl":"https://catalog.example/media/\(id)/preview.png",
                    "width":64,"height":64,"frameCount":2,"byteSize":1000,"variants":[],"likeCount":0,
                    "uploader":{"id":"\(LibraryPreviewFixture.owner)","displayName":"UI Rider"},"visibility":"private","status":"pending",
                    "moderationReason":"","aiState":"disabled","aiError":null}
                    """
                }.joined(separator: ",")
            return CommunityResponse(status: 200, data: Data("{\"items\":[\(items)],\"page\":1,\"limit\":100,\"total\":2}".utf8))
        }
        if request.httpMethod == "GET",
           path == "/media/\(LibraryPreviewFixture.linkedItem)/original.gif" ||
            path == "/media/\(LibraryPreviewFixture.remoteItem)/original.gif" {
            let bytes = try await MainActor.run {
                let frame = try TextArtwork.render("LED", size: PanelSize(width: 64, height: 64), font: .pixel,
                    alignment: .center, color: .magenta, pixelScale: 2)
                return try MediaCodec.encode([frame], delays: [0.5])
            }
            return CommunityResponse(status: 200, data: bytes)
        }
        if request.httpMethod == "GET",
           path == "/media/\(LibraryPreviewFixture.linkedItem)/preview.png" ||
            path == "/media/\(LibraryPreviewFixture.remoteItem)/preview.png" {
            let bytes = try await MainActor.run {
                let frame = try TextArtwork.render("LED", size: PanelSize(width: 64, height: 64), font: .pixel,
                    alignment: .center, color: .magenta, pixelScale: 2)
                guard let data = try frame.image().pngData() else { throw BackpackError.invalid("Preview fixture image failed.") }
                return data
            }
            return CommunityResponse(status: 200, data: bytes)
        }
        throw BackpackError.invalid("This UI preview does not perform live account operations.")
    }
}

@MainActor
private final class LibraryPreviewVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
enum LibraryPreviewFixture {
    nonisolated static let owner = "223609c9-cc77-4818-8951-0c55acdaab4e"
    nonisolated static let linkedItem = "abcdefab-1234-4567-89ab-abcdefabcdef"
    nonisolated static let remoteItem = "bbbbbbbb-1234-4567-89ab-abcdefabcdef"
    static func community() -> CommunityController {
        CommunityController(vault: LibraryPreviewVault(), factory: { _ in
            LibraryPreviewTransport(social: CommandLine.arguments.contains("--social-ui-fixture"),
                paging: CommandLine.arguments.contains("--pagination-ui-fixture"))
        })
    }
    static func make() throws -> LocalLibrary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LEDBackpack-UITest-\(UUID().uuidString)", isDirectory: true)
        let library = try LocalLibrary(folder: folder)
        let size = PanelSize(width: 64, height: 64)
        let first = try TextArtwork.render("LED", size: size, font: .pixel, alignment: .center, color: .cyan, pixelScale: 2)
        let second = try TextArtwork.render("LED", size: size, font: .pixel, alignment: .center, color: .magenta, pixelScale: 2)
        try library.add(name: "Night ride", data: MediaCodec.encode([first, second], delays: [0.5, 0.5]), category: "Pixel art")
        try library.add(name: "Meetup glow", data: MediaCodec.encode([second, first], delays: [0.5, 0.5]), category: "Patterns")
        guard let local = library.state.media.first(where: { $0.name == "Night ride" }),
              let item = UUID(uuidString: linkedItem), let owner = UUID(uuidString: Self.owner) else {
            throw BackpackError.invalid("Invalid generated library preview IDs.")
        }
        try library.connectCloudCopy(mediaID: local.id, itemID: item, origin: CommunityOrigin.parse("https://catalog.example"), accountID: owner)
        var preferences = library.state.preferences
        preferences.communityURL = "https://catalog.example"
        try library.savePreferences(preferences)
        return library
    }
}
#endif
