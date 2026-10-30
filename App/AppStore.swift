import Foundation
import Combine
import CryptoKit
#if !UI_PREVIEW
import ThingSmartBaseKit
import ThingSmartDeviceKit
import ThingSmartDeviceCoreKit
#endif

struct HomeRow: Identifiable { let id: Int64; let name: String; var role: Int = -999 }
struct HomeMemberRow: Identifiable { let id: Int64; let name: String; let role: Int }
struct HomeInviteRow: Identifiable { let id: Int64; let code: String; let hours: Int; let accepted: Bool }
struct DeviceRow: Identifiable { let id: String; let name: String; let online: Bool }

final class AppStore: NSObject, ObservableObject {
    @Published var loggedIn = false
    @Published var accountID = "guest"
    @Published var nickname = ""
    @Published private(set) var maskedAccount = ""
    @Published private(set) var identityFingerprint = ""
    @Published private(set) var sessionPresent = false
    @Published private(set) var accountRegion = ""
    @Published private(set) var verificationDeadlines: [String: Date] = [:]
    @Published var homes: [HomeRow] = []
    @Published var homeMembers: [HomeMemberRow] = []
    @Published var homeInvites: [HomeInviteRow] = []
    @Published var createdHomeCode = ""
    @Published var invitedHome: HomeRow?
    private var previewedHomeCode = ""
    var canInviteHomeMembers: Bool { homes.first { $0.id == homeID }.map { [1, 2].contains($0.role) } ?? false }
    var canChangeHome: Bool { !busy && session?.pending == nil && !["a", "p"].contains(session?.current?.state ?? "") }
    @Published var devices: [DeviceRow] = []
    @Published var homeID: Int64?
    @Published var selected: DeviceRow?
    @Published var session: MatchSession?
    @Published var busy = false
    @Published var status = "登录后连接你的羽小裁"
    @Published var codeSentAt = Date.distantPast
    private var operation = UUID()
    private var requestTimer: Timer?
    private var observation: AnyCancellable?
    #if !UI_PREVIEW
    private let manager = ThingSmartHomeManager()
    private let homeInvitation = ThingSmartHomeInvitation()
    private var home: ThingSmartHome?
    private var device: ThingSmartDevice?
    #endif
    override init() {
        super.init()
        #if UI_PREVIEW
        if ProcessInfo.processInfo.arguments.contains("--settlement-ui-test") {
            // UI-test-only transport: no Tuya SDK, Bluetooth or network commands.
            selected = DeviceRow(id: "settlement-ui", name: "结算流程测试设备", online: true)
            session = MatchSession(accountID: accountID, deviceID: "settlement-ui", online: true, cache: nil) { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let session = self?.session, let pending = session.pending else { return }
                    let state = pending.op == "P" ? "p" : pending.op == "A" ? "i" : session.current?.state ?? "a"
                    let scores = pending.op == "A" ? "0,0,0,0,0" : "8,6,0,0,0"
                    session.receive("@1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:" + String(format: "%08x", pending.token) + ":" + state + ":" + scores + ":0")
                }
            }
            observation = session?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        #endif
        #if !UI_PREVIEW
        loggedIn = ThingSmartUser.sharedInstance().isLogin
        if loggedIn { refreshAccountEvidence() }
        #endif
    }
    var connection: String { selected == nil ? "未连接设备" : session?.online == true ? "设备在线" : "设备离线" }
    private func begin(_ text: String) -> UUID? {
        guard !busy else { return nil }
        busy = true; status = text; operation = UUID(); let id = operation
        requestTimer?.invalidate()
        requestTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in self?.finish(id, "请求超时，请刷新后重试") }
        return id
    }
    private func finish(_ id: UUID, _ text: String, action: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.operation == id else { return }
            self.operation = UUID(); self.requestTimer?.invalidate(); self.busy = false; self.status = text; action?()
        }
    }
    private func failure(_ id: UUID, _ error: Error?) { finish(id, "请求失败：\((error as NSError?)?.localizedDescription ?? "请检查连接")") }
    func authenticate(email: String, password: String, code: String, register: Bool) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !password.isEmpty, !register || !code.isEmpty else { status = "请填写邮箱、密码及所需验证码"; return }
        #if !UI_PREVIEW
        guard let id = begin(register ? "正在注册…" : "正在登录…") else { return }
        if register {
            ThingSmartUser.sharedInstance().register(byEmail: "86", email: email, password: password, code: code, success: { [weak self] in self?.finish(id, "注册成功，请切换到登录") }, failure: { [weak self] in self?.failure(id, $0) })
        } else {
            ThingSmartUser.sharedInstance().login(byEmail: "86", email: email, password: password, success: { [weak self] in
                self?.finish(id, "登录成功") { [weak self] in
                    guard let self = self else { return }; self.refreshAccountEvidence(); self.loadHomes()
                }
            }, failure: { [weak self] in self?.failure(id, $0) })
        }
        #else
        status = "界面预览不连接账号服务"
        #endif
    }
    func verificationKey(account: String, country: String, purpose: Int) -> String {
        country + ":" + account.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + String(purpose)
    }
    func sendLoginCode(account: String, country: String, method: AccountLoginMethod, register: Bool) {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard method.valid(account: account, country: country) else { status = "请检查手机号或邮箱及国家区号"; return }
        let purpose = method.codePurpose(register: register)
        let key = verificationKey(account: account, country: country, purpose: purpose)
        guard (verificationDeadlines[key] ?? .distantPast) <= Date() else { status = "请等待验证码发送间隔结束"; return }
        #if !UI_PREVIEW
        guard let id = begin("正在发送验证码…") else { return }
        verificationDeadlines[key] = Date().addingTimeInterval(60)
        ThingSmartUser.sharedInstance().sendVerifyCode(withUserName: account, countryCode: country, type: purpose, success: { [weak self] in
            self?.finish(id, "验证码已发送，请查看短信或邮箱")
        }, failure: { [weak self] in self?.failure(id, $0) })
        #else
        status = "界面预览不会发送验证码，请使用真机验证"
        #endif
    }
    func loginWithCode(account: String, country: String, code: String, method: AccountLoginMethod) {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard method != .emailPassword, method.valid(account: account, country: country), !code.isEmpty else { status = "请填写有效账号和验证码"; return }
        #if !UI_PREVIEW
        guard let id = begin("正在验证登录…") else { return }
        let success: () -> Void = { [weak self] in self?.finish(id, "登录成功") { [weak self] in self?.refreshAccountEvidence(); self?.loadHomes() } }
        let failure: (Error?) -> Void = { [weak self] in self?.failure(id, $0) }
        if method == .phoneCode {
            ThingSmartUser.sharedInstance().login(withMobile: account, countryCode: country, code: code, success: success, failure: failure)
        } else {
            ThingSmartUser.sharedInstance().login(withEmail: account, countryCode: country, code: code, success: success, failure: failure)
        }
        #else
        status = "界面预览不会登录，请使用真机验证"
        #endif
    }
    func refreshAccountEvidence() {
        #if !UI_PREVIEW
        let user = ThingSmartUser.sharedInstance()
        loggedIn = user.isLogin
        guard loggedIn else { maskedAccount = ""; identityFingerprint = ""; sessionPresent = false; accountRegion = ""; return }
        accountID = user.uid; nickname = user.nickname ?? ""
        maskedAccount = AccountPrivacy.mask(user.userName ?? "")
        sessionPresent = !(user.sid ?? "").isEmpty
        accountRegion = user.regionCode ?? ""
        // Compare identity across login methods without displaying or exporting the SID.
        identityFingerprint = SHA256.hash(data: Data((accountRegion + ":" + accountID).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        #endif
    }
    func sendCode(_ email: String) {
        guard email.contains("@"), Date().timeIntervalSince(codeSentAt) >= 60 else { status = "请检查邮箱，验证码发送需间隔 60 秒"; return }
        #if !UI_PREVIEW
        guard let id = begin("正在发送验证码…") else { return }; codeSentAt = Date()
        ThingSmartUser.sharedInstance().sendVerifyCode(withUserName: email.trimmingCharacters(in: .whitespacesAndNewlines), region: nil, countryCode: "86", type: 1, success: { [weak self] in self?.finish(id,"验证码已发送") }, failure: { [weak self] in self?.failure(id,$0) })
        #endif
    }
    func loadHomes() {
        guard loggedIn else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在查询家庭…") else { return }
        manager.getHomeList(success: { [weak self] models in
            self?.finish(id, "家庭已更新") { [weak self] in
                guard let self = self else { return }
                self.homes = (models ?? []).map { HomeRow(id: $0.homeId, name: $0.name ?? "我的家庭", role: $0.role.rawValue) }
                let remembered = UserDefaults.standard.object(forKey: "ios.home.\(self.accountID)") as? Int64
                if let home = self.homes.first(where: { $0.id == self.homeID || $0.id == remembered }) ?? self.homes.first { self.loadDevices(home.id) }
                else { self.homeID = nil; self.clearDevice(); self.devices = []; self.status = "创建家庭，开始添加设备" }
            }
        }, failure: { [weak self] in self?.failure(id,$0) })
        #endif
    }
    func loadHomeMembers() {
        guard loggedIn, let homeID = homeID, !busy else { return }
        #if !UI_PREVIEW
        guard let object = ThingSmartHome(homeId: homeID), let id = begin("正在读取家庭成员…") else { return }
        object.getMemberList(success: { [weak self] members in
            self?.finish(id, "家庭成员已更新") { [weak self] in
                self?.homeMembers = (members ?? []).map { HomeMemberRow(id: $0.memberId, name: $0.name ?? "家庭成员", role: $0.role.rawValue) }
                self?.loadHomeInvites()
            }
        }, failure: { [weak self] in self?.failure(id, $0) })
        #endif
    }
    func loadHomeInvites() {
        guard loggedIn, canInviteHomeMembers, let homeID = homeID else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在读取邀请记录…") else { return }
        homeInvitation.fetchRecordList(withHomeID: homeID, success: { [weak self] records in
            self?.finish(id, "家庭邀请已更新") { [weak self] in
                self?.homeInvites = records.map { HomeInviteRow(id: $0.invitationID.int64Value, code: $0.invitationCode, hours: $0.validTime, accepted: $0.dealStatus.rawValue == 2) }
            }
        }, failure: { [weak self] in self?.failure(id, $0) })
        #endif
    }
    func createHomeInvitation() {
        guard loggedIn, canInviteHomeMembers, let homeID = homeID else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在生成家庭邀请码…") else { return }
        createdHomeCode = ""
        let request = ThingSmartHomeInvitationCreateRequestModel()
        request.homeID = homeID; request.role = ThingHomeRoleType(rawValue: 0)!; request.needMsgContent = false
        homeInvitation.createInvitation(with: request, success: { [weak self] result in
            self?.finish(id, "邀请码已生成，请只分享给要加入家庭的人") { [weak self] in
                self?.createdHomeCode = result.invitationCode; self?.loadHomeInvites()
            }
        }, failure: { [weak self] in self?.failure(id, $0) })
        #endif
    }
    func cancelHomeInvitation(_ invitation: HomeInviteRow) {
        guard loggedIn, canInviteHomeMembers else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在取消家庭邀请…") else { return }
        homeInvitation.cancelInvitation(withInvitationID: NSNumber(value: invitation.id), success: { [weak self] ok in
            self?.finish(id, ok ? "邀请已取消" : "邀请未取消，请刷新核对") { [weak self] in
                if ok { self?.createdHomeCode = "" }; self?.loadHomeInvites()
            }
        }, failure: { [weak self] in self?.failure(id, $0) })
        #endif
    }
    func clearHomeInvitationPreview() { invitedHome = nil; previewedHomeCode = "" }
    func previewHomeInvitation(_ code: String) {
        guard loggedIn, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在查看家庭邀请…") else { return }
        clearHomeInvitationPreview()
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        homeInvitation.fetchInvitationHomeInfo(withInvitationCode: value, success: { [weak self] model in
            self?.finish(id, "请核对家庭名称后再加入") { [weak self] in
                self?.invitedHome = HomeRow(id: model.homeId, name: model.name ?? "受邀家庭")
                self?.previewedHomeCode = value
            }
        }, failure: { [weak self] in self?.failure(id, $0) })
        #endif
    }
    func joinInvitedHome() {
        guard loggedIn, canChangeHome, let invited = invitedHome, !previewedHomeCode.isEmpty else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在加入家庭…") else { return }
        homeInvitation.joinHome(withInvitationCode: previewedHomeCode, success: { [weak self] ok in
            self?.finish(id, ok ? "已加入家庭，正在刷新设备" : "加入未确认，请刷新家庭列表核对") { [weak self] in
                guard let self = self else { return }
                self.clearHomeInvitationPreview()
                if ok { self.homeID = invited.id; UserDefaults.standard.set(invited.id, forKey: "ios.home.\(self.accountID)") }
                self.loadHomes()
            }
        }, failure: { [weak self] in self?.failure(id, $0) })
        #endif
    }
    func createHome(_ name: String) {
        guard loggedIn, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在创建家庭…") else { return }
        manager.addHome(withName: String(name.prefix(30)), geoName: "", rooms: [], latitude: 0, longitude: 0, success: { [weak self] _ in
            self?.finish(id, "家庭已创建") { [weak self] in self?.loadHomes() }
        }, failure: { [weak self] in self?.failure(id,$0) })
        #endif
    }
    func loadDevices(_ homeID: Int64) {
        #if !UI_PREVIEW
        guard let id = begin("正在查询设备…") else { return }
        clearDevice(); self.homeID = homeID; devices = []; homeMembers = []; homeInvites = []; createdHomeCode = ""
        UserDefaults.standard.set(homeID, forKey: "ios.home.\(accountID)")
        let object = ThingSmartHome(homeId: homeID); home = object
        object?.getDataWithSuccess({ [weak self] _ in
            self?.finish(id, "设备列表已更新") { [weak self] in
                guard let self = self else { return }
                self.devices = (object?.deviceList ?? []).map { DeviceRow(id: $0.devId, name: $0.name ?? "羽小裁", online: $0.isOnline) }
                if let previous = UserDefaults.standard.string(forKey: "ios.device.\(self.accountID)"), let row = self.devices.first(where: { $0.id == previous }) { self.select(row) }
            }
        }, failure: { [weak self] in self?.failure(id,$0) })
        #endif
    }
    func select(_ row: DeviceRow) {
        guard !busy, session?.pending == nil else { return }
        clearDevice(); selected = row
        #if !UI_PREVIEW
        guard let object = ThingSmartDevice(deviceId: row.id) else { selected = nil; status = "无法连接此设备，请刷新"; return }
        device = object; object.delegate = self
        session = MatchSession(accountID: accountID, deviceID: row.id, online: object.deviceModel.isOnline, cache: object.deviceModel.dps?["101"] as? String) { wire, completion in
            object.publishDps(["110": wire], success: { completion(nil) }, failure: { completion($0) })
        }
        UserDefaults.standard.set(row.id, forKey: "ios.device.\(accountID)")
        observation = session?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        session?.send("Q")
        #endif
    }
    private func clearDevice() {
        session?.disconnect(); session = nil; selected = nil; observation = nil
        #if !UI_PREVIEW
        device?.delegate = nil; device = nil
        #endif
    }
    func logout() {
        guard loggedIn, session?.pending == nil else { return }
        #if !UI_PREVIEW
        guard let id = begin("正在退出登录…") else { return }
        ThingSmartUser.sharedInstance().loginOut({ [weak self] in self?.finish(id, "已退出登录") { [weak self] in
            self?.homeMembers = []; self?.homeInvites = []; self?.createdHomeCode = ""; self?.invitedHome = nil; self?.previewedHomeCode = ""
            self?.clearDevice(); self?.homes = []; self?.devices = []; self?.homeID = nil; self?.loggedIn = false; self?.accountID = "guest"; self?.nickname = ""; self?.maskedAccount = ""; self?.identityFingerprint = ""; self?.sessionPresent = false; self?.accountRegion = ""
        } }, failure: { [weak self] in self?.failure(id,$0) })
        #endif
    }
    func background() { session?.invalidate("返回后请同步比分") }
    func foreground() { if session?.pending == nil { session?.send("Q") } }
    deinit { requestTimer?.invalidate() }
}
#if !UI_PREVIEW
extension AppStore: ThingSmartDeviceDelegate {
    func device(_ device: ThingSmartDevice, dpsUpdate dps: [AnyHashable: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.device === device, let raw = dps["101"] as? String else { return }; self.session?.receive(raw)
        }
    }
    func deviceInfoUpdate(_ device: ThingSmartDevice) {
        DispatchQueue.main.async { [weak self] in guard let self = self, self.device === device else { return }; self.session?.setOnline(device.deviceModel.isOnline) }
    }
    func deviceRemoved(_ device: ThingSmartDevice) {
        DispatchQueue.main.async { [weak self] in guard let self = self, self.device === device else { return }; self.clearDevice(); self.status = "设备已移除，请刷新设备列表" }
    }
}
#endif
