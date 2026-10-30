import SwiftUI

struct DevicePage: View {
    @EnvironmentObject var store: AppStore
    @State private var name = "羽小裁之家"
    @State private var pairing = false
    @State private var accountCenter = false
    @State private var familyMembers = false
    @State private var racketPage = false
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    SheetHeader(title:"设备与连接")
                    MenuRow(icon: "figure.badminton", title: "球拍与拍底", subtitle: "添加拍底、关联使用者、查看计分主机") { racketPage = true }
                    if !store.loggedIn { Button("登录羽小裁") { accountCenter = true }.buttonStyle(PrimaryStyle()) }
                    else {
                        HStack { Image(systemName:"checkmark.shield").foregroundColor(Palette.green);Text("已登录羽小裁").font(.headline);Spacer();Button("账号与安全") { accountCenter = true } }
                        if !store.homes.isEmpty {
                            Text("选择家庭").font(.headline)
                            ForEach(store.homes) { home in Button { store.loadDevices(home.id) } label: { HStack { Image(systemName:"house");Text(home.name);Spacer();if store.homeID == home.id { Image(systemName:"checkmark.circle.fill") } }.padding(16).background(store.homeID == home.id ? Palette.soft:Color.white).cornerRadius(14) }.disabled(store.busy || store.session?.pending != nil) }
                        }
                        MenuRow(icon: "person.2.fill", title: "家庭成员与邀请", subtitle: "邀请测试伙伴共享设备，或输入邀请码加入家庭") { familyMembers = true }
                        HStack { TextField("新家庭名称",text:$name).inputStyle();Button("创建") { store.createHome(name) }.disabled(store.busy || name.trimmingCharacters(in:.whitespaces).isEmpty) }
                        HStack { Text("我的设备").font(.headline);Spacer();Button("刷新") { store.loadHomes() }.disabled(store.busy || store.session?.pending != nil) }
                        if store.devices.isEmpty { EmptyCard(icon:"sensor.tag.radiowaves.forward",title:"把羽小裁带上场",detail:"选择或创建家庭，然后为设备配网。已绑定到其他账号的设备，需要先确认它的归属。") }
                        ForEach(store.devices) { row in
                            MenuRow(icon:store.selected?.id == row.id ? "checkmark.circle.fill":"sensor.tag.radiowaves.forward",title:row.name,subtitle:row.online ? "在线 · 点击使用":"离线 · 请检查设备网络") { store.select(row) }.disabled(store.busy || store.session?.pending != nil)
                        }
                        Button("添加设备") { pairing = true }.buttonStyle(PrimaryStyle()).disabled(store.homeID == nil || store.busy || store.session?.pending != nil)
                        if let homeID = store.homeID {
                            NavigationLink(destination: DeviceQRPairing(homeID: homeID, homeName: store.homes.first(where: { $0.id == homeID })?.name ?? "当前家庭", canBind: { [accountID = store.accountID] in
                                store.loggedIn && store.accountID == accountID && store.homeID == homeID && !store.busy && store.session?.pending == nil
                            }, onBound: {
                                if store.loggedIn && store.homeID == homeID { store.loadDevices(homeID) }
                            }).navigationBarHidden(false)) {
                                Label("扫码绑定树莓派 / 已联网设备", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(16)
                            }.disabled(store.busy || store.session?.pending != nil)
                        }
                        if let session = store.session { VStack(alignment:.leading,spacing:12) { Text("当前连接").font(.headline);Text(store.connection);Note(text:session.message);Button("同步设备比分") { session.send("Q") }.disabled(!session.can("Q")) }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Palette.soft).cornerRadius(18) }
                        Note(text:"配网请使用 2.4GHz Wi-Fi。换网与重新绑定可能影响原账号的访问，操作前请确认设备归属。")
                    }
                    if store.busy { ProgressView() }
                    Note(text:store.status)
                }.padding(22)
            }.background(Palette.background.ignoresSafeArea()).navigationBarHidden(true)
                .background(NavigationLink(isActive:$pairing,destination:{ PairingScreen(homeID:store.homeID ?? 0).navigationBarHidden(false).navigationTitle("添加设备").navigationBarTitleDisplayMode(.inline).onDisappear { store.loadHomes() } },label:{EmptyView()}))
        }.navigationViewStyle(.stack)
        .sheet(isPresented: $accountCenter) { AccountCenter().environmentObject(store) }
        .sheet(isPresented: $familyMembers) { HomeMembersPage().environmentObject(store) }
        .sheet(isPresented: $racketPage) { RacketPage() }
    }
}
struct AuthForm: View {
    @EnvironmentObject var store: AppStore
    @State private var method = AccountLoginMethod.phoneCode
    @State private var register = false
    @State private var account = ""
    @State private var country = "86"
    @State private var password = ""
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("登录羽小裁").font(.title2.bold())
            Picker("登录方式", selection: $method) {
                ForEach(AccountLoginMethod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(store.busy)
            if method.needsPassword {
                Picker("账号操作", selection: $register) { Text("登录").tag(false); Text("注册").tag(true) }.pickerStyle(.segmented).disabled(store.busy)
            }
            if method == .phoneCode {
                TextField("国家区号，例如 86", text: $country).keyboardType(.numberPad).inputStyle().disabled(store.busy)
            }
            TextField(method == .phoneCode ? "手机号（不含国家区号）" : "邮箱", text: $account)
                .textContentType(method == .phoneCode ? .telephoneNumber : .username)
                .keyboardType(method == .phoneCode ? .phonePad : .emailAddress)
                .autocapitalization(.none).disableAutocorrection(true).inputStyle().disabled(store.busy)
            if method.needsPassword { SecureField("密码", text: $password).textContentType(register ? .newPassword : .password).inputStyle().disabled(store.busy) }
            if !method.needsPassword || register {
                HStack {
                    TextField("验证码", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad).inputStyle().disabled(store.busy)
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        let key = store.verificationKey(account: account, country: country, purpose: method.codePurpose(register: register))
                        let remaining = max(0, Int(ceil((store.verificationDeadlines[key] ?? .distantPast).timeIntervalSince(tick.date))))
                        Button(remaining > 0 ? "\(remaining) 秒后重发" : "发送验证码") {
                            store.sendLoginCode(account: account, country: country, method: method, register: register)
                        }.font(.system(size: 13)).disabled(store.busy || remaining > 0 || !method.valid(account: account.trimmingCharacters(in: .whitespacesAndNewlines), country: country))
                    }
                }
            }
            Button(register ? "注册账号" : "登录") {
                if method.needsPassword { store.authenticate(email: account, password: password, code: code, register: register) }
                else { store.loginWithCode(account: account, country: country, code: code, method: method) }
            }.buttonStyle(PrimaryStyle()).disabled(store.busy || !method.valid(account: account.trimmingCharacters(in: .whitespacesAndNewlines), country: country) || (method.needsPassword ? password.isEmpty || register && code.isEmpty : code.isEmpty))
            Note(text: "请使用注册时的国家或地区。邮箱登录当前使用中国区（86）；独立 App 与原小程序账号不自动互通。")
        }
        .onChange(of: method) { _ in account = ""; code = ""; password = ""; register = false; country = "86" }
        .onChange(of: register) { _ in code = ""; password = "" }
        .onChange(of: account) { _ in code = "" }
        .onChange(of: country) { _ in code = "" }
        .onChange(of: store.loggedIn) { if $0 { password = ""; code = "" } }
        .onDisappear { password = ""; code = "" }
    }
}
#if !UI_PREVIEW
struct PairingScreen: UIViewControllerRepresentable {
    let homeID:Int64
    func makeUIViewController(context:Context) -> PairingViewController { PairingViewController(homeID:homeID) }
    func updateUIViewController(_ controller:PairingViewController,context:Context) {}
}
#else
struct PairingScreen: View {
    let homeID:Int64
    var body:some View { EmptyCard(icon:"wifi",title:"配网页面",detail:"请在真机版本使用蓝牙辅助 Wi-Fi 配网。界面预览不会扫描或连接设备。") }
}
#endif


struct HomeMembersPage: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    @State private var code = ""
    @State private var cancelInvitation: HomeInviteRow?
    @State private var confirmJoin = false
    private var homeName: String { store.homes.first { $0.id == store.homeID }?.name ?? "尚未选择家庭" }
    private var joiningBlocked: Bool { !store.canChangeHome || social.context != nil || social.oauthBusy }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SheetHeader(title: "家庭成员与邀请")
                Text(homeName).font(.title2.bold())
                Note(text: "家庭成员可使用家庭内共享的设备。这与球局报名不同；加入家庭不会重新配网，也不会自动加入组局。请使用羽小裁 App 中注册的账号。")
                if store.homeID != nil {
                    ForEach(store.homeMembers) { member in
                        HStack {
                            Label(member.name, systemImage: "person.crop.circle")
                            Spacer()
                            Text(member.role == 2 ? "家庭所有者" : member.role == 1 ? "管理员" : "成员").font(.caption).foregroundColor(Palette.muted)
                        }.padding(12).background(Color.white).cornerRadius(12)
                    }
                    Button("刷新成员与邀请") { store.loadHomeMembers() }.disabled(store.busy)
                    if store.canInviteHomeMembers {
                        Button("生成普通成员邀请码") { store.createHomeInvitation() }.buttonStyle(PrimaryStyle()).disabled(store.busy)
                        if !store.createdHomeCode.isEmpty {
                            Text(store.createdHomeCode).font(.title3.monospaced()).textSelection(.enabled)
                            Button("复制邀请码") { UIPasteboard.general.string = store.createdHomeCode }
                            Note(text: "让对方打开「我的设备 → 家庭成员与邀请」，粘贴邀请码并确认加入。")
                        }
                        ForEach(store.homeInvites) { invite in
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(invite.code).font(.body.monospaced())
                                    Text(invite.accepted ? "已接受" : "邀请有效期：\(invite.hours) 小时（以涂鸦校验为准）").font(.caption).foregroundColor(Palette.muted)
                                }
                                Spacer()
                                if !invite.accepted { Button("取消邀请", role: .destructive) { cancelInvitation = invite }.disabled(store.busy) }
                            }
                        }
                    } else { Note(text: "只有家庭所有者或管理员可以邀请新成员。") }
                }
                Divider()
                Text("加入其他家庭").font(.headline)
                TextField("粘贴家庭邀请码", text: $code).autocapitalization(.none).disableAutocorrection(true).inputStyle()
                    .disabled(store.busy).onChange(of: code) { _ in store.clearHomeInvitationPreview() }
                Button("查看邀请") { store.previewHomeInvitation(code) }.disabled(store.busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let home = store.invitedHome {
                    Text("受邀家庭：" + home.name).font(.headline)
                    Button("确认加入家庭") { confirmJoin = true }.buttonStyle(PrimaryStyle()).disabled(joiningBlocked)
                    Button("暂不加入") { store.clearHomeInvitationPreview() }.disabled(store.busy)
                    if joiningBlocked && !store.busy { Note(text: "请先处理当前比赛、组局或待确认操作，再切换家庭。") }
                }
                if store.busy { ProgressView() }
                Note(text: store.status)
                Note(text: "加入后会刷新家庭和设备列表。测试同一块设备时，请轮流操作，避免多人同时加分。")
            }.padding(22)
        }.background(Palette.background.ignoresSafeArea())
        .onAppear { store.clearHomeInvitationPreview(); store.loadHomeMembers() }
        .interactiveDismissDisabled(store.busy)
        .confirmationDialog("取消这份家庭邀请？", isPresented: Binding(get: { cancelInvitation != nil }, set: { if !$0 { cancelInvitation = nil } }), titleVisibility: .visible) {
            Button("取消邀请", role: .destructive) { if let invite = cancelInvitation { store.cancelHomeInvitation(invite) }; cancelInvitation = nil }
        } message: { Text("邀请码将无法继续用于加入家庭；不会移除已加入的成员。") }
        .confirmationDialog("加入「\(store.invitedHome?.name ?? "")」？", isPresented: $confirmJoin, titleVisibility: .visible) {
            Button("加入并查看设备") { if !joiningBlocked { store.joinInvitedHome(); code = "" } }
        } message: { Text("将使用当前登录账号加入此家庭，并切换到该家庭的设备列表。") }
    }
}
