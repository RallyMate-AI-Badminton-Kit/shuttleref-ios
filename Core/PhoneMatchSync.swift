import Foundation

enum PhoneSyncResult {
    case accepted(matchID: String, revision: UInt32, installation: String)
    case conflict
    case unavailable
}
@MainActor protocol MatchSyncService {
    /// Authentication comes from the adapter's business session, never the envelope.
    func upload(_ envelope: PhoneSyncEnvelope, operationID: String, scope: PhoneMatchScope) async throws -> PhoneSyncResult
}
@MainActor struct UnavailablePhoneMatchSync: MatchSyncService {
    func upload(_ envelope: PhoneSyncEnvelope, operationID: String, scope: PhoneMatchScope) async throws -> PhoneSyncResult { .unavailable }
}

/// Owned by the account's controller, not by the scoring page or BLE connection.
/// Credential renewal replaces the uploader without recreating the local writer.
@MainActor final class PhoneSyncPump {
    private let session: PhoneMatchSession
    private var service: MatchSyncService
    private var task: Task<Void,Never>?
    private var generation=UUID()
    init(session: PhoneMatchSession, service: MatchSyncService) { self.session=session;self.service=service }
    func update(service: MatchSyncService) { stop();self.service=service }
    func flush() async throws { try await session.synchronize(using:service) }
    func start(status: @escaping (String) -> Void) {
        stop();let epoch=generation
        task=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.generation==epoch else { return }
                do {
                    if try self.session.syncState()=="pending" { status("本机已保存 · 正在上传") }
                    try await self.flush()
                    guard !Task.isCancelled,self.generation==epoch else { return }
                    status(try self.currentMessage())
                } catch { if !Task.isCancelled,self.generation==epoch { status("本机已保存 · 尚未同步："+error.localizedDescription) } }
                try? await Task.sleep(nanoseconds:3_000_000_000)
            }
        }
    }
    func currentMessage() throws -> String {
        switch try session.syncState() {
        case "synced":return "云端已接收 · 可授权其他手机观赛"
        case "conflict":return "云端同步冲突 · 本机比分已保留，请核对原比赛"
        default:return "比分已保存本机，等待同步。"
        }
    }
    func stop() { generation=UUID();task?.cancel();task=nil }
}
