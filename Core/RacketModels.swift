import Foundation

struct RacketPerson: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case user, guest }
    let kind: Kind
    let stableID: String
    let name: String
    var id: String { kind.rawValue + ":" + stableID }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind && lhs.stableID == rhs.stableID }
    func hash(into hasher: inout Hasher) { hasher.combine(kind); hasher.combine(stableID) }
}

enum RacketConnection: String, Codable { case online, offline, unknown }
struct RacketHost: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let connection: RacketConnection
    let observedAt: Date
    func status(at now: Date) -> RacketConnection {
        now.timeIntervalSince(observedAt) >= 0 && now.timeIntervalSince(observedAt) < 60 ? connection : .unknown
    }
}
struct RacketDevice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    var version: Int
    var user: RacketPerson?
    let hostID: String?
    let authenticated: Bool
    let connection: RacketConnection
    let observedAt: Date
    var matchActive: Bool
    var battery: Int? = nil
    func status(at now: Date) -> RacketConnection {
        now.timeIntervalSince(observedAt) >= 0 && now.timeIntervalSince(observedAt) < 60 ? connection : .unknown
    }
    func readiness(for host: String?, at now: Date) -> String {
        guard authenticated else { return "设备尚未认证" }
        guard let hostID else { return "尚未连接计分主机" }
        guard hostID == host else { return "连接了其他主机" }
        switch status(at: now) {
        case .online: return "已连接当前主机 · 名单仍需确认"
        case .offline: return "拍底离线"
        case .unknown: return "连接状态未知，请刷新"
        }
    }
}
struct RacketCapabilities: Equatable {
    var hostDiscovery = false
    var bluetoothDiscovery = false
    var roster = false
    var directConnection = false
    var binding = true
    var unbinding = true
}
/// Immutable request identity. Token is only carried in memory, never encoded in the journal.
struct RacketContext: Equatable {
    let origin: String
    let userID: String
    let token: String
    var hostID: String?
    var userName: String = ""
    var scope: String { [origin, userID, hostID ?? ""].map { "\($0.utf8.count):\($0)" }.joined() }
}
struct RacketInventory {
    let devices: [RacketDevice]
    let people: [RacketPerson]
    var confirmedRosters: [RacketConfirmedRoster] = []
}
struct RacketConfirmedRoster {
    let roster: RacketRoster
    let deviceConfirmationID: String
    let observedAt: Date
}
struct RacketAssignment: Codable, Equatable {
    enum Team: String, Codable { case red, blue }
    let person: RacketPerson
    let team: Team
}
struct RacketRoster: Codable, Equatable {
    let matchKey: String
    let fixtureID: String?
    let expectedVersion: Int
    let players: [RacketAssignment]
    var valid: Bool {
        let red = players.filter { $0.team == .red }.count
        let blue = players.filter { $0.team == .blue }.count
        return !matchKey.isEmpty && players.allSatisfy { !$0.person.stableID.isEmpty } && [1,2].contains(red) && red == blue && Set(players.map { $0.person.id }).count == players.count
            && (fixtureID == nil || players.allSatisfy { $0.person.kind == .user })
    }
}
enum RacketAction: Codable, Equatable {
    // No target user ID: the server MUST resolve bindSelf from the authenticated business session.
    case bindSelf(deviceID: String, expectedVersion: Int, confirmation: String)
    case unbind(deviceID: String, expectedVersion: Int)
    case roster(RacketRoster)
    var resource: String {
        switch self {
        case .bindSelf(let id, _, _), .unbind(let id, _): return "device:" + id
        case .roster(let roster): return "match:" + roster.matchKey
        }
    }
}
enum RacketOperationState: String, Codable {
    case notSubmitted, submitting, awaitingDevice, confirmed, rejected, conflict, expired, unknown
    var label: String {
        switch self {
        case .notSubmitted: return "未提交"
        case .submitting: return "提交中"
        case .awaitingDevice: return "正在等待设备确认"
        case .confirmed: return "设备已确认"
        case .rejected: return "请求被拒绝"
        case .conflict: return "状态版本已变化，请刷新"
        case .expired: return "请求已过期，请先查询实际状态"
        case .unknown: return "结果尚未确认，请查询结果"
        }
    }
    var unresolved: Bool { [.submitting, .awaitingDevice, .unknown].contains(self) }
}
struct RacketOperation: Codable, Identifiable, Equatable {
    let id: UUID
    let scope: String
    let action: RacketAction
    var state: RacketOperationState
    var message: String = ""
}
struct RacketReceipt {
    let operationID: UUID
    let state: RacketOperationState
    /// Authenticated backend must verify device ACK, not just echo HTTP acceptance.
    let deviceConfirmationID: String?
    let error: RacketFailure?
}
struct RacketDeviceConfirmation {
    let deviceID: String
    let proof: String
    let expiresAt: Date
}
/// Diagnostic metadata only: never include payloads, session tokens or device keys.
struct RacketDiagnostic: LocalizedError {
    let stage: String
    let detail: String
    var errorDescription: String? { "拍底验证未完成（" + stage + "）：" + detail }
}

enum RacketFailure: String, Error, LocalizedError, Codable {
    case journalFull
    case unavailable, unauthenticated, forbidden, hostOffline, ownedByOther, pauseRequired, conflict, expired, unknown
    case bluetoothOff, bluetoothDenied, scanEmpty, interrupted, cancelled, verificationFailed, protocolUnavailable, operationNotFound
    var errorDescription: String? {
        switch self {
        case .journalFull: return "拍底的绑定记录已满，当前无法重新绑定。请联系开发者维护设备；重复连接或清除手机数据无法解决。"
        case .unavailable: return "拍底服务尚未接入或暂不可用，请稍后刷新。"
        case .unauthenticated: return "请先完成业务登录。"
        case .forbidden: return "没有权限访问该主机或拍底。"
        case .hostOffline: return "计分主机离线，请检查主机网络后刷新。"
        case .ownedByOther: return "拍底已关联其他使用者，请由有权限的人解除，不能直接抢占。"
        case .pauseRequired: return "拍底正在参与比赛，请先暂停，再按服务端结果操作。"
        case .conflict: return "状态版本冲突，请刷新后重新确认。"
        case .expired: return "操作或设备确认已过期，请查询状态。"
        case .unknown: return "结果尚未确认，请查询原操作，不要重复提交。"
        case .bluetoothOff: return "请开启蓝牙后重试。"
        case .bluetoothDenied: return "蓝牙权限被拒绝，请到系统设置允许访问。"
        case .scanEmpty: return "没有发现拍底，请靠近设备后重试。"
        case .interrupted: return "连接中断，请重新连接并验证设备。"
        case .cancelled: return "操作已取消。"
        case .verificationFailed: return "设备身份验证失败，不能继续关联。"
        case .protocolUnavailable: return "蓝牙协议尚未接入。"
        case .operationNotFound: return "服务端未收到该操作，可以重新连接后重试。"
        }
    }
}

@MainActor protocol RacketService {
    var capabilities: RacketCapabilities { get }
    func hosts(_ context: RacketContext) async throws -> [RacketHost]
    func pendingOperations(_ context: RacketContext) async throws -> [RacketOperation]
    func inventory(_ context: RacketContext) async throws -> RacketInventory
    func confirmDevice(_ id: String, context: RacketContext) async throws -> RacketDeviceConfirmation
    func submit(_ operation: RacketOperation, context: RacketContext) async throws -> RacketReceipt
    func result(_ id: UUID, context: RacketContext) async throws -> RacketReceipt
}
extension RacketService {
    func pendingOperations(_ context: RacketContext) async throws -> [RacketOperation] { [] }
}
struct RacketNearby: Identifiable { let id: String; let label: String }
struct RacketVerifiedNearby { let device: RacketDevice; let confirmation: RacketDeviceConfirmation }
@MainActor protocol RacketBluetoothDiscovery {
    func retainsConnection(for context:RacketContext) -> Bool
    /// Protocol integration availability, not Bluetooth permission/radio state (those are explicit errors).
    var available: Bool { get }
    func scan() async throws -> [RacketNearby]
    /// Firmware adapter owns authentication/provisioning/host selection; advertisement alone is not evidence.
    func verifyAndPrepare(_ candidate: RacketNearby, hostID: String?, context: RacketContext) async throws -> RacketVerifiedNearby
    func cancel()
}
@MainActor final class UnavailableRacketService: RacketService {
    let capabilities = RacketCapabilities()
    func hosts(_ context: RacketContext) async throws -> [RacketHost] { throw RacketFailure.unavailable }
    func inventory(_ context: RacketContext) async throws -> RacketInventory { throw RacketFailure.unavailable }
    func confirmDevice(_ id: String, context: RacketContext) async throws -> RacketDeviceConfirmation { throw RacketFailure.unavailable }
    func submit(_ operation: RacketOperation, context: RacketContext) async throws -> RacketReceipt { throw RacketFailure.unavailable }
    func result(_ id: UUID, context: RacketContext) async throws -> RacketReceipt { throw RacketFailure.unavailable }
}
@MainActor final class UnavailableRacketBluetooth: RacketBluetoothDiscovery {
    let available = false
    func scan() async throws -> [RacketNearby] { throw RacketFailure.protocolUnavailable }
    func verifyAndPrepare(_ candidate: RacketNearby, hostID: String?, context: RacketContext) async throws -> RacketVerifiedNearby { throw RacketFailure.protocolUnavailable }
    func cancel() {}
}

@MainActor extension RacketBluetoothDiscovery { func retainsConnection(for context:RacketContext) -> Bool { false } }
