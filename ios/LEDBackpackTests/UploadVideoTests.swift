import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class UploadVideoTests: XCTestCase {
    private func metadata() -> CommunityUploadMetadata {
        CommunityUploadMetadata(title: "My loop", category: "memes", tags: ["pixel"],
            attribution: "Creator", license: .original)
    }

    func testOrderedMultipartPreservesBytesAndCredits() throws {
        let boundary = "LEDBackpack-Test-Boundary-123456"
        let gif = Data([0, 1, 2, 255, 13, 10])
        var value = metadata()
        value.attribution = "Creator & collaborator"
        value.sourceUrl = "https://example.org/source"
        let body = try CommunityUpload.multipart(gif, metadata: value, boundary: boundary)
        let metadataHeader = Data("name=\"metadata\"\r\n\r\n".utf8)
        let fileHeader = Data("Content-Type: image/gif\r\n\r\n".utf8)
        let start = try XCTUnwrap(body.range(of: metadataHeader))
        let file = try XCTUnwrap(body.range(of: fileHeader))
        let separator = try XCTUnwrap(body.range(of: Data("\r\n--\(boundary)".utf8), in: start.upperBound..<body.endIndex))
        XCTAssertLessThan(start.lowerBound, file.lowerBound)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body.subdata(in: start.upperBound..<separator.lowerBound)) as? [String: Any])
        XCTAssertEqual(object["attribution"] as? String, "Creator & collaborator")
        XCTAssertNil(object["ownershipAttested"])
        XCTAssertEqual(object["license"] as? String, "original")
        XCTAssertNil(object["status"])
        XCTAssertEqual(body.subdata(in: file.upperBound..<(file.upperBound + gif.count)), gif)
        XCTAssertTrue(body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count).elementsEqual(Data("\r\n--\(boundary)--\r\n".utf8)))
        XCTAssertThrowsError(try CommunityUpload.multipart(gif, metadata: value, boundary: "bad\r\nboundary"))
        XCTAssertThrowsError(try CommunityUpload.multipart(Data(boundary.utf8), metadata: value, boundary: boundary))
    }

    func testUploadMetadataRequiresOnlyClassificationAndValidBudgets() throws {
        var value = metadata()
        XCTAssertNoThrow(try value.validate())
        value.attribution = nil; value.license = nil
        XCTAssertNoThrow(try value.validate())
        let minimal = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(Set(minimal.keys), Set(["title", "category", "tags"]))
        value = metadata(); value.title = String(repeating: "A", count: 121)
        XCTAssertThrowsError(try value.validate())
        value = metadata(); value.tags = Array(repeating: "tag", count: 13)
        XCTAssertThrowsError(try value.validate())
        value = metadata(); value.attribution = String(repeating: "A", count: 501)
        XCTAssertThrowsError(try value.validate())
        value = metadata(); value.sourceUrl = "https://user:password@example.org"
        XCTAssertThrowsError(try value.validate())
        value = metadata(); value.category = "unmoderated"
        XCTAssertThrowsError(try value.validate())
    }

    func testUploadPreservesExistingCreditsWithoutChoosingNewRights() throws {
        let credit = Attribution(source: "https://example.org/source", author: "Creator",
            license: "CC-BY-4.0", licenseURL: "https://creativecommons.org/licenses/by/4.0/")
        let value = CommunityUploadMetadata.preserving(credit, title: "Test", category: "memes", tags: [])
        XCTAssertNoThrow(try value.validate())
        XCTAssertEqual(value.attribution, credit.author)
        XCTAssertEqual(value.license, .by)
        XCTAssertEqual(value.sourceUrl, credit.source)
        let plain = CommunityUploadMetadata.preserving(nil, title: "Test", category: "memes", tags: [])
        XCTAssertNil(plain.attribution)
        XCTAssertNil(plain.license)
        XCTAssertNil(plain.sourceUrl)
    }

    func testUnspecifiedAndUnsupportedLicensesDoNotBecomeOriginalOrPublicDomain() throws {
        for raw in ["unspecified", "unreviewed", "CC BY-SA 2.5"] {
            let credit = Attribution(source: "https://example.org/source", author: "",
                license: raw, licenseURL: "https://example.org/license")
            let value = CommunityUploadMetadata.preserving(credit, title: "Test", category: "memes", tags: [])
            XCTAssertNoThrow(try value.validate())
            XCTAssertNotEqual(value.license, .original)
            XCTAssertNotEqual(value.license, .cc0)
            if raw == "unspecified" { XCTAssertEqual(value.license, .unspecified) }
            if raw == "unreviewed" { XCTAssertNil(value.license); XCTAssertEqual(value.attribution, "") }
            if raw == "CC BY-SA 2.5" {
                XCTAssertNil(value.license)
                XCTAssertTrue(value.attribution?.contains(raw) == true)
                XCTAssertTrue(value.attribution?.contains(credit.licenseURL) == true)
            }
        }
    }

    func testSingleFrameAndAnimatedGIFsCanBeSharedWithinBudgets() throws {
        let size = PanelSize(width: 16, height: 16)
        let black = PixelFrame.black(size)
        var marked = black
        marked.rgb[0] = 255
        let still = try MediaCodec.encode([black], delays: [1])
        XCTAssertNoThrow(try CommunityUpload.validateGIF(still))
        XCTAssertEqual(try MediaCodec.decode(still).images.count, 1)
        let animated = try MediaCodec.encode([marked, black], delays: [0.1, 0.1])
        XCTAssertNoThrow(try CommunityUpload.validateGIF(animated))
        XCTAssertThrowsError(try CommunityUpload.validateGIF(Data("not a GIF".utf8)))
        XCTAssertThrowsError(try CommunityUpload.validateGIF(Data(repeating: 0, count: 5_000_001)))
    }

    func testVideoPlanHonorsTrimTimingAndFrameLimits() throws {
        let plan = try VideoGIFPlan(assetDuration: 20, start: 5, duration: 6, fps: 20)
        XCTAssertEqual(plan.frameCount, 120)
        XCTAssertEqual(plan.delay, 0.05, accuracy: 0.00001)
        XCTAssertEqual(plan.times.first, 5)
        XCTAssertLessThan(try XCTUnwrap(plan.times.last), 11)
        for invalid in [(Double.nan, 0.0, 3.0, 10), (20.0, -1.0, 3.0, 10),
            (20.0, 19.0, 3.0, 10), (20.0, 0.0, 12.0, 20),
            (20.0, 0.0, 1.0, 1), (20.0, 0.0, 0.1, 2)] {
            XCTAssertThrowsError(try VideoGIFPlan(assetDuration: invalid.0, start: invalid.1, duration: invalid.2, fps: invalid.3))
        }
    }

    func testVideoImportCopiesAndOnlyRemovesManagedFiles() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try ImportedVideo.copy(source)
        XCTAssertNotEqual(imported.url, source)
        XCTAssertEqual(try Data(contentsOf: imported.url), Data([1, 2, 3]))
        try imported.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertThrowsError(try ImportedVideo(url: source).remove())
    }

    func testVideoConversionRespectsPortraitTransformAndProducesUploadableGIF() async throws {
        // Original red video with a changing marker and a 90-degree display matrix.
        let url = try XCTUnwrap(Bundle(for: UploadVideoTests.self).url(forResource: "portrait-red", withExtension: "mov"))
        let duration = try await VideoGIFCodec.inspect(url)
        XCTAssertEqual(duration, 1, accuracy: 0.02)
        let plan = try VideoGIFPlan(assetDuration: duration, start: 0.2, duration: 0.6, fps: 10)
        let size = PanelSize(width: 64, height: 64)
        var progress: [Double] = []
        let gif = try await VideoGIFCodec.convert(url, plan: plan, size: size, fit: .fit) { progress.append($0) }
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress.count, plan.frameCount)
        XCTAssertNoThrow(try CommunityUpload.validateGIF(gif))
        let decoded = try MediaCodec.decode(gif)
        XCTAssertEqual(decoded.images.count, plan.frameCount)
        let frame = try MediaCodec.transform(XCTUnwrap(decoded.images.first), size: size, fit: .fit, turns: 0, brightness: 1)
        let next = try MediaCodec.transform(XCTUnwrap(decoded.images.dropFirst().first), size: size, fit: .fit, turns: 0, brightness: 1)
        XCTAssertNotEqual(frame.rgb, next.rgb, "Video conversion must preserve actual changing frame content.")
        let marked = (0..<(64 * 64)).filter { frame.rgb[$0 * 3] > 200 }
        XCTAssertEqual(marked.map { $0 % 64 }.min(), 16)
        XCTAssertEqual(marked.map { $0 % 64 }.max(), 47)
        XCTAssertEqual(marked.map { $0 / 64 }.min(), 0)
        XCTAssertEqual(marked.map { $0 / 64 }.max(), 63)
    }

    func testCancelledConversionDoesNotProduceGIF() async throws {
        let plan = try VideoGIFPlan(assetDuration: 10, start: 0, duration: 1, fps: 10)
        let task = Task {
            try await VideoGIFCodec.convert(FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).mov"),
                plan: plan, size: PanelSize(width: 64, height: 64), fit: .fit) { _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not produce data") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
