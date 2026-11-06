import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class NativeRequestFileTests: XCTestCase {
    private func source(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("request-file-test-\(UUID().uuidString).body")
        try data.write(to: url)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func read(_ value: NativeRequestFile) throws -> Data {
        let stream = try value.openStream(); stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { throw stream.streamError ?? BackpackError.invalid("Snapshot read failed") }
            if count == 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
    func testIncrementalSnapshotHashesExactBytesAcrossChunkBoundary() async throws {
        let bytes = Data((0..<1_052_444).map { UInt8($0 % 251) })
        let original = try source(bytes)
        let value = try await NativeRequestFileBuilder.shared.capture(original, maxBytes: bytes.count)
        addTeardownBlock { try value.remove() }
        XCTAssertEqual(value.byteCount, bytes.count); XCTAssertEqual(value.bodyHash, NativeIntegrityBinding.digest(bytes))
        XCTAssertEqual(try read(value), bytes)
    }
    func testOriginalFileMutationCannotChangeAttestedStreamBytesOrLength() async throws {
        let originalBytes = Data("immutable original multipart bytes".utf8)
        let original = try source(originalBytes)
        let value = try await NativeRequestFileBuilder.shared.capture(original, maxBytes: 4096)
        addTeardownBlock { try value.remove() }
        try Data("different source after capture".utf8).write(to: original)
        XCTAssertEqual(try read(value), originalBytes); XCTAssertEqual(value.byteCount, originalBytes.count)
        XCTAssertEqual(value.bodyHash, NativeIntegrityBinding.digest(originalBytes))
    }
    func testExactByteBudgetRejectsOneByteOverAndAcceptsBoundary() async throws {
        let original = try source(Data(repeating: 7, count: 4096))
        let value = try await NativeRequestFileBuilder.shared.capture(original, maxBytes: 4096)
        addTeardownBlock { try value.remove() }
        XCTAssertEqual(value.byteCount, 4096)
        do { _ = try await NativeRequestFileBuilder.shared.capture(original, maxBytes: 4095); XCTFail("Byte budget exceeded") } catch {}
    }
    func testEmptyAndSymbolicSourcesCannotProduceSuccessShapedSnapshots() async throws {
        let empty = try source(Data())
        do { _ = try await NativeRequestFileBuilder.shared.capture(empty, maxBytes: 4096); XCTFail("Empty snapshot") } catch {}
        let target = try source(Data([1,2,3])), link = FileManager.default.temporaryDirectory.appendingPathComponent("request-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try FileManager.default.removeItem(at: link) }
        do { _ = try await NativeRequestFileBuilder.shared.capture(link, maxBytes: 4096); XCTFail("Link") } catch {}
    }
    func testRemovedOwnedSnapshotCannotBecomeAnEmptyUploadFallback() async throws {
        let original = try source(Data([1,2,3]))
        let value = try await NativeRequestFileBuilder.shared.capture(original, maxBytes: 4096)
        try value.remove()
        XCTAssertThrowsError(try value.openStream())
    }
}
