import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class AlphabetAuditTests: XCTestCase {
    private let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    private let reference: [String] = [
        "0E11111F111111", "1E11111E11111E", "0E11101010110E", "1E11111111111E",
        "1F10101E10101F", "1F10101E101010", "0E11101711110F", "1111111F111111",
        "0E04040404040E", "0702020212120C", "11121418141211", "1010101010101F",
        "111B1515111111", "11191513111111", "0E11111111110E", "1E11111E101010",
        "0E11111115120D", "1E11111E141211", "0F10100E01011E", "1F040404040404",
        "1111111111110E", "11111111110A04", "1111111515150A", "11110A040A1111",
        "11110A04040404", "1F01020408101F",
        "00000E010F110F", "1010161911111E", "00000E1110110E", "01010D1311110F",
        "00000E111F100E", "0609081C080808", "000E11110F010E", "10101619111111",
        "04000C0404040E", "0200060202120C", "10101214181412", "0C04040404040E",
        "00001A15151515", "00001619111111", "00000E1111110E", "001E11111E1010",
        "000F11110F0101", "00001619101010", "00000F100E011E", "08081C08080906",
        "0000111111130D", "00001111110A04", "0000111115150A", "0000110A040A11",
        "001111110F010E", "00001F0204081F",
        "0E11131519110E", "040C040404040E", "0E11010204081F", "1E01010E01011E",
        "02060A121F0202", "1F10101E01011E", "0E10101E11110E", "1F010204080808",
        "0E11110E11110E", "0E11110F01010E"
    ]

    func testEveryLetterAndDigitMatchesItsIndependentUprightReference() throws {
        XCTAssertEqual(reference.count, letters.count)
        var distinct = Set<String>()
        for (index, letter) in letters.enumerated() {
            let rows = try TextArtwork.glyphRows(letter)
            let encoded = rows.map { String(format: "%02X", $0) }.joined()
            XCTAssertEqual(encoded, reference[index], "Wrong glyph shape or row order for \(letter)")
            XCTAssertTrue(distinct.insert(encoded).inserted, "Indistinguishable letter or digit: \(letter)")
        }
    }

    func testAllPrintableCharactersAtEveryScaleOnEveryPanelPreserveExactPixels() throws {
        XCTAssertEqual(TextArtwork.supportedCharacters.count, 95)
        for size in MediaCodec.renderSizes {
            for scale in 1...TextArtwork.maximumPixelScale(size) {
                for character in TextArtwork.supportedCharacters {
                    let rows = try TextArtwork.glyphRows(character)
                    XCTAssertEqual(rows.count, 7, "\(character)")
                    XCTAssertTrue(rows.allSatisfy { $0 < 32 }, "\(character)")
                    if character == " " { XCTAssertTrue(rows.allSatisfy { $0 == 0 }); continue }
                    let frame = try TextArtwork.render(String(character), size: size, font: .pixel,
                        alignment: .center, color: .white, pixelScale: scale)
                    let x0 = (size.width - 5 * scale) / 2, y0 = (size.height - 7 * scale) / 2
                    var lit = 0
                    for y in 0..<size.height {
                        for x in 0..<size.width {
                            let inside = x >= x0 && x < x0 + 5 * scale && y >= y0 && y < y0 + 7 * scale
                            let expected: UInt8
                            if inside {
                                let row = (y - y0) / scale, column = (x - x0) / scale
                                expected = rows[row] & (1 << (4 - column)) != 0 ? 255 : 0
                            } else { expected = 0 }
                            let offset = (y * size.width + x) * 3
                            if frame.rgb[offset] != expected || frame.rgb[offset + 1] != expected || frame.rgb[offset + 2] != expected {
                                XCTFail("Glyph \(character) at \(5 * scale)x\(7 * scale) on \(size.width)x\(size.height), pixel \(x),\(y)")
                                return
                            }
                            if expected != 0 { lit += 1 }
                        }
                    }
                    XCTAssertGreaterThan(lit, 0, "Blank glyph \(character)")
                    let population = rows.reduce(0) { $0 + $1.nonzeroBitCount }
                    XCTAssertEqual(lit, population * scale * scale, "Missing or clipped LEDs for \(character)")
                }
            }
        }
    }

    func testActualLineCapacitiesAndWholeWordFitting() throws {
        let size = PanelSize(width: 64, height: 64)
        XCTAssertEqual((1...8).map { TextArtwork.lineCapacity(width: 60, scale: $0) }, [10, 5, 3, 2, 2, 1, 1, 1])
        let word = try TextArtwork.pixelLayout("HELLO", size: size)
        XCTAssertEqual(word.lines, ["HELLO"])
        XCTAssertEqual(word.scale, 2)
        XCTAssertThrowsError(try TextArtwork.pixelLayout("HELLO", size: size, scale: 3))
        let fixed = try TextArtwork.pixelLayout("HI", size: size, scale: 2)
        XCTAssertEqual(fixed.scale, 2)
        XCTAssertEqual(fixed.lines, ["HI"])
        XCTAssertThrowsError(try TextArtwork.pixelLayout("F", size: PanelSize(width: 16, height: 16), scale: 3))
    }

    func testEveryGlyphSurvivesActualGIFEncoding() throws {
        let size = PanelSize(width: 64, height: 64)
        let characters = TextArtwork.supportedCharacters.filter { $0 != " " }
        let frames = try characters.map {
            try TextArtwork.render(String($0), size: size, font: .pixel, alignment: .center, color: .white, pixelScale: 2)
        }
        let gif = try MediaCodec.encode(frames, delays: Array(repeating: 0.1, count: frames.count))
        let decoded = try MediaCodec.decode(gif)
        XCTAssertEqual(decoded.images.count, characters.count)
        for (index, image) in decoded.images.enumerated() {
            let frame = try MediaCodec.transform(image, size: size, fit: .fit, turns: 0, brightness: 1)
            XCTAssertEqual(frame.rgb, frames[index].rgb, "GIF altered glyph \(characters[index])")
        }
    }

    func testLivePixelFontUsesTheSameGlyphsAndNeverCropsAnOversizeLabel() throws {
        let size = PanelSize(width: 64, height: 64)
        var theme = LiveTheme.standard(for: .message)
        theme.typeface = .pixel; theme.animation = .still; theme.showSecondary = false
        theme.foreground = .white
        for character in letters {
            let live = try MediaCodec.styled(String(character), subtitle: "", size: size, theme: theme, phase: 0)
            let artwork = try TextArtwork.render(String(character), size: size, font: .pixel,
                alignment: .center, color: .white, pixelScale: 4)
            XCTAssertEqual(live.rgb, artwork.rgb, "Live text glyph differs: \(character)")
        }
        theme.showSecondary = true
        XCTAssertNoThrow(try MediaCodec.styled("NO GPS", subtitle: "INVALID / STALE", size: size,
            theme: theme, phase: 0, requiredStatus: true))
        XCTAssertThrowsError(try MediaCodec.styled("TOO MANY CHARACTERS FOR A LINE", subtitle: "", size: size,
            theme: theme, phase: 0))
    }

    func testFontProofSheetsAreAttachedForVisualReview() throws {
        let groups = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", "0123456789!?.:,;+-=/\\()[]{}<>#$%&*@_|~^`'\""]
        for scale in [1, 2, 3] {
            for (groupIndex, group) in groups.enumerated() {
                let columns = 10, cellWidth = 6 * scale + 4, cellHeight = 8 * scale + 4
                let height = ((group.count + columns - 1) / columns) * cellHeight
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1; format.opaque = true
                let glyphs = try group.map { try TextArtwork.glyphRows($0) }
                let image = UIGraphicsImageRenderer(size: CGSize(width: cellWidth * columns, height: height), format: format).image { result in
                    UIColor.black.setFill(); result.fill(CGRect(x: 0, y: 0, width: cellWidth * columns, height: height))
                    for index in glyphs.indices {
                        let rect = CGRect(x: (index % columns) * cellWidth + 2, y: (index / columns) * cellHeight + 2,
                            width: 5 * scale, height: 7 * scale)
                        let rows = glyphs[index]
                        result.cgContext.setFillColor(UIColor.white.cgColor)
                        for row in 0..<7 {
                            for column in 0..<5 where rows[row] & (1 << (4 - column)) != 0 {
                                result.fill(CGRect(x: rect.minX + CGFloat(column * scale), y: rect.minY + CGFloat(row * scale),
                                    width: scale, height: scale))
                            }
                        }
                    }
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "LED font group \(groupIndex + 1), \(5 * scale)x\(7 * scale) LEDs"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
