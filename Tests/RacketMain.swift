import Foundation

@MainActor final class ReceiptRacketService: RacketService {
    let capabilities = RacketCapabilities(hostDiscovery: true, bluetoothDiscovery: false, roster: true)
    var ack: String? = nil
    var returnedID: UUID?
    var hold: CheckedContinuation<RacketReceipt, Error>?
    var suspended = false
    var holdQueries = false
    var queryCalls = 0
    var queryHolds: [CheckedContinuation<RacketReceipt, Error>] = []
    func hosts(_ c: RacketContext) async throws -> [RacketHost] { [] }
    func inventory(_ c: RacketContext) async throws -> RacketInventory { RacketInventory(devices: [], people: []) }
    func confirmDevice(_ id: String, context: RacketContext) async throws -> RacketDeviceConfirmation { throw RacketFailure.verificationFailed }
    func submit(_ op: RacketOperation, context: RacketContext) async throws -> RacketReceipt {
        if suspended { return try await withCheckedThrowingContinuation { hold = $0 } }
        return RacketReceipt(operationID: returnedID ?? op.id, state: .confirmed, deviceConfirmationID: ack, error: nil)
    }
    func result(_ id: UUID, context: RacketContext) async throws -> RacketReceipt {
        queryCalls += 1
        if holdQueries { return try await withCheckedThrowingContinuation { queryHolds.append($0) } }
        return RacketReceipt(operationID: returnedID ?? id, state: .confirmed, deviceConfirmationID: ack, error: nil)
    }
}

@main struct RacketChecks {
    @MainActor static func main() async throws {
        let suite = "racket-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); count += 1; print("PASS: " + label)
        }
        let context = RacketContext(origin: "mock://one", userID: "me", token: "SECRET-SESSION", hostID: "mock-host")
        let service = MockRacketService()
        let store = RacketStore(service: service, bluetooth: MockRacketBluetooth(service: service), defaults: defaults, simulated: true, timeout: 20_000_000)
        store.configure(context); await store.refresh()
        check(store.devices.count == 3, "authenticated inventory loaded")
        check(Set(store.people.filter { $0.name == "小明" }.map { $0.id }).count == 2, "same display name does not merge user and guest")
        let original = store.devices[0]
        await store.choose(original); check(store.canBind, "host discovery can reach confirmed-device association")
        await store.bindSelf()
        let operation = store.operations.last!
        check(operation.state == .awaitingDevice && store.selected?.user == nil, "HTTP acceptance does not associate device")
        await store.bindSelf(); check(service.submissions == 1, "repeated taps do not create operations")
        try await Task.sleep(nanoseconds: 40_000_000)
        check(store.operations.last?.state == .unknown, "timeout produces unknown, not false failure or success")
        let restored = RacketStore(service: service, defaults: defaults, simulated: true)
        restored.configure(context)
        check(restored.operations.last?.id == operation.id, "restart restores same pending operation ID")
        await restored.refresh()
        await restored.refresh()
        check(restored.operations.last?.state == .confirmed && restored.devices[0].user?.stableID == "me", "query reconciles device ACK and authoritative binding")
        check(service.submissions == 1, "restart recovery never resubmits association")
        let encoded = defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }.compactMap { String(data: $0, encoding: .utf8) }.joined()
        check(!encoded.contains("SECRET-SESSION") && !encoded.contains("mock-proof"), "journal contains no login token or confirmation proof")
        let otherPhone = RacketStore(service: service, defaults: UserDefaults(suiteName: suite + "-other")!, simulated: true)
        defer { UserDefaults(suiteName: suite + "-other")!.removePersistentDomain(forName: suite + "-other") }
        otherPhone.configure(RacketContext(origin: context.origin, userID: "other-phone-user", token: "OTHER", hostID: context.hostID))
        await otherPhone.refresh(); await otherPhone.choose(otherPhone.devices[0])
        check(otherPhone.selected?.user?.stableID == "me" && !otherPhone.canBind, "second authorized phone sees same owner and cannot claim")
        await otherPhone.unbind(otherPhone.devices[0])
        check(service.submissions == 1, "ordinary user cannot unbind another user")
        let securedMock = MockRacketService()
        let fresh = try await securedMock.inventory(context).devices[0]
        let identity = UUID()
        let bind = RacketOperation(id: identity, scope: context.scope, action: .bindSelf(deviceID:fresh.id, expectedVersion:fresh.version, confirmation:"mock-proof"), state:.submitting)
        _ = try await securedMock.submit(bind, context:context)
        let altered = RacketOperation(id: identity, scope: context.scope, action: .unbind(deviceID:fresh.id, expectedVersion:fresh.version), state:.submitting)
        do { _ = try await securedMock.submit(altered, context:context); preconditionFailure("same ID accepted a different action") } catch RacketFailure.conflict { }
        check(securedMock.submissions == 1, "same operation ID cannot change binding intent")
        let confirmedBind = try await securedMock.result(identity, context:context)
        check(confirmedBind.state == .confirmed, "mock bind requires device confirmation")
        let bound = try await securedMock.inventory(context).devices[0]
        let unbindID = UUID()
        let unbind = RacketOperation(id:unbindID, scope:context.scope, action:.unbind(deviceID:bound.id, expectedVersion:bound.version), state:.submitting)
        let acceptedUnbind = try await securedMock.submit(unbind, context:context)
        let beforeUnbindAck = try await securedMock.inventory(context).devices[0]
        check(acceptedUnbind.state == .awaitingDevice && beforeUnbindAck.user != nil, "unbind acceptance retains existing owner")
        let unboundAck = try await securedMock.result(unbindID, context:context)
        let unbound = try await securedMock.inventory(context).devices[0]
        check(unboundAck.state == .confirmed && unbound.user == nil && unbound.version == bound.version + 1, "mock device confirmation clears owner and advances revision")
        let nextContext = RacketContext(origin:context.origin,userID:"other-phone-user",token:"OTHER",hostID:context.hostID)
        let nextBind = RacketOperation(id:UUID(),scope:nextContext.scope,action:.bindSelf(deviceID:unbound.id,expectedVersion:unbound.version,confirmation:"mock-proof"),state:.submitting)
        _ = try await securedMock.submit(nextBind,context:nextContext)
        _ = try await securedMock.result(nextBind.id,context:nextContext)
        let rebound = try await securedMock.inventory(context).devices[0]
        check(rebound.user?.stableID == "other-phone-user", "new user can bind after confirmed unbind")
        let me = RacketPerson(kind: .user, stableID: "me", name: "小明")
        let guest = RacketPerson(kind: .guest, stableID: "guest-1", name: "小明")
        check(me == RacketPerson(kind: .user, stableID: "me", name: "改名后"), "renaming display text never changes identity")
        let first = RacketRoster(matchKey: "match1", fixtureID: nil, expectedVersion: 0, players: [.init(person: me, team: .red), .init(person: guest, team: .blue)])
        restored.setRoster(first); await restored.submitRoster(); await restored.query(restored.operations.last!.id); await restored.refresh()
        check(restored.rosterConfirmed, "temporary match accepts host guest and waits for roster ACK")
        let second = RacketRoster(matchKey: "match2", fixtureID: nil, expectedVersion: 0, players: [.init(person: me, team: .blue), .init(person: guest, team: .red)])
        restored.setRoster(second); check(!restored.rosterConfirmed, "new match does not reuse old roster approval")
        await restored.submitRoster(); await restored.query(restored.operations.last!.id); await restored.refresh()
        check(restored.rosterConfirmed && restored.devices[0].user?.stableID == "me", "changing teams across matches never changes device ownership")
        service.confirmedRosters = [:]; await restored.refresh()
        check(!restored.rosterConfirmed, "server removal of roster invalidates old journal confirmation")
        check(!RacketRoster(matchKey: "formal", fixtureID: "fixture", expectedVersion: 0, players: first.players).valid, "formal roster does not silently admit host guests")
        check(!RacketRoster(matchKey: "dup", fixtureID: nil, expectedVersion: 0, players: [.init(person: me, team: .red), .init(person: me, team: .blue)]).valid, "same stable identity cannot occupy both teams")
        var active = restored.devices[0]; active.matchActive = true
        let before = service.submissions; await restored.unbind(active)
        check(service.submissions == before && restored.message.contains("暂停"), "active match requires pause before unbinding")
        var stale = original
        stale = RacketDevice(id: stale.id, name: stale.name, version: 1, user: nil, hostID: nil, authenticated: true, connection: .online, observedAt: Date().addingTimeInterval(-61), matchActive: false)
        check(stale.status(at: Date()) == .unknown, "old cache never stays online")
        check(stale.readiness(for: context.hostID, at: Date()).contains("尚未连接"), "association and host readiness remain distinct")
        service.failure = .hostOffline; await restored.refresh()
        check(restored.devices.isEmpty && restored.hosts.isEmpty && !restored.rosterConfirmed && restored.message.contains("离线"), "failed refresh removes stale online inventory and invalidates roster readiness")
        service.failure = .forbidden; await restored.refresh(); check(restored.message.contains("权限"), "permission failure has distinct recovery message")
        service.failure = nil

        let receiptService = ReceiptRacketService()
        let receiptStore = RacketStore(service: receiptService, defaults: defaults, simulated: true)
        receiptStore.configure(RacketContext(origin: "mock://receipt", userID: "me", token: "token", hostID: "host"))
        await receiptStore.submit(.roster(first))
        check(receiptStore.operations.last?.state == .unknown, "confirmed without device evidence is rejected as unknown")
        receiptService.ack = "device-ack"; receiptService.returnedID = UUID()
        await receiptStore.query(receiptStore.operations.last!.id)
        check(receiptStore.operations.last?.state == .unknown, "wrong operation ID cannot confirm pending work")
        receiptService.returnedID = nil; await receiptStore.query(receiptStore.operations.last!.id)
        check(receiptStore.operations.last?.state == .confirmed, "correct operation and device evidence confirm")
        for next in [RacketOperationState.rejected, .conflict, .expired] {
            service.nextState = next
            restored.setRoster(RacketRoster(matchKey: UUID().uuidString, fixtureID: nil, expectedVersion: 0, players: first.players))
            await restored.submitRoster(); await restored.query(restored.operations.last!.id)
            check(restored.operations.last?.state == next, "terminal \(next.rawValue) is not success")
        }
        receiptService.suspended = true
        let work = Task { await receiptStore.submit(.roster(second)) }
        while receiptService.hold == nil { await Task.yield() }
        let oldID = receiptStore.operations.last!.id
        receiptStore.configure(RacketContext(origin: "mock://new-origin", userID: "new-user", token: "new", hostID: "new-host"))
        receiptService.hold?.resume(returning: RacketReceipt(operationID: oldID, state: .confirmed, deviceConfirmationID: "late-ack", error: nil))
        await work.value
        check(receiptStore.operations.isEmpty && receiptStore.devices.isEmpty, "late response after account/host/origin switch is discarded")
        let late = ReceiptRacketService(); late.suspended = true
        let lateStore = RacketStore(service: late, defaults: defaults, simulated: true, timeout: 20_000_000)
        lateStore.configure(RacketContext(origin: "mock://late", userID: "me", token: "token", hostID: "host"))
        let lateTask = Task { await lateStore.submit(.roster(first)) }
        while late.hold == nil { await Task.yield() }
        try await Task.sleep(nanoseconds: 40_000_000)
        let lateID = lateStore.operations.last!.id
        late.hold?.resume(returning: RacketReceipt(operationID: lateID, state: .awaitingDevice, deviceConfirmationID: nil, error: nil))
        await lateTask.value
        check(lateStore.operations.last?.state == .unknown, "late HTTP acceptance cannot resurrect elapsed operation deadline")
        let queries = ReceiptRacketService(); queries.holdQueries = true
        let queryStore = RacketStore(service: queries, defaults: defaults, simulated: true, timeout: 150_000_000)
        queryStore.configure(RacketContext(origin: "mock://queries", userID: "me", token: "token", hostID: "host"))
        await queryStore.submit(.roster(first)); let queryID = queryStore.operations.last!.id
        let query1 = Task { await queryStore.query(queryID) }
        while queries.queryHolds.count < 1 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        queries.queryHolds[0].resume(returning: RacketReceipt(operationID: queryID, state: .awaitingDevice, deviceConfirmationID: nil, error: nil))
        await query1.value
        let query2 = Task { await queryStore.query(queryID) }
        while queries.queryHolds.count < 2 { await Task.yield() }
        try await Task.sleep(nanoseconds: 75_000_000)
        await queryStore.query(queryID)
        check(queries.queryCalls == 2, "old query timer cannot release newer query guard")
        queries.queryHolds[1].resume(returning: RacketReceipt(operationID: queryID, state: .confirmed, deviceConfirmationID: "ack", error: nil))
        await query2.value
        check(queryStore.operations.last?.state == .confirmed, "new query survives previous attempt watchdog")
        let ble = RacketStore(service: service, bluetooth: MockRacketBluetooth(service: service), defaults: defaults, simulated: true)
        ble.configure(RacketContext(origin: "mock://ble", userID: "ble-me", token: "ble", hostID: "mock-host"))
        await ble.scan(); check(ble.selected == nil && !ble.canBind, "advertisement alone is not authentication")
        await ble.chooseNearby(ble.nearby[0]); check(ble.canBind, "verified BLE enters the same association flow")
        ble.cancelDiscovery(); check(ble.selected == nil && !ble.canBind, "cancellation discards device confirmation")
        let faultyBLE = MockRacketBluetooth(service: service)
        let bluetoothStore = RacketStore(service: service, bluetooth: faultyBLE, defaults: defaults, simulated: true)
        bluetoothStore.configure(context)
        for failure in [RacketFailure.bluetoothOff, .bluetoothDenied, .interrupted, .verificationFailed] {
            faultyBLE.failure = failure; await bluetoothStore.scan()
            check(bluetoothStore.message == failure.localizedDescription && !bluetoothStore.canBind && !bluetoothStore.preparing, "BLE \(failure.rawValue) has recovery message without association")
        }
        faultyBLE.failure = nil; faultyBLE.empty = true; await bluetoothStore.scan()
        check(bluetoothStore.message == RacketFailure.scanEmpty.localizedDescription, "empty BLE scan has explicit retry state")
        let live = RacketStore(defaults: defaults)
        live.configure(context); await live.refresh()
        check(!live.capabilities.hostDiscovery && !live.canUseBluetooth && !live.capabilities.roster && live.message.contains("不可用"), "unimplemented live transport never falls back to mock")
        live.configure(nil); await live.refresh(); check(live.message.contains("登录"), "unauthenticated state is explicit")
        print("PASS: \(count) racket state and integration-boundary checks")
    }
}
