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
                        Text(social.credentials.map { "组局账号 · " + $0.user.name } ?? "登录后查看我的组局")
                        Spacer()
                        Button("账号与安全") { settings = true }.accessibilityIdentifier("gathering-accounts")
                    }.font(.caption)
                    GatheringInvitationEntry(login: { settings = true })
                    if social.needsLogin { identityForm }
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
                .sheet(isPresented: $settings) { AccountCenter().environmentObject(social) }
                .sheet(isPresented: Binding(get: { social.detail != nil }, set: { if !$0 { social.closeDetail() } })) {
                    GatheringDetail(openCourt: { dismiss(); openCourt() }).environmentObject(social).environmentObject(store)
                }
                .task { if social.credentials != nil { social.run { try await social.refresh() } } }
        }.navigationViewStyle(.stack).tint(Palette.green)
    }
    private var identityForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Note(text: "登录羽小裁后，即可发起组局、报名和保存成绩，无需先绑定设备。")
            Button("登录羽小裁") { settings = true }.buttonStyle(PrimaryStyle())
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
            Label(g.playFormat.title, systemImage: g.playFormat.icon).font(.caption).foregroundColor(Palette.green)
            Text("\(g.members.filter { $0.status == "confirmed" }.count)/\(g.capacity) 人 · \(g.fixtures.count) 场对阵").font(.caption)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(18)
    }
}

struct GatheringAccount: View {
    @EnvironmentObject var social: GatheringStore
    @EnvironmentObject var store: AppStore
    @State private var endpoint = ""
    @State private var recovery = ""
    private var blocked: Bool {
        social.busy || social.oauthBusy || store.busy || social.context != nil || !social.journal.events.isEmpty || !social.recordsJournal.pending.isEmpty || store.session?.pending != nil || ["a","p"].contains(store.session?.current?.state ?? "")
    }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            SheetHeader(title:"服务器与旧账号恢复")
            if let credentials = social.credentials { Text("当前账号：" + credentials.user.name).font(.headline) }
            Note(text:"新账号请在账号与安全中注册。旧恢复凭据仅用于找回原有数据，恢复后需设置账号密码才能继续操作。")
            SecureField("旧版账号恢复凭据",text:$recovery).inputStyle()
            Button("恢复旧账号") {
                social.run {
                    defer { recovery = "" }
                    try await social.login(name:"",recovery:recovery)
                    store.logout()
                }
            }.disabled(blocked || recovery.isEmpty || !social.needsLogin)
            if !social.needsLogin { Note(text:"请先在账号与安全退出当前账号，再恢复其他账号。") }
            #if DEBUG
            Divider()
            Text("开发服务器").font(.headline)
            TextField("HTTPS 地址或 Mac 局域网地址",text:$endpoint).autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL).inputStyle()
            Button("保存服务器地址") { social.run { try social.configure(endpoint); store.logout() } }.buttonStyle(PrimaryStyle()).disabled(blocked)
            Button("切换到赛事服务器") { social.run { try social.configure(GatheringStore.defaultOrigin); endpoint = social.origin; store.logout() } }.disabled(blocked || social.origin == GatheringStore.defaultOrigin)
            Note(text:"不同服务器的登录凭据相互隔离。切换地址后需重新登录。局域网 HTTP 仅用于开发测试。")
            #endif
            Text(social.origin).font(.caption).textSelection(.enabled)
            Button("检查服务连接") { social.run { try await social.checkAuthorizationConnection(); social.message="业务服务可连接" } }.disabled(blocked)
            Note(text:social.message)
        }.padding(22) }.background(Palette.background.ignoresSafeArea()).onAppear { endpoint=social.origin }
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
    @State private var playFormat = GatheringFormat.free
    @State private var hasEnd = false
    @State private var end = Date().addingTimeInterval(10800)
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: existing == nil ? "发起组局" : "修改组局")
            Text("选一种相聚的方式").font(.title2.bold())
            ForEach(GatheringFormat.allCases) { mode in
                Button { playFormat = mode; capacity = max(capacity, mode.minimum) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: mode.icon).frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) { Text(mode.title).font(.headline); Text(mode.subtitle).font(.caption).foregroundColor(Palette.muted) }
                        Spacer()
                        Image(systemName: playFormat == mode ? "checkmark.circle.fill" : "circle")
                    }.padding(16).background(playFormat == mode ? Palette.soft : Color.white).cornerRadius(18)
                }.buttonStyle(.plain).disabled(existing?.fixtures.isEmpty == false)
            }
            Note(text: playFormat.explanation)
            TextField("活动名称（最多30字）", text: $title).inputStyle().onChange(of: title) { title = String($0.prefix(30)) }
            TextField("球馆或地点", text: $location).inputStyle()
            DatePicker("开始时间", selection: $date)
            Toggle("设置预计结束时间", isOn: $hasEnd)
            if hasEnd { DatePicker("预计结束", selection: $end, in: date...) }
            Stepper("人数上限 · \(capacity) 人", value: $capacity, in: 2...32)
            TextField("场地备注（选填）", text: $court).inputStyle()
            TextField("活动说明（选填）", text: $notes).inputStyle().onChange(of: notes) { notes = String($0.prefix(500)) }
            Note(text: "发布后分享给熟人，满员自动候补。报名后确认球员和赛程。所有玩法当前均使用设备赛制：21 分 · 三局两胜。")
            Button(existing == nil ? "保存草稿" : "保存修改") {
                social.run {
                    let body: [String: Any] = ["format": playFormat.rawValue, "ends_at": hasEnd ? end.timeIntervalSince1970 as Any : NSNull(), "title": title, "location": location, "starts_at": date.timeIntervalSince1970, "capacity": capacity, "notes": notes, "court": court]
                    if let existing = existing { try await social.action("edit", gathering: existing, body: body) }
                    else { try await social.create(body) }
                    dismiss()
                }
            }.buttonStyle(PrimaryStyle()).disabled(title.isEmpty || location.isEmpty || social.busy)
            Note(text: social.message)
        }.padding(22) }.background(Palette.background.ignoresSafeArea()).onAppear {
            if let g = existing { playFormat = g.playFormat; title = g.title; location = g.location; notes = g.notes; court = g.court; date = Date(timeIntervalSince1970: g.starts_at); capacity = g.capacity; hasEnd = g.ends_at != nil; end = Date(timeIntervalSince1970: g.ends_at ?? g.starts_at + 7200) }
        }
    }
}

struct GatheringDetail: View {
    @State private var racketFixture: GatheringFixture?
    @EnvironmentObject var rackets: RacketStore
    @EnvironmentObject var social: GatheringStore
    @EnvironmentObject var store: AppStore
    let openCourt: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edit = false
    @State private var arrange = false
    @State private var schedule = false
    @State private var editingFixture: GatheringFixture?
    @State private var share: String?
    @State private var confirmAction: String?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "组局详情")
            if let g = social.detail {
                Text(g.title).font(.title.bold())
                Label(g.playFormat.title, systemImage: g.playFormat.icon).foregroundColor(Palette.green)
                Note(text: g.playFormat.subtitle)
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
                HStack { Text("对阵与成绩").font(.headline); Spacer(); if g.owner_id == social.userID && !g.terminal && g.status != "draft" { if !g.playFormat.staged { Button("安排对阵") { editingFixture = nil; arrange = true } } } }
                if g.fixtures.isEmpty {
                    Note(text: g.playFormat.explanation)
                    if g.playFormat != .free && g.owner_id == social.userID && !g.terminal && g.status != "draft" {
                        Button("选择球员，预览赛程") { schedule = true }.buttonStyle(PrimaryStyle()).disabled(social.busy)
                    }
                }
                if !g.standings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(g.playFormat == .family_doubles ? "一起完成的比赛" : "本次活动 · 个人战绩").font(.headline)
                        ForEach(g.standings) { row in
                            HStack {
                                Text(row.name); Text(String(row.id.suffix(6))).font(.caption2).foregroundColor(Palette.muted)
                                Spacer(); Text("\(row.played) 场 · \(row.won) 胜").monospacedDigit()
                            }
                        }
                        Note(text: "仅统计正常完成的对阵，提前结束不计胜负。按胜场、净胜局排序；同分并列，不作为官方竞技排名。")
                    }.padding(16).background(Palette.soft).cornerRadius(18)
                }
                if g.canAdvance && g.owner_id == social.userID {
                    Button("按本轮成绩生成下一轮") { social.run { try await social.action("next-round", gathering: g) } }.buttonStyle(PrimaryStyle()).disabled(social.busy)
                }
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
            .sheet(isPresented: $schedule) { if let g = social.detail { GatheringScheduleEditor(gathering: g).environmentObject(social) } }
            .sheet(isPresented: $arrange) { if let g = social.detail { GatheringLineup(gathering: g, existing: editingFixture).environmentObject(social) } }
            .sheet(item: $racketFixture) { fixture in
                RacketRosterPage(matchKey: fixture.id, requiredHostID: store.selected?.id, fixtureID: fixture.id,
                    fixed: fixture.red.map { RacketAssignment(person: RacketPerson(kind: .user, stableID: $0, name: fixture.names[$0] ?? "球友"), team: .red) }
                        + fixture.blue.map { RacketAssignment(person: RacketPerson(kind: .user, stableID: $0, name: fixture.names[$0] ?? "球友"), team: .blue) },
                    maySubmit: fixture.referee_id == social.userID && fixture.status == "scheduled")
            }
            .sheet(isPresented: Binding(get: { share != nil }, set: { if !$0 { share = nil } })) { if let share = share { GatheringShare(text: share) } }
            .confirmationDialog("确认操作？", isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }), titleVisibility: .visible) {
                Button("确认", role: .destructive) { if let action = confirmAction, let g = social.detail { social.run { try await social.action(action, gathering: g) } }; confirmAction = nil }
                Button("返回", role: .cancel) { confirmAction = nil }
            } message: { Text(confirmAction == "leave" ? "退出后将移出报名或候补名单，空出的正式名额会按顺序递补。若已安排对阵，需要先由发起人处理。" : "结束或取消活动后停止报名，未开始的对阵标记为未进行。正在比赛或暂停的球局必须先处理。") }
    }
    private func fixtureCard(_ f: GatheringFixture, gathering g: Gathering) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("第 \(f.number) 场").font(.headline); Spacer(); Text(f.stateLabel).font(.caption) }
            if let round = f.round { Text((f.pool.map { "\($0) 组 · " } ?? "") + (f.stage == "knockout" ? "淘汰阶段 · " : "") + "第 \(round) 轮").font(.caption).foregroundColor(Palette.muted) }
            Text(f.label)
            Button("球员与拍底准备状态") { racketFixture = f }
            if let mvp = f.mvp_name { Label("MVP · " + mvp, systemImage: "star.fill").foregroundColor(Palette.green) }
            if let court = f.court, !court.isEmpty { Note(text: court) }
            if let snapshot = f.snapshot { Text("局数 \(snapshot.scores[2]) : \(snapshot.scores[3]) · 当前比分 \(snapshot.scores[0]) : \(snapshot.scores[1])") }
            if f.status == "scheduled" && !g.terminal {
                if f.referee_id == social.userID {
                    Button("用当前设备开赛") { social.run { try await social.reserve(f, gathering: g, session: store.session, deviceID: store.selected?.id); dismiss(); openCourt() } }
                        .disabled(rackets.operation(for: "match:" + f.id) != nil && (!rackets.rosterConfirmed || rackets.rosterDraft?.matchKey != f.id || rackets.context?.hostID != store.selected?.id))
                    Note(text: "当前设备：\(store.selected?.name ?? "未选择，请回到我的装备连接")")
                }
                if g.owner_id == social.userID {
                    Button("修改阵容 / 裁判") { editingFixture = f; arrange = true }
                    if !g.playFormat.staged { Button("移除待开始对阵", role: .destructive) { social.run { try await social.deleteFixture(f, gathering: g) } } } }
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
    @EnvironmentObject var rackets: RacketStore
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
            Picker("形式", selection: $doubles) { Text("单打").tag(false); Text("双打").tag(true) }.pickerStyle(.segmented).disabled(gathering.playFormat.staged && existing != nil)
            ForEach(doubles ? [0,1,2,3] : [0,2], id: \.self) { index in
                Picker(["我方球员", "我方队友", "对方球员", "对方队友"][index], selection: $slots[index]) {
                    Text("请选择").tag("")
                    ForEach(gathering.members.filter { $0.status == "confirmed" }) { Text($0.name).tag($0.user_id) }
                }.disabled(gathering.playFormat.staged && existing != nil)
                if !slots[index].isEmpty {
                    let linked = rackets.devices.filter { $0.user?.kind == .user && $0.user?.stableID == slots[index] }
                    if linked.isEmpty { Note(text: rackets.capabilities.roster && rackets.message.isEmpty ? "未发现关联拍底，可通过 App 计分" : "拍底状态尚未接入，不影响报名与手动计分") }
                    ForEach(linked) { device in RacketRow(device: device) }
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

/// The server previews and commits the same stable-ID roster. No client-side fake fixtures.
struct GatheringScheduleEditor: View {
    @EnvironmentObject var social: GatheringStore
    @Environment(\.dismiss) private var dismiss
    let gathering: Gathering
    @State private var selected: [String] = []
    @State private var pairs: [String] = []
    @State private var preview: [GatheringFixture] = []
    @State private var working = false
    @State private var error = ""
    @State private var operationID = UUID().uuidString
    private var members: [GatheringMember] { gathering.members.filter { $0.status == "confirmed" } }
    private var mode: GatheringFormat { gathering.playFormat }
    private var valid: Bool {
        let n = selected.count
        return n >= mode.minimum && n <= 16 && (mode.requiredCount == nil || n == mode.requiredCount)
            && (!mode.fixedTeams || (n.isMultiple(of: 2) && pairs.count == n && Set(pairs) == Set(selected)))
    }
    private var payload: [String: Any] {
        var body: [String: Any] = ["players": selected, "expected_format": mode.rawValue]
        if mode.fixedTeams { body["teams"] = stride(from: 0, to: pairs.count - pairs.count % 2, by: 2).map { [pairs[$0], pairs[$0 + 1]] } }
        return body
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: mode.title)
            Note(text: mode.subtitle)
            Text("参赛球员 · 已选 \(selected.count) 人").font(.headline)
            Note(text: "仅选择正式报名成员，最多 16 人。同名球友请核对编号。")
            ForEach(members) { member in
                Button {
                    if selected.contains(member.id) { selected.removeAll { $0 == member.id } }
                    else if selected.count < 16 { selected.append(member.id) }
                    pairs = selected; preview = []; error = ""; operationID = UUID().uuidString
                } label: {
                    HStack { Text(member.name); Text(String(member.id.suffix(6))).font(.caption).foregroundColor(Palette.muted); Spacer(); Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle") }
                        .padding(12).background(Color.white).cornerRadius(12)
                }.buttonStyle(.plain).disabled(working)
            }
            if mode.fixedTeams && !selected.isEmpty {
                Text(mode == .family_doubles ? "确认家庭搭档" : "确认固定搭档").font(.headline)
                Note(text: mode.explanation)
                ForEach(pairs.indices, id: \.self) { index in
                    Picker("第 \(index / 2 + 1) 组 · \(mode == .family_doubles ? (index % 2 == 0 ? "家长" : "孩子") : (index % 2 == 0 ? "球员一" : "球员二"))", selection: Binding(get: { pairs[index] }, set: { new in
                        if let previous = pairs.firstIndex(of: new) { pairs.swapAt(index, previous) }
                        preview = []; operationID = UUID().uuidString
                    })) {
                        ForEach(members.filter { selected.contains($0.id) }) { member in
                            Text(member.name + " · " + member.id.suffix(6)).tag(member.id)
                        }
                    }.disabled(working)
                }
            }
            Button(working ? "正在处理…" : "预览赛程") { Task { await loadPreview() } }
                .buttonStyle(PrimaryStyle()).disabled(!valid || working)
            if !valid { Note(text: mode.requiredCount.map { "此玩法需要恰好 \($0) 人。" } ?? (mode.fixedTeams ? "请选择 4–16 位球员，两人组成一队。" : "请选择 2–16 位球员。")) }
            if !preview.isEmpty {
                Text((mode.staged ? "首阶段赛程 · " : "赛程预览 · ") + "\(preview.count) 场").font(.title2.bold())
                Note(text: "按轮次依次开赛，默认由组织者执裁；生成后可逐场修改裁判和场地。21 分 · 三局两胜。")
                ForEach(preview) { f in
                    VStack(alignment: .leading, spacing: 6) {
                        if let pool = f.pool { Text(pool + " 组").font(.caption) }
                        Text("第 \(f.round ?? 1) 轮 · 第 \(f.number) 场").font(.caption).foregroundColor(Palette.muted)
                        Text(f.label).font(.subheadline)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(14)
                }
                Button("确认生成 \(preview.count) 场对阵") { Task { await commit() } }.buttonStyle(PrimaryStyle()).disabled(working)
            }
            if !error.isEmpty { Note(text: error) }
        }.padding(22) }.background(Palette.background.ignoresSafeArea())
    }
    private func loadPreview() async {
        working = true; error = ""; defer { working = false }
        do {
            let value: GatheringSchedulePreview = try await social.request("/gatherings/\(gathering.id)/schedule-preview", body: payload)
            preview = value.fixtures
        } catch { self.error = error.localizedDescription; preview = [] }
    }
    private func commit() async {
        working = true; error = ""; defer { working = false }
        do {
            var body = payload; body["operation_id"] = operationID
            let _: Gathering = try await social.request("/gatherings/\(gathering.id)/schedule", body: body)
            try await social.open(gathering.id)
            dismiss()
        } catch { self.error = error.localizedDescription + "。若网络中断，可重试确认；同一次操作不会重复生成。" }
    }
}
