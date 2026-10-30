import SwiftUI

struct RecordsPage: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var social: GatheringStore
    let openMatch: () -> Void
    @State private var period = RecordPeriod.month
    @State private var anchor = Date()
    @State private var selectedDay: Date?
    @State private var filter = "全部"
    @State private var refreshing = false
    @State private var refreshError = ""
    @State private var accountCenter = false
    @State private var importRecord: PersonalRecord?
    @State private var selectedRecord: RecordEntry?
    private var calendar: Calendar { RecordPeriod.calendar }
    private var allRows: [RecordEntry] {
        var items: [String: RecordEntry] = [:]
        let groups = social.results
        let groupKeys = Set(groups.compactMap { g -> String? in
            guard let device = g.fixture.device_id, let match = g.fixture.match_id else { return nil }
            return device + ":" + match
        })
        for r in store.session?.completedResults ?? [] {
            let device = store.selected?.id ?? ""
            let key = device + ":" + r.id
            if !groupKeys.contains(key) { items[key] = RecordEntry(personal: PersonalRecord(deviceID: device, result: r), source: "仅本机 · 当前设备", importable: true) }
        }
        for (records, source) in [(social.recordsJournal.uploaded, "已同步 · 当前账号"), (social.recordsJournal.pending, "待上传 · 已保存在本机")] {
            for record in records where !groupKeys.contains(record.id) { items[record.id] = RecordEntry(personal: record, source: source) }
        }
        for result in groups {
            if let row = RecordEntry(group: result) { items[row.id] = row }
        }
        return items.values.sorted { $0.date > $1.date }
    }
    private var periodRows: [RecordEntry] { allRows.filter { period.contains($0.date, anchor: anchor) } }
    private var rows: [RecordEntry] { periodRows.filter { row in
        (selectedDay == nil || calendar.isDate(row.date, inSameDayAs: selectedDay!))
            && (filter == "全部" || (filter == "已完赛" ? !row.early : row.early))
    } }
    private var dateGroups: [Date] { Array(Set(rows.map { calendar.startOfDay(for: $0.date) })).sorted(by: >) }
    private var activeDays: Int { Set(periodRows.map { calendar.startOfDay(for: $0.date) }).count }
    private var days: [Date] {
        guard let interval = calendar.dateInterval(of: period.component, for: anchor) else { return [] }
        return (0..<(period == .week ? 7 : calendar.range(of: .day, in: .month, for: anchor)!.count)).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "战绩")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("每一次上场，都算数").font(.system(size: 24, weight: .bold))
                    Text("从一周的坚持，到一年的进步").font(.subheadline).foregroundColor(Palette.muted)
                    Picker("统计周期", selection: $period) {
                        ForEach(RecordPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).onChange(of: period) { _ in selectedDay = nil }
                    HStack {
                        Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上一个周期")
                        Spacer(); Text(period.title(anchor)).font(.headline); Spacer()
                        Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下一个周期")
                    }
                    HStack(spacing: 0) {
                        metric("上场", value: periodRows.count, suffix: "场")
                        metric("完赛", value: periodRows.filter { !$0.early }.count, suffix: "场")
                        metric("活跃", value: activeDays, suffix: "天")
                    }.padding(.vertical, 22).background(Palette.soft).cornerRadius(22)
                    if period == .year { yearGrid } else { dayGrid }
                    Button("回到本" + period.rawValue) { anchor = Date(); selectedDay = nil }.font(.caption)
                    if let saved = store.session?.saved {
                        Button(action: openMatch) {
                            HStack { Image(systemName: "play.circle.fill").font(.title); VStack(alignment: .leading, spacing: 4) { Text("继续未完成的球局").font(.headline); Text("本机暂存 · \(saved.scores[0]) : \(saved.scores[1])").font(.caption) }; Spacer(); Image(systemName: "chevron.right") }
                                .padding(18).background(Color.white).cornerRadius(18)
                        }.buttonStyle(.plain)
                    }
                    HStack { Text(selectedDay.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "比赛记录").font(.title2.bold()); Spacer(); if selectedDay != nil { Button("查看整" + period.rawValue) { selectedDay = nil }.font(.caption) } }
                    Picker("战绩筛选", selection: $filter) { ForEach(["全部", "已完赛", "提前结束"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    if social.credentials != nil && !social.needsLogin {
                        HStack { Text("\(social.credentials?.user.name ?? "")的战绩").font(.caption); Spacer(); Button(refreshing ? "刷新中…" : "刷新 / 重试") { Task { await refresh() } }.disabled(refreshing) }
                    } else { Button("登录羽小裁，同步战绩") { accountCenter = true } }
                    if !refreshError.isEmpty { Note(text: refreshError) }
                    if !social.recordsMessage.isEmpty { Note(text: social.recordsMessage) }
                    if rows.isEmpty { EmptyCard(icon: "flag.checkered", title: "这里还没有比赛记录", detail: "换个日期看看，或开始一场新的球局。普通比赛和组局成绩都会出现在这里。") }
                    ForEach(dateGroups, id: \.self) { day in
                        Text(day.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundColor(Palette.muted)
                        ForEach(rows.filter { calendar.isDate($0.date, inSameDayAs: day) }) { row in recordCard(row) }
                    }
                    ReplayRecordsSection()
                    Note(text: "提前结束保留比分，不判定胜负。仅本机成绩需保存到当前账号后才能跨手机查看。")
                }.padding(22)
            }.refreshable { await refresh() }
        }
        .task(id: social.userID + social.origin) { selectedRecord = nil; await refresh() }
        .sheet(isPresented: $accountCenter) { AccountCenter() }
        .sheet(item: $selectedRecord) { MatchRecapPage(record: $0) }
        .confirmationDialog("保存到当前战绩账号", isPresented: Binding(get: { importRecord != nil }, set: { if !$0 { importRecord = nil } })) {
            Button("保存到「" + (social.credentials?.user.name ?? "") + "」") {
                guard let record = importRecord else { return }
                do { try social.queueRecord(record.result, deviceID: record.deviceID); Task { await refresh() } }
                catch { refreshError = error.localizedDescription }
                importRecord = nil
            }
            Button("取消", role: .cancel) { importRecord = nil }
        } message: { Text("成绩将归入当前账号，重复保存不会产生重复战绩。") }
    }
    private func metric(_ title: String, value: Int, suffix: String) -> some View {
        VStack(spacing: 7) { Text(title).font(.caption).foregroundColor(Palette.muted); HStack(alignment: .firstTextBaseline, spacing: 3) { Text("\(value)").font(.system(size: 30, weight: .bold, design: .rounded)); Text(suffix).font(.caption) } }.frame(maxWidth: .infinity)
    }
    private var yearGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            ForEach(1...12, id: \.self) { month in
                let date = calendar.date(from: DateComponents(year: calendar.component(.year, from: anchor), month: month))!
                let count = periodRows.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }.count
                Button { anchor = date; period = .month; selectedDay = nil } label: {
                    VStack(spacing: 9) { Text("\(month) 月").font(.subheadline); Text(count == 0 ? "—" : "\(count) 场").font(.headline).foregroundColor(count == 0 ? Palette.muted : Palette.green) }.frame(maxWidth: .infinity).padding(.vertical, 18).background(count == 0 ? Color.white : Palette.soft).cornerRadius(16)
                }.buttonStyle(.plain)
            }
        }
    }
    private var dayGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 8) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundColor(Palette.muted) }
                if period == .month, let first = days.first {
                    ForEach(0..<((calendar.component(.weekday, from: first) + 5) % 7), id: \.self) { _ in Color.clear.frame(height: 44) }
                }
                ForEach(days, id: \.self) { date in
                    let selected = selectedDay.map { calendar.isDate($0, inSameDayAs: date) } ?? false
                    let count = periodRows.filter { calendar.isDate($0.date, inSameDayAs: date) }.count
                    Button { selectedDay = selected ? nil : date } label: {
                        VStack(spacing: 4) {
                            Text("\(calendar.component(.day, from: date))").font(.system(size: 14, weight: calendar.isDateInToday(date) ? .bold : .regular))
                            Circle().fill(count > 0 ? (selected ? Color.white : Palette.green) : Color.clear).frame(width: 4, height: 4)
                        }.frame(maxWidth: .infinity).frame(height: 44).background(selected ? Palette.green : Color.clear).foregroundColor(selected ? .white : Palette.ink).cornerRadius(12)
                    }.accessibilityLabel(date.formatted(date: .abbreviated, time: .omitted) + "，\(count) 场")
                }
            }
        }.padding(14).background(Color.white).cornerRadius(20)
    }
    private func recordCard(_ row: RecordEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { selectedRecord = row } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(row.title).font(.headline); Spacer(); Text(row.early ? "提前结束" : "已完赛").font(.caption).foregroundColor(Palette.muted) }
                    HStack { Text(row.red.joined(separator: " / ")).frame(maxWidth: .infinity, alignment: .leading); Text(row.setScore).font(.system(size: 28, weight: .bold, design: .rounded)); Text(row.blue.joined(separator: " / ")).frame(maxWidth: .infinity, alignment: .trailing) }.font(.subheadline)
                    HStack { Label("MVP · " + row.mvp, systemImage: "star.fill").font(.caption).foregroundColor(Palette.green); Spacer(); Image(systemName: "arrow.up.right") }
                    Text(row.source).font(.caption2).foregroundColor(Palette.muted)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let record = row.importable, social.credentials != nil { Button("保存到当前账号") { importRecord = record }.font(.caption) }
        }.padding(20).background(Color.white).cornerRadius(22)
    }
    private func shift(_ value: Int) { anchor = calendar.date(byAdding: period.component, value: value, to: anchor) ?? anchor; selectedDay = nil }
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true; refreshError = ""; defer { refreshing = false }
        do { try await social.refreshRecords() } catch { refreshError = "刷新未完成，仍显示已有记录：" + error.localizedDescription }
    }
}

struct MatchRecapPage: View {
    let record: RecordEntry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView { VStack(alignment: .leading, spacing: 24) {
                Text(record.title).font(.title.bold())
                Text(record.date.formatted(date: .long, time: .shortened)).foregroundColor(Palette.muted)
                VStack(spacing: 16) {
                    Text(record.early ? "提前结束 · 不判定胜负" : "比赛已完成").font(.subheadline)
                    HStack(alignment: .top, spacing: 16) {
                        team(record.red, title: "红方", winner: !record.early && record.snapshot.scores[2] > record.snapshot.scores[3])
                        VStack { Text(record.setScore).font(.system(size: 38, weight: .bold, design: .rounded)); Text("局数").font(.caption).foregroundColor(Palette.muted) }
                        team(record.blue, title: "蓝方", winner: !record.early && record.snapshot.scores[3] > record.snapshot.scores[2])
                    }
                    Divider()
                    Text("结束时比分  \(record.snapshot.scores[0]) : \(record.snapshot.scores[1])").font(.headline)
                }.padding(22).background(Palette.soft).cornerRadius(24)
                HStack(spacing: 16) { Image(systemName: "star.circle.fill").font(.system(size: 40)).foregroundColor(Palette.green); VStack(alignment: .leading, spacing: 5) { Text("本场 MVP").font(.caption).foregroundColor(Palette.muted); Text(record.mvp).font(.title2.bold()) } }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(20)
                Text("比赛进程").font(.title2.bold())
                if record.observations.isEmpty {
                    Note(text: "这场历史比赛仅保存了结算比分，没有过程记录。新比赛将保留实际收到的计分状态。")
                } else {
                    Note(text: "以下为实际收到的计分状态，离线期间可能存在缺口；撤回和恢复也会反映在记录中，并非完整逐球录像。")
                    ForEach(Array(record.observations.enumerated()), id: \.offset) { index, observation in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 4) { Circle().fill(Palette.green).frame(width: 8, height: 8); if index < record.observations.count - 1 { Rectangle().fill(Palette.soft).frame(width: 2, height: 32) } }.padding(.top, 5)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(observation.snapshot.scores[0]) : \(observation.snapshot.scores[1])").font(.headline).monospacedDigit()
                                Text("局数 \(observation.snapshot.scores[2]) : \(observation.snapshot.scores[3]) · " + (observation.snapshot.state == "p" ? "暂停" : "计分同步")).font(.caption).foregroundColor(Palette.muted)
                            }
                            Spacer(); Text(observation.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundColor(Palette.muted)
                        }
                    }
                }
                Note(text: record.source)
            }.padding(22) }.background(Palette.background)
                .navigationTitle("比赛回顾").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func team(_ names: [String], title: String, winner: Bool) -> some View {
        VStack(spacing: 8) { Text(title).font(.caption).foregroundColor(Palette.muted); ForEach(Array(names.enumerated()), id: \.offset) { _, name in Text(name).font(.headline).multilineTextAlignment(.center) }; if winner { Text("胜").font(.caption.bold()).foregroundColor(Palette.green) } }.frame(maxWidth: .infinity)
    }
}
