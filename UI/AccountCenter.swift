import SwiftUI

// First integration stage: both existing identities remain explicit until server verification is available.
struct AccountCenter: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    @State private var businessAccount = false
    @State private var confirmLogout = false
    @StateObject private var oauth = NativeOAuth()
    @State private var confirmLink = false
    @State private var oauthEndpoint = ""
    @AppStorage("ios.auth.reference-fingerprint") private var reference = ""
    private var actionState: AccountActionState {
        AccountActionState(loggedIn: store.loggedIn, deviceBusy: store.busy,
            businessBusy: social.busy, authorizing: oauth.busy || social.oauthBusy,
            deviceMatchActive: ["a", "p"].contains(store.session?.current?.state ?? ""),
            deviceCommandPending: store.session?.pending != nil, businessContext: social.context != nil,
            pendingEvents: !social.journal.events.isEmpty, pendingRecords: !social.recordsJournal.pending.isEmpty)
    }
    private var changingBlocked: Bool { actionState.deviceChangeBlockReason != nil }
    private var authorizationBlocked: Bool { actionState.businessAuthorizationBlockReason != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SheetHeader(title: "账号与安全")
                if store.loggedIn {
                    Label("设备账号已登录", systemImage: "checkmark.shield.fill").font(.headline).foregroundColor(Palette.green)
                    Text(store.nickname.isEmpty ? "羽小裁球友" : store.nickname).font(.title2.bold())
                    Text(store.maskedAccount).foregroundColor(Palette.muted)
                    Button("退出设备账号 / 更换登录") { confirmLogout = true }.disabled(changingBlocked)
                    if let reason = actionState.deviceChangeBlockReason { Note(text: reason) }
                } else { AuthForm() }
                if store.busy { ProgressView() }
                Note(text: store.status)
                Divider()
                MenuRow(icon: "person.crop.circle", title: "战绩与组局账号", subtitle: social.credentials.map { $0.user.name + " · 管理 / 切换" } ?? "登录或恢复已有成绩账号") { businessAccount = true }
                    .accessibilityIdentifier("account-business-entry")
                if store.loggedIn {
                    Text("战绩与组局登录").font(.headline)
                    if social.credentials?.auth_provider == "tuya" {
                        Label("已通过涂鸦授权登录", systemImage: "checkmark.shield")
                        Note(text: "成绩和组局已关联涂鸦身份。退出后可重新授权登录，不再使用旧恢复码。")
                        Button("重新授权登录") { Task { await oauth.signIn(app: store, social: social, link: false) } }.disabled(authorizationBlocked)
                    } else {
                        Button(social.credentials == nil ? "使用涂鸦账号登录战绩与组局" : "关联当前战绩与组局账号") {
                            if social.credentials == nil { Task { await oauth.signIn(app: store, social: social, link: false) } }
                            else { confirmLink = true }
                        }.buttonStyle(PrimaryStyle()).disabled(authorizationBlocked)
                    }
                    if let reason = actionState.businessAuthorizationBlockReason, !oauth.busy { Note(text: reason) }
                    if oauth.busy { ProgressView(); Button("取消授权") { oauth.cancel() } }
                    if !oauth.message.isEmpty { Note(text: oauth.message) }
                    #if DEBUG
                    DisclosureGroup("授权服务（开发）") {
                        TextField("HTTPS 授权服务地址", text: $oauthEndpoint).keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true).inputStyle()
                        Button("保存授权地址") { UserDefaults.standard.set(oauthEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "ios.oauth.origin") }.disabled(oauth.busy)
                    }
                    #endif
                }
                #if DEBUG
                DisclosureGroup("登录验证（开发）") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SDK 登录：" + (store.loggedIn ? "成功" : "未登录"))
                        Text("会话凭据 SID：" + (store.sessionPresent ? "存在（不显示原文）" : "未取得"))
                        Text("账号区域：" + (store.accountRegion.isEmpty ? "未知" : store.accountRegion))
                        Text("身份指纹：" + (store.identityFingerprint.isEmpty ? "未取得" : store.identityFingerprint)).font(.caption.monospaced())
                        if !reference.isEmpty && !store.identityFingerprint.isEmpty {
                            Text(reference == store.identityFingerprint ? "与上次记录为同一身份" : "与上次记录为不同身份")
                        }
                        Button("记录当前身份用于对比") { reference = store.identityFingerprint }.disabled(store.identityFingerprint.isEmpty)
                        Button("刷新 SDK 状态") { store.refreshAccountEvidence() }
                        Note(text: "服务端通过 OAuth 独立验证身份；不会上传 SDK 的 SID。请使用上方入口授权登录或关联战绩账号。")
                    }.padding(.top, 12)
                }
                #endif
            }.padding(22)
        }.background(Palette.background.ignoresSafeArea())
            .onAppear { store.refreshAccountEvidence(); oauthEndpoint = oauth.origin }
            .sheet(isPresented: $businessAccount) { GatheringAccount().environmentObject(social) }
            .confirmationDialog("退出设备账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出设备账号", role: .destructive) {
                    if !changingBlocked {
                        if social.credentials?.auth_provider == "tuya" { social.run { try await social.logout(); store.logout() } }
                        else { store.logout() }
                    }
                }
            } message: { Text("将停止设备连接，并退出已通过涂鸦授权的战绩账号；设备绑定、服务器战绩和本机记录保留。尚未关联的旧战绩账号仍单独管理。") }
            .alert("关联当前战绩账号？", isPresented: $confirmLink) {
                Button("取消", role: .cancel) {}
                Button("保留数据并关联") { Task { await oauth.signIn(app: store, social: social, link: true) } }
            } message: { Text("将保留「\(social.credentials?.user.name ?? "")」的成绩和组局。关联后旧恢复码失效，今后用当前涂鸦账号授权登录；不会自动合并其他账号。") }
    }
}
