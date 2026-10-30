import Foundation
import Combine

@MainActor final class RacketStore: ObservableObject {
    @Published private(set) var context: RacketContext?
    @Published private(set) var hosts: [RacketHost] = []
    @Published private(set) var devices: [RacketDevice] = []
    @Published private(set) var people: [RacketPerson] = []
    @Published private(set) var operations: [RacketOperation] = []
    @Published private(set) var message = ""
    @Published private(set) var loading = false
    @Published private(set) var nearby: [RacketNearby] = []
    @Published private(set) var selected: RacketDevice?
    @Published private(set) var preparing = false
    @Published private(set) var rosterDraft: RacketRoster?
    @Published private(set) var confirmedRosters: [RacketConfirmedRoster] = []
    let service: RacketService
    let bluetooth: RacketBluetoothDiscovery
    let simulated: Bool
    private let defaults: UserDefaults
    private var generation = UUID()
    private var refreshID = UUID()
    private var discoveryID = UUID()
    private var confirmation: RacketDeviceConfirmation?
    private var queryIDs: [UUID: UUID] = [:]
    private let timeout: UInt64
    var capabilities: RacketCapabilities { service.capabilities }
    var canUseBluetooth: Bool { capabilities.bluetoothDiscovery && bluetooth.available }

    init(service: RacketService? = nil, bluetooth: RacketBluetoothDiscovery? = nil, defaults: UserDefaults = .standard, simulated: Bool = false, timeout: UInt64 = 20_000_000_000) {
        self.service = service ?? UnavailableRacketService(); self.bluetooth = bluetooth ?? UnavailableRacketBluetooth(); self.defaults = defaults; self.simulated = simulated; self.timeout = timeout
    }
    func configure(_ value: RacketContext?, disconnect: Bool = true) {
        guard context != value else { return }
        if disconnect { bluetooth.cancel() }; generation = UUID(); refreshID = UUID(); discoveryID = UUID()
        context = value; hosts = []; devices = []; people = []; nearby = []; selected = nil; confirmation = nil
        rosterDraft = nil; confirmedRosters = []; loading = false; preparing = false; queryIDs = [:]; message = ""
        operations = value.flatMap { c in
            defaults.data(forKey: journalKey(c)).flatMap { try? JSONDecoder().decode([RacketOperation].self, from: $0) }
        } ?? []
        operations = operations.filter { $0.scope == value?.scope }.map { op in
            var result = op; if result.state.unresolved { result.state = .unknown }; return result
        }
    }
    private var canRetainConnection: Bool {
        guard let context, !operations.contains(where: { $0.state.unresolved }) else { return false }
        return (selected?.authenticated == true && selected?.user?.stableID == context.userID) || bluetooth.retainsConnection(for:context)
    }
    func finishDiscovery() {
        guard context != nil else { return }
        let keep = canRetainConnection
        discoveryID = UUID(); if !keep { bluetooth.cancel() }
        preparing = false; nearby = []; confirmation = nil; selected = nil
    }
    func finishPresentation() {
        let keep = canRetainConnection
        configure(nil,disconnect:!keep)
    }
    private func journalKey(_ c: RacketContext) -> String { "racket.operations.v1." + (simulated ? "mock." : "live.") + c.scope }
    private func persist() {
        guard let context else { return }
        let safe = operations.map { op -> RacketOperation in
            var op = op
            if case .bindSelf(let id, let version, _) = op.action {
                op = RacketOperation(id: op.id, scope: op.scope, action: .bindSelf(deviceID: id, expectedVersion: version, confirmation: ""), state: op.state, message: op.message)
            }
            return op
        }
        if let data = try? JSONEncoder().encode(safe) { defaults.set(data, forKey: journalKey(context)) }
    }
    func selectHost(_ id: String) {
        guard var context else { return }; context.hostID = id; configure(context)
        Task { await refresh() }
    }
    func refresh() async {
        guard let context else { message = RacketFailure.unauthenticated.localizedDescription; return }
        let epoch = generation, read = UUID(); refreshID = read; loading = true
        Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, self.generation == epoch, self.refreshID == read, self.loading else { return }
            self.refreshID = UUID(); self.loading = false; self.hosts = []; self.devices = []; self.people = []; self.confirmedRosters = []; self.selected = nil; self.confirmation = nil
            self.message = "读取超时，连接状态未知，请刷新。"
        }
        defer { if epoch == generation && read == refreshID { loading = false } }
        do {
            let newHosts = try await service.hosts(context)
            guard epoch == generation, read == refreshID else { return }
            hosts = newHosts
            if context.hostID != nil || capabilities.directConnection {
                let inventory = try await service.inventory(context)
                guard epoch == generation, read == refreshID else { return }
                devices = inventory.devices; people = inventory.people; confirmedRosters = inventory.confirmedRosters; message = ""
                if let id = selected?.id { selected = devices.first { $0.id == id } }
            } else { message = hosts.isEmpty ? "没有有权限访问的计分主机。" : "请选择计分主机。" }
        } catch {
            guard epoch == generation, read == refreshID else { return }
            // Stale online states are never retained after a failed read.
            hosts = []; devices = []; people = []; confirmedRosters = []; selected = nil; confirmation = nil
            message = (error as? RacketFailure ?? .unavailable).localizedDescription
        }
        guard epoch == generation else { return }
        do {
            let recovered = try await service.pendingOperations(context)
            guard epoch == generation else { return }
            for op in recovered where op.scope == context.scope && !operations.contains(where: { $0.id == op.id }) { operations.append(op) }
            persist()
        } catch { if epoch == generation { message = "未决操作暂未同步，请刷新后再试。" } }
        guard epoch == generation else { return }
        for op in operations where op.state.unresolved { await query(op.id) }
    }
    func cancelDiscovery() {
        discoveryID = UUID(); bluetooth.cancel(); preparing = false; nearby = []; confirmation = nil; selected = nil
    }
    func scan() async {
        guard context != nil, canUseBluetooth, !preparing else { return }
        cancelDiscovery(); let epoch = generation, run = discoveryID; preparing = true
        expireDiscovery(run, epoch: epoch)
        defer { if epoch == generation && run == discoveryID { preparing = false } }
        do {
            let rows = try await bluetooth.scan()
            guard epoch == generation, run == discoveryID else { return }
            nearby = rows; message = rows.isEmpty ? RacketFailure.scanEmpty.localizedDescription : "请选择拍底，连接后还需验证设备身份。"
        } catch { if epoch == generation && run == discoveryID { message = (error as? RacketFailure ?? .interrupted).localizedDescription } }
    }
    func choose(_ device: RacketDevice) async {
        guard let context, !preparing else { return }
        selected = device; confirmation = nil; preparing = true
        let epoch = generation, run = UUID(); discoveryID = run
        expireDiscovery(run, epoch: epoch)
        defer { if epoch == generation && run == discoveryID { preparing = false } }
        do {
            let proof = try await service.confirmDevice(device.id, context: context)
            guard epoch == generation, run == discoveryID else { return }
            guard proof.deviceID == device.id, proof.expiresAt > Date(), !proof.proof.isEmpty, device.authenticated else { throw RacketFailure.verificationFailed }
            confirmation = proof; message = "设备已确认，请核对当前账号后关联。"
        } catch { if epoch == generation && run == discoveryID { message = (error as? RacketDiagnostic)?.localizedDescription ?? (error as? RacketFailure ?? .verificationFailed).localizedDescription } }
    }
    func chooseNearby(_ candidate: RacketNearby) async {
        guard let context, canUseBluetooth, !preparing else { return }
        confirmation = nil; selected = nil; preparing = true
        let epoch = generation, run = UUID(); discoveryID = run
        expireDiscovery(run, epoch: epoch)
        defer { if epoch == generation && run == discoveryID { preparing = false } }
        do {
            let verified = try await bluetooth.verifyAndPrepare(candidate, hostID: context.hostID, context: context)
            guard epoch == generation, run == discoveryID else { return }
            guard verified.device.authenticated, verified.confirmation.deviceID == verified.device.id,
                  verified.confirmation.expiresAt > Date(), (verified.device.user != nil || !verified.confirmation.proof.isEmpty) else { throw RacketFailure.verificationFailed }
            for operation in operations where operation.state.unresolved && operation.action.resource == "device:" + verified.device.id {
                let receipt = try await service.result(operation.id,context:context)
                guard epoch == generation, run == discoveryID else { return }
                apply(receipt,expected:operation.id)
            }
            selected = verified.device; confirmation = verified.confirmation
            message = verified.device.user == nil ? "设备已验证，请核对账号后关联。" : "设备已验证，显示当前使用者。"
        } catch { if epoch == generation && run == discoveryID { message = (error as? RacketDiagnostic)?.localizedDescription ?? (error as? RacketFailure ?? .verificationFailed).localizedDescription } }
    }
    func operation(for resource: String) -> RacketOperation? { operations.last { $0.action.resource == resource } }
    var canBind: Bool {
        guard capabilities.binding, let context, let selected, selected.user == nil, selected.authenticated, !selected.matchActive,
              let confirmation, confirmation.deviceID == selected.id, confirmation.expiresAt > Date() else { return false }
        return !operations.contains { $0.scope == context.scope && $0.action.resource == "device:" + selected.id && $0.state.unresolved }
    }
    func bindSelf() async {
        guard canBind, let device = selected, let confirmation else { return }
        await submit(.bindSelf(deviceID: device.id, expectedVersion: device.version, confirmation: confirmation.proof))
    }
    func unbind(_ device: RacketDevice) async {
        guard capabilities.unbinding else { message = RacketFailure.protocolUnavailable.localizedDescription; return }
        guard let context, device.user?.kind == .user, device.user?.stableID == context.userID else { message = RacketFailure.ownedByOther.localizedDescription; return }
        guard !device.matchActive else { message = RacketFailure.pauseRequired.localizedDescription; return }
        await submit(.unbind(deviceID: device.id, expectedVersion: device.version))
    }
    func setRoster(_ roster: RacketRoster) { rosterDraft = roster }
    func submitRoster() async {
        guard capabilities.roster, let rosterDraft, rosterDraft.valid else { message = "请为两队选择不同的稳定身份；单打各一人，双打各两人。"; return }
        await submit(.roster(rosterDraft))
    }
    var rosterConfirmed: Bool {
        guard let context, hosts.contains(where: { $0.id == context.hostID && $0.status(at: Date()) == .online }) else { return false }
        guard let rosterDraft else { return false }
        return confirmedRosters.contains {
            $0.roster == rosterDraft && !$0.deviceConfirmationID.isEmpty && (0..<60).contains(Date().timeIntervalSince($0.observedAt))
        }
    }
    func submit(_ action: RacketAction) async {
        guard let context, !operations.contains(where: { $0.action.resource == action.resource && $0.state.unresolved }) else { return }
        let epoch = generation
        let op = RacketOperation(id: UUID(), scope: context.scope, action: action, state: .submitting)
        operations.append(op); persist(); expireWait(op.id, epoch: epoch)
        do {
            let receipt = try await service.submit(op, context: context)
            guard epoch == generation else { return }
            apply(receipt, expected: op.id)
            if operations.first(where: { $0.id == op.id })?.state == .awaitingDevice { poll(op.id, epoch: epoch) }
        } catch {
            guard epoch == generation else { return }
            // Transport failure does not prove rejection. Query this exact operation ID.
            mark(op.id, .unknown, (error as? RacketFailure ?? .unknown).localizedDescription)
        }
    }
    func query(_ id: UUID) async {
        guard let context, let op = operations.first(where: { $0.id == id }), queryIDs[id] == nil else { return }
        let epoch = generation, query = UUID(); queryIDs[id] = query
        Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, self.generation == epoch, self.queryIDs[id] == query else { return }
            self.queryIDs[id] = nil; self.mark(id, .unknown, RacketFailure.unknown.localizedDescription)
        }
        defer { if epoch == generation, queryIDs[id] == query { queryIDs[id] = nil } }
        do {
            let receipt = try await service.result(op.id, context: context)
            guard epoch == generation, queryIDs[id] == query else { return }; apply(receipt, expected: id)
        } catch { if epoch == generation, queryIDs[id] == query, op.state.unresolved { mark(id, .unknown, (error as? RacketFailure ?? .unknown).localizedDescription) } }
    }
    private func apply(_ receipt: RacketReceipt, expected: UUID) {
        guard receipt.operationID == expected, let op = operations.first(where: { $0.id == expected }), op.state.unresolved else { return }
        var state = receipt.state
        if state == .confirmed && (receipt.deviceConfirmationID ?? "").isEmpty { state = .unknown }
        if [.notSubmitted, .submitting].contains(state) { state = .awaitingDevice }
        // A late HTTP acceptance must not restart an elapsed operation deadline.
        // Only an authoritative terminal result may resolve an unknown outcome.
        if op.state == .unknown && state.unresolved { return }
        mark(expected, state, receipt.error?.localizedDescription ?? "")
        if state == .confirmed { Task { await refresh() } }
    }
    private func mark(_ id: UUID, _ state: RacketOperationState, _ detail: String) {
        guard let index = operations.firstIndex(where: { $0.id == id }), operations[index].state.unresolved else { return }
        operations[index].state = state; operations[index].message = detail; persist()
    }
    private func expireWait(_ id: UUID, epoch: UUID) {
        Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, self.generation == epoch else { return }
            self.mark(id, .unknown, RacketFailure.unknown.localizedDescription)
        }
    }
    private func expireDiscovery(_ id: UUID, epoch: UUID) {
        Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, self.generation == epoch, self.discoveryID == id, self.preparing else { return }
            self.cancelDiscovery(); self.message = "设备确认或扫描超时，请重试。"
        }
    }
    private func poll(_ id: UUID, epoch: UUID) {
        Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.generation == epoch, self.operations.first(where: { $0.id == id })?.state == .awaitingDevice else { return }
                await self.query(id)
            }
        }
    }
}
