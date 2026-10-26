import SwiftUI
import UIKit

struct GatheringPage: View {
    @EnvironmentObject var social: GatheringStore
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let openCourt: () -> Void
    @State private var create = false
    @State private var settings = false
    @State private var nickname = ""
    @State private var recovery = ""
    @State private var showRecovery = false
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("约上熟悉的人，好好打一场。").font(.title2.bold())
                    HStack {
                        Text(social.credentials.map { "组局账号 · " + $0.user.name } ?? "尚未登录组局账号")
                        Spacer()
                        Button("切换 / 管理账号") { settings = true }.accessibilityIdentifier("gathering-accounts")
                    }.font(.caption)
                    GatheringInvitationEntry(login: { settings = true })
                    if social.credentials == nil { identityForm }
                    else {
                        Button("发起组局") { create = true }.buttonStyle(PrimaryStyle()).accessibilityIdentifier("gathering-create")
                        if let context = social.context {
                            MenuRow(icon: "sportscourt", title: social.journal.archived ? "成绩已归档 · 清理设备比分" : "继续当前组局球局", subtitle: "关联已保留，请使用原设备同步状态") { dismiss(); openCourt() }
                            Note(text: "活动编号 \(context.gatheringID.prefix(8)) · \(social.journal.events.count) 条待上传")
                        }
                        if social.gatherings.isEmpty { EmptyCard(icon: "person.2", title: "今天和谁一起打？", detail: "发起一场组局，或粘贴朋友发来的邀请码。") }
                        ForEach(social.gatherings) { gathering in
                            Button { social.run { try await social.open(gathering.id) } } label: { gatheringCard(gathering) }.buttonStyle(.plain)
                        }
                        if !social.results.isEmpty { Text("我的已完成对阵").font(.headline) }
                        ForEach(social.results) { result in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(result.title).font(.headline)
                                Text(result.fixture.label)
                                Text(result.fixture.stateLabel).font(.caption).foregroundColor(Palette.muted)
                                if let mvp = result.fixture.mvp_name { Label("MVP · " + mvp, systemImage: "star.fill") }
                                if let scores = result.fixture.snapshot?.scores { Text("局数 \(scores[2]) : \(scores[3])") }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(16)
                        }
                        Button("刷新活动") { social.run { try await social.refresh() } }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    if social.busy { ProgressView("正在连接…") }
                    if !social.message.isEmpty { Note(text: social.message).accessibilityIdentifier("gathering-message") }
                }.padding(22)
            }.background(Palette.background.ignoresSafeArea()).navigationTitle("约朋友打球").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
                .sheet(isPresented: $create) { GatheringEditor().environmentObject(social) }
                .sheet(isPresented: $settings) { GatheringAccount().environmentObject(social) }
                .sheet(isPresented: Binding(get: { social.detail != nil }, set: { if !$0 { social.closeDetail() } })) {
                    GatheringDetail(openCourt: { dismiss(); openCourt() }).environmentObject(social).environmentObject(store)
                }
                .task { if social.credentials != nil { social.run { try await social.refresh() } } }
        }.navigationViewStyle(.stack).tint(Palette.green)
    }
    private var identityForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Note(text: "组局身份用于报名和保存活动，独立于设备账号。球友无需绑定设备。")
            TextField("你的球场昵称", text: $nickname).inputStyle()
            Button("创建组局身份") { social.run { try await social.login(name: nickname); settings = true } }.buttonStyle(PrimaryStyle()).disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty || social.busy)
            SecureField("已有身份的恢复凭据", text: $recovery).inputStyle()
            Button("恢复身份") { social.run { try await social.login(name: "", recovery: recovery); recovery = "" } }.disabled(recovery.isEmpty || social.busy)
            Button("配置本地服务器") { settings = true }
        }
    }
    private func gatheringCard(_ g: Gathering) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(g.title).font(.headline); Spacer(); Text(g.stateLabel).font(.caption).foregroundColor(Palette.green) }
            HStack {
                if g.owner_id == social.userID { Text("我发起的").font(.caption.bold()) }
                Text(g.registration(for: social.userID).title).font(.caption.bold())
            }.foregroundColor(Palette.green)
            Text(g.location).font(.subheadline)
            Text(Date(timeIntervalSince1970: g.starts_at).formatted()).font(.caption).foregroundColor(Palette.muted)
            Text("\(g.members.filter { $0.status == "confirmed" }.count)/\(g.capacity) 人 · \(g.fixtures.count) 场对阵").font(.caption)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(18)
    }
}

struct GatheringAccount: View {
    @EnvironmentObject var social: GatheringStore
    @State private var endpoint = ""
    @State private var reveal = false
    @State private var nickname = ""
    @State private var recovery = ""
    @State private var confirmLogout = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "组局身份与服务器")
            if let credentials = social.credentials {
                Text(credentials.user.name).font(.title2.bold())
                Note(text: credentials.auth_provider == "tuya" ? "已关联涂鸦身份。退出后请在「账号与安全」重新授权登录，旧恢复码已失效。" : "恢复凭据相当于登录密码，请存入密码管理器，不要随邀请分享。换手机时用它恢复组局身份。")
                if credentials.recovery != nil { Button(reveal ? "隐藏恢复凭据" : "查看恢复凭据") { reveal.toggle() } }
                if reveal, let recovery = credentials.recovery { Text(recovery).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Button("退出并移除此机登录", role: .destructive) { confirmLogout = true }
            }
            Text("本机组局账号").font(.headline)
            Note(text: "组局账号独立于涂鸦设备账号。切换后可用同一部手机体验邀请人与受邀人的操作。")
            ForEach(social.savedAccounts, id: \.user.id) { account in
                HStack {
                    VStack(alignment: .leading) { Text(account.user.name); Text(String(account.user.id.prefix(8))).font(.caption).foregroundColor(Palette.muted) }
                    Spacer()
                    if account.user.id == social.userID { Text("当前账号") }
                    else if account.auth_provider == "tuya" { Text("请退出当前账号后重新授权").font(.caption) }
                    else { Button("切换到 " + account.user.name) { social.run { try await social.switchAccount(account.user.id); reveal = false } }.disabled(social.busy || social.oauthBusy) }
                }
            }
            Divider()
            TextField("新账号昵称", text: $nickname).inputStyle()
            Button("创建并切换新账号") { social.run { try await social.login(name: nickname); nickname = ""; reveal = false } }.disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || social.busy)
            SecureField("其他账号的恢复凭据", text: $recovery).inputStyle()
            Button("恢复并切换账号") { social.run { try await social.login(name: "", recovery: recovery); recovery = ""; reveal = false } }.disabled(recovery.isEmpty || social.busy)
            #if DEBUG
            Text("开发服务器").font(.headline)
            TextField("http://Mac的局域网IP:18100", text: $endpoint).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL).inputStyle()
            Note(text: "真机不能用 127.0.0.1 访问 Mac。请使用同一 Wi-Fi 下 Mac 的局域网地址，并允许本地网络访问。")
            Button("保存服务器地址") { social.run { try social.configure(endpoint) } }.buttonStyle(PrimaryStyle())
            #endif
            Text(social.origin).font(.caption).textSelection(.enabled)
            Note(text: social.message)
        }.padding(22) }.background(Palette.background.ignoresSafeArea()).onAppear { endpoint = social.origin }
        .confirmationDialog(social.credentials?.auth_provider == "tuya" ? "退出后可使用同一涂鸦账号重新授权登录，成绩和组局保留。" : "退出前请保存恢复凭据，否则无法重新登录这个组局账号。其他本机账号会保留。", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出并移除此机登录", role: .destructive) { social.run { try await social.logout(); reveal = false } }
        }
    }
}

struct GatheringEditor: View {
    @EnvironmentObject var social: GatheringStore
    @Environment(\.dismiss) private var dismiss
    var existing: Gathering? = nil
    @State private var title = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var court = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var capacity = 8
    @State private var hasEnd = false
    @State private var end = Date().addingTimeInterval(10800)
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: existing == nil ? "发起组局" : "修改组局")
            TextField("活动名称（最多30字）", text: $title).inputStyle().onChange(of: title) { title = String($0.prefix(30)) }
            TextField("球馆或地点", text: $location).inputStyle()
            DatePicker("开始时间", selection: $date)
            Toggle("设置预计结束时间", isOn: $hasEnd)
            if hasEnd { DatePicker("预计结束", selection: $end, in: date...) }
            Stepper("人数上限 · \(capacity) 人", value: $capacity, in: 2...32)
            TextField("场地备注（选填）", text: $court).inputStyle()
            TextField("活动说明（选填）", text: $notes).inputStyle().onChange(of: notes) { notes = String($0.prefix(500)) }
            Note(text: "发布后分享给熟人。满员后自动候补；单打、双打对阵在报名后手动安排。设备赛制：21 分 · 三局两胜。")
            Button(existing == nil ? "保存草稿" : "保存修改") {
                social.run {
                    let body: [String: Any] = ["ends_at": hasEnd ? end.timeIntervalSince1970 as Any : NSNull(), "title": title, "location": location, "starts_at": date.timeIntervalSince1970, "capacity": capacity, "notes": notes, "court": court]
                    if let existing = existing { try await social.action("edit", gathering: existing, body: body) }
                    else { try await social.create(body) }
                    dismiss()
                }
            }.buttonStyle(PrimaryStyle()).disabled(title.isEmpty || location.isEmpty || social.busy)
            Note(text: social.message)
        }.padding(22) }.background(Palette.background.ignoresSafeArea()).onAppear {
            if let g = existing { title = g.title; location = g.location; notes = g.notes; court = g.court; date = Date(timeIntervalSince1970: g.starts_at); capacity = g.capacity; hasEnd = g.ends_at != nil; end = Date(timeIntervalSince1970: g.ends_at ?? g.starts_at + 7200) }
        }
    }
}

struct GatheringDetail: View {
    @EnvironmentObject var social: GatheringStore
    @EnvironmentObject var store: AppStore
    let openCourt: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edit = false
    @State private var arrange = false
    @State private var editingFixture: GatheringFixture?
    @State private var share: String?
    @State private var confirmAction: String?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "组局详情")
            if let g = social.detail {
                Text(g.title).font(.title.bold())
                Text("\(g.stateLabel) · \(g.organizer) 发起").foregroundColor(Palette.muted)
                VStack(alignment: .leading, spacing: 8) {
                    Text("我的报名 · " + g.registration(for: social.userID).title).font(.headline)
                    Note(text: g.terminal ? "活动已" + (g.status == "cancelled" ? "取消" : "结束") + "，以上为最终报名状态。" : g.registration(for: social.userID).explanation)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.soft).cornerRadius(16)
                Label(g.location, systemImage: "mappin.and.ellipse")
                Text(Date(timeIntervalSince1970: g.starts_at).formatted())
                if let end = g.ends_at { Note(text: "预计结束 · " + Date(timeIntervalSince1970: end).formatted()) }
                if !g.court.isEmpty { Text(g.court) }
                if !g.notes.isEmpty { Note(text: g.notes) }
                if g.owner_id == social.userID && !g.terminal {
                    if g.status == "draft" { Button("确认发布") { social.run { try await social.action("publish", gathering: g) } }.buttonStyle(PrimaryStyle()) }
                    else if g.signup_open { Button("生成新邀请并分享") { social.run { share = try await social.invite(g) } }.buttonStyle(PrimaryStyle()) }
                    HStack { Button("修改信息") { edit = true }; Spacer(); if g.signup_open { Button("关闭报名") { social.run { try await social.action("close", gathering: g) } } } }
                }
                Text("报名名单 · \(g.members.filter { $0.status == "confirmed" }.count)/\(g.capacity)").font(.headline)
                ForEach(Array(g.members.enumerated()), id: \.element.id) { index, m in
                    HStack { Text(m.name); Spacer(); Text(m.status == "confirmed" ? "已报名" : "候补 \(g.members.prefix(index + 1).filter { $0.status == "waitlisted" }.count)").foregroundColor(Palette.muted) }
                }
                if !g.terminal && g.members.contains(where: { $0.user_id == social.userID }) { Button("退出参赛名单", role: .destructive) { confirmAction = "leave" } }
                Divider()
                HStack { Text("对阵与成绩").font(.headline); Spacer(); if g.owner_id == social.userID && !g.terminal && g.status != "draft" { Button("安排对阵") { editingFixture = nil; arrange = true } } }
                if g.fixtures.isEmpty { Note(text: "等球友报名后，选择单打或双打阵容。") }
                ForEach(g.fixtures) { f in fixtureCard(f, gathering: g) }
                if g.owner_id == social.userID && !g.terminal {
                    Divider()
                    HStack { Button("结束活动") { confirmAction = "finish" }; Spacer(); Button("取消活动", role: .destructive) { confirmAction = "cancel" } }
                }
                Button("刷新详情") { social.run { try await social.open(g.id); await social.flush() } }.frame(maxWidth: .infinity, minHeight: 44)
                Note(text: social.message)
            }
        }.padding(22) }.background(Palette.background.ignoresSafeArea())
            .sheet(isPresented: $edit) { if let g = social.detail { GatheringEditor(existing: g).environmentObject(social) } }
            .sheet(isPresented: $arrange) { if let g = social.detail { GatheringLineup(gathering: g, existing: editingFixture).environmentObject(social) } }
            .sheet(isPresented: Binding(get: { share != nil }, set: { if !$0 { share = nil } })) { if let share = share { GatheringShare(text: share) } }
            .confirmationDialog("确认操作？", isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }), titleVisibility: .visible) {
                Button("确认", role: .destructive) { if let action = confirmAction, let g = social.detail { social.run { try await social.action(action, gathering: g) } }; confirmAction = nil }
                Button("返回", role: .cancel) { confirmAction = nil }
            } message: { Text(confirmAction == "leave" ? "退出后将移出报名或候补名单，空出的正式名额会按顺序递补。若已安排对阵，需要先由发起人处理。" : "结束或取消活动后停止报名，未开始的对阵标记为未进行。正在比赛或暂停的球局必须先处理。") }
    }
    private func fixtureCard(_ f: GatheringFixture, gathering g: Gathering) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("第 \(f.number) 场").font(.headline); Spacer(); Text(f.stateLabel).font(.caption) }
            Text(f.label)
            if let mvp = f.mvp_name { Label("MVP · " + mvp, systemImage: "star.fill").foregroundColor(Palette.green) }
            if let court = f.court, !court.isEmpty { Note(text: court) }
            if let snapshot = f.snapshot { Text("局数 \(snapshot.scores[2]) : \(snapshot.scores[3]) · 当前比分 \(snapshot.scores[0]) : \(snapshot.scores[1])") }
            if f.status == "scheduled" && !g.terminal {
                if f.referee_id == social.userID {
                    Button("用当前设备开赛") { social.run { try await social.reserve(f, gathering: g, session: store.session, deviceID: store.selected?.id); dismiss(); openCourt() } }
                    Note(text: "当前设备：\(store.selected?.name ?? "未选择，请回到我的装备连接")")
                }
                if g.owner_id == social.userID {
                    Button("修改阵容 / 裁判") { editingFixture = f; arrange = true }
                    Button("移除待开始对阵", role: .destructive) { social.run { try await social.deleteFixture(f, gathering: g) } } }
            }
            if social.context?.fixtureID == f.id {
                Button("回到关联球局并同步") { store.session?.send("Q"); dismiss(); openCourt() }
                if f.status == "scheduled" || f.status == "starting" {
                    Button("核对设备未开赛") { social.run { try await social.reconcileUnstarted(f, session: store.session, deviceID: store.selected?.id) } }
                    Note(text: "仅在原设备最新同步为待机且无比分时可解除开赛预占。")
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(18)
    }
}

struct GatheringLineup: View {
    @EnvironmentObject var social: GatheringStore
    @Environment(\.dismiss) private var dismiss
    let gathering: Gathering
    var existing: GatheringFixture? = nil
    @State private var doubles = false
    @State private var slots = ["", "", "", ""]
    @State private var referee = ""
    @State private var court = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "安排一场对阵")
            Picker("形式", selection: $doubles) { Text("单打").tag(false); Text("双打").tag(true) }.pickerStyle(.segmented)
            ForEach(doubles ? [0,1,2,3] : [0,2], id: \.self) { index in
                Picker(["我方球员", "我方队友", "对方球员", "对方队友"][index], selection: $slots[index]) {
                    Text("请选择").tag("")
                    ForEach(gathering.members.filter { $0.status == "confirmed" }) { Text($0.name).tag($0.user_id) }
                }
            }
            Picker("裁判", selection: $referee) {
                Text(gathering.organizer + "（组织者）").tag(gathering.owner_id)
                ForEach(gathering.members.filter { $0.status == "confirmed" && $0.user_id != gathering.owner_id }) { Text($0.name).tag($0.user_id) }
            }
            TextField("本场场地备注（选填）", text: $court).inputStyle()
            Note(text: "裁判需使用自己有控制权限的设备。每个活动同时只进行一场，暂停后请先恢复或放弃。")
            Button("保存对阵") { social.run { try await social.fixture(gathering, red: doubles ? [slots[0],slots[1]] : [slots[0]], blue: doubles ? [slots[2],slots[3]] : [slots[2]], referee: referee, court: court, existing: existing); dismiss() } }.buttonStyle(PrimaryStyle()).disabled(social.busy)
            Note(text: social.message)
        }.padding(22) }.background(Palette.background.ignoresSafeArea()).onAppear {
            referee = existing?.referee_id ?? gathering.owner_id
            if let f = existing { court = f.court ?? ""; doubles = f.red.count == 2; slots = [f.red[0], f.red.count > 1 ? f.red[1] : "", f.blue[0], f.blue.count > 1 ? f.blue[1] : ""] }
        }
    }
}
struct GatheringShare: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [text], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
