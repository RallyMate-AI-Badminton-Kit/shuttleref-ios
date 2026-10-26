import SwiftUI

struct RecordsPage: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    @State private var refreshing = false
    @State private var refreshError = ""
    @State private var importRecord: PersonalRecord?
    let openMatch: () -> Void
    @State private var filter = "全部"
    @State private var month = Date()
    @State private var selectedDate: Date?
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian);c.firstWeekday = 2;return c }
    private var days:[Int] {
        guard let range = calendar.range(of:.day,in:.month,for:month), let start = calendar.date(from:calendar.dateComponents([.year,.month],from:month)) else { return [] }
        let offset = (calendar.component(.weekday,from:start)+5)%7
        return Array(repeating:0,count:offset)+Array(range)
    }
    private var monthTitle:String { let c = calendar.dateComponents([.year,.month],from:month);return "\(c.year ?? 2026) 年 \(c.month ?? 1) 月" }
    private struct Row: Identifiable {
        let id: String; let title: String; let date: Date
        let snapshot: MatchSnapshot; let mvp: String; let early: Bool; let source: String
        var local: LocalMatchResult? = nil
    }
    private var rows: [Row] {
        var rows: [String: Row] = [:]
        let groups = social.results
        let groupMatches = Set(groups.compactMap { $0.fixture.match_id })
        for result in store.session?.completedResults ?? [] where !groupMatches.contains(result.id) {
            let id = (store.selected?.id ?? "") + ":" + result.id
            rows[id] = Row(id: id, title: result.doubles ? "双打" : "单打", date: result.date, snapshot: result.snapshot, mvp: result.mvpName, early: result.earlyEnded == true, source: "仅本机 · 当前设备", local: result)
        }
        for (records, label) in [(social.recordsJournal.uploaded, "已同步 · 当前账号"), (social.recordsJournal.pending, "待上传 · 已保存在本机")] {
            for item in records {
                let r = item.result
                rows[item.id] = Row(id: item.id, title: r.doubles ? "双打" : "单打", date: r.date, snapshot: r.snapshot, mvp: r.mvpName, early: r.earlyEnded == true, source: label)
            }
        }
        for group in groups {
            guard let snap = group.fixture.snapshot else { continue }
            let date = Date(timeIntervalSince1970: group.played_at ?? social.gatherings.first(where: { $0.id == group.gathering_id })?.starts_at ?? 0)
            rows["group:" + group.id] = Row(id: "group:" + group.id, title: group.title + " · " + group.fixture.label, date: date, snapshot: snap, mvp: group.fixture.mvp_name ?? "未评选", early: group.fixture.end_reason == "early", source: "组局成绩 · 已同步")
        }
        return rows.values.filter { selectedDate == nil || calendar.isDate($0.date, inSameDayAs: selectedDate!) }.sorted { $0.date > $1.date }
    }
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true; refreshError = ""; defer { refreshing = false }
        do { try await social.refreshRecords() } catch { refreshError = "刷新未完成，仍显示已有记录：" + error.localizedDescription }
    }
    var body:some View {
        VStack(spacing:0) {
            PageHeader(title:"战绩")
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    HStack { VStack(alignment:.leading,spacing:6) { Text("把每一场，留在这里").font(.system(size:22,weight:.bold));Text("你的进步，藏在一次次来回里").font(.system(size:13)).foregroundColor(Palette.muted) };Spacer();Image(systemName:"calendar").font(.system(size:29,weight:.light)).foregroundColor(Palette.green) }
                    calendarView
                    Picker("战绩筛选",selection:$filter) { ForEach(["全部","未完成","已结束"],id:\.self) { Text($0) } }.pickerStyle(.segmented)
                    if let account = social.credentials?.user {
                        HStack { Text("战绩账号 · " + account.name).font(.caption); Spacer(); Button(refreshing ? "刷新中…" : "刷新 / 重试") { Task { await refresh() } }.disabled(refreshing) }
                    } else { Note(text: "登录「我的 → 账号管理」中的账号后，可将普通球局保存到服务端。") }
                    if !refreshError.isEmpty { Note(text: refreshError) }
                    if !social.recordsMessage.isEmpty { Note(text: social.recordsMessage) }
                    if filter != "未完成" {
                        ForEach(rows) { result in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(result.title + (result.early ? " · 提前结束" : " · 已结算")).font(.headline)
                                Text("局数 \(result.snapshot.scores[2]) : \(result.snapshot.scores[3])")
                                Text("结束时比分 \(result.snapshot.scores[0]) : \(result.snapshot.scores[1])")
                                Label("MVP · " + result.mvp, systemImage: "star.fill").foregroundColor(Palette.green)
                                Text(result.date.formatted()).font(.caption)
                                Note(text: result.source)
                                if let local = result.local, social.credentials != nil {
                                    Button("保存到当前账号") { if let device = store.selected?.id { importRecord = PersonalRecord(deviceID: device, result: local) } }
                                }
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(20)
                        }
                    }
                    if let saved = store.session?.saved, filter != "已结束", selectedDate == nil {
                        Button(action:openMatch) {
                            VStack(alignment:.leading,spacing:15) {
                                HStack { Text("未完成的球局").font(.headline);Spacer();Text("本机暂存").font(.system(size:11)).padding(7).background(Palette.soft).clipShape(Capsule()) }
                                HStack { Text("我方");Spacer();Text("\(saved.scores[0]) : \(saved.scores[1])").font(.system(size:32,weight:.bold,design:.rounded));Spacer();Text("对方") }
                                Text("回到球场，接着打  →").font(.system(size:14,weight:.medium))
                            }.padding(22).background(Color.white).cornerRadius(22)
                        }.buttonStyle(.plain)
                    }
                    if (filter == "未完成" || rows.isEmpty) && !(store.session?.saved != nil && filter != "已结束" && selectedDate == nil) {
                        EmptyCard(icon:"flag.checkered",title:selectedDate == nil ? "期待你的下一场精彩":"这一天，暂无球局记录",detail:"普通球局与参加过的组局成绩都会显示在这里。下拉刷新，查看最新战绩。")
                    }
                    if selectedDate != nil { Button("清除日期筛选") { selectedDate = nil }.frame(minHeight:44) }
                    Note(text:"已同步成绩可使用同一战绩账号在其他设备查看；待上传和仅本机成绩请勿在同步前卸载 App。暂存球局仍保存在当前设备。")
                }.padding(22)
            }
        }
        .task(id: social.userID + social.origin) { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog("保存到当前战绩账号", isPresented: Binding(get: { importRecord != nil }, set: { if !$0 { importRecord = nil } })) {
            Button("保存到「" + (social.credentials?.user.name ?? "") + "」") {
                guard let record = importRecord else { return }
                do { try social.queueRecord(record.result, deviceID: record.deviceID); Task { await refresh() } }
                catch { refreshError = error.localizedDescription }
                importRecord = nil
            }
            Button("取消", role: .cancel) { importRecord = nil }
        } message: { Text("此本机成绩将归入当前账号，重复保存不会产生重复战绩。") }
    }
    private var calendarView:some View {
        VStack(spacing:17) {
            HStack { Button { shift(-1) } label:{ Image(systemName:"chevron.left").frame(width:44,height:44) }.accessibilityLabel("上个月");Spacer();Text(monthTitle).font(.system(size:16,weight:.semibold));Spacer();Button { shift(1) } label:{Image(systemName:"chevron.right").frame(width:44,height:44)}.accessibilityLabel("下个月") }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:2),count:7),spacing:6) {
                ForEach(["一","二","三","四","五","六","日"],id:\.self) { Text($0).font(.system(size:12)).foregroundColor(Palette.muted) }
                ForEach(Array(days.enumerated()),id:\.offset) { _,day in
                    if day == 0 { Color.clear.frame(height:36) }
                    else {
                        let date = dateFor(day)
                        let chosen = selectedDate.map { calendar.isDate($0,inSameDayAs:date) } ?? false
                        Button { selectedDate = chosen ? nil:date } label: { Text("\(day)").font(.system(size:14,weight:calendar.isDateInToday(date) ? .bold:.regular)).frame(maxWidth:.infinity).frame(height:36).background(chosen ? Palette.green : calendar.isDateInToday(date) ? Palette.soft:Color.clear).foregroundColor(chosen ? .white:Palette.ink).clipShape(Circle()) }.accessibilityLabel("\(monthTitle)\(day)日")
                    }
                }
            }
        }.padding(14).background(Color.white).cornerRadius(22)
    }
    private func dateFor(_ day:Int)->Date { var c = calendar.dateComponents([.year,.month],from:month);c.day = day;return calendar.date(from:c) ?? month }
    private func shift(_ offset:Int) { month = calendar.date(byAdding:.month,value:offset,to:month) ?? month }
}
