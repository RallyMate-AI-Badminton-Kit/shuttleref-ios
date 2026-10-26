import SwiftUI

struct CourtPage: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    @Binding var focused: Bool
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewScores: [UInt8] = [8,6,0,0,0]
    let resumeRequest: UUID
    let openDevices: () -> Void
    let openRecords: () -> Void
    let openGatherings: () -> Void
    @State private var stage = "home"
    @State private var doubles = false
    @State private var names = ["我方球员","我方队友","对方球员","对方队友"]
    @State private var selfNameEdited = false
    @State private var editIndex: Int?
    @State private var nameDraft = ""
    @State private var fortune = false
    @State private var exitMenu = false
    @State private var discard = false
    @State private var result = false
    @State private var earlyResult = false
    private var session: MatchSession? { store.session }
    private var groupDeviceReady: Bool { social.context == nil || social.context?.deviceID == store.selected?.id && social.context?.matchID == session?.current?.id }
    private var currentSettled: Bool {
        guard let current = session?.current, current.hasID, ["a", "p"].contains(current.state) else { return false }
        if let context = social.context {
            return context.matchID == current.id && context.deviceID == store.selected?.id && (social.journal.archived || social.journal.events.contains { $0.context.matchID == current.id && ["complete", "early_end"].contains($0.op) })
        }
        return session?.completedResults.contains { $0.id == current.id } == true
    }
    private var homeState: CourtHomeState { CourtHomeState(snapshot: session?.current, saved: session?.saved, settled: currentSettled) }
    private var defaultSelfName: String { CourtRoster.defaultName(account: social.credentials?.user.name, deviceAccount: store.nickname) }

    private var settledEarly: Bool { social.context != nil ? social.journal.earlyEnded == true : session?.completedResults.first(where: { $0.id == session?.current?.id })?.earlyEnded == true }
    private var live: Bool { stage == "live" }
    private var hasMatch: Bool { session?.current?.state == "a" || session?.current?.state == "p" || session?.saved != nil }
    private var previewLive: Bool {
        #if UI_PREVIEW
        return live
        #else
        return false
        #endif
    }
    var body: some View {
        VStack(spacing:0) {
            PageHeader(title:stage == "home" ? "球局" : live ? "本局得分":"准备开赛", back:stage == "home" ? nil : { stage = "home" }, deviceAction:openDevices)
            ScrollView {
                VStack(spacing:20) {
                    courtHeading
                    CourtScene(live:live, compact:stage == "home", doubles:doubles, names:names,
                               scores:previewLive ? previewScores : session?.current?.scores,
                               scoreContext:scoreContext, scoreEventsEnabled:previewLive || scoreAnimationAllowed,
                               visible:visible, actionable:stage != "home" && (!live || previewLive || session?.can("r") == true && groupDeviceReady)) { index in
                        if live {
                            #if UI_PREVIEW
                            previewScores[index >= 2 ? 1:0] += 1
                            #else
                            session?.send(index >= 2 ? "b":"r")
                            #endif
                        } else if social.context == nil { nameDraft = names[index]; editIndex = index }
                    }
                    .frame(maxWidth:.infinity)
                    .frame(height:stage == "home" ? 300 : live ? 455:365)
                    .padding(.vertical,stage == "home" ? 8:0)
                    .padding(.bottom,live ? 8:0)
                    if live {
                        Text("21 分 · 三局两胜").font(.system(size:12,weight:.medium))
                            .foregroundColor(Palette.muted)
                            .accessibilityIdentifier("live-match-rules")
                    }
                    if stage == "home" { homeContent }
                    else { matchContent }
                }.padding(.horizontal,22).padding(.top,12).padding(.bottom,28)
            }.accessibilityIdentifier("court-scroll")
        }
        .animation(reduceMotion ? nil : .timingCurve(0.22,0.8,0.24,1,duration:0.95),value:stage)
        .animation(reduceMotion ? nil : .timingCurve(0.22,0.8,0.24,1,duration:0.95),value:doubles)
        .onChange(of:stage) { focused = $0 != "home" }
        .onChange(of:resumeRequest) { _ in loadGroupRoster(); stage = "live"; session?.send("Q") }
        .onChange(of:social.context?.matchID) { _ in if social.context == nil && !hasMatch { loadRoster() } else { loadGroupRoster() } }
        .onChange(of:social.userID) { _ in if social.context == nil && !hasMatch { loadRoster() } }
        .onChange(of:defaultSelfName) { _ in if social.context == nil && !hasMatch && !selfNameEdited { names[0] = defaultSelfName } }
        .onChange(of:session?.lastConfirmed) { op in
            if op == "B" || op == "R" { stage = "live" }
            if op == "P" || op == "A" { stage = "home" }
            if op == "A" { loadRoster() }
        }
        .onChange(of:store.accountID) { _ in stage = "home"; loadRoster() }
        .onAppear {
            loadRoster(); loadGroupRoster()
            #if UI_PREVIEW
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of:"--screen"),args.count > i+1, ["prepare","live"].contains(args[i+1]) { stage = args[i+1];focused = true }
            #endif
        }
        #if UI_PREVIEW
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--motion-tour") else { return }
            do {
                try await Task.sleep(nanoseconds:1_500_000_000); stage = "prepare"
                try await Task.sleep(nanoseconds:1_500_000_000); doubles = true
                try await Task.sleep(nanoseconds:1_500_000_000); doubles = false
                try await Task.sleep(nanoseconds:1_500_000_000); doubles = true
                try await Task.sleep(nanoseconds:1_500_000_000); stage = "live"
                try await Task.sleep(nanoseconds:2_000_000_000); previewScores[0] += 1
                try await Task.sleep(nanoseconds:1_200_000_000); previewScores[1] += 1
                try await Task.sleep(nanoseconds:1_200_000_000); previewScores[0] -= 1
                try await Task.sleep(nanoseconds:1_500_000_000); stage = "home"
            } catch { /* Preview closed: cancel subsequent actions. */ }
        }
        #endif
        .sheet(isPresented:Binding(get:{ editIndex != nil },set:{ if !$0 { editIndex = nil } })) {
            VStack(alignment:.leading,spacing:24) {
                SheetHeader(title:"球员名字")
                TextField("输入名字",text:$nameDraft).inputStyle().onChange(of:nameDraft) { nameDraft = String($0.prefix(12)) }
                Button("保存") { if let index = editIndex { names[index] = nameDraft.trimmingCharacters(in:.whitespacesAndNewlines); if index == 0 { selfNameEdited = true }; saveRoster() };editIndex = nil }.buttonStyle(PrimaryStyle()).disabled(nameDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Spacer()
            }.padding(24).background(Palette.background.ignoresSafeArea())
        }
        .sheet(isPresented:$fortune) { FortuneSheet() }
        .sheet(isPresented:$result) { ResultSheet(names: names, doubles: doubles, early: earlyResult).environmentObject(store).environmentObject(social) }
        .confirmationDialog("这场球先打到这里？",isPresented:$exitMenu,titleVisibility:.visible) {
            Button("暂存球局，下次继续") { session?.send("P") }.disabled(session?.can("P") != true || !groupDeviceReady)
            Button("提前结束，可选 MVP") { earlyResult = true; result = true }.disabled(session?.fresh != true || !groupDeviceReady)
            Button("继续比赛",role:.cancel) {}
        } message: { Text("暂存后可以继续；提前结束会保留当前比分，可选择本场 MVP。") }
        .alert("放弃并清空球局？",isPresented:$discard) {
            Button("取消",role:.cancel) {}; Button("确认放弃",role:.destructive) { session?.send("A") }
        } message: { Text("设备比分和本机暂存会被清空，无法撤销。") }
    }
    private var scoreAnimationAllowed: Bool {
        guard let session = session, session.fresh, session.online,
              session.current?.state == "a", session.current?.code == 0 else { return false }
        return session.pending == nil || ["r","b","U"].contains(session.pending!.op)
    }
    private var scoreContext: String {
        if previewLive { return "preview" }
        guard let value = session?.current else { return "" }
        return "\(store.selected?.id ?? ""):\(value.id):\(value.state):\(value.scores[2]):\(value.scores[3])"
    }
    @ViewBuilder private var courtHeading: some View {
        if stage == "home" {
            HStack { Text("每一分，都值得认真").font(.system(size:13)).foregroundColor(Palette.muted); Spacer(); Text("羽小裁").font(.system(size:12,weight:.semibold)).tracking(2).foregroundColor(Palette.green) }
        } else if !live {
            Picker("比赛形式",selection:$doubles) { Text("单打").tag(false); Text("双打").tag(true) }.pickerStyle(.segmented).disabled(social.context != nil).onChange(of:doubles) { _ in saveRoster() }
        } else {
            HStack { Text(doubles ? "双打":"单打"); Spacer(); Text(session?.phase ?? (previewLive ? "界面预览":"等待设备")); Spacer(); Text("局数 \(session?.current?.scores[2] ?? 0) : \(session?.current?.scores[3] ?? 0)") }.font(.system(size:13,weight:.medium)).foregroundColor(Palette.muted)
        }
    }
    private var homeContent: some View {
        VStack(spacing:22) {
            VStack(spacing:9) { Text(homeState == .ended ? "本场已结束，精彩已留下" : homeState == .resume ? "还有一场，等你继续":"上场吧，今天也打个好球").font(.system(size:24,weight:.bold)).multilineTextAlignment(.center); Text(homeState == .ended ? "查看结算，清空设备比分后可开始下一场。" : homeState == .resume ? "比分还在，让这一场接着精彩。":"带上球拍，把这一场交给羽小裁。").font(.system(size:14)).foregroundColor(Palette.muted) }
            Button(homeState.buttonTitle) { let entry = homeState; stage = entry == .ready ? "prepare":"live"; if entry != .ready { session?.send("Q") } }.buttonStyle(PrimaryStyle()).accessibilityIdentifier("prepare-match")
            Button("找回未完成的球局  →",action:openRecords).font(.system(size:14,weight:.medium)).frame(minHeight:44)
            MenuRow(icon:"person.2",title:"约朋友打球",subtitle:"发起组局，邀请熟人，现场一起计分",action:openGatherings).accessibilityIdentifier("gathering-entry")
            MenuRow(icon:"sensor.tag.radiowaves.forward",title:"我的装备",subtitle:store.selected?.name ?? "连接你的羽小裁，开启实时计分",action:openDevices)
        }
    }
    private var matchContent: some View {
        VStack(spacing:16) {
            if live {
                #if UI_PREVIEW
                Button("预览撤销红方一分") { if previewScores[0] > 0 { previewScores[0] -= 1 } }
                #endif
                if currentSettled { Text(settledEarly ? "已提前结束 · 不计正常完赛胜负" : "本场已结算").font(.headline) }
                else if session?.current?.state == "p" || session?.saved != nil && session?.current?.state != "a" {
                    Text("已暂存 · \(session?.saved?.scores[0] ?? 0) : \(session?.saved?.scores[1] ?? 0)").font(.headline)
                    Button("恢复球局") { session?.send("R") }.buttonStyle(PrimaryStyle()).disabled(session?.can("R") != true || !groupDeviceReady || currentSettled)
                    Note(text:"暂存保存在这台 iPhone，卸载 App 后会丢失。")
                }
                HStack {
                    Button { session?.send("U") } label: { Label("撤销上一分",systemImage:"arrow.uturn.backward") }.disabled(session?.can("U") != true || !groupDeviceReady)
                    Spacer()
                    Button(session?.current?.finished == true || currentSettled ? "查看结果":"暂存 / 提前结束") { if session?.current?.finished == true || currentSettled { earlyResult = settledEarly; result = true } else { exitMenu = true } }.disabled(session == nil || session?.pending != nil || !groupDeviceReady)
                }.font(.system(size:14,weight:.medium)).frame(minHeight:44)
                if social.context != nil {
                    if !groupDeviceReady { Note(text:"请连接关联的原设备并同步球局，当前设备不能操作这场组局。") }
                    Button(social.journal.archived ? "组局成绩已归档" : "结算并选择 MVP") { earlyResult = false; result = true }.buttonStyle(PrimaryStyle()).disabled(session?.current?.finished != true || social.journal.archived || !social.journal.events.isEmpty)
                    Note(text:social.message)
                    Button("查看组局 / 重试上传",action:openGatherings)
                }
                if session?.current?.finished == true || social.journal.archived || session?.completedResults.contains(where: { $0.id == session?.current?.id }) == true { Button("清空比分，准备下一场") { discard = true }.frame(minHeight:44).disabled(session?.can("A") != true || (social.context != nil ? !social.journal.archived : session?.completedResults.contains(where: { $0.id == session?.current?.id }) != true)) }
                Note(text:session?.message ?? "请先连接设备。点击球员加分，以设备确认的比分为准。")
            } else {
                #if UI_PREVIEW
                Button("预览开赛动画") { stage = "live" }.accessibilityIdentifier("preview-start")
                #endif
                Note(text:"点击球员修改名字 · 比赛规则与设备一致")
                MenuRow(icon:"sensor.tag.radiowaves.forward",title:store.connection,subtitle:store.selected?.name,action:openDevices)
                Button { fortune = true } label: { HStack { Text("今日羽签").fontWeight(.semibold); Spacer(); Text("开场小提醒  ›") }.font(.system(size:14)).padding(17).background(Palette.soft).cornerRadius(14) }
                Button(session?.pending != nil ? "等待设备确认…":"开始比赛") { saveRoster(); session?.send("B") }.buttonStyle(PrimaryStyle()).disabled(session?.can("B") != true || social.context != nil)
                if store.selected == nil { Button("连接设备后开始",action:openDevices).frame(minHeight:44) }
                if session?.hasOldScore == true || hasMatch {
                    Note(text:"设备上已有比分或暂存球局，可以继续比赛，或确认放弃后重新开始。")
                    HStack { Button("回到球局") { stage = "live" };Spacer();Button("结束旧球局") { if session?.current?.hasID == true && ["a", "p"].contains(session?.current?.state ?? "") { earlyResult = true; result = true } else { discard = true } }.disabled(session?.can("A") != true || !groupDeviceReady) }.font(.system(size:14)).frame(minHeight:44)
                }
                if let session = session { Note(text:session.message) }
            }
            if let session = session, !session.fresh { Button("重新同步比分") { session.send("Q") }.frame(minHeight:44).disabled(!session.can("Q")) }
        }
    }
    private func loadGroupRoster() {
        guard let c = social.context else { return }
        doubles = c.red.count == 2
        names = [c.red.first ?? "我方球员", c.red.count > 1 ? c.red[1] : "我方队友", c.blue.first ?? "对方球员", c.blue.count > 1 ? c.blue[1] : "对方队友"]
    }
    private var rosterKey: String { "ios.roster.\(store.accountID)" + (social.userID.isEmpty ? "" : ".social.\(social.userID)") }
    private func loadRoster() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: rosterKey)
        names = stored?.count == 4 ? stored! : ["我方球员","我方队友","对方球员","对方队友"]
        selfNameEdited = (defaults.object(forKey: rosterKey + ".selfEdited") as? Bool) ?? (names[0] != "我方球员" && !names[0].isEmpty)
        if !selfNameEdited { names[0] = defaultSelfName }
        doubles = defaults.bool(forKey: rosterKey + ".double")
    }
    private func saveRoster() {
        guard social.context == nil else { return }
        UserDefaults.standard.set(names, forKey: rosterKey)
        UserDefaults.standard.set(selfNameEdited, forKey: rosterKey + ".selfEdited")
        UserDefaults.standard.set(doubles, forKey: rosterKey + ".double")
    }

}
struct FortuneSheet: View {
    private let tips = ["先站稳，再出手。\n让每一次回球都有余地。","放松握拍，盯住来球。\n节奏会慢慢回到你手里。","多一点耐心，少一点着急。\n下一分，就是新的开始。","先热身，再上场。\n好状态值得认真准备。","享受来回，也享受进步。\n今天比昨天更从容一点。"]
    var body: some View { VStack(alignment:.leading,spacing:30) { SheetHeader(title:"今日羽签");Image(systemName:"sun.max").font(.system(size:50,weight:.ultraLight)).foregroundColor(Palette.green);Text(tips[(Calendar.current.ordinality(of:.day,in:.era,for:Date()) ?? 0)%tips.count]).font(.system(size:25,weight:.medium)).lineSpacing(12);Note(text:"一份开场提醒，愿你享受今天的每一分。");Spacer() }.padding(26).background(Palette.background.ignoresSafeArea()) }
}
struct ResultSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    let names: [String]; let doubles: Bool; var early = false
    @State private var waitingForPause = false
    @State private var expectedMatch: String?
    @State private var expectedDevice: String?
    @State private var players: [(id: String, name: String)] = []
    @State private var selection: String?
    @State private var error = ""
    @State private var retry = 0
    @State private var celebration: MatchCelebration?
    @Environment(\.dismiss) private var dismiss
    private var session: MatchSession? { store.session }
    private var group: Bool { social.context != nil }
    private var local: LocalMatchResult? { session?.completedResults.first { $0.id == session?.current?.id } }
    private var submitted: Bool { group ? social.journal.archived || social.journal.events.contains { ["complete", "early_end"].contains($0.op) } : local != nil }
    private func commit() {
        do {
            guard session?.current?.id == expectedMatch, store.selected?.id == expectedDevice else { throw SocialClientError("设备或球局已改变，请重新打开结算") }
            if group { try social.complete(session, mvpUserID: selection, early: early) }
            else if let session = session {
                try session.settle(names: names, doubles: doubles, mvpSlot: selection.flatMap(Int.init), early: early)
                if !social.userID.isEmpty, let result = local, let device = store.selected?.id {
                    do { try social.queueRecord(result, deviceID: device); Task { await social.uploadRecords() } }
                    catch { social.recordsMessage = "成绩已保存在本机，请到战绩页重试上传：" + error.localizedDescription }
                }
            }
            // Present only after the immutable result/outbox has been saved successfully.
            showCelebration()
        } catch { self.error = error.localizedDescription }
    }
    private func showCelebration() {
        guard submitted, let snapshot = session?.current else { return }
        let name = players.first { $0.id == selection }?.name
        celebration = MatchCelebration(player: name, scores: snapshot.scores, early: early,
            storage: group ? (social.journal.archived ? "成绩已归档" : "成绩已保存到本机，等待上传") : "成绩已保存到本机")
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            SheetHeader(title: early ? "提前结束本场" : "本场结算")
            Text("\(session?.current?.scores[2] ?? 0) : \(session?.current?.scores[3] ?? 0)").font(.system(size: 64, weight: .bold, design: .rounded)).frame(maxWidth: .infinity)
            Text("局数 · 三局两胜").foregroundColor(Palette.muted)
            if early { Text("当前比分 \(session?.current?.scores[0] ?? 0) : \(session?.current?.scores[1] ?? 0)"); Note(text: "提前结束保留当前比分，不计正常完赛胜负。") }
            Text(early ? "本场 MVP（可选）" : "选择本场 MVP").font(.title2.bold())
            Note(text: "从本场参赛球员中选择一人，确认后与成绩一同保存。")
            if early { Button("不评选 MVP") { selection = nil }.disabled(submitted || waitingForPause) }
            ForEach(players, id: \.id) { player in
                Button { selection = player.id } label: {
                    HStack { Text(player.name); Spacer(); Image(systemName: selection == player.id ? "checkmark.circle.fill" : "circle") }.padding(18).background(Palette.soft).cornerRadius(16)
                }.disabled(submitted || waitingForPause).accessibilityIdentifier("mvp-" + player.id)
            }
            if players.isEmpty && error.isEmpty { ProgressView("正在加载参赛名单…") }
            if submitted {
                Label(group ? (social.journal.archived ? "成绩与 MVP 已归档" : "已保存在本机，等待上传") : "成绩与 MVP 已保存到本机", systemImage: "checkmark.circle.fill")
                Button("重看结算展示") { showCelebration() }.accessibilityIdentifier("replay-settlement")
                if group && !social.journal.archived { Button("重试上传") { social.run { await social.flush() } } }
            } else {
                Button(waitingForPause ? "等待设备暂停确认…" : early ? "确认提前结束" : group ? "确认 MVP 并归档成绩" : "确认 MVP 并保存本局") {
                    error = ""
                    if early && session?.current?.state == "a" {
                        waitingForPause = true; session?.send("P")
                    } else { commit() }
                }.buttonStyle(PrimaryStyle()).disabled((!early && selection == nil) || waitingForPause || social.busy || session?.fresh != true || session?.pending != nil || (!early && session?.current?.finished != true))
            }
            if submitted {
                Button("清空设备比分，准备下一场") { session?.send("A") }.disabled(session?.can("A") != true || group && !social.journal.archived)
            }
            if session?.fresh != true { Button("同步设备状态") { session?.send("Q") }.disabled(session?.can("Q") != true) }
            if !error.isEmpty { Note(text: error); if players.isEmpty { Button("重新加载名单") { retry += 1 } } }
            if group { Note(text: social.message) }
            Button("返回球局") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
        }.padding(24) }.background(Palette.background.ignoresSafeArea())
            .fullScreenCover(item: $celebration) { value in MatchCelebrationView(result: value) }
            .onChange(of: "\(session?.pending?.token.description ?? "none"):\(session?.fresh == true):\(session?.current?.state ?? "")") { _ in
                guard waitingForPause, session?.pending == nil else { return }
                // MatchSession publishes pending before freshness; process after the receive callback.
                DispatchQueue.main.async {
                    guard waitingForPause else { return }
                    waitingForPause = false
                    if session?.fresh == true && session?.current?.state == "p" { commit() }
                    else { error = "暂停结果未确认，请先同步设备状态再重试。" }
                }
            }
            .onChange(of: session?.lastConfirmed) { if $0 == "A" { dismiss() } }
            .task(id: retry) {
                error = ""
                if expectedMatch == nil { expectedMatch = session?.current?.id; expectedDevice = store.selected?.id }
                do {
                    if group { players = try await social.settlementPlayers(); selection = social.journal.mvpUserID }
                    else { players = (doubles ? [0,1,2,3] : [0,2]).map { (id: String($0), name: names[$0]) }; selection = local?.mvpSlot.map { String($0) } }
                } catch { self.error = error.localizedDescription }
            }
    }
}

// A frozen presentation of the saved result; no DP commands or media generation.
private struct MatchCelebration: Identifiable {
    let id = UUID()
    let player: String?
    let scores: [UInt8]
    let early: Bool
    let storage: String
}

private struct PlainMatchCelebrationView: View {
    let result: MatchCelebration
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    private let gold = Color(hex: 0xe6d49b)
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Palette.ink.ignoresSafeArea()
                RadialGradient(colors: [Palette.green, Palette.ink], center: .center,
                               startRadius: 0, endRadius: max(geometry.size.height * 0.65, 1)).ignoresSafeArea()
                Circle().stroke(gold.opacity(0.12), lineWidth: 1)
                    .frame(width: geometry.size.width * 1.35, height: geometry.size.width * 1.35)
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .scaleEffect(revealed ? 1 : 0.75).accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: 24) {
                        HStack {
                            Text("SHUTTLEREF / MATCH MOMENT").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).lineLimit(1).minimumScaleFactor(0.6)
                            Spacer()
                            Button("跳过") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                        }.foregroundColor(gold)
                        Spacer(minLength: max(24, geometry.size.height * 0.06))
                        Image(systemName: result.player == nil ? "flag.checkered" : "laurel.leading")
                            .font(.system(size: 64, weight: .ultraLight)).foregroundColor(gold)
                            .rotationEffect(.degrees(revealed ? 0 : -12))
                        Text(result.player == nil ? "本场已结束" : "本场 MVP")
                            .font(.system(size: 20, weight: .medium)).tracking(5).foregroundColor(gold)
                        Text(result.player ?? "感谢每一次挥拍")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(3)
                            .accessibilityIdentifier("celebration-player")
                        Text(result.player == nil ? "这一场，同样值得留下" : "这一刻，为你喝彩")
                            .font(.subheadline).foregroundColor(.white.opacity(0.7))
                        Rectangle().fill(gold.opacity(0.35)).frame(width: 56, height: 1).padding(.vertical, 10)
                        VStack(spacing: 10) {
                            Text(result.early ? "提前结束 · 当前比分" : "本场局数")
                                .font(.subheadline).foregroundColor(gold)
                            Text(result.early ? "\(result.scores[0]) : \(result.scores[1])" : "\(result.scores[2]) : \(result.scores[3])")
                                .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                            if result.early { Text("保留比分，不计正常完赛胜负").font(.caption).foregroundColor(.white.opacity(0.65)) }
                        }
                        Spacer(minLength: 24)
                        Text(result.storage).font(.caption).foregroundColor(.white.opacity(0.65))
                        Button("查看本场结果") { dismiss() }
                            .font(.headline).foregroundColor(Palette.ink).frame(maxWidth: .infinity)
                            .padding(.vertical, 18).background(gold).cornerRadius(18)
                    }
                    .padding(28).frame(minHeight: geometry.size.height)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed || reduceMotion ? 0 : 24)
                }
            }.foregroundColor(.white)
            .task {
                if reduceMotion { revealed = true }
                else { withAnimation(.easeOut(duration: 0.85)) { revealed = true } }
            }
        }.interactiveDismissDisabled().preferredColorScheme(.dark)
    }
}

private struct MatchCelebrationView: View {
    let result: MatchCelebration
    var body: some View {
        if result.player != nil { PortraitMVPView(result: result) }
        else { PlainMatchCelebrationView(result: result) }
    }
}

// Native port of tools/mvp_studio/web/timeline.js, using its original stills.
// Coordinates and timings deliberately remain in the shared 540 × 960 design space.
private enum MVPTimeline {
    static let duration = 7.8
    static func ease(_ value: Double) -> Double {
        let p = min(1, max(0, value)); return p * p * (3 - 2 * p)
    }
    static let eyes = UIImage(named: "mvp-eyes.png")
    static let grip = UIImage(named: "mvp-grip.png")
    static let hero = UIImage(named: "mvp-hero.png")
    static let cutout = UIImage(named: "mvp-cutout.png")
    static let leftEdge = edge(right: false)
    static let rightEdge = edge(right: true)
    private static func edge(right: Bool) -> UIImage? {
        guard let cg = hero?.cgImage,
              let column = cg.cropping(to: CGRect(x: right ? cg.width - 1 : 0, y: 0, width: 1, height: cg.height)) else { return nil }
        return UIImage(cgImage: column)
    }
    static var ready: Bool { eyes != nil && grip != nil && hero != nil && cutout != nil }
    static func draw(context: GraphicsContext, size: CGSize, time t: Double) {
        var ctx = context
        ctx.scaleBy(x: size.width / 540, y: size.height / 960)
        func polygon(_ points: [CGPoint], color: Color) {
            var path = Path(); path.addLines(points); path.closeSubpath(); ctx.fill(path, with: .color(color))
        }
        func image(_ source: UIImage?, rect: CGRect, cover: Bool = false, alpha: Double = 1) {
            guard let source else { return }
            var layer = ctx; layer.opacity = alpha
            var target = rect
            if cover {
                layer.clip(to: Path(rect))
                let ratio = max(rect.width / source.size.width, rect.height / source.size.height)
                target = CGRect(x: rect.midX - source.size.width * ratio / 2,
                                y: rect.midY - source.size.height * ratio / 2,
                                width: source.size.width * ratio, height: source.size.height * ratio)
            }
            layer.draw(Image(uiImage: source), in: target)
        }
        ctx.fill(Path(CGRect(x: 0, y: 0, width: 540, height: 960)), with: .color(Color(hex: 0x060c14)))
        let rect = CGRect(x: 56.25, y: 15, width: 427.5, height: 760)
        if t >= 2.15 {
            let zoom = 1 + 0.035 * (1 - ease((t - 2.15) / 1.2))
            let box = CGRect(x: rect.midX - rect.width * zoom / 2, y: rect.midY - rect.height * zoom / 2,
                             width: rect.width * zoom, height: rect.height * zoom)
            image(leftEdge, rect: CGRect(x: 0, y: box.minY, width: box.minX, height: box.height))
            image(rightEdge, rect: CGRect(x: box.maxX, y: box.minY, width: 540-box.maxX, height: box.height))
            image(hero, rect: box)
        } else {
            let eyesShot = t < 1.35
            let p = ease(eyesShot ? (t - 0.25) / 1.1 : (t - 1.35) / 0.8)
            let zoom = eyesShot ? 1.08 - 0.05 * p : 1.06 - 0.04 * p
            let x = (eyesShot ? 6.0 : -5.0) * (1 - p)
            image(eyesShot ? eyes : grip, rect: CGRect(x: 270 - 270 * zoom + x, y: 482 - 152 * zoom,
                                                       width: 540 * zoom, height: 304 * zoom), cover: true)
        }
        let slit = ease((t - 0.25) / 0.65), open = ease((t - 2.15) / 1.1)
        let top = (0.51 - 0.07 * slit - 0.20 * open) * 960
        let bottom = (0.51 + 0.07 * slit + 0.15 * open) * 960
        let black = Color(hex: 0x020304)
        polygon([.zero, CGPoint(x: 540,y: 0), CGPoint(x: 540,y: top-32), CGPoint(x: 0,y: top+32)], color: black)
        polygon([CGPoint(x: 0,y: bottom+32), CGPoint(x: 540,y: bottom-32), CGPoint(x: 540,y: 960), CGPoint(x: 0,y: 960)], color: black)
        for y in [top, bottom] {
            var edge = Path(); edge.move(to: CGPoint(x: 0,y: y+32)); edge.addLine(to: CGPoint(x: 540,y: y-32))
            ctx.stroke(edge, with: .color(Color(hex: 0xcbb48b).opacity(slit)), lineWidth: 1.1)
        }
        let titleAlpha = ease((t - 3.8) / 0.45)
        var title = ctx; title.opacity = titleAlpha
        title.draw(Text("羽小裁 | 赛后战报").font(.system(size: 19)).foregroundColor(Color(hex: 0xeedec0)), at: CGPoint(x: 25,y: 43), anchor: .leading)
        title.draw(Text("MVP").font(.system(size: 100, weight: .black)).foregroundColor(Color(hex: 0xeedec0)), at: CGPoint(x: 20,y: 105), anchor: .leading)
        // Exactly the same rectangle as the frozen hero: the subject crosses both the border and title.
        image(cutout, rect: rect, alpha: ease((t - 3.35) / 0.5))
        if t > 3.28 && t < 3.46 {
            ctx.fill(Path(CGRect(x: 0,y: 0,width: 540,height: 960)), with: .color(Color(hex: 0xfff1d2).opacity(0.1 * sin((t-3.28)/0.18 * .pi))))
        }
    }
}

private struct PortraitMVPView: View {
    let result: MatchCelebration
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()
    @State private var elapsed = 0.0
    @State private var finished = false
    @State private var suspended = false
    private let cream = Color(hex: 0xeedec0)
    private func time(_ date: Date) -> Double {
        #if UI_PREVIEW
        if let value = ProcessInfo.processInfo.environment["MVP_FRAME_TEST"], let frame = Double(value) { return frame }
        #endif
        return reduceMotion || finished ? MVPTimeline.duration : min(MVPTimeline.duration, elapsed + (suspended ? 0 : date.timeIntervalSince(started)))
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: finished || reduceMotion || scenePhase != .active)) { clock in
                    let t = time(clock.date)
                    let availableHeight = max(1, geometry.size.height - 76)
                    let scale = min(geometry.size.width / 540, availableHeight / 960)
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in MVPTimeline.draw(context: context, size: size, time: t) }
                            .accessibilityLabel("眼神特写、握拍特写、全身人像与破框定格动画")
                            .accessibilityIdentifier("mvp-portrait-animation")
                        Text("本场 MVP").font(.system(size: 27 * scale, weight: .bold))
                            .opacity(MVPTimeline.ease((t-3.8)/0.45)).position(x: 93*scale,y: 181*scale)
                        VStack(alignment: .trailing, spacing: 6*scale) {
                            Text(result.player ?? "").font(.system(size: 37*scale, weight: .bold)).lineLimit(2).minimumScaleFactor(0.65)
                                .accessibilityIdentifier("celebration-player")
                            Text("默认示例形象 · 非球员本人").font(.system(size: 17*scale)).foregroundColor(cream.opacity(0.8))
                        }.frame(width: 490*scale, alignment: .trailing)
                            .opacity(MVPTimeline.ease((t-4.25)/0.4)).position(x: 267*scale,y: 750*scale)
                        VStack(spacing: 9*scale) {
                            Text(result.early ? "提前结束 · 当前比分" : "本场局数").font(.system(size: 18*scale))
                            Text(result.early ? "\(result.scores[0]) : \(result.scores[1])" : "\(result.scores[2]) : \(result.scores[3])")
                                .font(.system(size: 51*scale, weight: .bold)).monospacedDigit()
                            Text(result.storage).font(.system(size: 16*scale)).foregroundColor(cream.opacity(0.7))
                            Text("AI 示例人像演绎，非比赛回放").font(.system(size: 13*scale)).foregroundColor(cream.opacity(0.6))
                        }.frame(width: 490*scale).opacity(MVPTimeline.ease((t-4.65)/0.45))
                            .position(x: 270*scale,y: 866*scale)
                        HStack {
                            Spacer()
                            Button("跳过动画") { finished = true }.padding(12).background(.black.opacity(0.55)).clipShape(Capsule())
                        }.padding(12)
                        if !MVPTimeline.ready { Text("人像素材未就绪，请重新安装完整 App").padding().background(.black) }
                    }.frame(width: 540*scale,height: 960*scale).clipped()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: t >= MVPTimeline.duration) { if $0 { finished = true } }
                }
                HStack(spacing: 12) {
                    Button("再看一次") { elapsed = 0; started = Date(); finished = false }
                        .frame(maxWidth: .infinity, minHeight: 48).overlay(RoundedRectangle(cornerRadius: 12).stroke(cream.opacity(0.5)))
                    Button("查看本场结果") { dismiss() }.frame(maxWidth: .infinity, minHeight: 48)
                        .background(cream).foregroundColor(Color.black).cornerRadius(12)
                }.padding(.horizontal, 20).frame(height: 76)
            }
        }.foregroundColor(cream).background(Color(hex: 0x020304).ignoresSafeArea())
            .preferredColorScheme(.dark).interactiveDismissDisabled()
            .onChange(of: scenePhase) { phase in
                if phase == .active { started = Date(); suspended = false }
                else if !finished && !suspended { elapsed = min(MVPTimeline.duration, elapsed + Date().timeIntervalSince(started)); suspended = true }
            }
    }
}
