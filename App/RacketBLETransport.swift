import Foundation
import CoreBluetooth

@MainActor final class RacketBLETransport: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private(set) var scoreDisconnectReason = ""
    var scoreNotification: ((Data) -> Void)?
    var connectionEnded: (() -> Void)?
    var scoreDisconnected: (() -> Void)?
    private var archiveDiscovery: CheckedContinuation<Void,Error>?
    private var managementService = RacketArchiveWire.service
    private var managementRX = RacketArchiveWire.rx
    private var managementTX = RacketArchiveWire.tx
    private var subscription: CheckedContinuation<Void, Error>?
    func exchangeArchive(_ command:Data) async throws -> Data { try await exchangeManagement(command,dual:false) }
    func exchangeMode(_ command:Data) async throws -> Data { try await exchangeManagement(command,dual:true) }
    func readModeDiagnostics() async throws -> RacketNetworkSnapshot {
        guard exchangeID==nil,scoreNotification==nil else { throw RacketFailure.pauseRequired }
        guard let peripheral,peripheral.state == .connected else { throw RacketFailure.interrupted }
        let id=UUID(),current=run;exchangeID=id
        defer { if exchangeID==id { exchangeID=nil } }
        managementService=RacketDualHostWire.service
        managementRX=RacketDualHostWire.rx
        managementTX=RacketNetworkSnapshot.characteristic
        if chars[CBUUID(string:managementTX)] == nil {
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                archiveDiscovery=c;peripheral.discoverServices([CBUUID(string:managementService)])
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds:5_000_000_000)
                    guard let self,self.run==current,self.exchangeID==id,let waiting=self.archiveDiscovery else { return }
                    self.archiveDiscovery=nil;waiting.resume(throwing:RacketFailure.protocolUnavailable)
                }
            }
        }
        var assembler=RacketNetworkAssembler()
        for _ in 0..<10 {
            try Task.checkCancellation()
            guard run==current else { throw RacketFailure.cancelled }
            let frame=try await read(RacketNetworkSnapshot.characteristic)
            guard run==current else { throw RacketFailure.cancelled }
            if let snapshot=try assembler.append(frame) { return snapshot }
        }
        throw RacketFailure.verificationFailed
    }
    private func exchangeManagement(_ command:Data,dual:Bool) async throws -> Data {
        guard exchangeID == nil, scoreNotification == nil, let peripheral, peripheral.state == .connected else { throw RacketFailure.pauseRequired }
        let frames: (Data,UInt8) throws -> [Data] = dual ? RacketDualHostWire.frames : RacketArchiveWire.frames
        let validate: (Data,Data) throws -> Void = dual ? RacketDualHostWire.response : RacketArchiveWire.response
        managementService = dual ? RacketDualHostWire.service:RacketArchiveWire.service
        managementRX = dual ? RacketDualHostWire.rx:RacketArchiveWire.rx
        managementTX = dual ? RacketDualHostWire.tx:RacketArchiveWire.tx
        let id=UUID(), current=run; exchangeID=id
        defer { if exchangeID==id { exchangeID=nil } }
        if chars[CBUUID(string:managementTX)] == nil {
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                archiveDiscovery=c; peripheral.discoverServices([CBUUID(string:managementService)])
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds:5_000_000_000)
                    guard let self,self.run==current,self.exchangeID==id,let waiting=self.archiveDiscovery else { return }
                    self.archiveDiscovery=nil;waiting.resume(throwing:RacketFailure.protocolUnavailable)
                }
            }
        }
        transaction &+= 1
        for frame in try frames(command,transaction) {
            guard run==current else { throw RacketFailure.cancelled }
            _ = try await access(managementRX,value:frame)
        }
        var assembler=RacketScoreAssembler(); let until=Date().addingTimeInterval(15)
        while Date()<until {
            try Task.checkCancellation();guard run==current else { throw RacketFailure.cancelled }
            let frame=try await read(managementTX)
            if frame==Data([0]) { try await Task.sleep(nanoseconds:50_000_000);continue }
            if let response=try assembler.append(frame,now:0) { try validate(response,command);return response }
        }
        throw RacketFailure.unknown
    }
    func scoreInfo() async throws -> RacketScoreInfo {
        guard let peripheral else { throw RacketFailure.interrupted }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            subscription = c
            peripheral.discoverServices([CBUUID(string: RacketScoreWire.service)])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let waiting = self.subscription else { return }
                self.subscription = nil; waiting.resume(throwing: RacketFailure.interrupted)
            }
        }
        return try RacketScoreWire.info(await read(RacketScoreWire.infoCharacteristic))
    }
    func writeControlFrame(_ frame: Data) async throws { _ = try await access(RacketScoreWire.controlCharacteristic, value: frame) }
    func readScoreState() async throws -> Data { try await read(RacketScoreWire.stateCharacteristic) }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == CBUUID(string: RacketScoreWire.eventCharacteristic), let waiting = subscription else { return }
        subscription = nil
        if error == nil && characteristic.isNotifying { waiting.resume() }
        else { waiting.resume(throwing: RacketFailure.interrupted) }
    }
    var isConnected: Bool { peripheral?.state == .connected }
    private var central: CBCentralManager!
    private var candidates: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var scanning: CheckedContinuation<[RacketNearby], Error>?
    private var connecting: CheckedContinuation<Void, Error>?
    private var io: CheckedContinuation<Data, Error>?
    private var ioID = UUID()
    private var run = UUID()
    private var expected: CBUUID?
    private var writing = false
    private var transaction: UInt8 = 0
    private var exchangeID: UUID?
    private let v2: Bool
    private var serviceUUID: String { v2 ? RacketBLEWireV2.service : RacketBLEWire.service }
    private var infoUUID: String { v2 ? RacketBLEWireV2.info : RacketBLEWire.info }
    private var rxUUID: String { v2 ? RacketBLEWireV2.rx : RacketBLEWire.rx }
    private var txUUID: String { v2 ? RacketBLEWireV2.tx : RacketBLEWire.tx }
    init(v2: Bool = false) { self.v2 = v2; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    private func parseInfo(_ data: Data) throws -> RacketBLEWire.Info {
        if v2 {
            let info = try RacketBLEWireV2.parseInfo(data)
            return RacketBLEWire.Info(deviceID: info.deviceID, session: info.session, revision: info.revision, bound: info.bound)
        }
        return try RacketBLEWire.parseInfo(data)
    }
    private func ready() async throws {
        for _ in 0..<30 {
            if central.state == .poweredOn { return }
            if central.state == .unauthorized { throw RacketFailure.bluetoothDenied }
            if central.state == .poweredOff { throw RacketFailure.bluetoothOff }
            if central.state == .unsupported { throw RacketFailure.protocolUnavailable }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RacketFailure.interrupted
    }
    func scan() async throws -> [RacketNearby] {
        cancel(); let id = run
        try await ready(); try Task.checkCancellation()
        guard run == id else { throw RacketFailure.cancelled }
        candidates = [:]
        return try await withCheckedThrowingContinuation { continuation in
            scanning = continuation
            central.scanForPeripherals(withServices: [CBUUID(string: serviceUUID)])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.run == id, let waiting = self.scanning else { return }
                self.scanning = nil; self.central.stopScan()
                let values = self.candidates.values.map { RacketNearby(id: $0.identifier.uuidString, label: $0.name ?? "附近拍底") }.sorted { $0.id < $1.id }
                if values.isEmpty { waiting.resume(throwing: RacketFailure.scanEmpty) } else { waiting.resume(returning: values) }
            }
        }
    }
    func connect(_ candidate: RacketNearby) async throws -> RacketBLEWire.Info {
        guard let id = UUID(uuidString: candidate.id), let device = candidates[id] else { throw RacketFailure.interrupted }
        cancelConnection(); let current = run
        try await ready(); try Task.checkCancellation()
        guard run == current else { throw RacketFailure.cancelled }
        // CoreBluetooth cancellation is asynchronous. Do not start a replacement
        // connection until the previous disconnect has completed on this peripheral.
        for _ in 0..<50 {
            if device.state == .disconnected { break }
            try await Task.sleep(nanoseconds:100_000_000)
            guard run == current else { throw RacketFailure.cancelled }
        }
        guard device.state == .disconnected else { throw RacketDiagnostic(stage:"等待旧连接释放",detail:"蓝牙连接未释放，请关闭其他拍底页面后重试。") }
        peripheral = device; device.delegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connecting = continuation; central.connect(device)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.run == current, let waiting = self.connecting else { return }
                self.connecting = nil; waiting.resume(throwing:RacketDiagnostic(stage:"连接 / 发现绑定服务",detail:"8 秒内未完成，请确认拍底未被其他手机占用。"))
                self.cancelConnection()
            }
        }
        do { return try parseInfo(await read(infoUUID)) }
        catch { throw RacketDiagnostic(stage:"读取绑定 INFO",detail:"已连接但读取失败：" + error.localizedDescription) }
    }
    func currentInfo() async throws -> RacketBLEWire.Info {
        guard exchangeID == nil else { throw RacketFailure.conflict }; return try parseInfo(await read(infoUUID))
    }
    func reconnect(_ candidate: RacketNearby) async throws -> RacketBLEWire.Info {
        guard let id = UUID(uuidString: candidate.id), let device = candidates[id] else { throw RacketFailure.interrupted }
        cancelConnection()
        for _ in 0..<50 {
            if device.state == .disconnected { return try await connect(candidate) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RacketFailure.interrupted
    }
    func locate() async throws { guard exchangeID == nil else { throw RacketFailure.conflict }; _ = try await access(rxUUID, value: Data([0])) }
    func exchange(_ command: Data) async throws -> Data {
        guard exchangeID == nil else { throw RacketFailure.conflict }
        let exchange = UUID(); exchangeID = exchange
        defer { if exchangeID == exchange { exchangeID = nil } }
        transaction &+= 1; let id = transaction, current = run
        let start = Date()
        let fragments = try v2 ? RacketBLEWireV2.fragments(command, transaction: id) : RacketBLEWire.fragments(command, transaction: id)
        for fragment in fragments {
            guard run == current, Date().timeIntervalSince(start) < 5 else { throw RacketFailure.interrupted }
            _ = try await access(rxUUID, value: fragment)
        }
        var assembler = RacketBLEWire.Assembler(transaction: id)
        var assemblerV2 = RacketBLEWireV2.Assembler(transaction: id)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try Task.checkCancellation()
            guard run == current else { throw RacketFailure.cancelled }
            let frame = try await read(txUUID)
            if let message = try v2 ? assemblerV2.append(frame) : assembler.append(frame) { return message }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        cancelConnection(); throw RacketFailure.unknown
    }
    private func read(_ uuid: String) async throws -> Data { try await access(uuid, value: nil) }
    private func access(_ uuid: String, value: Data?) async throws -> Data {
        guard io == nil, let peripheral, peripheral.state == .connected, let characteristic = chars[CBUUID(string: uuid)] else { throw RacketFailure.interrupted }
        let operation = UUID(); ioID = operation; expected = characteristic.uuid; writing = value != nil
        return try await withCheckedThrowingContinuation { continuation in
            io = continuation
            if let value { peripheral.writeValue(value, for: characteristic, type: .withResponse) }
            else { peripheral.readValue(for: characteristic) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.ioID == operation, self.io != nil else { return }
                self.cancelConnection(reason:"蓝牙读写超过 3 秒未完成")
            }
        }
    }
    func cancel() { central.stopScan(); scanning?.resume(throwing: RacketFailure.cancelled); scanning = nil; cancelConnection() }
    private func cancelConnection(reason: String = "App 关闭连接") {
        RacketDiagnosticLog.shared.record(.disconnected,code:"BLE_DISCONNECT")
        scoreDisconnectReason = reason
        archiveDiscovery?.resume(throwing:RacketFailure.interrupted); archiveDiscovery=nil
        connectionEnded?()
        scoreDisconnected?()
        subscription?.resume(throwing: RacketFailure.interrupted); subscription = nil
        run = UUID(); ioID = UUID(); exchangeID = nil
        connecting?.resume(throwing: RacketFailure.interrupted); connecting = nil
        io?.resume(throwing: RacketFailure.interrupted); io = nil; expected = nil
        if let peripheral { peripheral.delegate = nil; central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; chars = [:]
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { RacketDiagnosticLog.shared.record(.connected,code:"BLE_STATE",status:central.state.rawValue); if central.state != .poweredOn { cancel() } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) { if scanning != nil { candidates[peripheral.identifier] = peripheral } }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        RacketDiagnosticLog.shared.record(.connected,code:"BLE_CONNECTED")
        peripheral.discoverServices([CBUUID(string: serviceUUID)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { if self.peripheral === peripheral { connecting?.resume(throwing: RacketDiagnostic(stage:"建立蓝牙连接",detail:error?.localizedDescription ?? "系统拒绝连接")); connecting = nil; cancelConnection() } }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { if self.peripheral === peripheral { RacketDiagnosticLog.shared.record(.disconnected,code:"BLE_SYSTEM",status:(error as NSError?)?.code); cancelConnection(reason: error?.localizedDescription ?? "设备主动断开连接") } }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        if archiveDiscovery != nil {
            guard error == nil, let service=peripheral.services?.first(where:{$0.uuid==CBUUID(string:managementService)}) else {
                archiveDiscovery?.resume(throwing:RacketFailure.protocolUnavailable);archiveDiscovery=nil;return
            }
            peripheral.discoverCharacteristics(nil,for:service);return
        }
        if subscription != nil {
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: RacketScoreWire.service) }) else {
                subscription?.resume(throwing: RacketFailure.protocolUnavailable); subscription = nil; return
            }
            peripheral.discoverCharacteristics(nil, for: service); return
        }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: serviceUUID) }) else { cancelConnection(); return }
        peripheral.discoverCharacteristics([CBUUID(string: infoUUID), CBUUID(string: rxUUID), CBUUID(string: txUUID)], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else { cancelConnection(); return }
        for characteristic in service.characteristics ?? [] { chars[characteristic.uuid] = characteristic }
        if service.uuid == CBUUID(string:managementService) {
            let valid=chars[CBUUID(string:managementRX)]?.properties.contains(.write)==true && chars[CBUUID(string:managementTX)]?.properties.contains(.read)==true
            let c=archiveDiscovery;archiveDiscovery=nil
            if valid { c?.resume() } else { c?.resume(throwing:RacketFailure.protocolUnavailable) };return
        }
        if service.uuid == CBUUID(string: RacketScoreWire.service) {
            guard let event = chars[CBUUID(string: RacketScoreWire.eventCharacteristic)], event.properties.contains(.notify),
                  chars[CBUUID(string: RacketScoreWire.controlCharacteristic)]?.properties.contains(.write) == true,
                  chars[CBUUID(string: RacketScoreWire.infoCharacteristic)]?.properties.contains(.read) == true,
                  chars[CBUUID(string: RacketScoreWire.stateCharacteristic)]?.properties.contains(.read) == true else {
                subscription?.resume(throwing: RacketFailure.protocolUnavailable); subscription = nil; return
            }
            peripheral.setNotifyValue(true, for: event); return
        }
        guard chars[CBUUID(string: infoUUID)]?.properties.contains(.read) == true,
              chars[CBUUID(string: txUUID)]?.properties.contains(.read) == true,
              chars[CBUUID(string: rxUUID)]?.properties.contains(.write) == true else { cancelConnection(); return }
        connecting?.resume(); connecting = nil
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if self.peripheral === peripheral, characteristic.uuid == CBUUID(string: RacketScoreWire.eventCharacteristic) {
            if error == nil, let data = characteristic.value { scoreNotification?(data) }; return
        }
        guard self.peripheral === peripheral, !writing, expected == characteristic.uuid, let continuation = io else { return }
        io = nil; expected = nil
        if let error { continuation.resume(throwing: error) } else if let data = characteristic.value { continuation.resume(returning: data) } else { continuation.resume(throwing: RacketFailure.interrupted) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, writing, expected == characteristic.uuid, let continuation = io else { return }
        io = nil; expected = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: Data()) }
    }
}

extension RacketBLETransport: RacketScoreTransport {}
