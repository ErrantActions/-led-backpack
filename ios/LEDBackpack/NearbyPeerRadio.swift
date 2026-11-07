import CoreBluetooth
import Combine
import BackpackProtocol

@MainActor
final class NearbyPeerRadio: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: NearbyTokenPolicy.service)
    static let tokenUUID = CBUUID(string: NearbyTokenPolicy.characteristic)
    @Published private(set) var status = "Bluetooth peer discovery off"
    @Published private(set) var active = false
    @Published private(set) var ready = false
    var observedToken: ((String) -> Void)?
    var interrupted: (() -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var service: CBMutableService?
    private var characteristic: CBMutableCharacteristic?
    private var token: Data?
    private var tokenDeadline: Date?
    private var connections: [ObjectIdentifier: CBPeripheral] = [:]
    private var timeouts: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var lastReads: [ObjectIdentifier: TimeInterval] = [:]
    private var expiry: Task<Void, Never>?
    private var gate = NearbyTransportGate()
    func prepare() throws {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackpackError.invalid("Bluetooth usage declaration is missing; discovery permission is unavailable.")
        }
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        peripheral = CBPeripheralManager(delegate: self, queue: .main, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        status = "Preparing OS Bluetooth state; explicit Start still required"
    }
    func start(look: Bool, discoverable: Bool, token: String?, remaining: TimeInterval) throws {
        stop()
        guard ready, let central, let peripheral, central.state == .poweredOn, peripheral.state == .poweredOn,
              look || discoverable, remaining > 0 else { throw BackpackError.invalid("Bluetooth unavailable/unauthorized. Prepare permission, then explicitly Start in the foreground.") }
        try gate.arm(look: look, discoverable: discoverable, foreground: true, ready: ready, consent: true)
        if discoverable {
            guard let token, NearbyTokenPolicy.valid(token) else { throw BackpackError.invalid("A live service-issued ephemeral token is required to advertise.") }
            self.token = Data(token.utf8); tokenDeadline = Date().addingTimeInterval(min(120, remaining))
        }
        active = true
        if look { central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
        if discoverable {
            let characteristic = CBMutableCharacteristic(type: Self.tokenUUID, properties: [.read], value: nil, permissions: [.readable])
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [characteristic]
            self.service = service; self.characteristic = characteristic
            peripheral.add(service)
        }
        status = "Foreground peer discovery active — hints, not proximity proof"
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(min(120, remaining))) } catch { return }
            self?.stop(); self?.interrupted?()
        }
    }
    func stop() {
        active = false; gate.stop(); central?.stopScan(); peripheral?.stopAdvertising(); peripheral?.removeAllServices()
        for task in timeouts.values { task.cancel() }; timeouts = [:]
        for peer in connections.values { central?.cancelPeripheralConnection(peer) }
        connections = [:]; lastReads = [:]; token = nil; tokenDeadline = nil; service = nil; characteristic = nil
        expiry?.cancel(); expiry = nil; status = "Bluetooth peer discovery off"
    }
    private func stateChanged() {
        ready = central?.state == .poweredOn && peripheral?.state == .poweredOn
        guard !ready else { if !active { status = "Bluetooth ready — explicit Start required" }; return }
        let wasActive = active
        stop()
        status = "Bluetooth unavailable, resetting, unsupported or permission denied — QR/manual fallback"
        if wasActive { interrupted?() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { stateChanged() }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { stateChanged() }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard active, service === self.service else { return }
        guard error == nil else { stop(); status = "Read-only peer service could not be published"; interrupted?(); return }
        // iOS supports service UUID advertising; no arbitrary service-data or local name.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if error != nil && active { stop(); status = "Foreground peer advertising unavailable"; interrupted?() }
        else if active { status = "CoreBluetooth advertising started — token readable only until its deadline; not proximity proof" }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard active, request.characteristic.uuid == Self.tokenUUID, let deadline = tokenDeadline else {
            peripheral.respond(to: request, withResult: .readNotPermitted); return
        }
        do {
            request.value = try NearbyTokenPolicy.readValue(token, offset: request.offset, active: gate.advertising, expired: Date() >= deadline)
            peripheral.respond(to: request, withResult: .success)
        } catch { peripheral.respond(to: request, withResult: .readNotPermitted) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peer: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, gate.scanning, connections.count < 4 else { return }
        let key = ObjectIdentifier(peer), now = ProcessInfo.processInfo.systemUptime
        guard connections[key] == nil, now - (lastReads[key] ?? -100) >= 10, lastReads.count < 128 || lastReads[key] != nil else { return }
        lastReads[key] = now; connections[key] = peer; peer.delegate = self
        central.connect(peer, options: nil)
        timeouts[key] = Task { [weak self, weak peer] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if let peer { self?.finish(peer) }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peer: CBPeripheral) {
        guard active, connections[ObjectIdentifier(peer)] != nil else { central.cancelPeripheralConnection(peer); return }
        peer.discoverServices([Self.serviceUUID])
    }
    func peripheral(_ peer: CBPeripheral, didDiscoverServices error: Error?) {
        guard active, connections[ObjectIdentifier(peer)] != nil, error == nil,
              let service = peer.services?.first(where: { $0.uuid == Self.serviceUUID }) else { finish(peer); return }
        peer.discoverCharacteristics([Self.tokenUUID], for: service)
    }
    func peripheral(_ peer: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active, connections[ObjectIdentifier(peer)] != nil, error == nil,
              let value = service.characteristics?.first(where: { $0.uuid == Self.tokenUUID && $0.properties.contains(.read) }) else { finish(peer); return }
        peer.readValue(for: value)
    }
    func peripheral(_ peer: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, connections[ObjectIdentifier(peer)] != nil, characteristic.uuid == Self.tokenUUID, error == nil,
              let data = characteristic.value else { finish(peer); return }
        do { let value = try NearbyTokenPolicy.decode(data); observedToken?(value) }
        catch { status = "Invalid peer token ignored; no profile resolved" }
        finish(peer)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peer: CBPeripheral, error: Error?) { finish(peer) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peer: CBPeripheral, error: Error?) { finish(peer) }
    private func finish(_ peer: CBPeripheral) {
        let key = ObjectIdentifier(peer)
        guard connections.removeValue(forKey: key) != nil else { return }
        timeouts.removeValue(forKey: key)?.cancel()
        central?.cancelPeripheralConnection(peer); peer.delegate = nil
    }
}
