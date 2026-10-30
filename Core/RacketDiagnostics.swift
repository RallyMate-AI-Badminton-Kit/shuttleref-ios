import Foundation

/// Structured allowlist only: never accepts request bodies, tokens or arbitrary error text.
struct RacketDiagnostics {
    enum Event: String { case request, http, bleReply, bind, query, connected, disconnected, failed }
    private(set) var lines: [String] = []
    mutating func record(_ event:Event, operation:String? = nil, device:String? = nil,
                         code:String? = nil, status:Int? = nil, length:Int? = nil,
                         version:Int? = nil, kind:Int? = nil, bound:Int? = nil,
                         before:UInt32? = nil, after:UInt32? = nil) {
        var fields = [ISO8601DateFormatter().string(from:Date()),event.rawValue]
        if let operation, UUID(uuidString:operation) != nil { fields.append("operation="+operation.lowercased()) }
        if let device, device.utf8.count == 12, device.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { fields.append("device="+device) }
        let allowedCodes: Set<String> = ["AUTH","BIND","UNBIND","QUERY","RESPONSE","READ","NETWORK","BLE_CONNECTED","BLE_DISCONNECT","BLE_SYSTEM","BLE_STATE","PENDING","CONFIRMED","REJECTED","AUTHENTICATED","INVALID_DEVICE_RESPONSE","RESULT_CONFLICT","VERSION_CONFLICT","OPERATION_PENDING","OPERATION_ID_REUSED","PROOF_INVALID","PROOF_SCOPE_MISMATCH","CHALLENGE_EXPIRED","OWNED_BY_OTHER","NOT_FOUND","FORBIDDEN","BLE_DEVICE_FORBIDDEN","BLE_BIND_DISABLED","BLE_CAPABILITY_UNAVAILABLE","HOST_ASSOCIATION_EXISTS","INVALID_REQUEST","NOT_APPLIED_AFTER_RECONNECT","JOURNAL_FULL","ARCHIVE_RESPONSE","ARCHIVE_DISABLED","ARCHIVE_HISTORY_GAP","ARCHIVE_HISTORY_CONFLICT","ARCHIVE_SUMMARY_REQUIRED","ARCHIVE_NOT_ELIGIBLE","ARCHIVE_PENDING","OBSERVED","UNKNOWN","SUPERSEDED","HISTORY_UNAVAILABLE"]
        if let code, !code.isEmpty { fields.append("code=" + (allowedCodes.contains(code) ? code:"OTHER")) }

        for (key,value) in [("status",status),("length",length),("version",version),("kind",kind),("bound",bound)] { if let value { fields.append("\(key)=\(value)") } }
        if let before { fields.append("before_revision=\(before)") }; if let after { fields.append("after_revision=\(after)") }
        lines.append(fields.joined(separator:" "))
        if lines.count > 200 { lines.removeFirst(lines.count-200) }
    }
    func report() -> String { "羽小裁 · 拍底诊断 v1\n仅含结构化阶段、操作编号、公开设备编号、状态码及版本；不含登录或设备密钥。\n" + (lines.isEmpty ? "本次启动尚无记录":lines.joined(separator:"\n")) }
}
