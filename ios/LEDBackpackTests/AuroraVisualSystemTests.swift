import XCTest
import SwiftUI
import UIKit
@testable import LEDBackpack

@MainActor
final class AuroraVisualSystemTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 390, height: 800)
    private let artwork = CGRect(x: 20, y: 120, width: 350, height: 180)

    private func moving(reduceMotion: Bool = false, paused: Bool = false, activeScene: Bool = true,
        activeDestination: Bool = true, appeared: Bool = true, frame: CGRect? = nil,
        viewport: CGRect? = nil) -> Bool {
        AuroraMotionPolicy.allowsAnimation(reduceMotion: reduceMotion, paused: paused,
            activeScene: activeScene, activeDestination: activeDestination, appeared: appeared,
            frame: frame ?? artwork, viewport: viewport ?? self.viewport)
    }

    func testVisibleActiveHeroCanMove() {
        XCTAssertTrue(moving())
        XCTAssertTrue(moving(frame: CGRect(x: 20, y: 790, width: 350, height: 180)))
    }

    func testEveryMotionOffSwitchIndependentlyStopsTheClock() {
        XCTAssertFalse(moving(reduceMotion: true))
        XCTAssertFalse(moving(paused: true))
        XCTAssertFalse(moving(activeScene: false))
        XCTAssertFalse(moving(activeDestination: false))
        XCTAssertFalse(moving(appeared: false))
    }

    func testOffscreenAndUnmeasuredArtworkCannotStartAClock() {
        XCTAssertFalse(moving(frame: .zero))
        XCTAssertFalse(moving(viewport: .zero))
        XCTAssertFalse(moving(frame: CGRect(x: 20, y: 900, width: 350, height: 180)))
        XCTAssertFalse(moving(frame: CGRect(x: 20, y: -200, width: 350, height: 180)))
        XCTAssertFalse(moving(frame: CGRect(x: 500, y: 120, width: 350, height: 180)))
    }

    func testGeometryChangesDoNotAlterDestinationOrPauseOwnership() {
        let expanded = CGRect(x: 0, y: 0, width: 1000, height: 700)
        XCTAssertTrue(moving(viewport: expanded))
        XCTAssertFalse(moving(paused: true, viewport: expanded))
        XCTAssertFalse(moving(activeDestination: false, viewport: expanded))
    }

    func testOpaquePaletteHasReadableTextAndActionPairsInBothAppearances() throws {
        for appearance in [UIUserInterfaceStyle.dark, .light] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for surface in [Aurora.background, Aurora.surface, Aurora.raised, Aurora.mintSurface,
                Aurora.lavenderSurface, Aurora.roseSurface] {
                let background = try components(surface, traits)
                XCTAssertEqual(background.alpha, 1)
                XCTAssertGreaterThanOrEqual(try contrast(Aurora.ink, surface, traits), 4.5)
                XCTAssertGreaterThanOrEqual(try contrast(Aurora.supporting, surface, traits), 4.5)
            }
            XCTAssertGreaterThanOrEqual(try contrast(Aurora.onAction, Aurora.mint, traits), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(Aurora.mint, Aurora.surface, traits), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(Aurora.lavender, Aurora.surface, traits), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast(Aurora.rose, Aurora.surface, traits), 4.5)
        }
    }

    private func components(_ color: Color, _ traits: UITraitCollection) throws
        -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let resolved = UIColor(color).resolvedColor(with: traits)
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return (red, green, blue, alpha)
    }

    private func contrast(_ foreground: Color, _ background: Color, _ traits: UITraitCollection) throws -> Double {
        func luminance(_ color: Color) throws -> Double {
            let value = try components(color, traits)
            func linear(_ channel: CGFloat) -> Double {
                let component = Double(channel)
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return linear(value.red) * 0.2126 + linear(value.green) * 0.7152 + linear(value.blue) * 0.0722
        }
        let first = try luminance(foreground), second = try luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
