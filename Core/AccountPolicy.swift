import Foundation

/// Device-account changes and business authorization affect different identities.
struct AccountActionState {
    var renewingBusinessIdentity = false
    var loggedIn = false
    var deviceBusy = false
    var businessBusy = false
    var authorizing = false
    var deviceMatchActive = false
    var deviceCommandPending = false
    var businessContext = false
    var pendingEvents = false
    var pendingRecords = false

    var businessAuthorizationBlockReason: String? {
        if !loggedIn { return "请先登录设备账号。" }
        if authorizing { return "正在授权，请完成或取消本次授权。" }
        if deviceBusy { return "设备账号正在处理请求，请稍候。" }
        if businessBusy { return "战绩与组局正在处理请求，请稍候。" }
        if renewingBusinessIdentity { return nil }
        if businessContext { return "请先处理当前组局球局，再授权登录。" }
        if pendingEvents { return "请先同步待上传的组局操作，再授权登录。" }
        if pendingRecords { return "请先同步待上传的战绩，再授权登录。" }
        return nil
    }

    var deviceChangeBlockReason: String? {
        if authorizing { return "请先完成或取消授权，再更换设备账号。" }
        if deviceBusy || businessBusy { return "正在处理请求，请稍候再更换设备账号。" }
        if deviceCommandPending { return "请等待设备确认当前操作，再更换设备账号。" }
        if deviceMatchActive { return "请先处理当前设备球局，再更换设备账号。" }
        if businessContext { return "请先处理当前组局球局，再更换设备账号。" }
        if pendingEvents || pendingRecords { return "请先同步待上传的数据，再更换设备账号。" }
        return nil
    }
}

enum AccountLoginMethod: String, CaseIterable, Identifiable {
    case phoneCode = "手机验证码", emailCode = "邮箱验证码", emailPassword = "邮箱密码"
    var id: String { rawValue }
    var needsPassword: Bool { self == .emailPassword }
    func codePurpose(register: Bool) -> Int { register ? 1 : 2 }
    func valid(account: String, country: String) -> Bool {
        guard !country.isEmpty, country.count <= 4, country.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        if self == .phoneCode {
            return account.allSatisfy { $0.isASCII && $0.isNumber } && (country == "86" ? account.count == 11 && account.first == "1" : (5...15).contains(account.count))
        }
        return account.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}
enum AccountPrivacy {
    static func mask(_ value: String) -> String {
        if let at = value.firstIndex(of: "@") { return String(value.prefix(1)) + "***" + String(value[at...]) }
        if value.count >= 7 { return String(value.prefix(3)) + "****" + String(value.suffix(4)) }
        return value.isEmpty ? "未提供" : "***"
    }
}
