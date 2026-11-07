import XCTest
import BackpackProtocol
@testable import LEDBackpack

final class NaturalEyesTests: XCTestCase {
    func testGazeChangesBetweenFixationsWithoutMechanicalContinuousSweep() throws {
        let a = try NaturalEyeRenderer.pose(at: 1), b = try NaturalEyeRenderer.pose(at: 5)
        XCTAssertNotEqual(a.x, b.x)
        XCTAssertLessThan(abs(try NaturalEyeRenderer.pose(at: 1.1).x - a.x), 0.05)
    }
    func testGlanceTransitionsAreSmoothAndRemainWithinBounds() throws {
        var previous = try NaturalEyeRenderer.pose(at: 4.39)
        for n in 0..<50 {
            let pose = try NaturalEyeRenderer.pose(at: 4.4 + Double(n) * 0.01)
            XCTAssertLessThan(abs(pose.x - previous.x), 0.1)
            XCTAssertTrue((-1...1).contains(pose.x)); XCTAssertTrue((-1...1).contains(pose.y))
            previous = pose
        }
    }
    func testBlinkHasFastClosureSlowerReopeningAndReturnsOpen() throws {
        XCTAssertGreaterThan(try NaturalEyeRenderer.pose(at: 2.9).openness, 0.99)
        XCTAssertLessThan(try NaturalEyeRenderer.pose(at: 3.02).openness, 0.01)
        XCTAssertGreaterThan(try NaturalEyeRenderer.pose(at: 3.38).openness, 0.99)
    }
    func testReduceMotionProducesStableOpenEyesNoGazeOrBlink() throws {
        XCTAssertEqual(try NaturalEyeRenderer.pose(at: 1, reducedMotion: true), try NaturalEyeRenderer.pose(at: 3.02, reducedMotion: true))
    }
    func testRendererHasExactBoundedPixelsAndMovingPupils() throws {
        let size = PanelSize(width: 64, height: 64)
        let a = try NaturalEyeRenderer.render(size: size, foreground: [255,255,255], background: [0,0,0], accent: [0,255,255], elapsed: 1)
        let b = try NaturalEyeRenderer.render(size: size, foreground: [255,255,255], background: [0,0,0], accent: [0,255,255], elapsed: 5)
        XCTAssertEqual(a.rgb.count, 64 * 64 * 3); XCTAssertTrue(a.exactLiveColors); XCTAssertNotEqual(a.rgb,b.rgb)
    }
    func testInvalidClockAndOversizeCanvasRejectRatherThanBlackFallback() {
        XCTAssertThrowsError(try NaturalEyeRenderer.pose(at: .nan))
        XCTAssertThrowsError(try NaturalEyeRenderer.pose(at: Double.greatestFiniteMagnitude, speed: 4))
        XCTAssertThrowsError(try NaturalEyeRenderer.render(size: .init(width: 4096, height: 4096), foreground: [255,255,255],
            background: [0,0,0], accent: [255,0,0], elapsed: 1))
    }
}
