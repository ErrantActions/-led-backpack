import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import LEDBackpack

enum LocalPixelFixtures {
    static let attribution = Attribution(source: "Local fixture", author: "Fixture author", license: "CC0", licenseURL: "https://example.invalid/cc0")
    static func gif(delays: [Int] = [1, 12000], repeats: Int? = nil, disposal: Int = 1,
                    transparent: Bool = false, optimized: Bool = false, control: Bool = true) -> Data {
        func le(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8)] }
        var bytes = Array("GIF89a".utf8) + le(optimized ? 2 : 1) + le(1) + [0x80,0,0,0,0,0,255,255,255]
        if let repeats { bytes += [0x21,0xFF,11] + Array("NETSCAPE2.0".utf8) + [3,1] + le(repeats) + [0] }
        for (index, delay) in delays.enumerated() {
            if control { bytes += [0x21,0xF9,4, UInt8((disposal << 2) | (transparent ? 1 : 0))] + le(delay) + [0,0] }
            bytes += [0x2C,0,0,0,0,1,0,1,0,0,2,2,index.isMultiple(of: 2) ? 0x44 : 0x4C,1,0]
        }
        return Data(bytes + [0x3B])
    }
    static func artwork(_ width: Int = 3, _ height: Int = 2) throws -> LocalPixelArtwork {
        var art = try LocalPixelArtwork.blank(width: width, height: height)
        art.attribution = attribution
        art.frames[0].rgba = (0..<(width * height)).flatMap { pixel -> [UInt8] in
            pixel.isMultiple(of: 2) ? [255,0,0,255] : [0,255,255,255]
        }
        return art
    }
    static func png(width: Int = 1, animated: Bool = false) -> Data {
        func be(_ value: UInt32) -> [UInt8] {
            [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        }
        func chunk(_ name: String, _ payload: [UInt8]) -> [UInt8] {
            let content = Array(name.utf8) + payload
            var crc: UInt32 = 0xFFFFFFFF
            for byte in content {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB88320) }
            }
            return be(UInt32(payload.count)) + content + be(crc ^ 0xFFFFFFFF)
        }
        func compressed(_ blue: Bool) -> [UInt8] {
            let scanline = [UInt8(0)] + (0..<width).flatMap { _ -> [UInt8] in blue ? [0,0,255,255] : [255,0,0,255] }
            let size = scanline.count
            var a: UInt32 = 1, b: UInt32 = 0
            for byte in scanline { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
            return [0x78,0x01,0x01,UInt8(size & 255),UInt8(size >> 8),UInt8((~size) & 255),UInt8(((~size) >> 8) & 255)]
                + scanline + be((b << 16) | a)
        }
        func control(_ sequence: UInt32) -> [UInt8] {
            be(sequence) + be(UInt32(width)) + be(1) + be(0) + be(0) + [0,1,0,10,0,0]
        }
        var bytes: [UInt8] = [137,80,78,71,13,10,26,10]
        bytes += chunk("IHDR", be(UInt32(width)) + be(1) + [8,6,0,0,0])
        if animated { bytes += chunk("acTL", be(2) + be(0)) + chunk("fcTL", control(0)) }
        bytes += chunk("IDAT", compressed(false))
        if animated { bytes += chunk("fcTL", control(1)) + chunk("fdAT", be(2) + compressed(true)) }
        bytes += chunk("IEND", [])
        return Data(bytes)
    }
    static func decodedPixels(_ data: Data, frame: Int = 0) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, frame, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        XCTAssertTrue(success); return (image.width, image.height, bytes)
    }
}

final class LocalPixelCodecTests: XCTestCase {
    func testPNGIsRealPNGWithActualRectangularDimensionsAndOpaquePixels() throws {
        let art = try LocalPixelFixtures.artwork(7, 11)
        let data = try LocalPixelCodec.png(art, frame: 0)
        XCTAssertEqual(Array(data.prefix(8)), [137,80,78,71,13,10,26,10])
        let decoded = try LocalPixelFixtures.decodedPixels(data)
        XCTAssertEqual(decoded.width, 7); XCTAssertEqual(decoded.height, 11); XCTAssertEqual(decoded.rgba, art.frames[0].rgba)
    }
    func testPNGPreservesPartialAlphaAndTransparentPixels() throws {
        var art = try LocalPixelArtwork.blank(width: 2, height: 1)
        art.frames[0].rgba = [0,0,255,128, 0,0,0,0]
        let bytes = try LocalPixelCodec.png(art, frame: 0)
        let decoded = try LocalPixelFixtures.decodedPixels(bytes)
        XCTAssertEqual(decoded.rgba, [0,0,128,128, 0,0,0,0])
        let imported = try LocalPixelCodec.decode(bytes)
        XCTAssertEqual(imported.frames[0].rgba, art.frames[0].rgba)
    }
    func testPNGExportsOnlySelectedFrameAndEmbedsAttribution() throws {
        var art = try LocalPixelFixtures.artwork(1, 1)
        art.frames.append(LocalPixelFrame(rgba: [0,0,255,255], centiseconds: 20))
        let data = try LocalPixelCodec.png(art, frame: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(try LocalPixelFixtures.decodedPixels(data).rgba, [0,0,255,255])
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let png = properties?[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        XCTAssertEqual(png?[kCGImagePropertyPNGAuthor as String] as? String, LocalPixelFixtures.attribution.author)
        XCTAssertThrowsError(try LocalPixelCodec.png(art, frame: 2))
    }
    func testRealGIFRoundTripKeepsAllFramesDimensionsPixelsCentisecondsAndRepeats() throws {
        var art = try LocalPixelFixtures.artwork(3, 2)
        art.frames[0].centiseconds = 12000
        art.frames.append(LocalPixelFrame(rgba: Array(repeating: [UInt8(0),0,255,255], count: 6).flatMap { $0 }, centiseconds: 65535))
        art.repeats = 3
        let data = try LocalPixelCodec.gif(art), structure = try GIFStructure.inspect(data)
        XCTAssertEqual(structure.frames.map(\.delayCentiseconds), [12000,65535])
        XCTAssertEqual(structure.frames.map(\.disposal), [2,2])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        for index in 0..<2 {
            let decoded = try LocalPixelFixtures.decodedPixels(data, frame: index)
            XCTAssertEqual(decoded.width, 3); XCTAssertEqual(decoded.height, 2)
            XCTAssertEqual(decoded.rgba, art.frames[index].rgba)
        }
        let imported = try LocalPixelCodec.decode(data)
        XCTAssertEqual(imported.repeats, 3)
        XCTAssertEqual(imported.frames.map(\.centiseconds), [12000,65535])
        XCTAssertTrue(data.range(of: Data(LocalPixelFixtures.attribution.author.utf8)) != nil)
    }
    func testGIFDistinguishesOnceForeverAndMaximumFiniteRepeats() throws {
        for repeats in [Optional<Int>.none, Optional(0), Optional(65535)] {
            var art = try LocalPixelFixtures.artwork(1, 1); art.repeats = repeats
            let bytes = try LocalPixelCodec.gif(art)
            let imported = try LocalPixelCodec.decode(bytes)
            XCTAssertEqual(imported.repeats, repeats)
            XCTAssertEqual(bytes.range(of: Data("NETSCAPE2.0".utf8)) != nil, repeats != nil)
        }
    }
    func testGIFBinaryTransparencyAndDisposalAreEncodedWithoutFlattening() throws {
        var art = try LocalPixelArtwork.blank(width: 2, height: 1)
        art.frames[0].rgba = [255,0,0,255, 0,0,0,0]
        art.frames.append(LocalPixelFrame(rgba: [0,0,0,0, 0,0,255,255], centiseconds: 20))
        let bytes = try LocalPixelCodec.gif(art)
        let structure = try GIFStructure.inspect(bytes)
        XCTAssertTrue(structure.frames.allSatisfy(\.transparent))
        XCTAssertTrue(structure.frames.allSatisfy { $0.disposal == 2 })
        XCTAssertEqual(try LocalPixelFixtures.decodedPixels(bytes).rgba, art.frames[0].rgba)
        XCTAssertEqual(try LocalPixelFixtures.decodedPixels(bytes, frame: 1).rgba, art.frames[1].rgba)
    }
    func testGIFPartialAlphaIsRejectedWithoutChangingInput() throws {
        var art = try LocalPixelFixtures.artwork(1, 1)
        art.frames[0].rgba[3] = 128
        let before = art
        XCTAssertThrowsError(try LocalPixelCodec.gif(art)); XCTAssertEqual(art, before)
        XCTAssertNoThrow(try LocalPixelCodec.png(art, frame: 0))
    }
    func testGIF257ColorsAreRejectedRatherThanSilentlyQuantized() throws {
        var art = try LocalPixelArtwork.blank(width: 128, height: 3)
        for pixel in 0..<384 {
            let offset = pixel * 4
            art.frames[0].rgba.replaceSubrange(offset..<offset + 4,
                with: [UInt8(pixel & 255), UInt8(pixel >> 8), 0, 255])
        }
        XCTAssertThrowsError(try LocalPixelCodec.gif(art))
    }
    func testGIF256OpaqueColorsAreRepresentableExactly() throws {
        var art = try LocalPixelArtwork.blank(width: 128, height: 2)
        art.frames[0].rgba = (0..<256).flatMap { [UInt8($0),0,0,255] }
        let data = try LocalPixelCodec.gif(art)
        XCTAssertEqual(try LocalPixelFixtures.decodedPixels(data).rgba, art.frames[0].rgba)
    }
    func testImportedGIFKeepsLongDelayZeroDelayAndRepeatsAndOriginalBytesUntouched() throws {
        let original = LocalPixelFixtures.gif(delays: [0,12000,65535], repeats: 9)
        let retained = original
        let imported = try LocalPixelCodec.decode(original, attribution: LocalPixelFixtures.attribution)
        XCTAssertEqual(imported.frames.map(\.centiseconds), [0,12000,65535])
        XCTAssertEqual(imported.repeats, 9); XCTAssertEqual(imported.attribution, LocalPixelFixtures.attribution)
        XCTAssertEqual(original, retained)
        let export = try LocalPixelCodec.gif(imported)
        XCTAssertEqual(try GIFStructure.inspect(export).frames.map(\.delayCentiseconds), [0,12000,65535])
    }
    func testReservedDisposalStillFailsExplicitlyRatherThanGuessingComposition() {
        XCTAssertThrowsError(try LocalPixelCodec.decode(LocalPixelFixtures.gif(disposal: 7)))
    }
    func testDamagedUnsupportedAndOversizedInputsFailBeforeEditing() {
        for bytes in [Data(), Data("not raster".utf8), Data(repeating: 0, count: 5_000_001),
                      LocalPixelFixtures.gif().dropLast()] {
            XCTAssertThrowsError(try LocalPixelCodec.decode(Data(bytes)))
        }
    }
    func testMaximal120Frame128SquareGIFRemainsBoundedAndStructurallyComplete() throws {
        var art = try LocalPixelFixtures.artwork(128, 128)
        art.frames = (0..<120).map { index in LocalPixelFrame(rgba: art.frames[0].rgba, centiseconds: index + 1) }
        let bytes = try LocalPixelCodec.gif(art)
        XCTAssertLessThanOrEqual(bytes.count, LocalPixelCodec.fileBudget)
        let structure = try GIFStructure.inspect(bytes)
        XCTAssertEqual(structure.frames.count, 120)
        XCTAssertEqual(structure.frames.last?.delayCentiseconds, 120)
    }
    func testPreviewBrightnessAndBlackFloorNeverMutateAuthoredPixelsOrExport() throws {
        let art = try LocalPixelFixtures.artwork()
        let before = try LocalPixelCodec.png(art, frame: 0)
        _ = try LocalPixelPreviewRenderer.render(frame: art.frames[0], width: art.width, height: art.height, brightness: 0.3, blackFloor: 0.1)
        XCTAssertEqual(try LocalPixelCodec.png(art, frame: 0), before)
        XCTAssertThrowsError(try LocalPixelPreviewRenderer.render(frame: art.frames[0], width: art.width, height: art.height, brightness: .infinity, blackFloor: 0))
    }
    func testCancelledWorkerDoesNotReturnACompletedDecode() async throws {
        let worker = Task {
            try await LocalPixelWork.run {
                try Task.checkCancellation()
                return try LocalPixelCodec.decode(LocalPixelFixtures.gif())
            }
        }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled work must not be accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testRealOversizedPNGAndAnimatedPNGAreExplicitlyUnavailableWithoutResizingOrFirstFrameFallback() throws {
        let large = LocalPixelFixtures.png(width: 129), animation = LocalPixelFixtures.png(animated: true)
        XCTAssertEqual(try LocalPixelFixtures.decodedPixels(large).width, 129)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(animation as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertThrowsError(try LocalPixelCodec.decode(large))
        XCTAssertThrowsError(try LocalPixelCodec.decode(animation))
    }
}
