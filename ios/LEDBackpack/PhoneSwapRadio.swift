import CoreBluetooth
import Combine
import BackpackProtocol

// Separate purpose/service from friend discovery and all backpack characteristics.
@MainActor
final class PhoneSwapRadio: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    enum Purpose: Equatable { case game, acceptedFriend, localPair }
    static let service = CBUUID(string: "E28D4000-5B96-4B65-AD2E-E2156EA61621")
    static let tokenID = CBUUID(string: "E28D4001-5B96-4B65-AD2E-E2156EA61621")
    static let inboxID = CBUUID(string: "E28D4002-5B96-4B65-AD2E-E2156EA61621")
    static let outboxID = CBUUID(string: "E28D4003-5B96-4B65-AD2E-E2156EA61621")
    private let purpose: Purpose
    private var purposeLabel: String {
        switch purpose { case .game: return "Game"; case .acceptedFriend: return "Accepted-friend"; case .localPair: return "Local-pair" }
    }
    private var serviceID: CBUUID { identifier(0) }
    private var hintID: CBUUID { identifier(1) }
    private var inputID: CBUUID { identifier(2) }
    private var outputID: CBUUID { identifier(3) }
    private func identifier(_ offset: Int) -> CBUUID {
        switch purpose {
        case .game: return [Self.service,Self.tokenID,Self.inboxID,Self.outboxID][offset]
        case .acceptedFriend: return CBUUID(string: "A7C2500\(offset)-9055-4916-B4FE-CE72ED134B06")
        case .localPair: return CBUUID(string: "A7C2600\(offset)-9055-4916-B4FE-CE72ED134B06")
        }
    }
    init(purpose: Purpose = .game) {
        self.purpose = purpose; super.init()
        status = purposeLabel + " radio off"
    }
    @Published private(set) var ready = false
    @Published private(set) var status = "Game radio off"
    private(set) var active = false
    var observed: ((UUID, String) -> Void)?
    var received: ((UUID, PhoneSwapWire.Outer) -> Void)?
    var lost: ((UUID) -> Void)?
    var failed: ((String) -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var ownService: CBMutableService?
    private var outbox: CBMutableCharacteristic?
    private var ownToken: Data?
    private var end: Date?
    private var lease: Task<Void, Never>?
    private final class Channel {
        let id = UUID()
        var peer: CBPeripheral?
        var subscriber: CBCentral?
        var writer, notifier: CBCharacteristic?
        var token: String?
        var parser = PhoneSwapFrameDecoder()
        var fragments: [Data] = []
        var pending: CheckedContinuation<Void, Error>?
        var writing = false
        var timeout: Task<Void, Never>?
        var sendTimeout: Task<Void, Never>?
    }
    private var channels: [UUID: Channel] = [:]
    private var seen: [ObjectIdentifier: TimeInterval] = [:]
    func prepare() throws {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String, !text.isEmpty else { throw BackpackError.invalid("Bluetooth usage description unavailable; game radio cannot initialize.") }
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        peripheral = CBPeripheralManager(delegate: self, queue: .main, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        status = "OS peer-radio preparation only — separately arm the chosen purpose after readiness"
    }
    func start(token: String, seconds: TimeInterval) throws {
        stop()
        guard ready, let central, let peripheral, NearbyTokenPolicy.valid(token), seconds > 0 else { throw BackpackError.invalid("Game radio not ready or token expired.") }
        active = true; ownToken = Data(token.utf8); end = Date().addingTimeInterval(min(120, seconds))
        let service = CBMutableService(type: serviceID, primary: true)
        let value = CBMutableCharacteristic(type: hintID, properties: .read, value: nil, permissions: .readable)
        let input = CBMutableCharacteristic(type: inputID, properties: .write, value: nil, permissions: .writeable)
        let output = CBMutableCharacteristic(type: outputID, properties: .notify, value: nil, permissions: .readable)
        service.characteristics = [value,input,output]; ownService = service; outbox = output
        peripheral.add(service)
        central.scanForPeripherals(withServices: [serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        status = purposeLabel + " foreground radio active — no proximity guarantee"
        lease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(min(120, seconds))) } catch { return }
            self?.stop(); self?.failed?("Game token expired; no automatic renewal")
        }
    }
    func stop() {
        active = false; lease?.cancel(); lease = nil
        central?.stopScan(); peripheral?.stopAdvertising(); peripheral?.removeAllServices()
        ownToken = nil; end = nil; ownService = nil; outbox = nil
        for id in Array(channels.keys) { close(id, notify: false) }
        seen = [:]; status = purposeLabel + " radio off"
    }
    func close(_ id: UUID, notify: Bool = false) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        channel.timeout?.cancel(); channel.sendTimeout?.cancel()
        channel.pending?.resume(throwing: BackpackError.invalid("Game channel stopped/disconnected; no application acknowledgment implied."))
        channel.pending = nil
        if let peer = channel.peer { peer.delegate = nil; central?.cancelPeripheralConnection(peer) }
        if notify { lost?(id) }
    }
    func send(_ message: PhoneSwapWire.Outer, to id: UUID) async throws {
        guard active, let channel = channels[id], channel.pending == nil, !channel.writing else { throw BackpackError.invalid("Game channel unavailable or backpressure violated.") }
        let bytes = try PhoneSwapWire.packet(message)
        let maximum = channel.peer?.maximumWriteValueLength(for: .withResponse) ?? channel.subscriber?.maximumUpdateValueLength ?? 20
        let chunk = max(1, min(160, maximum))
        channel.fragments = stride(from: 0, to: bytes.count, by: chunk).map { Data(bytes[$0..<min(bytes.count, $0 + chunk)]) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                channel.pending = continuation
                channel.sendTimeout?.cancel()
                channel.sendTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.close(id, notify: true)
                }
                pump(channel)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close(id, notify: true) } }
    }
    private func pump(_ channel: Channel) {
        guard active, channel.pending != nil, !channel.writing else { return }
        if channel.fragments.isEmpty {
            channel.sendTimeout?.cancel(); channel.sendTimeout = nil
            let continuation = channel.pending; channel.pending = nil; continuation?.resume()
            return
        }
        if let peer = channel.peer, let writer = channel.writer {
            channel.writing = true; peer.writeValue(channel.fragments.removeFirst(), for: writer, type: .withResponse)
        } else if let subscriber = channel.subscriber, let outbox, let peripheral {
            while let first = channel.fragments.first {
                guard peripheral.updateValue(first, for: outbox, onSubscribedCentrals: [subscriber]) else { return }
                channel.fragments.removeFirst()
            }
            pump(channel)
        }
    }
    private func ingest(_ bytes: Data, _ channel: Channel) throws {
        guard active, end.map({ Date() < $0 }) == true else { throw BackpackError.invalid("Game radio lease expired.") }
        for message in try channel.parser.push(bytes) { received?(channel.id, message) }
    }
    private func stateChanged() {
        ready = central?.state == .poweredOn && peripheral?.state == .poweredOn
        if !ready {
            let running = active; stop()
            status = "Game Bluetooth unavailable/denied; phone original retained"
            if running { failed?("Game Bluetooth/permission changed") }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { stateChanged() }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { stateChanged() }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard active, service === ownService else { return }
        guard error == nil else { stop(); failed?("Game GATT service unavailable"); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if active && error != nil { stop(); failed?("Game advertising failed") }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        do {
            guard request.characteristic.uuid == hintID, let end else { throw BackpackError.invalid("Only this purpose's current ephemeral token is readable.") }
            request.value = try NearbyTokenPolicy.readValue(ownToken, offset: request.offset, active: active, expired: Date() >= end)
            peripheral.respond(to: request, withResult: .success)
        } catch { peripheral.respond(to: request, withResult: .readNotPermitted) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard active, characteristic.uuid == outputID, channels.values.filter({ $0.subscriber != nil }).count < 1 else { return }
        let channel = Channel(); channel.subscriber = central; channels[channel.id] = channel
        channel.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.close(channel.id, notify: true)
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if let value = channels.values.first(where: { $0.subscriber?.identifier == central.identifier }) { close(value.id, notify: true) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard active, request.characteristic.uuid == inputID, request.offset == 0,
                  let channel = channels.values.first(where: { $0.subscriber?.identifier == request.central.identifier }),
                  let bytes = request.value, bytes.count <= 512 else { peripheral.respond(to: request, withResult: .writeNotPermitted); continue }
            do {
                channel.timeout?.cancel(); channel.timeout = nil
                try ingest(bytes, channel); peripheral.respond(to: request, withResult: .success)
            } catch {
                peripheral.respond(to: request, withResult: .unlikelyError); close(channel.id, notify: true)
            }
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for channel in channels.values where channel.subscriber != nil { pump(channel) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peer: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, channels.values.filter({ $0.peer != nil }).count < 2 else { return }
        let handle = ObjectIdentifier(peer), now = ProcessInfo.processInfo.systemUptime
        guard now - (seen[handle] ?? -100) >= 10, seen.count < 64 || seen[handle] != nil,
              !channels.values.contains(where: { $0.peer === peer }) else { return }
        seen[handle] = now
        let channel = Channel(); channel.peer = peer; channels[channel.id] = channel; peer.delegate = self
        central.connect(peer, options: nil)
        channel.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(channel.id, notify: false)
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peer: CBPeripheral) { if active { peer.discoverServices([serviceID]) } else { central.cancelPeripheralConnection(peer) } }
    func peripheral(_ peer: CBPeripheral, didDiscoverServices error: Error?) {
        guard active, error == nil, let value = peer.services?.first(where: { $0.uuid == serviceID }) else { disconnect(peer); return }
        peer.discoverCharacteristics([hintID,inputID,outputID], for: value)
    }
    func peripheral(_ peer: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let channel = channels.values.first(where: { $0.peer === peer }), active, error == nil,
              let fields = service.characteristics,
              let token = fields.first(where: { $0.uuid == hintID && $0.properties.contains(.read) }),
              let writer = fields.first(where: { $0.uuid == inputID && $0.properties.contains(.write) }),
              let notifier = fields.first(where: { $0.uuid == outputID && $0.properties.contains(.notify) }) else { disconnect(peer); return }
        channel.writer = writer; channel.notifier = notifier
        peer.readValue(for: token)
    }
    func peripheral(_ peer: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active, error == nil, characteristic.isNotifying,
              let channel = channels.values.first(where: { $0.peer === peer }), let token = channel.token else { disconnect(peer); return }
        channel.timeout?.cancel(); channel.timeout = nil
        observed?(channel.id, token)
    }
    func peripheral(_ peer: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, error == nil, let channel = channels.values.first(where: { $0.peer === peer }),
              let bytes = characteristic.value else { disconnect(peer); return }
        do {
            if characteristic.uuid == hintID {
                channel.token = try NearbyTokenPolicy.decode(bytes)
                if let notifier = channel.notifier { peer.setNotifyValue(true, for: notifier) }
            } else if characteristic.uuid == outputID { try ingest(bytes, channel) }
        } catch { close(channel.id, notify: true) }
    }
    func peripheral(_ peer: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let channel = channels.values.first(where: { $0.peer === peer }) else { return }
        guard error == nil else { close(channel.id, notify: true); return }
        channel.writing = false; pump(channel)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peer: CBPeripheral, error: Error?) { disconnect(peer) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peer: CBPeripheral, error: Error?) { disconnect(peer) }
    private func disconnect(_ peer: CBPeripheral) {
        if let value = channels.values.first(where: { $0.peer === peer }) { close(value.id, notify: true) }
    }
}
