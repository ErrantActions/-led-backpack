import Foundation
import BackpackProtocol

enum HTTP {
    static func fetch(_ url: URL, maxBytes: Int = 2_000_000) async throws -> Data {
        guard url.scheme == "https" else { throw BackpackError.invalid("Only HTTPS sources are supported.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("LEDBackpack/0.1 (https://github.com/ErrantActions/-led-backpack)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BackpackError.invalid("Server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        if response.expectedContentLength > Int64(maxBytes) { throw BackpackError.invalid("Download exceeds the app's size limit.") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maxBytes { throw BackpackError.invalid("Download exceeds the app's size limit.") }
            data.append(byte)
        }
        return data
    }
}

enum GIFTopic: String, CaseIterable, Identifiable {
    case all = "All", pixelArt = "Pixel art", animals = "Animals", nature = "Nature"
    case space = "Space", patterns = "Patterns", symbols = "Symbols", retro = "Retro"
    var id: String { rawValue }
    var libraryCategory: String? { self == .all ? nil : rawValue }
    var searchTerms: String {
        switch self {
        case .all: return ""
        case .pixelArt: return "pixel art"
        case .animals: return "animal"
        case .nature: return "nature"
        case .space: return "space"
        case .patterns: return "pattern"
        case .symbols: return "icon"
        case .retro: return "retro"
        }
    }
}

struct GIFResult: Identifiable, Equatable {
    let id: Int
    let title: String
    let url: URL
    let page: URL
    let attribution: Attribution
    let previewURL: URL
    let width: Int
    let height: Int
    let bytes: Int
}

struct GIFSearchPage {
    let items: [GIFResult]
    let nextOffset: Int?
    let excludedCount: Int
    let notice: String?
}

enum CommonsSearch {
    private struct Result: Decodable {
        let query: Query?
        let error: APIError?
        let batchcomplete: Bool?
        let continuation: Continuation?
        let warnings: [String: Warning]?
        enum CodingKeys: String, CodingKey {
            case query, error, batchcomplete, warnings
            case continuation = "continue"
        }
    }
    private struct APIError: Decodable { let code: String?; let info: String? }
    private struct Warning: Decodable { let warnings: String? }
    private struct Continuation: Decodable { let gsroffset: Int }
    private struct Query: Decodable { let pages: [Page]? }
    private struct Page: Decodable {
        let pageid: Int?
        let title: String
        let index: Int?
        let imageinfo: [Info]?
    }
    private struct Metadata: Decodable { let value: String }
    private struct Info: Decodable {
        let url: String
        let descriptionurl: String
        let size: Int
        let mime: String
        let width: Int
        let height: Int
        let thumburl: String?
        let extmetadata: [String: Metadata]?
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    static func requestURL(_ text: String, topic: GIFTopic = .all, offset: Int = 0) throws -> URL {
        guard text.count <= 100, (0...10000).contains(offset) else {
            throw BackpackError.invalid("Search terms must be at most 100 characters, with a valid page offset.")
        }
        let words = [topic.searchTerms, text.trimmingCharacters(in: .whitespacesAndNewlines), "filemime:image/gif"]
            .filter { !$0.isEmpty }.joined(separator: " ")
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            "action": "query", "format": "json", "formatversion": "2",
            "generator": "search", "gsrsearch": words, "gsroffset": String(offset),
            "gsrnamespace": "6", "gsrlimit": "20", "prop": "imageinfo",
            "iiprop": "url|size|mime|extmetadata", "iiurlwidth": "240", "iiurlheight": "240",
            "iiextmetadatafilter": "Artist|LicenseShortName|LicenseUrl"
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw BackpackError.invalid("Could not construct search URL.") }
        return url
    }

    static func search(_ text: String, topic: GIFTopic = .all, offset: Int = 0) async throws -> GIFSearchPage {
        let url = try requestURL(text, topic: topic, offset: offset)
        return try decode(await HTTP.fetch(url))
    }

    static func decode(_ data: Data) throws -> GIFSearchPage {
        let response: Result
        do { response = try JSONDecoder().decode(Result.self, from: data) }
        catch is DecodingError { throw BackpackError.invalid("The GIF catalog returned an unreadable response. Try again later.") }
        if let error = response.error {
            throw BackpackError.invalid("GIF catalog: \(plain(error.info ?? error.code ?? "Unknown service error"))")
        }
        guard response.query?.pages != nil || response.batchcomplete == true || response.continuation != nil else {
            throw BackpackError.invalid("The GIF catalog returned an incomplete response.")
        }
        let pages = response.query?.pages ?? []
        let ordered = pages.enumerated().sorted {
            ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset)
        }
        let items = ordered.compactMap { entry -> GIFResult? in
            let page = entry.element
            guard let id = page.pageid, id > 0,
                  let info = page.imageinfo?.first, info.mime == "image/gif", (1...5_000_000).contains(info.size),
                  (1...4096).contains(info.width), (1...4096).contains(info.height),
                  let url = URL(string: info.url), url.scheme == "https", url.host == "upload.wikimedia.org",
                  let source = URL(string: info.descriptionurl), source.scheme == "https", source.host == "commons.wikimedia.org",
                  let license = info.extmetadata?["LicenseShortName"]?.value,
                  !plain(license).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let preview = URL(string: info.thumburl ?? info.url),
                  preview.scheme == "https", preview.host == "upload.wikimedia.org" else { return nil }
            let metadata = info.extmetadata ?? [:]
            return GIFResult(id: id, title: page.title.replacingOccurrences(of: "File:", with: ""),
                url: url, page: source, attribution: Attribution(source: source.absoluteString,
                    author: plain(metadata["Artist"]?.value ?? "See source page"),
                    license: plain(license), licenseURL: metadata["LicenseUrl"]?.value ?? source.absoluteString),
                previewURL: preview, width: info.width, height: info.height, bytes: info.size)
        }
        let next = response.continuation?.gsroffset
        if let next, !(1...10000).contains(next) { throw BackpackError.invalid("The GIF catalog returned an invalid page cursor.") }
        let notices = (response.warnings ?? [:]).values.compactMap(\.warnings).map(plain).sorted()
        return GIFSearchPage(items: items, nextOffset: next, excludedCount: pages.count - items.count,
            notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }
}

struct WeatherReading: Decodable {
    let current: Current
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let wind_speed_10m: Double
    }
}

enum WeatherService {
    static func current(latitude: Double, longitude: Double) async throws -> WeatherReading {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            "latitude": String(latitude), "longitude": String(longitude),
            "current": "temperature_2m,weather_code,wind_speed_10m",
            "temperature_unit": "celsius", "wind_speed_unit": "kmh"
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw BackpackError.invalid("Could not construct forecast URL.") }
        let result = try JSONDecoder().decode(WeatherReading.self, from: await HTTP.fetch(url))
        guard result.current.temperature_2m.isFinite, result.current.wind_speed_10m.isFinite else {
            throw BackpackError.invalid("Weather source returned invalid numbers.")
        }
        return result
    }
}
