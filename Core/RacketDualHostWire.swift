import Foundation

enum RacketDualHostWire {
    static func pendingKey(origin:String,account:String,device:String) -> String {
        "racket.mode."+[origin,account,device].map { "\($0.utf8.count):\($0)" }.joined()
    }
    static let service="7a6e5000-6c7d-4c8a-9b12-01d40a521001"
    static let rx="7a6e5001-6c7d-4c8a-9b12-01d40a521001"
    static let tx="7a6e5002-6c7d-4c8a-9b12-01d40a521001"
    static func frames(_ command:Data,transaction:UInt8) throws -> [Data] {
        guard command.count==277,command[0]==1,command[1]<=1 else { throw PhoneScoreError.invalidWire }
        return try RacketScoreWire.frames(command,transaction:transaction)
    }
    static func response(_ data:Data,command:Data) throws {
        guard data.count==98,command.count==277,data[0]==1,data[1]<=5,data[2]<=1,data[3]<=2,
              data.subdata(in:8..<24)==command.subdata(in:8..<24),
              data.subdata(in:24..<40)==command.subdata(in:229..<245),
              data.subdata(in:40..<46)==command.subdata(in:2..<8) else { throw PhoneScoreError.invalidWire }
        // Backend verifies signature and mutation nonce/generation; UI never infers success.
    }
}

/// Public, unsigned runtime snapshot. Never used to authorize configuration or scoring.
struct RacketNetworkSnapshot {
    static let characteristic="7a6e5003-6c7d-4c8a-9b12-01d40a521001"
    private let b:[UInt8]
    init(_ data:Data) throws {
        guard (data.count==65 && data.first==1) || (data.count==73 && data.first==2) else { throw PhoneScoreError.invalidWire }
        b=Array(data)
    }
    var targetHost:String { ip(8) }
    var targetPort:UInt32 { number(12,2) }
    var version:UInt8 { b[0] }
    var wifiAttempts:UInt32? { version==2 ? number(65) : nil }
    var lastWiFiAttempt:UInt32? { version==2 ? number(69) : nil }
    var wifiAttemptSummary:String {
        guard let wifiAttempts,let lastWiFiAttempt else { return "当前固件未提供 Wi-Fi 重试计数" }
        return "Wi-Fi 连接请求：\(wifiAttempts) 次 · 最近请求：开机后 \(lastWiFiAttempt) ms"
    }
    private func number(_ at:Int,_ count:Int=4)->UInt32 { b[at..<at+count].reduce(0) { ($0 << 8) | UInt32($1) } }
    private func ip(_ at:Int)->String { b[at..<at+4].map(String.init).joined(separator:".") }
    private func flag(_ mask:UInt8)->Bool { b[14] & mask != 0 }
    var ready:Bool { b[1]==3 && b[14] & 31 == 31 && b[15]==6 && b[19]==2 && b[18] != 2 && number(40)==0 }
    var headline:String {
        if b[1] != 3 { return "拍底尚未连接 Wi-Fi" }
        if !flag(1) { return "拍底身份与保存配置不一致" }
        if !flag(2) { return "Wi-Fi 已连接，等待树莓派连接" }
        if !flag(4) { return "已连接树莓派，等待认证" }
        return ready ? "拍底报告计分已就绪" : "主机已连接，等待比赛就绪"
    }
    var guidance:String {
        if b[1] != 3 && number(2,2)==15 { return "最近一次 Wi-Fi 安全握手超时。请核对网络名称、密码及热点兼容性；此状态不能单独证明密码错误。" }
        if b[1] != 3 && number(2,2)==202 { return "最近一次 Wi-Fi 认证失败。请核对热点当前凭据与安全模式；可间隔 30 秒刷新，观察连接请求次数是否增加。" }
        if b[1] != 3 { return "请确认拍底所在位置能够连接配置的 Wi-Fi。" }
        if !flag(2) { return "请确认树莓派接收服务正在运行，且目标 IP 和端口仍然有效。" }
        if !ready { return "请核对树莓派上的比赛与球员映射，再刷新状态。" }
        return "可双击拍底一次，核对树莓派和 App 的比分是否同步变化。"
    }
    private func stage(_ code:UInt8)->String {
        let names=["空闲","等待 Wi-Fi","身份校验阻止连接","重试 TCP","等待主机挑战","等待主机认证回复","已认证"]
        return Int(code)<names.count ? names[Int(code)] : "未知阶段 \(code)"
    }
    var report:String {
        let reason=number(2,2)
        let failure=["无","Wi-Fi 断开","身份版本不符","TCP 连接失败","挑战无效","报文无效","签名无效","认证回复无效","命令无效","接收超时","发送不完整","签名计算失败","序号耗尽","报文溢出","主机断开","主机地址无效","存储故障"]
        let failureName=Int(b[16])<failure.count ? failure[Int(b[16])] : "未知 \(b[16])"
        return """
        Wi-Fi：\(b[1]==3 ? "已连接" : "未连接")（状态码 \(b[1])）
        \(wifiAttemptSummary)
        拍底 IP：\(ip(4))
        目标主机：\(ip(8)):\(number(12,2))
        TCP：\(flag(2) ? "已连接" : "未连接") · 主机认证：\(flag(4) ? "已通过" : "未完成")
        当前阶段：\(stage(b[15]))
        配置代次：\(number(20))
        保存 / 当前关联版本：\(number(24)) / \(number(28))
        身份匹配：\(flag(1)) · 存储正常：\(flag(8)) · 已绑定：\(flag(16))
        TCP 尝试：\(number(32)) · 最近返回值：\(b[17]==128 ? "尚未尝试" : String(Int8(bitPattern:b[17])))
        最近连接耗时：\(number(32)==0 ? "尚未尝试" : "\(number(36)) ms")
        计分阶段：\(b[19]) · guard：\(b[18]) · 未决事件：\(number(40))
        最近断线原因：\(reason)\(reason==15 ? "（安全握手超时）" : (reason==202 ? "（Wi-Fi 认证失败）" : "")) · 发生于开机后 \(number(56)) ms
        最近故障：\(failureName) · 阶段：\(stage(b[64])) · 开机后 \(number(60)) ms
        开机时长：\(number(44)) ms · boot：\(b[48..<56].map { String(format:"%02x",$0) }.joined())
        """
    }
}

struct RacketNetworkAssembler {
    private var transaction:UInt8?
    private var raw=Data()
    private var expectedCount:UInt8?
    mutating func append(_ frame:Data) throws -> RacketNetworkSnapshot? {
        let b=Array(frame)
        guard b.count>=4,b.count<=20,(b[2]==4 || b[2]==5),b[1]<b[2] else { throw PhoneScoreError.invalidWire }
        if b[1]==0 {
            guard (b[3]==1 && b[2]==4) || (b[3]==2 && b[2]==5) else { throw PhoneScoreError.invalidWire }
            transaction=b[0];expectedCount=b[2];raw.removeAll()
        }
        guard let transaction else { return nil }
        guard b[0]==transaction,b[2]==expectedCount,Int(b[1])==raw.count/17,
              b.count==(b[1]==b[2]-1 ? (b[2]==4 ? 17:8):20) else { throw PhoneScoreError.invalidWire }
        raw.append(contentsOf:b.dropFirst(3))
        return b[1]==b[2]-1 ? try RacketNetworkSnapshot(raw) : nil
    }
}
