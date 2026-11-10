import Foundation

struct CatalogMediaCache {
    struct Entry {
        let data: Data
        let etag: String
    }
    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private(set) var byteCount = 0
    private let maximumBytes = 20_000_000
    private let maximumEntries = 16

    func entry(for url: URL, maximumBytes: Int) -> Entry? {
        guard let entry = entries[url], entry.data.count <= maximumBytes else { return nil }
        return entry
    }

    mutating func remove(_ url: URL) {
        if let old = entries.removeValue(forKey: url) { byteCount -= old.data.count }
        order.removeAll { $0 == url }
    }

    mutating func clear() {
        entries.removeAll(); order.removeAll(); byteCount = 0
    }

    mutating func store(_ data: Data, etag: String?, for url: URL) {
        remove(url)
        guard let etag, etag.range(of: "^\"[a-f0-9]{64}\"$", options: .regularExpression) != nil,
              !data.isEmpty, data.count <= maximumBytes else { return }
        while (byteCount + data.count > maximumBytes || entries.count >= maximumEntries), let oldest = order.first {
            remove(oldest)
        }
        entries[url] = Entry(data: data, etag: etag)
        order.append(url); byteCount += data.count
    }
}
