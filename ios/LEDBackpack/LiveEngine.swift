import Foundation
import Combine
import UIKit
import CoreLocation
import CoreMotion
import MediaPlayer
import UserNotifications
import BackpackProtocol

@MainActor
final class DisconnectAlerts: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    func request() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func disconnected(_ name: String) async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw BackpackError.invalid("Disconnect notifications are not authorized. Enable them in iOS Settings.")
        }
        let content = UNMutableNotificationContent()
        content.title = "Backpack disconnected"
        content.body = "\(name) is no longer connected. Live display updates have stopped."
        content.sound = .default
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "backpack-disconnected", content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class LiveSensors: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let motion = CMMotionManager()
    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: Double?
    @Published private(set) var roll = 0.0
    @Published private(set) var acceleration = 0.0
    @Published private(set) var authorization = CLAuthorizationStatus.notDetermined
    @Published private(set) var failure: String?
    var onWake: (() -> Void)?
    var locationRunning = false

    override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func requestAlways() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { manager.requestAlwaysAuthorization() }
    }

    func startLocation(background: Bool, precise: Bool) throws {
        guard CLLocationManager.locationServicesEnabled() else { throw BackpackError.invalid("Location Services are off.") }
        guard ![.denied, .restricted].contains(manager.authorizationStatus) else {
            throw BackpackError.invalid("Location permission denied. Open iOS Settings.")
        }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        failure = nil; locationRunning = true
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
        manager.distanceFilter = precise ? kCLDistanceFilterNone : 1000
        manager.activityType = .automotiveNavigation
        manager.allowsBackgroundLocationUpdates = background && manager.authorizationStatus == .authorizedAlways
        manager.showsBackgroundLocationIndicator = manager.allowsBackgroundLocationUpdates
        manager.pausesLocationUpdatesAutomatically = !precise
        manager.startUpdatingLocation()
    }

    func startHeading() throws {
        guard CLLocationManager.headingAvailable() else { throw BackpackError.invalid("This device has no heading sensor.") }
        failure = nil; heading = nil
        manager.startUpdatingHeading()
    }

    func startMotion() throws {
        guard motion.isDeviceMotionAvailable else { throw BackpackError.invalid("Device motion is unavailable.") }
        failure = nil
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] value, error in
            guard let self else { return }
            if let error { self.failure = error.localizedDescription; return }
            guard let value else { return }
            self.roll = value.attitude.roll * 180 / .pi
            let a = value.userAcceleration
            self.acceleration = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        }
    }

    func stop() {
        manager.stopUpdatingLocation(); manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        motion.stopDeviceMotionUpdates(); locationRunning = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if [.denied, .restricted].contains(authorization) { failure = "Location permission denied." }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let latest = locations.last, latest.horizontalAccuracy >= 0 { location = latest }
        onWake?()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading value: CLHeading) {
        heading = value.headingAccuracy >= 0 ? (value.trueHeading >= 0 ? value.trueHeading : value.magneticHeading) : nil
        onWake?()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let error = error as? CLError, error.code == .locationUnknown { return }
        failure = error.localizedDescription
        onWake?()
    }
}

enum LiveMode: String, CaseIterable, Identifiable {
    case speed = "GPS speed", weather = "Weather", music = "System Music"
    case motion = "Phone motion", clock = "Clock", compass = "Phone heading"
    case battery = "Phone battery", eyes = "Pixel eyes", message = "Scrolling message", loading = "Loading rider"
    var id: String { rawValue }
}

@MainActor
final class LiveEngine: ObservableObject {
    let panel: PanelController
    let sensors: LiveSensors
    @Published private(set) var mode: LiveMode?
    @Published private(set) var preview: UIImage?
    @Published private(set) var status = "Stopped"
    @Published var message = "HELLO FROM MY BACKPACK"
    var preferences = Preferences()
    var themes: [String: LiveTheme] = [:]
    private var task: Task<Void, Never>?
    private var rendering = false
    private var wakeTask: Task<Void, Never>?
    private var backgrounded = false
    private var lastRender = Date.distantPast
    private var weather: WeatherReading?
    private var weatherFetched = Date.distantPast
    private var weatherAttempted = Date.distantPast
    private var weatherFetch: Task<Void, Never>?
    private var weatherLocation: CLLocation?
    private var speedHistory: [(Date, Double)] = []
    private var alertUntil = Date.distantPast
    private var lastBrake = Date.distantPast

    init(panel: PanelController, sensors: LiveSensors) {
        self.panel = panel; self.sensors = sensors
        sensors.onWake = { [weak self] in self?.wake() }
        panel.link.onWake = { [weak self] in self?.wake() }
        panel.link.onLiveError = { [weak self] error in
            self?.panel.report(error); self?.task?.cancel()
        }
    }

    func start(_ selected: LiveMode) async throws {
        guard task == nil, mode == nil else { throw BackpackError.invalid("Stop the current live screen first.") }
        try (themes[selected.rawValue] ?? .standard(for: selected)).validate()
        if selected == .speed || selected == .weather {
            try sensors.startLocation(background: preferences.backgroundLocation, precise: selected == .speed)
        }
        do {
            if selected == .motion { try sensors.startMotion() }
            if selected == .compass { try sensors.startHeading() }
            if selected == .music {
                let granted = await withCheckedContinuation { continuation in
                    MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
                }
                guard granted else { throw BackpackError.invalid("Music library permission denied.") }
            }
            try await panel.beginLive()
        } catch { sensors.stop(); throw error }
        mode = selected; status = "Starting"; lastRender = .distantPast
        speedHistory = []; alertUntil = .distantPast
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let tickStarted = Date()
                if !backgrounded || (selected == .speed && preferences.backgroundLocation
                    && sensors.authorization == .authorizedAlways) {
                    await render()
                }
                let interval = (themes[selected.rawValue] ?? .standard(for: selected)).refreshInterval
                do { try await Task.sleep(for: .seconds(max(0.1, interval - Date().timeIntervalSince(tickStarted)))) }
                catch { break }
            }
            let pendingWeather = weatherFetch
            pendingWeather?.cancel()
            await pendingWeather?.value
            weatherFetch = nil
            wakeTask?.cancel()
            await wakeTask?.value
            sensors.stop()
            do { try await panel.endLive() } catch { panel.report(error) }
            mode = nil; task = nil; status = "Stopped"
        }
    }

    func stop() async {
        task?.cancel()
        await task?.value
    }

    func connectionLost() { task?.cancel() }

    func setBackground(_ value: Bool) {
        backgrounded = value
        if value && mode != nil {
            status = "Background: GPS continues only with permission; other screens refresh on allowed callbacks."
        }
        if !value { wake() }
    }

    private func wake() {
        guard task != nil, mode != nil, wakeTask == nil, Date().timeIntervalSince(lastRender) >= 1, !rendering else { return }
        wakeTask = Task {
            await render()
            wakeTask = nil
        }
    }

    private func render() async {
        guard !Task.isCancelled, let mode, !rendering, let size = panel.size, panel.link.connected else { return }
        rendering = true; lastRender = Date()
        defer { rendering = false }
        do {
            if [.speed, .weather, .motion, .compass].contains(mode), let failure = sensors.failure {
                throw BackpackError.invalid(failure)
            }
            let frame = try content(mode, size: size)
            try await panel.paintLive(frame)
            preview = panel.monitorImage
        } catch {
            panel.report(error); task?.cancel()
        }
    }

    private func content(_ mode: LiveMode, size: PanelSize) throws -> PixelFrame {
        let now = Date()
        switch mode {
        case .speed:
            guard let location = sensors.location, location.horizontalAccuracy <= 50,
                  location.speedAccuracy >= 0, location.speedAccuracy <= 5,
                  let speed = SpeedPolicy.display(metersPerSecond: location.speed,
                    age: now.timeIntervalSince(location.timestamp), mph: preferences.mph,
                    cap: preferences.speedCapEnabled ? preferences.speedCap : nil) else {
                status = "GPS invalid or older than 5 seconds"
                return try themed("NO GPS", subtitle: "INVALID / STALE", size: size, requiredStatus: true)
            }
            speedHistory.append((now, location.speed))
            speedHistory.removeAll { now.timeIntervalSince($0.0) > 2 }
            if preferences.brakeDisplay, let first = speedHistory.first,
               now.timeIntervalSince(first.0) >= 1.2, first.1 > 8 / 2.236936,
               first.1 - location.speed >= 6 / 2.236936, now.timeIntervalSince(lastBrake) > 9 {
                alertUntil = now.addingTimeInterval(2.5); lastBrake = now
            }
            status = preferences.speedCapEnabled ? "GPS speed; display capped at \(preferences.speedCap)" : "GPS speed"
            if alertUntil > now { return try themed("SLOW", subtitle: "EXPERIMENTAL", size: size, requiredStatus: true) }
            return try themed(String(speed), subtitle: preferences.mph ? "MPH" : "KM/H", size: size, gaugeValue: Double(speed))
        case .weather:
            scheduleWeather()
            guard let weather, now.timeIntervalSince(weatherFetched) < 900 else {
                status = "Waiting for valid location/weather"
                return try themed("WEATHER", subtitle: "NO DATA", size: size, requiredStatus: true)
            }
            let degrees = preferences.fahrenheit ? weather.current.temperature_2m * 9 / 5 + 32 : weather.current.temperature_2m
            let age = Int(now.timeIntervalSince(weatherFetched))
            status = "Weather updated \(age)s ago; Open-Meteo"
            let conditions = weather.current.weather_code
            let label = conditions == 0 ? "CLEAR" : conditions < 4 ? "CLOUD" : conditions >= 71 && conditions <= 77 ? "SNOW" : "WEATHER"
            return try themed("\(Int(degrees.rounded()))\(preferences.fahrenheit ? "F" : "C")",
                subtitle: age > 300 ? "STALE" : label, size: size, requiredStatus: age > 300, gaugeValue: degrees)
        case .music:
            guard let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem else {
                status = "No system Music item; other apps are not universally accessible"
                return try themed("NO MUSIC", size: size, requiredStatus: true)
            }
            status = "System Music metadata"
            return try themed(String((item.title ?? "Unknown track").prefix(80)),
                subtitle: String((item.artist ?? "Music").prefix(24)), size: size)
        case .motion:
            status = "PHONE motion, not motorcycle lean; acceleration \(String(format: "%.2f", sensors.acceleration))g"
            return try themed("\(Int(sensors.roll.rounded()))", subtitle: "PHONE ROLL", size: size, gaugeValue: sensors.roll)
        case .clock:
            status = "Phone clock"
            return try themed(now.formatted(date: .omitted, time: .shortened), size: size)
        case .compass:
            status = "Phone heading, not bike heading"
            guard let heading = sensors.heading else { return try themed("NO HEADING", size: size, requiredStatus: true) }
            return try themed("\(Int(heading.rounded()))", subtitle: "PHONE DEG", size: size, gaugeValue: heading)
        case .battery:
            let level = UIDevice.current.batteryLevel
            status = "Phone battery, not backpack battery"
            return try themed(level < 0 ? "?" : "\(Int(level * 100))", subtitle: "PHONE BAT", size: size,
                gaugeValue: level >= 0 ? Double(level * 100) : nil)
        case .message:
            status = "Custom message"
            return try themed(String(message.prefix(80)), size: size)
        case .loading:
            status = "Just for fun"
            let count = Int(now.timeIntervalSince1970) % 4
            return try themed(String(repeating: ".", count: count + 1), subtitle: "LOADING RIDER", size: size)
        case .eyes:
            status = "Pixel eyes"
            let theme = themes[mode.rawValue] ?? .standard(for: mode)
            try theme.validate()
            let blink = Int(now.timeIntervalSince1970 * 3 * theme.animationSpeed) % 17 == 0
            return try MediaCodec.canvas(size) { context in
                let w = CGFloat(size.width), h = CGFloat(size.height)
                context.setFillColor(theme.background.uiColor.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                context.setFillColor(theme.foreground.uiColor.cgColor)
                let eyeHeight: CGFloat = blink ? 2 : h * 0.25
                context.fill(CGRect(x: w * 0.18, y: h * 0.35, width: w * 0.2, height: eyeHeight))
                context.fill(CGRect(x: w * 0.62, y: h * 0.35, width: w * 0.2, height: eyeHeight))
            }
        }
    }

    private func themed(_ text: String, subtitle: String = "", size: PanelSize, requiredStatus: Bool = false, gaugeValue: Double? = nil) throws -> PixelFrame {
        guard let mode else { throw BackpackError.invalid("No active live screen.") }
        var theme = themes[mode.rawValue] ?? .standard(for: mode)
        if requiredStatus { theme.topLabel = "" }
        let phase = Date().timeIntervalSince1970 * theme.animationSpeed / 8
        let field: String?
        if requiredStatus { field = nil }
        else {
            switch theme.secondaryField {
            case .automatic: field = nil
            case .clock: field = Date().formatted(date: .omitted, time: .shortened)
            case .battery:
                let battery = UIDevice.current.batteryLevel
                field = battery >= 0 ? "PHONE \(Int(battery * 100))%" : "PHONE BAT ?"
            }
        }
        return try MediaCodec.styled(text, subtitle: subtitle, size: size, theme: theme,
            phase: phase, field: field, requiredStatus: requiredStatus, gaugeValue: gaugeValue)
    }

    private func scheduleWeather() {
        guard weatherFetch == nil, let location = sensors.location,
              Date().timeIntervalSince(location.timestamp) < 3600,
              location.horizontalAccuracy >= 0,
              Date().timeIntervalSince(weatherAttempted) >= 30 else { return }
        let moved = weatherLocation.map { location.distance(from: $0) >= 5000 } ?? true
        guard Date().timeIntervalSince(weatherFetched) >= 300 || moved else { return }
        weatherAttempted = Date()
        weatherFetch = Task {
            defer { weatherFetch = nil }
            do {
                weather = try await WeatherService.current(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                weatherFetched = Date(); weatherLocation = location
            } catch {
                if !Task.isCancelled { panel.report(error) }
            }
        }
    }
}
