import Foundation
import BackpackProtocol

enum HTTP {
    static func fetch(_ url: URL, maxBytes: Int = 2_000_000) async throws -> Data {
        guard url.scheme == "https" else { throw BackpackError.invalid("Only HTTPS sources are supported.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("LEDBackpack/0.1 (personal LED controller)", forHTTPHeaderField: "User-Agent")
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

struct GIFResult: Identifiable {
    let id: Int
    let title: String
    let url: URL
    let page: URL
    let attribution: Attribution
}

enum CommonsSearch {
    private struct Result: Decodable { let query: Query?; let error: APIError? }
    private struct APIError: Decodable { let info: String }
    private struct Query: Decodable { let pages: [Page] }
    private struct Page: Decodable { let pageid: Int; let title: String; let imageinfo: [Info]? }
    private struct Metadata: Decodable { let value: String }
    private struct Info: Decodable {
        let url: String
        let descriptionurl: String
        let size: Int
        let mime: String
        let extmetadata: [String: Metadata]?
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
    }

    static func search(_ text: String) async throws -> [GIFResult] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 100 else {
            throw BackpackError.invalid("Enter a search term up to 100 characters.")
        }
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            "action": "query", "format": "json", "formatversion": "2",
            "generator": "search", "gsrsearch": "\(text) filetype:bitmap ext:gif",
            "gsrnamespace": "6", "gsrlimit": "20", "prop": "imageinfo",
            "iiprop": "url|size|mime|extmetadata"
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw BackpackError.invalid("Could not construct search URL.") }
        let response = try JSONDecoder().decode(Result.self, from: await HTTP.fetch(url))
        if let error = response.error { throw BackpackError.invalid(error.info) }
        return (response.query?.pages ?? []).compactMap { page -> GIFResult? in
            guard let info = page.imageinfo?.first, info.mime == "image/gif", info.size <= 5_000_000,
                  let url = URL(string: info.url), url.scheme == "https", url.host == "upload.wikimedia.org",
                  let source = URL(string: info.descriptionurl), source.scheme == "https",
                  let license = info.extmetadata?["LicenseShortName"]?.value, !license.isEmpty else { return nil }
            let metadata = info.extmetadata ?? [:]
            return GIFResult(id: page.pageid, title: page.title.replacingOccurrences(of: "File:", with: ""),
                url: url, page: source, attribution: Attribution(source: source.absoluteString,
                    author: plain(metadata["Artist"]?.value ?? "See source page"),
                    license: plain(license), licenseURL: metadata["LicenseUrl"]?.value ?? source.absoluteString))
        }.sorted { $0.title < $1.title }
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
