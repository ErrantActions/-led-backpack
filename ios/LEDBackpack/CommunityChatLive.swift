import Foundation
import BackpackProtocol

enum ChatLiveHint: String { case ready, messages, activity, typing, revoked }
struct ChatSSEParser {
    private var line = Data()
    private var payload = Data()
    mutating func push(_ byte: UInt8) throws -> ChatLiveHint? {
        if byte != 10 {
            guard line.count < 8192 else { throw BackpackError.invalid("Live chat line exceeds its bounded protocol.") }
            line.append(byte); return nil
        }
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { throw BackpackError.invalid("Invalid live chat UTF-8.") }
        line = Data()
        if text.isEmpty {
            guard !payload.isEmpty else { return nil }
            let value = try JSONSerialization.jsonObject(with: payload)
            payload = Data()
            guard let object = value as? [String: String], Set(object.keys) == Set(["type"]),
                  let raw = object["type"], let hint = ChatLiveHint(rawValue: raw) else {
                throw BackpackError.invalid("Live hints must contain only the known type, never private message data.")
            }
            return hint
        }
        if text.hasPrefix(":") { return nil }
        if text.hasPrefix("data:") {
            let data = Data(text.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
            guard payload.count + data.count + 1 <= 8192 else { throw BackpackError.invalid("Live chat event exceeds its bound.") }
            if !payload.isEmpty { payload.append(10) }
            payload.append(data)
        }
        return nil
    }
}
private final class ChatLiveRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor
extension CommunityFeatureClient {
    func chatHints(_ context: ChatConversation) throws -> AsyncThrowingStream<ChatLiveHint, Error> {
        let (origin, request) = try chatEventsRequest(context)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForResource = 75
                let session = URLSession(configuration: configuration, delegate: ChatLiveRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse, let url = response.url, origin.contains(url),
                          response.statusCode == 200,
                          response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 503
                        throw CommunityFailure(status: status, code: "chat_live_unavailable", message: "Live chat access/transport is unavailable.")
                    }
                    var parser = ChatSSEParser()
                    for try await byte in bytes {
                        try Task.checkCancellation(); try check(.messaging)
                        guard chatLiveEnabled else { throw BackpackError.invalid("Live chat capability was withdrawn.") }
                        if let hint = try parser.push(byte) { continuation.yield(hint) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
