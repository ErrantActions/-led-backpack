import Foundation
import BackpackProtocol

enum SoloSolarResult: Equatable {
    case events(sunrise: Date, sunset: Date)
    case polarDay, polarNight, unavailable
}
enum SoloSolar {
    // Approximate solar transit, standard 0.833° refraction; not weather or a navigation prediction.
    static func calculate(day: Date, point: SoloPoint, timeZoneID: String) -> SoloSolarResult {
        guard (try? point.validate()) != nil, let zone = TimeZone(identifier: timeZoneID),
              day.timeIntervalSince1970.isFinite else { return .unavailable }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, (1900...2100).contains(year),
              let localNoon = calendar.date(from: DateComponents(year: year, month: parts.month, day: parts.day, hour: 12)) else { return .unavailable }
        let radians = Double.pi / 180
        func sinD(_ x: Double) -> Double { sin(x * radians) }
        func cosD(_ x: Double) -> Double { cos(x * radians) }
        let julian = localNoon.timeIntervalSince1970 / 86400 + 2440587.5
        let n = (julian - 2451545.0009 + point.longitude / 360).rounded()
        let transit = 2451545.0009 - point.longitude / 360 + n
        let mean = (357.5291 + 0.98560028 * (transit - 2451545)).truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sinD(mean) + 0.0200 * sinD(2 * mean) + 0.0003 * sinD(3 * mean)
        let longitude = mean + center + 180 + 102.9372
        let noon = transit + 0.0053 * sinD(mean) - 0.0069 * sinD(2 * longitude)
        let declination = asin(sinD(longitude) * sinD(23.44))
        let denominator = cosD(point.latitude) * cos(declination)
        let numerator = sinD(-0.833) - sinD(point.latitude) * sin(declination)
        guard abs(denominator) > 1e-12 else { return numerator < 0 ? .polarDay : .polarNight }
        let angle = numerator / denominator
        if angle > 1 { return .polarNight }
        if angle < -1 { return .polarDay }
        let fraction = acos(angle) / (2 * Double.pi)
        func date(_ j: Double) -> Date { Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }
        let rise = date(noon - fraction), set = date(noon + fraction)
        guard calendar.isDate(rise, inSameDayAs: day), calendar.isDate(set, inSameDayAs: day) else {
            // Explicit zone/longitude can disagree; never silently choose another date or zone.
            return .unavailable
        }
        return .events(sunrise: rise, sunset: set)
    }
}
