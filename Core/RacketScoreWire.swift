import Foundation

enum PhoneScoreError: Error { case configurationRejected, invalidWire, invalidState, protocolConflict, storageFailed, storageUncertain, staleWriter, unavailable }
enum RacketScoreValue: Equatable { case text(String), number(UInt32) }
struct RacketScoreMessage: Equatable {
    let fields: [String: RacketScoreValue]
    var type: String { text("type") }
    func text(_ key: String) -> String { if case .text(let s) = fields[key] { return s }; return "" }
    func number(_ key: String) -> UInt32 { if case .number(let n) = fields[key] { return n }; return 0 }
}
struct RacketScoreInfo { let capabilities: UInt8; let device: String; let boot: String }
struct RacketScoreState { let phase: UInt8; let seq: UInt32; let lease: UInt32; let boot: String }

/// Isolated draft v0.1. Not a replacement for v2 identity authentication.
enum RacketScoreWire {
    static let service = "7a6e3000-6c7d-4c8a-9b12-01d40a521001"
    static let infoCharacteristic = "7a6e3001-6c7d-4c8a-9b12-01d40a521001"
    static let controlCharacteristic = "7a6e3002-6c7d-4c8a-9b12-01d40a521001"
    static let eventCharacteristic = "7a6e3003-6c7d-4c8a-9b12-01d40a521001"
    static let stateCharacteristic = "7a6e3004-6c7d-4c8a-9b12-01d40a521001"
    static func hex(_ s: String, count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func identityUUID(_ s: String) -> String? {
        if uuid(s) { return s }
        guard hex(s,count:32) else { return nil }
        let a = Array(s)
        let value = [String(a[0..<8]),String(a[8..<12]),String(a[12..<16]),String(a[16..<20]),String(a[20..<32])].joined(separator:"-")
        return uuid(value) ? value:nil
    }
    static func uuid(_ s: String) -> Bool { UUID(uuidString:s)?.uuidString.lowercased() == s }
    static func info(_ data: Data) throws -> RacketScoreInfo {
        let b = [UInt8](data)
        guard b.count == 20, b[0] == 1, b[1] & ~3 == 0, b[16] == 2, b[17] == 0,
              b[18] == 20, b[19] == 0 else { throw PhoneScoreError.invalidWire }
        return RacketScoreInfo(capabilities:b[1], device:hexBytes(b[2..<8]), boot:hexBytes(b[8..<16]))
    }
    static func state(_ data: Data) throws -> RacketScoreState {
        let b = [UInt8](data)
        guard b.count == 20, b[0] == 1, b[1] <= 4, b[18] == 0, b[19] == 0 else { throw PhoneScoreError.invalidWire }
        return RacketScoreState(phase:b[1], seq:u32(b[2..<6]), lease:u32(b[6..<10]), boot:hexBytes(b[10..<18]))
    }
    private static func hexBytes(_ bytes: ArraySlice<UInt8>) -> String { bytes.map { String(format:"%02x",$0) }.joined() }
    private static func u32(_ b: ArraySlice<UInt8>) -> UInt32 { b.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func decode(_ data: Data) throws -> RacketScoreMessage {
        guard (1...512).contains(data.count), String(data:data,encoding:.utf8) != nil else { throw PhoneScoreError.invalidWire }
        var parser = FlatJSON(bytes:[UInt8](data))
        let message = RacketScoreMessage(fields:try parser.parse())
        try validate(message); return message
    }
    static func message(_ type: String, text: [String:String] = [:], numbers: [String:UInt32] = [:]) throws -> RacketScoreMessage {
        var fields: [String:RacketScoreValue] = ["v":.number(1),"type":.text(type)]
        for (k,v) in text { guard fields[k] == nil else { throw PhoneScoreError.invalidWire }; fields[k] = .text(v) }
        for (k,v) in numbers { guard fields[k] == nil else { throw PhoneScoreError.invalidWire }; fields[k] = .number(v) }
        let m = RacketScoreMessage(fields:fields); _ = try encode(m); return m
    }
    static func encode(_ m: RacketScoreMessage) throws -> Data {
        try validate(m)
        let values: [String:Any] = m.fields.mapValues { value in
            switch value { case .text(let s): return s; case .number(let n): return n }
        }
        let data = try JSONSerialization.data(withJSONObject:values, options:[.sortedKeys,.withoutEscapingSlashes])
        guard data.count <= 512 else { throw PhoneScoreError.invalidWire }; return data
    }
    private static func validate(_ m: RacketScoreMessage) throws {
        let keys: [String:[String]] = [
            "configure":["context","match_id","device","boot","owner","association_revision","side"],
            "configured":["context","status"], "ready":["context","lease"], "stop":["context"],
            "event":["context","seq","lease","action","detected_ms"],
            "ack":["context","seq","status","revision","reason"]]
        guard let required = keys[m.type], Set(m.fields.keys) == Set(required + ["v","type"]),
              m.fields["v"] == .number(1), hex(m.text("context"),count:32) else { throw PhoneScoreError.invalidWire }
        for k in required {
            if ["association_revision","lease","seq","detected_ms","revision"].contains(k) {
                guard case .number = m.fields[k] else { throw PhoneScoreError.invalidWire }
                if ["lease","seq"].contains(k) && m.number(k) == 0 { throw PhoneScoreError.invalidWire }
            } else { guard case .text = m.fields[k] else { throw PhoneScoreError.invalidWire } }
        }
        switch m.type {
        case "configure":
            guard uuid(m.text("match_id")), uuid(m.text("owner")), hex(m.text("device"),count:12),
                  hex(m.text("boot"),count:16), ["r","b"].contains(m.text("side")) else { throw PhoneScoreError.invalidWire }
        case "configured": guard ["ok","rejected"].contains(m.text("status")) else { throw PhoneScoreError.invalidWire }
        case "event": guard ["add","undo"].contains(m.text("action")) else { throw PhoneScoreError.invalidWire }
        case "ack":
            let allowed = ["committed":["ok"], "unknown":["storage_uncertain"],
                           "rejected":["not_ready","stale_lease","match_closed","no_undo","identity_changed","invalid_event","storage_failed"]]
            guard allowed[m.text("status")]?.contains(m.text("reason")) == true else { throw PhoneScoreError.invalidWire }
        default: break
        }
    }
    static func frames(_ data: Data, transaction: UInt8) throws -> [Data] {
        guard (1...512).contains(data.count) else { throw PhoneScoreError.invalidWire }
        let b = [UInt8](data), count = (b.count + 16) / 17
        return (0..<count).map { i in Data([transaction,UInt8(i),UInt8(count)] + b[(i*17)..<min(b.count,(i+1)*17)]) }
    }
}

/// Only flat objects are valid in this protocol. Parse before JSON decoding so duplicate
/// keys (including escaped spellings) cannot be silently overwritten by Foundation.
private struct FlatJSON {
    let bytes: [UInt8]; var i = 0
    mutating func whitespace() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
    mutating func take(_ b: UInt8) throws { whitespace(); guard i < bytes.count, bytes[i] == b else { throw PhoneScoreError.invalidWire }; i += 1 }
    mutating func string() throws -> String {
        whitespace(); let start = i; try take(34)
        while i < bytes.count {
            let b = bytes[i]; i += 1
            if b == 34 { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<i])) }
            if b == 92 { guard i < bytes.count else { throw PhoneScoreError.invalidWire }; i += 1 }
        }
        throw PhoneScoreError.invalidWire
    }
    mutating func parse() throws -> [String:RacketScoreValue] {
        var result: [String:RacketScoreValue] = [:]; try take(123)
        while true {
            let key = try string(); guard result[key] == nil else { throw PhoneScoreError.invalidWire }
            try take(58); whitespace(); guard i < bytes.count else { throw PhoneScoreError.invalidWire }
            if bytes[i] == 34 { result[key] = .text(try string()) }
            else {
                let start = i
                while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
                guard i > start, i-start == 1 || bytes[start] != 48,
                      let n = UInt32(String(decoding:bytes[start..<i],as:UTF8.self)) else { throw PhoneScoreError.invalidWire }
                result[key] = .number(n)
            }
            whitespace(); guard i < bytes.count else { throw PhoneScoreError.invalidWire }
            if bytes[i] == 125 { i += 1; break }; try take(44)
        }
        whitespace(); guard i == bytes.count else { throw PhoneScoreError.invalidWire }; return result
    }
}
struct RacketScoreAssembler {
    private var transaction: UInt8?; private var count: UInt8 = 0; private var next: UInt8 = 0
    private var began: UInt64 = 0; private var buffer = Data()
    mutating func reset() { transaction = nil; count = 0; next = 0; buffer = Data() }
    mutating func append(_ frame: Data, now: UInt64) throws -> Data? {
        let b = [UInt8](frame)
        do {
            guard (4...20).contains(b.count), (1...31).contains(b[2]), b[1] < b[2],
                  b[1] == b[2]-1 || b.count == 20 else { throw PhoneScoreError.invalidWire }
            if b[1] == 0 { reset(); transaction = b[0]; count = b[2]; began = now }
            guard transaction == b[0], count == b[2], next == b[1], now >= began, now-began < 2000 else { throw PhoneScoreError.invalidWire }
            buffer.append(contentsOf:b.dropFirst(3)); next += 1
            guard buffer.count <= 512 else { throw PhoneScoreError.invalidWire }
            if next == count { let complete = buffer; reset(); return complete }; return nil
        } catch { reset(); throw error }
    }
}

extension PhoneScoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .configurationRejected: return "拍底拒绝比赛配置，请重新认证并核对关联身份和版本。"
        case .invalidState: return "比赛上下文未就绪或已失效，请重新连接拍底。"
        case .invalidWire: return "拍底比赛消息格式不匹配。"
        case .protocolConflict: return "拍底消息与已保存结果冲突，请核对比分。"
        case .storageFailed: return "本机数据保存失败。"
        case .storageUncertain: return "本机保存结果尚未确认，请查询结果。"
        case .staleWriter: return "账号或比赛会话已变化，请重新打开球局。"
        case .unavailable: return "当前比赛服务不可用。"
        }
    }
}
