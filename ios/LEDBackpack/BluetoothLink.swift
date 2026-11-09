import Foundation
import Combine
import CoreBluetooth
import BackpackProtocol

struct NearbyPanel: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

@MainActor
final class BluetoothLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var state = "Bluetooth idle — scan explicitly for a backpack"
    @Published private(set) var nearby: [NearbyPanel] = []
    @Published private(set) var connected = false
    @Published private(set) var scanning = false
    @Published private(set) var connectionRevision = UUID()
    @Published private(set) var log: [String] = []
    @Published var showAll = false
    var autoReconnect = true
    var onReady: (() async -> Void)?
    var onDisconnect: (() async -> Void)?
    var onLiveError: ((Error) -> Void)?
    var onEstablishedDrop: ((String) async -> Void)?
    var onWake: (() -> Void)?
    var onPlayback: ((Playback) -> Void)?
    var systemDisconnectAlerts = true
    var selectedID: UUID? { peripheral?.identifier }
    private lazy var central = CBCentralManager(delegate: self, queue: .main, options: [
        CBCentralManagerOptionRestoreIdentifierKey: "LEDBackpack.central"
    ])
    private var peripheral: CBPeripheral?
    private var found: [UUID: CBPeripheral] = [:]
    private var writer: CBCharacteristic?
    private var notifier: CBCharacteristic?
    private var available: [CBUUID: [CBUUID: CBCharacteristic]] = [:]
    private var serviceDiscoveries = 0
    private var assembler = FrameAssembler()
    private var sequence: UInt16 = 0
    private var manualDisconnect = false
    private var retry = 0
    private var connectionDeadline: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var scanDeadline: Task<Void, Never>?
    private var scanIntent = BluetoothScanIntent()
    private var scanForeground = false
    private var scanStarted = false
    private var responseDeadline: Task<Void, Never>?
    private var writeDeadline: Task<Void, Never>?
    private var recentLive: [UInt16] = []
    private var liveFailure: Error?

    private struct ResponseWaiter {
        let sequence: UInt16
        let matches: (Reply) -> Bool
        let continuation: AsyncThrowingStream<Reply, Error>.Continuation
    }
    private var response: ResponseWaiter?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var chunks: [Data] = []
    private var chunkIndex = 0
    private var awaitingWriteResponse = false
    private var writeType = CBCharacteristicWriteType.withoutResponse

    override init() {
        super.init()
    }

    func note(_ text: String) {
        log.append("\(Date().ISO8601Format()) \(text)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func scan() throws {
        guard scanForeground else { throw BackpackError.invalid("Open the app before scanning.") }
        guard peripheral == nil else { throw BackpackError.invalid("Disconnect before scanning for another panel.") }
        stopScan()
        try scanIntent.request(now: ProcessInfo.processInfo.systemUptime)
        scanning = true
        let manager = central
        switch manager.state {
        case .unknown, .resetting:
            state = "Preparing Bluetooth"
            scanDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) }
                catch is CancellationError { return }
                catch { self?.scanFailed(error); return }
                guard !Task.isCancelled else { return }
                self?.stopScan("Bluetooth preparation expired. Choose Scan again.")
            }
        case .poweredOn:
            try startPendingScan(manager)
        default:
            let error = BackpackError.invalid("Enable Bluetooth and allow access in Settings, then choose Scan.")
            scanFailed(error)
            throw error
        }
    }

    func setScanActivity(active: Bool, backgrounded: Bool) {
        scanForeground = active
        if backgrounded || !active && scanStarted { stopScan("Scan stopped"); return }
        guard active, scanIntent.pending else { return }
        do {
            if central.state == .poweredOn { try startPendingScan(central) }
        } catch { scanFailed(error) }
    }

    func stopScan(_ reason: String? = nil) {
        let wasScanning = scanning
        scanIntent.cancel(); scanDeadline?.cancel(); scanDeadline = nil
        if scanStarted { central.stopScan() }
        scanStarted = false; scanning = false
        if wasScanning { state = reason ?? "Scan stopped" }
    }

    private func scanFailed(_ error: Error) {
        stopScan(error.localizedDescription)
        state = error.localizedDescription
        note("Scan failed: \(error.localizedDescription)")
    }

    private func startPendingScan(_ manager: CBCentralManager) throws {
        guard peripheral == nil else {
            throw BackpackError.invalid("A connection started before Bluetooth scanning was ready.")
        }
        guard try scanIntent.consume(now: ProcessInfo.processInfo.systemUptime, foreground: scanForeground) else { return }
        scanDeadline?.cancel()
        nearby = []; found = [:]
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanStarted = true; scanning = true
        state = "Scanning"
        scanDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) }
            catch is CancellationError { return }
            catch { self?.scanFailed(error); return }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            stopScan("Scan finished")
            note("Scan finished: \(nearby.count) matching device(s).")
        }
    }

    func connect(_ id: UUID) throws {
        guard peripheral == nil else { throw BackpackError.invalid("A connection is already active or in progress. Disconnect first.") }
        guard let candidate = found[id] else { throw BackpackError.invalid("Scan again; the selected device is no longer available.") }
        manualDisconnect = false; retry = 0
        beginConnection(candidate)
    }

    private func beginConnection(_ candidate: CBPeripheral) {
        stopScan(); reconnectTask?.cancel()
        peripheral = candidate; candidate.delegate = self
        state = "Connecting to \(candidate.name ?? "panel")"
        central.connect(candidate, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: systemDisconnectAlerts
        ])
        connectionDeadline?.cancel()
        connectionDeadline = Task {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, !connected else { return }
            note("Connection or discovery timed out.")
            state = "Connection timed out"
            central.cancelPeripheralConnection(candidate)
        }
    }

    func disconnect() {
        stopScan()
        manualDisconnect = true
        reconnectTask?.cancel()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        reset(BackpackError.invalid("Disconnected by user."))
        state = "Disconnected"
    }

    private func reset(_ error: Error) {
        connectionRevision = UUID()
        connected = false; writer = nil; notifier = nil; available = [:]
        connectionDeadline?.cancel()
        assembler.reset()
        response?.continuation.finish(throwing: error); response = nil
        responseDeadline?.cancel()
        finishWrite(error)
        liveFailure = error
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanIntent.pending {
                do { try startPendingScan(central) }
                catch { scanFailed(error) }
            } else if !scanning, peripheral == nil { state = "Ready to scan" }
        case .poweredOff: state = "Bluetooth is off"
        case .unauthorized: state = "Bluetooth permission denied"
        case .unsupported: state = "Bluetooth LE is unavailable"
        case .resetting: state = "Bluetooth resetting"
        default: state = "Bluetooth unavailable"
        }
        if central.state != .poweredOn {
            if ![CBManagerState.unknown, .resetting].contains(central.state) || scanStarted {
                stopScan(state)
            }
            let notify = connected && !manualDisconnect
            let name = peripheral?.name ?? "LED backpack"
            reset(BackpackError.invalid(state))
            reconnectTask?.cancel(); peripheral = nil
            if notify { Task { await onEstablishedDrop?(name) } }
            Task { await onDisconnect?() }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover candidate: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? candidate.name ?? "Unnamed"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let matches = name.range(of: "^(YS|TL|LO|EL|TT)[0-9]{2,}", options: [.regularExpression, .caseInsensitive]) != nil
            || services.contains { service in Wire.gatt.contains { service == CBUUID(string: $0.service) } }
        guard showAll || matches else { return }
        found[candidate.identifier] = candidate
        nearby.removeAll { $0.id == candidate.identifier }
        nearby.append(NearbyPanel(id: candidate.identifier, name: name, rssi: RSSI.intValue))
        nearby.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("Connected; discovering services.")
        state = "Discovering services"
        available = [:]; serviceDiscoveries = 0
        peripheral.discoverServices(Wire.gatt.map { CBUUID(string: $0.service) })
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect candidate: CBPeripheral, error: Error?) {
        handleDrop(candidate, error: error ?? BackpackError.invalid("Connection attempt failed."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral candidate: CBPeripheral, error: Error?) {
        handleDrop(candidate, error: error ?? BackpackError.invalid("Panel disconnected."))
    }

    private func handleDrop(_ candidate: CBPeripheral, error: Error) {
        guard peripheral?.identifier == candidate.identifier else { return }
        let notify = connected && !manualDisconnect
        reset(error); note(error.localizedDescription); state = "Disconnected"
        if notify { Task { await onEstablishedDrop?(candidate.name ?? "LED backpack") } }
        Task { await onDisconnect?() }
        guard autoReconnect, !manualDisconnect, central.state == .poweredOn, retry < 5 else {
            peripheral = nil; return
        }
        retry += 1
        let wait = min(16, 1 << (retry - 1))
        state = "Reconnect \(retry)/5 in \(wait)s"
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, !manualDisconnect else { return }
            beginConnection(candidate)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored; restored.delegate = self
        note("Restored Bluetooth connection; live display is not automatically resumed.")
        if restored.state == .connected {
            restored.discoverServices(Wire.gatt.map { CBUUID(string: $0.service) })
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { discoveryFailed(error); return }
        let services = peripheral.services ?? []
        guard !services.isEmpty else { discoveryFailed(BackpackError.invalid("No supported LED backpack service found.")); return }
        serviceDiscoveries = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { discoveryFailed(error); return }
        for characteristic in service.characteristics ?? [] {
            available[service.uuid, default: [:]][characteristic.uuid] = characteristic
        }
        serviceDiscoveries -= 1
        guard serviceDiscoveries == 0 else { return }
        for pair in Wire.gatt {
            if let write = available[CBUUID(string: pair.service)]?[CBUUID(string: pair.write)],
               let notify = available[CBUUID(string: pair.service)]?[CBUUID(string: pair.notify)],
               (write.properties.contains(.writeWithoutResponse) || write.properties.contains(.write)),
               (notify.properties.contains(.notify) || notify.properties.contains(.indicate)) {
                writer = write; notifier = notify
                writeType = write.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.setNotifyValue(true, for: notify)
                return
            }
        }
        discoveryFailed(BackpackError.invalid("Supported write/notify characteristic pair is missing."))
    }

    private func discoveryFailed(_ error: Error) {
        note(error.localizedDescription); state = error.localizedDescription
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { discoveryFailed(error); return }
        guard characteristic === notifier, characteristic.isNotifying else {
            discoveryFailed(BackpackError.invalid("Notifications could not be enabled.")); return
        }
        connected = true; retry = 0; sequence = 0; recentLive = []; liveFailure = nil
        connectionDeadline?.cancel()
        state = "Connected"
        note("Notifications enabled; maximum write \(peripheral.maximumWriteValueLength(for: writeType)) bytes.")
        Task { await onReady?() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            note(error.localizedDescription)
            response?.continuation.finish(throwing: error)
            onLiveError?(error); return
        }
        guard characteristic === notifier, let data = characteristic.value else { return }
        let assembled = assembler.push(Array(data))
        for message in assembled.errors { note("RX error: \(message)") }
        for frame in assembled.frames {
            do {
                let reply = try Wire.reply(frame.body)
                if case .playback(let value) = reply { onPlayback?(value) }
                if case .identity = reply {
                    note("RX seq \(frame.sequence) [device identity redacted]")
                } else {
                    note("RX seq \(frame.sequence) \(String(describing: reply))")
                }
                if case .status(let code) = reply, code != 0 {
                    let error = BackpackError.invalid(code == 14 ? "Panel locked: supply its existing password." : "Panel rejected command: status \(code).")
                    if recentLive.contains(frame.sequence) { liveFailure = error; onLiveError?(error) }
                    if response?.sequence == frame.sequence { response?.continuation.finish(throwing: error) }
                } else if let response {
                    if case .status = reply {
                        if frame.sequence == response.sequence && response.matches(reply) {
                            response.continuation.yield(reply); response.continuation.finish()
                        }
                        onWake?()
                    } else if response.matches(reply) {
                        response.continuation.yield(reply); response.continuation.finish()
                    }
                }
            } catch {
                note("RX parse error: \(error.localizedDescription)")
                response?.continuation.finish(throwing: error)
            }
        }
    }

    func request(_ body: [UInt8], sensitive: Bool = false, matches: @escaping (Reply) -> Bool) async throws -> Reply {
        guard connected, response == nil else { throw BackpackError.invalid("Connect first and wait for the current request.") }
        let serial = sequence; sequence &+= 1
        let stream = AsyncThrowingStream<Reply, Error> { continuation in
            response = ResponseWaiter(sequence: serial, matches: matches, continuation: continuation)
        }
        responseDeadline = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, response?.sequence == serial else { return }
            response?.continuation.finish(throwing: BackpackError.invalid("Panel response timed out. Delivery is not confirmed."))
        }
        defer { responseDeadline?.cancel(); response = nil }
        note("TX seq \(serial) \(sensitive ? "[password request redacted]" : body.map { String(format: "%02X", $0) }.joined())")
        try await write(try Wire.frame(body, sequence: serial))
        for try await reply in stream { return reply }
        throw BackpackError.invalid("Connection closed before the response.")
    }

    func acknowledged(_ body: [UInt8], sensitive: Bool = false) async throws {
        _ = try await request(body, sensitive: sensitive) { if case .status(0) = $0 { return true }; return false }
    }

    func live(_ body: [UInt8]) async throws {
        guard connected, response == nil else { throw BackpackError.invalid("Live write interrupted by connection/request state.") }
        if let liveFailure { throw liveFailure }
        let serial = sequence; sequence &+= 1
        recentLive.append(serial)
        if recentLive.count > 256 { recentLive.removeFirst(recentLive.count - 256) }
        try await write(try Wire.frame(body, sequence: serial))
        if let liveFailure { throw liveFailure }
    }

    func resetLiveErrors() { liveFailure = nil; recentLive = [] }

    private func write(_ bytes: [UInt8]) async throws {
        guard connected, let peripheral, writer != nil, writeContinuation == nil else {
            throw BackpackError.invalid("BLE writer is unavailable or busy.")
        }
        let capacity = min(512, peripheral.maximumWriteValueLength(for: writeType))
        guard capacity > 0 else { throw BackpackError.invalid("Invalid Bluetooth write limit.") }
        chunks = stride(from: 0, to: bytes.count, by: capacity).map {
            Data(bytes[$0..<min(bytes.count, $0 + capacity)])
        }
        chunkIndex = 0; awaitingWriteResponse = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeContinuation = continuation
            writeDeadline = Task {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                finishWrite(BackpackError.invalid("Bluetooth write timed out."))
            }
            pump()
        }
    }

    private func pump() {
        guard let peripheral, let writer, writeContinuation != nil, !awaitingWriteResponse else { return }
        while chunkIndex < chunks.count {
            if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            let chunk = chunks[chunkIndex]; chunkIndex += 1
            if writeType == .withResponse { awaitingWriteResponse = true }
            peripheral.writeValue(chunk, for: writer, type: writeType)
            if writeType == .withResponse { return }
        }
        finishWrite(nil)
    }

    private func finishWrite(_ error: Error?) {
        writeDeadline?.cancel()
        let continuation = writeContinuation
        writeContinuation = nil; chunks = []; awaitingWriteResponse = false
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { pump() }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === writer else { return }
        if let error { finishWrite(error); return }
        awaitingWriteResponse = false; pump()
    }
}
