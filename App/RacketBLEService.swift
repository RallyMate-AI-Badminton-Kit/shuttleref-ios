import Foundation

private final class RacketNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Test-firmware adapter. No device key or HMAC implementation exists in the app.
@MainActor final class RacketBLEService: RacketService, RacketBluetoothDiscovery {
    let transport: RacketBLETransport
    let available = true
    private let registryConnection = UUID()
    private let http = URLSession(configuration: .ephemeral, delegate: RacketNoRedirect(), delegateQueue: nil)
    private var journalFull = false
    let bindingEnabled: Bool
    private let v2: Bool
    private(set) var authenticatedScoreOwner: String?
    private var activeProof: String?
    private var candidate: RacketNearby?
    var connectedCandidate: RacketNearby? { transport.isConnected ? candidate:nil }
    func retainsConnection(for context:RacketContext) -> Bool { hasOwnedConnection(context) }
    func hasOwnedConnection(_ context:RacketContext) -> Bool {
        guard active?.origin == context.origin, active?.userID == context.userID,
              transport.isConnected, let current else { return false }
        return KnownRacketRegistry.devices(context).contains { $0.id == current.deviceID && $0.user?.stableID == context.userID }
    }
    private var epoch = UUID()
    private var active: RacketContext?
    private var current: RacketBLEWire.Info?
    var capabilities: RacketCapabilities { RacketCapabilities(hostDiscovery: false, bluetoothDiscovery: true, roster: false, directConnection: true, binding: bindingEnabled && !journalFull, unbinding: v2 && bindingEnabled && !journalFull) }
    init(bindingEnabled: Bool = false, v2: Bool = false) { self.bindingEnabled = bindingEnabled; self.v2 = v2; self.transport = RacketBLETransport(v2: v2)
        transport.connectionEnded = { [weak self] in if let self { KnownRacketRegistry.disconnected(self.registryConnection) } }
    }
    func cancel() { epoch = UUID(); active = nil; current = nil; authenticatedScoreOwner = nil; activeProof = nil; candidate = nil; transport.cancel() }
    func scan() async throws -> [RacketNearby] {
        guard transport.scoreNotification == nil else { throw RacketFailure.pauseRequired }
        return try await transport.scan()
    }
    func confirmConnection(_ context:RacketContext) async -> Bool {
        guard active?.origin == context.origin, active?.userID == context.userID,
              transport.isConnected, let previous = current else {
            KnownRacketRegistry.disconnected(registryConnection); return false
        }
        do {
            let live = try await transport.currentInfo()
            guard live.deviceID == previous.deviceID, live.session == previous.session, live.bound,
                  live.revision == previous.revision else {
                KnownRacketRegistry.disconnected(registryConnection); return false
            }
            KnownRacketRegistry.connected(live.deviceID,context:context,connection:registryConnection)
            return true
        } catch { KnownRacketRegistry.disconnected(registryConnection); return false }
    }
    private func activate(_ context: RacketContext) {
        if active != context { epoch = UUID(); current = nil; authenticatedScoreOwner = nil; activeProof = nil; candidate = nil; active = context }
    }
    private func call(_ path: String, context: RacketContext, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard active == context else { throw RacketFailure.cancelled }
        let run = epoch
        let operation = (body?["operation_id"] as? String) ?? path.split(separator:"/").map(String.init).first(where:{ UUID(uuidString:$0) != nil })
        let route = path == "/confirm" ? "AUTH" : path == "/associate-me" ? "BIND" : path == "/unbind-me" ? "UNBIND" : path.hasSuffix("/query") ? "QUERY" : path.hasSuffix("/response") ? "RESPONSE" : "READ"
        RacketDiagnosticLog.shared.record(.request,operation:operation,device:body?["device_id"] as? String,code:route)
        guard let origin = URL(string: context.origin), origin.scheme == "https" || origin.scheme == "http",
              let url = URL(string: context.origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/social/racket-ble" + (v2 ? "/v2" : "") + path) else { throw RacketFailure.unavailable }
        if v2 && origin.scheme != "https" { throw RacketFailure.unavailable }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        request.setValue("Bearer " + context.token, forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data; let response: URLResponse
        do { (data,response) = try await http.data(for:request) }
        catch { RacketDiagnosticLog.shared.record(.failed,operation:operation,code:"NETWORK",status:(error as NSError).code); throw error }
        guard epoch == run, active == context else { throw RacketFailure.cancelled }
        guard let response = response as? HTTPURLResponse else { throw RacketFailure.unavailable }
        guard response.statusCode == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (error?["error"] as? [String: Any])?["code"] as? String ?? ""
            RacketDiagnosticLog.shared.record(.http,operation:operation,code:code,status:response.statusCode)
            if code.hasPrefix("ARCHIVE_") {
                let detail = code == "ARCHIVE_DISABLED" ? "归档回收尚未开放；可以检查容量，设备记录不会被删除。" : code == "ARCHIVE_HISTORY_GAP" ? "后端历史不完整，已停止归档，请联系开发者恢复账本。" : code == "ARCHIVE_PENDING" ? "已有归档批次未确认，请先查询原结果。" : "归档条件尚未满足（"+code+"）。"
                throw RacketDiagnostic(stage:"回执维护",detail:detail)
            }
            if code == "SCORE_BUSY" { throw RacketFailure.pauseRequired }
            if code.hasPrefix("MODE_") || code == "FRESH_AUTH_REQUIRED" || code == "DUAL_HOST_DISABLED" || code == "PROFILE_UNAVAILABLE" {
                throw RacketDiagnostic(stage:"主机配置",detail:code == "FRESH_AUTH_REQUIRED" ? "请重新连接并认证拍底。" : code == "DUAL_HOST_DISABLED" ? "实验配网尚未开放。" : "配置条件尚未满足（"+code+"），请查询当前状态。")
            }
            if response.statusCode == 401 { throw RacketFailure.unauthenticated }
            if code == "OWNED_BY_OTHER" { throw RacketFailure.ownedByOther }
            if response.statusCode == 403 { throw RacketFailure.forbidden }
            if response.statusCode == 404 && code == "NOT_FOUND" { throw RacketFailure.operationNotFound }
            if code == "CHALLENGE_EXPIRED" || code == "PROOF_INVALID" { throw RacketFailure.expired }
            if response.statusCode == 409 { throw RacketFailure.conflict }
            throw RacketDiagnostic(stage: "认证服务", detail: "HTTP \(response.statusCode)，请检查业务服务器地址和服务状态。")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RacketFailure.verificationFailed }
        RacketDiagnosticLog.shared.record(.http,operation:operation,code:(object["status"] as? String)?.uppercased(),status:response.statusCode)
        return object
    }
    private func device(_ value: Any) throws -> RacketDevice {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(RacketDevice.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func hosts(_ context: RacketContext) async throws -> [RacketHost] { activate(context); return [] }
    func pendingOperations(_ context: RacketContext) async throws -> [RacketOperation] {
        let reply = try await call("/operations", context: context)
        return (reply["operations"] as? [[String: Any]] ?? []).compactMap { item in
            guard let text = item["operation_id"] as? String, let id = UUID(uuidString: text), let device = item["device_id"] as? String else { return nil }
            return RacketOperation(id: id, scope: context.scope, action: .bindSelf(deviceID: device, expectedVersion: 0, confirmation: ""), state: .unknown)
        }
    }
    func inventory(_ context: RacketContext) async throws -> RacketInventory {
        let response = try await call("/devices", context: context)
        let devices = try (response["devices"] as? [Any] ?? []).map { try device($0) }
        KnownRacketRegistry.replace(devices,context:context)
        for row in devices where row.id == current?.deviceID { KnownRacketRegistry.remember(row,peripheral:candidate?.id,context:context) }
        return RacketInventory(devices: devices, people: devices.compactMap(\.user))
    }
    /// The App relays opaque signed messages; it never chooses a deletion prefix.
    func modeRequest(_ path:String,body:[String:Any]? = nil,context:RacketContext) async throws -> [String:Any] {
        try await call("/mode"+path,context:context,body:body)
    }
    func forwardMode(_ command:Data,operation:String,context:RacketContext) async throws -> [String:Any] {
        let run=epoch
        let response=try await transport.exchangeMode(command)
        guard run==epoch,active==context else { throw RacketFailure.cancelled }
        return try await call("/mode/"+operation+"/response",context:context,body:["response":response.base64EncodedString()])
    }
    func archiveRequest(_ path:String,body:[String:Any],context:RacketContext) async throws -> [String:Any] {
        guard transport.scoreNotification == nil, transport.isConnected else { throw RacketFailure.pauseRequired }
        activate(context)
        return try await call("/archive"+path,context:context,body:body)
    }
    func archiveResult(_ id:String,context:RacketContext) async throws -> [String:Any] {
        activate(context)
        return try await call("/archive/"+id,context:context)
    }
    func archiveRoundtrip(_ path:String,body:[String:Any],context:RacketContext,willForward:(() -> Void)? = nil) async throws -> [String:Any] {
        activate(context);let generation=epoch
        let issued=try await archiveRequest(path,body:body,context:context)
        guard epoch==generation,active==context else {throw RacketFailure.cancelled}
        guard let id=issued["operation_id"] as? String, let encoded=issued["command"] as? String,
              let command=Data(base64Encoded:encoded) else { return issued }
        willForward?()
        let response=try await transport.exchangeArchive(command)
        RacketDiagnosticLog.shared.record(.bleReply,operation:id,code:"ARCHIVE_RESPONSE",status:Int(response[2]),length:response.count,version:Int(response[0]),kind:Int(response[1]),bound:Int(response[93]))
        guard epoch==generation,active==context else {throw RacketFailure.cancelled}
        return try await call("/archive/"+id+"/response",context:context,body:["response":response.base64EncodedString()])
    }
    func confirmDevice(_ id: String, context: RacketContext) async throws -> RacketDeviceConfirmation { throw RacketFailure.protocolUnavailable }
    func verifyAndPrepare(_ candidate: RacketNearby, hostID: String?, context: RacketContext) async throws -> RacketVerifiedNearby {
        guard transport.scoreNotification == nil else { throw RacketFailure.pauseRequired }
        activate(context); let run = epoch
        var stage = "蓝牙连接 / 读取 INFO"
        do {
        let info: RacketBLEWire.Info
        if self.candidate?.id == candidate.id && transport.isConnected { info = try await transport.currentInfo() }
        else { info = try await transport.connect(candidate) }
        self.candidate = candidate
        guard epoch == run, active == context else { throw RacketFailure.cancelled }
        current = info
        if v2 {
            stage = "恢复尚未确认的操作"
            for operation in try await pendingOperations(context) {
                if case .bindSelf(let device, _, _) = operation.action, device == info.deviceID {
                    let receipt = try await result(operation.id, context: context)
                    // Query the original ACK first; unknown must not prevent a fresh signed AUTH.
                    if receipt.state == .rejected { continue }
                }
            }
        }
        let id = UUID().uuidString.lowercased()
        stage = "获取后端认证挑战"
        let challenge = try await call("/confirm", context: context, body: ["operation_id": id, "device_id": info.deviceID, "session": info.session, "expected_revision": info.revision])
        stage = "蓝牙认证分帧交换"
        let response = try await relay(challenge)
        guard epoch == run, active == context else { throw RacketFailure.cancelled }
        stage = "后端校验设备回执"
        let verified = try await call("/confirmations/\(id)/response", context: context, body: ["response": response])
        if verified["bound"] as? Bool == true && !v2 {
            for operation in try await pendingOperations(context) {
                if case .bindSelf(let device, _, _) = operation.action, device == info.deviceID { _ = try await result(operation.id, context: context) }
            }
            let inventory = try await inventory(context)
            guard let owned = inventory.devices.first(where: { $0.id == info.deviceID && $0.user?.stableID == context.userID }) else { throw RacketFailure.unknown }
            return RacketVerifiedNearby(device: owned, confirmation: RacketDeviceConfirmation(deviceID: owned.id, proof: "", expiresAt: .distantPast))
        }
        if v2 {
            stage = "核对重新认证后的未决操作"
            for operation in try await pendingOperations(context) {
                if case .bindSelf(let device, _, _) = operation.action, device == info.deviceID {
                    let receipt = try await result(operation.id,context:context)
                    guard receipt.state == .confirmed || receipt.state == .rejected else { throw RacketFailure.unknown }
                }
            }
        }
        // Only consume the device owner after backend validation of this signed response.
        if v2, let bytes = Data(base64Encoded:response), bytes.count == 164, bytes[3] == 1 {
            let compact = bytes[90..<106].map { String(format:"%02x",$0) }.joined()
            authenticatedScoreOwner = RacketScoreWire.identityUUID(compact)
        } else { authenticatedScoreOwner = nil }
        stage = "解析已认证设备信息"
        guard let rawDevice = verified["device"] else { throw RacketFailure.verificationFailed }
        let proof = verified["proof"] as? String ?? ""
        activeProof = proof.isEmpty ? nil : proof
        var row = try device(rawDevice)
        guard row.user != nil || !proof.isEmpty else { throw RacketFailure.verificationFailed }
        // Authenticated backend fact; the live BLE connection is separate from host readiness.
        row = RacketDevice(id: row.id, name: row.name, version: row.version, user: row.user, hostID: nil, authenticated: true, connection: .online, observedAt: Date(), matchActive: false)
        KnownRacketRegistry.remember(row,peripheral:candidate.id,context:context)
        KnownRacketRegistry.connected(row.id,context:context,connection:registryConnection)
        return RacketVerifiedNearby(device: row, confirmation: RacketDeviceConfirmation(deviceID: row.id, proof: proof, expiresAt: Date().addingTimeInterval(55)))
        } catch let error as RacketDiagnostic { throw error }
        catch {
            let detail: String
            if let known = error as? RacketFailure { detail = known.localizedDescription }
            else if error is DecodingError { detail = "服务端设备信息格式不匹配。" }
            else { let native = error as NSError; detail = "系统错误 \(native.domain) / \(native.code)" }
            throw RacketDiagnostic(stage: stage, detail: detail)
        }
    }
    private func relay(_ value: [String: Any]) async throws -> String {
        guard let encoded = value["command"] as? String, let command = Data(base64Encoded: encoded), command.count == (v2 ? 140 : 124) else { throw RacketFailure.verificationFailed }
        let reply = try await transport.exchange(command)
        let bytes = [UInt8](reply)
        func revision(_ start:Int) -> UInt32? {
            guard bytes.count >= start+4 else { return nil }
            return bytes[start..<start+4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        RacketDiagnosticLog.shared.record(.bleReply,operation:value["operation_id"] as? String,
            status:bytes.count > 2 ? Int(bytes[2]):nil,length:bytes.count,version:bytes.first.map(Int.init),
            kind:bytes.count > 1 ? Int(bytes[1]):nil,bound:bytes.count > 3 ? Int(bytes[3]):nil,
            before:v2 ? revision(106):nil,after:v2 ? revision(110):nil)
        return reply.base64EncodedString()
    }
    func submit(_ operation: RacketOperation, context: RacketContext) async throws -> RacketReceipt {
        guard bindingEnabled else { throw RacketFailure.protocolUnavailable }
        let id: String, revision: Int, proof: String, path: String
        switch operation.action {
        case .bindSelf(let device, let version, let confirmation): id = device; revision = version; proof = confirmation; path = "/associate-me"
        case .unbind(let device, let version):
            guard v2 else { throw RacketFailure.protocolUnavailable }
            guard let candidate else { throw RacketFailure.interrupted }
            let info = try await transport.reconnect(candidate)
            guard info.deviceID == device, info.revision == version else { throw RacketFailure.conflict }
            current = info
            let authID = UUID().uuidString.lowercased()
            let challenge = try await call("/confirm", context: context, body: ["operation_id": authID, "device_id": device, "session": info.session, "expected_revision": version])
            let response = try await relay(challenge)
            let verified = try await call("/confirmations/\(authID)/response", context: context, body: ["response": response])
            guard verified["bound"] as? Bool == true, let freshProof = verified["proof"] as? String else { throw RacketFailure.verificationFailed }
            id = device; revision = version; proof = freshProof; path = "/unbind-me"
        default: throw RacketFailure.protocolUnavailable
        }
        guard let current, current.deviceID == id else { throw RacketFailure.interrupted }
        let oid = operation.id.uuidString.lowercased()
        let command = try await call(path, context: context, body: ["operation_id": oid, "device_id": id, "session": current.session, "expected_revision": revision, "proof": proof])
        activeProof = nil
        if command["status"] as? String != "pending" { return try receipt(command, id: operation.id) }
        let response = try await relay(command)
        guard active == context else { throw RacketFailure.cancelled }
        let result = try receipt(await call("/operations/\(oid)/response", context: context, body: ["response": response]), id: operation.id)
        if result.state == .confirmed { self.current = try? await transport.currentInfo(); _ = try? await inventory(context) }
        return result
    }
    func result(_ id: UUID, context: RacketContext) async throws -> RacketReceipt {
        let oid = id.uuidString.lowercased()
        let value: [String: Any]
        do { value = try await call("/operations/\(oid)", context: context) }
        catch RacketFailure.operationNotFound where v2 {
            return RacketReceipt(operationID: id, state: .rejected, deviceConfirmationID: nil, error: .operationNotFound)
        }
        if value["status"] as? String == "pending", let info = try? await transport.currentInfo(), info.deviceID == value["device_id"] as? String {
            let query = try await call("/operations/\(oid)/query", context: context, body: ["session": info.session])
            if query["command"] == nil { return try receipt(query, id: id) }
            let response = try await relay(query)
            return try receipt(await call("/operations/\(oid)/response", context: context, body: ["response": response]), id: id)
        }
        return try receipt(value, id: id)
    }
    private func receipt(_ value: [String: Any], id: UUID) throws -> RacketReceipt {
        guard value["operation_id"] as? String == id.uuidString.lowercased(), let status = value["status"] as? String else { throw RacketFailure.verificationFailed }
        let state: RacketOperationState
        switch status { case "pending": state = .awaitingDevice; case "confirmed": state = .confirmed; case "rejected": state = .rejected; case "conflict": state = .conflict; case "expired": state = .expired; default: state = .unknown }
        let full = value["reason"] as? String == "JOURNAL_FULL"
        if full { journalFull = true }
        return RacketReceipt(operationID: id, state: state, deviceConfirmationID: value["ack_id"] as? String, error: full ? .journalFull : (value["reason"] as? String == "SCORE_BUSY" ? .pauseRequired:nil))
    }
}

/// One live central/transport per business account, shared by presentation and scoring.
@MainActor final class RacketBLEConnectionHub {
    static let shared = RacketBLEConnectionHub()
    private var scope: String?
    private var current = RacketBLEService(bindingEnabled:true,v2:true)
    func service(for context:RacketContext? = nil) -> RacketBLEService {
        guard let context else { return current }
        let key = context.origin + "|" + context.userID
        if let scope, scope != key { RacketDiagnosticLog.shared.reset(); current.cancel(); current = RacketBLEService(bindingEnabled:true,v2:true) }
        scope = key; return current
    }
    func reset() { current.cancel(); scope = nil }
}
