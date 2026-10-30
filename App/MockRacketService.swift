#if DEBUG || RACKET_TESTS
import Foundation

/// Explicitly injected only. Never selected as fallback after a live request fails.
@MainActor final class MockRacketService: RacketService {
    let capabilities = RacketCapabilities(hostDiscovery: true, bluetoothDiscovery: true, roster: true)
    var failure: RacketFailure?
    var nextState: RacketOperationState = .confirmed
    var submissions = 0
    var delay: UInt64 = 0
    private var saved: [UUID: RacketOperation] = [:]
    private var receipts: [UUID: RacketReceipt] = [:]
    private var inventoryByScope: [String: [RacketDevice]] = [:]
    var confirmedRosters: [String: [RacketRoster]] = [:]
    private func inventoryKey(_ context: RacketContext) -> String { context.origin + "/" + (context.hostID ?? "") }
    func hosts(_ context: RacketContext) async throws -> [RacketHost] {
        if let failure { throw failure }
        return [RacketHost(id: "mock-host", name: "模拟计分主机", connection: .online, observedAt: Date())]
    }
    func inventory(_ context: RacketContext) async throws -> RacketInventory {
        if let failure { throw failure }
        let people = [RacketPerson(kind: .user, stableID: context.userID, name: "模拟球友"), RacketPerson(kind: .user, stableID: "other", name: "小明"), RacketPerson(kind: .guest, stableID: "guest-1", name: "小明"), RacketPerson(kind: .guest, stableID: "guest-2", name: "访客二")]
        let key = inventoryKey(context)
        if inventoryByScope[key] == nil {
            inventoryByScope[key] = [
                RacketDevice(id: "mock-racket-1", name: "我的拍底", version: 1, user: nil, hostID: context.hostID, authenticated: true, connection: .online, observedAt: Date(), matchActive: false, battery: 82),
                RacketDevice(id: "mock-racket-2", name: "访客拍底", version: 3, user: people[2], hostID: context.hostID, authenticated: true, connection: .offline, observedAt: Date(), matchActive: false),
                RacketDevice(id: "mock-racket-3", name: "球友拍底", version: 2, user: people[1], hostID: context.hostID, authenticated: true, connection: .unknown, observedAt: Date(), matchActive: true)
            ]
        }
        return RacketInventory(devices: inventoryByScope[key] ?? [], people: people,
            confirmedRosters: (confirmedRosters[key] ?? []).map { RacketConfirmedRoster(roster: $0, deviceConfirmationID: "mock-roster-ack", observedAt: Date()) })
    }
    func confirmDevice(_ id: String, context: RacketContext) async throws -> RacketDeviceConfirmation {
        let rows = try await inventory(context)
        guard rows.devices.contains(where: { $0.id == id && $0.authenticated }) else { throw RacketFailure.verificationFailed }
        return RacketDeviceConfirmation(deviceID: id, proof: "mock-proof", expiresAt: Date().addingTimeInterval(60))
    }
    func submit(_ operation: RacketOperation, context: RacketContext) async throws -> RacketReceipt {
        guard operation.scope == context.scope else { throw RacketFailure.forbidden }
        if let existing = saved[operation.id] {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            guard existing.scope == operation.scope,
                  try encoder.encode(existing.action) == encoder.encode(operation.action) else { throw RacketFailure.conflict }
            return receipts[operation.id] ?? RacketReceipt(operationID: operation.id, state: .awaitingDevice, deviceConfirmationID: nil, error: nil)
        }
        submissions += 1; saved[operation.id] = operation
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        let receipt = RacketReceipt(operationID: operation.id, state: .awaitingDevice, deviceConfirmationID: nil, error: nil)
        receipts[operation.id] = receipt
        return receipt
    }
    func result(_ id: UUID, context: RacketContext) async throws -> RacketReceipt {
        if let failure { throw failure }
        guard let op = saved[id], op.scope == context.scope else { throw RacketFailure.unknown }
        if let final = receipts[id], !final.state.unresolved { return final }
        var state = nextState
        var error: RacketFailure?
        let key = inventoryKey(context)
        _ = try await inventory(context)
        if state == .confirmed {
            switch op.action {
            case .bindSelf(let deviceID, let version, let proof):
                guard let index = inventoryByScope[key]?.firstIndex(where: { $0.id == deviceID }) else { throw RacketFailure.forbidden }
                var device = inventoryByScope[key]![index]
                if device.matchActive { state = .rejected; error = .pauseRequired }
                else if device.user != nil { state = .rejected; error = .ownedByOther }
                else if device.version != version { state = .conflict; error = .conflict }
                else if proof != "mock-proof" { state = .rejected; error = .verificationFailed }
                else { device.user = RacketPerson(kind: .user, stableID: context.userID, name: "模拟球友"); device.version += 1; inventoryByScope[key]![index] = device }
            case .unbind(let deviceID, let version):
                guard let index = inventoryByScope[key]?.firstIndex(where: { $0.id == deviceID }) else { throw RacketFailure.forbidden }
                var device = inventoryByScope[key]![index]
                if device.matchActive { state = .rejected; error = .pauseRequired }
                else if device.user?.kind != .user || device.user?.stableID != context.userID { state = .rejected; error = .ownedByOther }
                else if device.version != version { state = .conflict; error = .conflict }
                else { device.user = nil; device.version += 1; inventoryByScope[key]![index] = device }
            case .roster(let roster):
                if !roster.valid { state = .rejected; error = .forbidden }
                else { confirmedRosters[key] = (confirmedRosters[key] ?? []).filter { $0.matchKey != roster.matchKey } + [roster] }
            }
        }
        let receipt = RacketReceipt(operationID: id, state: state, deviceConfirmationID: state == .confirmed ? "mock-device-ack" : nil, error: error)
        receipts[id] = receipt; return receipt
    }
}

@MainActor final class MockRacketBluetooth: RacketBluetoothDiscovery {
    let available = true
    var failure: RacketFailure?
    var empty = false
    let service: MockRacketService
    init(service: MockRacketService) { self.service = service }
    func scan() async throws -> [RacketNearby] {
        if let failure { throw failure }
        return empty ? [] : [RacketNearby(id: "candidate-1", label: "模拟附近拍底 · 01")]
    }
    func verifyAndPrepare(_ candidate: RacketNearby, hostID: String?, context: RacketContext) async throws -> RacketVerifiedNearby {
        if let failure { throw failure }
        guard candidate.id == "candidate-1" else { throw RacketFailure.verificationFailed }
        let inventory = try await service.inventory(context)
        let device = inventory.devices[0]
        return RacketVerifiedNearby(device: device, confirmation: try await service.confirmDevice(device.id, context: context))
    }
    func cancel() {}
}
#endif
