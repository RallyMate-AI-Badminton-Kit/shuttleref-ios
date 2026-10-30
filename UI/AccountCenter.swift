import SwiftUI
#if DEBUG && !UI_PREVIEW
import ThingSmartBaseKit
#endif

struct AccountCenter: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    @State private var settings = false
    @State private var confirmLogout = false
    #if DEBUG
    @StateObject private var sessionProbe = SessionCapabilityProbe()
    #endif
    private var blocked: String? {
        AccountActionState(loggedIn:store.loggedIn, deviceBusy:store.busy, businessBusy:social.busy,
            authorizing:social.oauthBusy, deviceMatchActive:["a","p"].contains(store.session?.current?.state ?? ""),
            deviceCommandPending:store.session?.pending != nil, businessContext:social.context != nil,
            pendingEvents:!social.journal.events.isEmpty,pendingRecords:!social.recordsJournal.pending.isEmpty).deviceChangeBlockReason
    }
    var body: some View {
        ScrollView { VStack(alignment:.leading, spacing:22) {
            SheetHeader(title:"账号与安全")
            if !store.loggedIn {
                AuthForm()
                Note(text:"登录后自动同步战绩、组局和设备。")
            } else if store.loggedIn && social.needsLogin {
                Text("正在连接羽小裁账号").font(.headline)
                Button("重新连接") { Task { await social.loginWithTuyaTicket(app: store) } }.disabled(social.ticketLoginBusy || social.deviceLoginBusy)
            } else if !social.needsLogin, let account = social.credentials {
                Label(social.verifiedBusiness ? "已登录羽小裁" : "旧账号待升级", systemImage:"person.crop.circle.badge.checkmark").font(.headline)
                Text(account.user.name).font(.title2.bold())
                if let login = account.user.login_name { Text("账号：" + login).foregroundColor(Palette.muted) }
            }
            if social.credentials != nil || store.loggedIn {
                Button("退出登录 / 切换账号",role:.destructive) { confirmLogout = true }.disabled(blocked != nil)
            }
            if let blocked { Note(text:blocked) }
            Note(text:social.message)
            if social.verifiedBusiness && social.credentials?.auth_provider != "tuya" && store.loggedIn && !social.hasDevicePair(app: store) {
                Button(social.deviceLoginBusy ? "正在登记…" : "启用本机快速登录") {
                    social.run { try await social.registerDevicePair(app: store) }
                }.disabled(social.busy || social.deviceLoginBusy || blocked != nil)
                Note(text:"临时方案：登记后本机涂鸦登录可自动恢复当前业务账号。涂鸦身份的服务端校验尚未接入。")
            }
            Divider()
            MenuRow(icon:"gearshape", title:"服务器与旧账号恢复", subtitle:"服务器地址、旧恢复凭据") { settings = true }
            #if DEBUG
            DisclosureGroup("登录验证（开发）") {
                Text("SDK 登录：" + (store.loggedIn ? "成功" : "未登录"))
                Text("账号区域：" + store.accountRegion)
                Text("身份指纹：" + store.identityFingerprint).font(.caption.monospaced())
                Button("刷新 SDK 状态") { store.refreshAccountEvidence() }
                Button(sessionProbe.running ? "检测中…" : "检测当前会话免登能力") { sessionProbe.run() }.disabled(!store.loggedIn || sessionProbe.running)
                Text(sessionProbe.report).font(.caption).textSelection(.enabled)
                Button("复制脱敏检测结果") { UIPasteboard.general.string = sessionProbe.report }
            }
            #endif
        }.padding(22) }.background(Palette.background.ignoresSafeArea())
        .interactiveDismissDisabled(social.busy || store.busy)
        .sheet(isPresented:$settings) { GatheringAccount().environmentObject(social).environmentObject(store) }
        .confirmationDialog("退出羽小裁并停止当前设备连接？",isPresented:$confirmLogout,titleVisibility:.visible) {
            Button("退出登录",role:.destructive) { guard blocked == nil else { return }; social.run { if social.credentials != nil { try await social.logout() }; store.logout() } }
        } message: { Text("已保存的数据和设备绑定保留。再次使用时登录原账号即可。尚未设置密码的旧账号建议先完成设密。") }
    }
}

struct NativePasswordForm: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    var upgrading = false
    var changing = false
    @State private var mode = "login"
    @State private var username = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var oldPassword = ""
    @State private var recovery = ""
    @State private var error = ""
    private var action: String { upgrading ? "set-password" : changing ? "change-password" : mode }
    private var blocked: Bool {
        let restoringIdentity = social.credentials != nil && ["login","set-password","change-password"].contains(action)
        let pending = social.context != nil || !social.journal.events.isEmpty || !social.recordsJournal.pending.isEmpty || store.session?.pending != nil || ["a","p"].contains(store.session?.current?.state ?? "")
        return store.busy || social.busy || social.oauthBusy || (!restoringIdentity && pending)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            if !upgrading && !changing {
                Picker("登录方式",selection:$mode) { Text("登录").tag("login"); Text("注册").tag("register"); Text("账号恢复").tag("recover-password") }.pickerStyle(.segmented)
            }
            if !changing { TextField("登录账号（字母、数字、_ 或 -）",text:$username).textContentType(.username).autocapitalization(.none).disableAutocorrection(true).inputStyle() }
            if action == "register" { TextField("球友昵称",text:$nickname).inputStyle() }
            if changing { SecureField("当前密码",text:$oldPassword).textContentType(.password).inputStyle() }
            if action == "recover-password" {
                Note(text:"请向测试管理员申请一次性恢复码，有效期 15 分钟。不会按昵称或邮箱自动合并账号。")
                SecureField("一次性恢复码",text:$recovery).inputStyle()
            }
            SecureField(action == "login" ? "密码" : "新密码（12–128 个字符）",text:$password).textContentType(action == "login" ? .password : .newPassword).inputStyle()
            if action != "login" { SecureField("再次输入新密码",text:$repeatPassword).textContentType(.newPassword).inputStyle() }
            Button(upgrading ? "设置密码并保留当前数据" : changing ? "修改密码" : mode == "register" ? "注册羽小裁账号" : mode == "recover-password" ? "恢复账号并设置密码" : "登录羽小裁") {
                guard !blocked else { return }
                guard action == "login" || password == repeatPassword else { error = "两次密码不一致"; return }
                error = ""
                let selectedAction=action, enteredPassword=password, enteredOld=oldPassword, enteredCode=recovery
                let oldUser=social.userID
                social.run {
                    defer { password=""; repeatPassword=""; oldPassword=""; recovery="" }
                    try await social.passwordAction(selectedAction,username:username,password:enteredPassword,name:nickname,oldPassword:enteredOld,recovery:enteredCode)
                    if oldUser != social.userID { store.logout() }
                }
            }.buttonStyle(PrimaryStyle()).disabled(blocked || password.isEmpty)
            if social.busy { ProgressView() }
            Note(text:error)
        }.onAppear { username=social.credentials?.user.login_name ?? "" }
        .onChange(of:mode) { _ in password="";repeatPassword="";oldPassword="";recovery="";error="" }
    }
}

#if DEBUG
/// Throwaway capability spike. Never exports credentials or treats SDK callbacks as business identity proof.
@MainActor private final class SessionCapabilityProbe: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var report = ""
    private var generation = UUID()
    private var pending: Set<String> = []
    #if !UI_PREVIEW
    private var request: ThingSmartRequest?
    private var ticketRequest: ThingSmartRequest?
    #endif

    func run() {
        guard !running else { return }
        #if UI_PREVIEW
        report = "界面预览不调用 SDK；请在已登录的真机检测。"
        #else
        let user = ThingSmartUser.sharedInstance()
        guard user.isLogin else { report = "请先登录设备账号。"; return }
        let uid = user.uid
        let id = UUID(); generation = id
        running = true; pending = ["网关凭证", "社区 SSO", "登录态 ticket"]
        report = "会话能力实验 v2\n社区代码：shuttleref（未配置）\n"
        user.requestHighwayToken(success: { [weak self] value in
            // Only examine structure in memory; do not print or persist token values.
            let dictionary = value as? [String: Any]
            let tokenPresent = ["accessToken", "access_token", "token"].contains {
                !(dictionary?[$0] as? String ?? "").isEmpty
            } || !(value as? String ?? "").isEmpty
            let summary = tokenPresent ? "成功回调，存在凭证字段；尚未验证服务端用途" : "成功回调，未识别凭证字段；不能认定可用"
            Task { @MainActor in self?.complete("网关凭证", summary, id: id, uid: uid) }
        }, failure: { [weak self] error in
            let summary = Self.errorSummary(error)
            Task { @MainActor in self?.complete("网关凭证", summary, id: id, uid: uid) }
        })
        let api = ThingSmartRequest(); request = api
        api.request(withApiName: "m.life.user.community.url.get", postData: ["communityCode": "shuttleref"], version: "1.0", success: { [weak self] value in
            let root = value as? [String: Any]
            let payload = root?["resultDO"] as? [String: Any] ?? root
            let hasURL = !(payload?["communityUrl"] as? String ?? "").isEmpty
            let summary = hasURL ? "返回社区链接（未打开、未保存）；仍需服务端验签验证" : "成功回调但没有社区链接；不能认定 SSO 可用"
            Task { @MainActor in self?.complete("社区 SSO", summary, id: id, uid: uid) }
        }, failure: { [weak self] error in
            let summary = Self.errorSummary(error)
            Task { @MainActor in self?.complete("社区 SSO", summary, id: id, uid: uid) }
        })
        let ticketAPI = ThingSmartRequest(); ticketRequest = ticketAPI
        ticketAPI.request(withApiName: "tuya.m.user.sso.ticket.getbysid", postData: [:], version: "1.0", success: { [weak self] value in
            let root = value as? [String: Any]
            let payload = root?["result"] as? [String: Any] ?? root?["resultDO"] as? [String: Any] ?? root
            let present = !(payload?["ticket"] as? String ?? "").isEmpty
            let summary = present ? "获取成功（未保存或展示）；尚未进行服务端兑换" : "成功回调但未识别 ticket 字段"
            Task { @MainActor in self?.complete("登录态 ticket", summary, id: id, uid: uid) }
        }, failure: { [weak self] error in
            let summary = Self.errorSummary(error)
            Task { @MainActor in self?.complete("登录态 ticket", summary, id: id, uid: uid) }
        })
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.generation == id, self.running else { return }
            self.request?.cancel()
            self.ticketRequest?.cancel()
            for stage in self.pending.sorted() { self.complete(stage, "25 秒内未返回，结果不确定", id: id, uid: uid) }
        }
        #endif
    }

    private func complete(_ stage: String, _ summary: String, id: UUID, uid: String) {
        guard generation == id, pending.remove(stage) != nil else { return }
        #if !UI_PREVIEW
        guard ThingSmartUser.sharedInstance().isLogin, ThingSmartUser.sharedInstance().uid == uid else {
            generation = UUID(); pending = []; running = false; request?.cancel(); request = nil; ticketRequest?.cancel(); ticketRequest = nil
            report = "检测期间账号已变更，已丢弃结果。"; return
        }
        #endif
        report += "\(stage)：\(summary)\n"
        if pending.isEmpty {
            running = false
            #if !UI_PREVIEW
            request = nil
            ticketRequest = nil
            #endif
            report += "结论：本次仅探测客户端能力，尚未证明业务服务端可可信验证身份。"
        }
    }

    nonisolated private static func errorSummary(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "失败，SDK 未返回错误对象" }
        // SDK documents FailureReason as its symbolic error code. Never copy descriptions/userInfo wholesale.
        let raw = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? ""
        let symbolic = raw.range(of: "^[A-Z][A-Z0-9_]{1,63}$", options: .regularExpression) != nil ? raw : "未提供标准错误码"
        return "失败，code=\(error.code)，\(symbolic)"
    }
}
#endif
