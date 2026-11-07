import Foundation
import BackpackProtocol

struct NaturalEyePose: Equatable {
    let x, y, openness, lift: Double
}
enum NaturalEyeRenderer {
    private static let gazes: [(Double, Double, Double)] = [
        (0,0,4.4),(-0.55,0.12,3.3),(0.35,-0.18,5.2),(0.7,0.1,3.9),
        (0,0,6.1),(-0.25,-0.35,4.8),(-0.65,0.15,3.7),(0.2,0.25,5.6),(0,0,4.5)]
    static func pose(at elapsed: Double, speed: Double = 1, reducedMotion: Bool = false) throws -> NaturalEyePose {
        guard elapsed.isFinite, elapsed >= 0, speed.isFinite, (0.25...4).contains(speed) else { throw BackpackError.invalid("Invalid eye animation clock/speed.") }
        if reducedMotion { return .init(x: 0, y: 0, openness: 1, lift: 0) }
        let time = elapsed * speed, total = gazes.reduce(0) { $0 + $1.2 }
        guard time.isFinite else { throw BackpackError.invalid("Eye animation clock overflowed.") }
        var cursor = time.truncatingRemainder(dividingBy: total), index = 0
        for n in gazes.indices {
            if cursor < gazes[n].2 { index = n; break }
            cursor -= gazes[n].2
        }
        let previous = gazes[(index + gazes.count - 1) % gazes.count], target = gazes[index]
        let transition = smooth(min(1, cursor / (0.55 + Double(index % 3) * 0.06)))
        let x = previous.0 + (target.0 - previous.0) * transition + 0.025 * sin(time * 1.6)
        let y = previous.1 + (target.1 - previous.1) * transition + 0.012 * sin(time * 2.3)
        let blinkTime = time.truncatingRemainder(dividingBy: 28.6)
        var open = 1.0
        for (start,duration) in [(2.9,0.48),(6.8,0.51),(11.4,0.44),(11.95,0.38),(17.3,0.54),(23.9,0.46)] {
            let t = blinkTime - start
            if t >= 0 && t < duration {
                let closing = duration * 0.25
                open = t < closing ? 1 - smooth(t / closing) : smooth((t - closing) / (duration - closing))
                break
            }
        }
        return .init(x: x, y: y, openness: open, lift: 0.025 * sin(time * 0.6))
    }
    private static func smooth(_ value: Double) -> Double {
        let t = max(0, min(1, value)); return t * t * (3 - 2 * t)
    }
    static func render(size: PanelSize, foreground: [UInt8], background: [UInt8], accent: [UInt8],
        elapsed: Double, speed: Double = 1, reducedMotion: Bool = false) throws -> PixelFrame {
        guard (8...128).contains(size.width), (8...128).contains(size.height),
              foreground.count == 3, background.count == 3, accent.count == 3 else { throw BackpackError.invalid("Unsupported bounded eye canvas/colors.") }
        let pose = try pose(at: elapsed, speed: speed, reducedMotion: reducedMotion)
        var frame = PixelFrame(size: size, rgb: Array(repeating: background, count: size.width * size.height).flatMap { $0 })
        frame.exactLiveColors = true
        let w = Double(size.width), h = Double(size.height)
        for centerX in [w * 0.27,w * 0.73] {
            let centerY = h * (0.48 + pose.lift), rx = w * 0.17, ry = max(0.75,h * 0.17 * pose.openness)
            let pupilX = centerX + pose.x * rx * 0.42, pupilY = centerY + pose.y * h * 0.06
            let pupilR = max(1,w * 0.055)
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let ex = (px - centerX) / rx, ey = (py - centerY) / ry
                    guard ex * ex + ey * ey <= 1 else { continue }
                    var color = foreground
                    let dx = px - pupilX, dy = py - pupilY
                    if pose.openness > 0.18 && dx * dx + dy * dy <= pupilR * pupilR {
                        color = background
                        if dx < -pupilR * 0.2 && dy < -pupilR * 0.2 { color = accent }
                    }
                    let offset = (y * size.width + x) * 3
                    frame.rgb.replaceSubrange(offset..<(offset + 3), with: color)
                }
            }
        }
        return frame
    }
}
