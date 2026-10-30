import SwiftUI

struct RacketPage: View {
    @EnvironmentObject var rackets: RacketStore
    @State private var adding = false
    @State private var account = false
    #if DEBUG
    @State private var demo = false
    @State private var phoneBLE = false
    #endif
    var body: some View {
        NavigationView {
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                SheetHeader(title: "球拍与拍底")
                if rackets.simulated { Label("模拟环境 · 不连接真实设备", systemImage: "testtube.2").foregroundColor(.orange) }
                Note(text: "拍底关联使用者，跨比赛保留。换队不用重绑；换人使用时主动解除或修改。")
                if rackets.context == nil {
                    EmptyCard(icon: "person.crop.circle", title: "请先登录", detail: "关联到我需要已验证的战绩与组局账号。")
                    Button("账号与安全") { account = true }.buttonStyle(PrimaryStyle())
                } else {
                    RacketHostPicker()
                    if rackets.loading { ProgressView("正在读取实际状态…") }
                    if rackets.devices.isEmpty && !rackets.loading && rackets.message.isEmpty {
                        EmptyCard(icon: "sensor.tag.radiowaves.forward", title: "还没有拍底", detail: "选择主机后添加已认证的拍底。没有拍底仍可通过 App 计分。")
                    }
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        ForEach(rackets.devices) { device in
                            Button { Task { await rackets.choose(device) } } label: { RacketRow(device: device, now: timeline.date) }
                                .buttonStyle(.plain).disabled(rackets.preparing).accessibilityIdentifier("racket-row-" + device.id)
                        }
                    }
                    if rackets.capabilities.hostDiscovery || rackets.canUseBluetooth {
                        Button("添加拍底") { adding = true }.buttonStyle(PrimaryStyle())
                    }
                    Button("刷新拍底与操作结果") { Task { await rackets.refresh() } }.disabled(rackets.loading)
                    Note(text: rackets.message)
                    ForEach(rackets.operations.filter { $0.state.unresolved }) { operation in RacketOperationView(operation: operation) }
                }
                #if DEBUG
                if !rackets.simulated {
                    Button("手机直连拍底（BLE 测试）") { phoneBLE = true }
                    DisclosureGroup("开发验证") {
                        Button("打开独立模拟环境") { demo = true }
                        Note(text: "模拟身份、主机和确认回执均为测试数据，不会写入正式账号。")
                    }
                }
                #endif
            }.padding(22) }.background(Palette.background.ignoresSafeArea()).navigationBarHidden(true)
        }.navigationViewStyle(.stack)
        .task { await rackets.refresh() }
        .sheet(isPresented: $account) { AccountCenter() }
        .sheet(isPresented: $adding) { RacketAddPage() }
        .sheet(isPresented: Binding(get: { rackets.selected != nil && !adding }, set: { if !$0 { rackets.finishDiscovery() } })) { RacketAssociationPage() }
        #if DEBUG
        .sheet(isPresented: $demo) { RacketDemoPage() }
        .sheet(isPresented: $phoneBLE) { RacketBLEEntryPage(context: rackets.context) }
        #endif
    }
}

struct RacketHostPicker: View {
    @EnvironmentObject var rackets: RacketStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("计分主机").font(.headline)
            TimelineView(.periodic(from: .now, by: 15)) { tick in
                ForEach(rackets.hosts) { host in
                    Button { rackets.selectHost(host.id) } label: {
                        HStack { Text(host.name); Spacer(); Text(connectionLabel(host.status(at: tick.date))); if rackets.context?.hostID == host.id { Image(systemName: "checkmark") } }
                    }.padding(12).background(Palette.soft).cornerRadius(12)
                }
            }
            Note(text: "通过业务服务读取有权限访问的主机，不要求手机与主机处于同一局域网。")
        }
    }
}
private func connectionLabel(_ status: RacketConnection) -> String {
    switch status { case .online: return "在线"; case .offline: return "离线"; case .unknown: return "状态未知" }
}
struct RacketRow: View {
    @EnvironmentObject var rackets: RacketStore
    let device: RacketDevice
    var now = Date()
    private var owner: String {
        guard let user = device.user else { return "未关联" }
        if user.kind == .guest { return "访客 · " + user.name + " · " + String(user.stableID.suffix(6)) }
        return user.stableID == rackets.context?.userID ? "已关联到我" : "其他用户 · " + user.name
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { tick in card(at: tick.date) }
    }
    private func card(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(device.name).font(.headline); Spacer(); Text(connectionLabel(device.status(at: now))).font(.caption) }
            Text("编号 · " + String(device.id.suffix(8))).font(.caption.monospaced())
            Text(owner)
            Text(device.hostID.map { hostID in "主机 · " + (rackets.hosts.first { $0.id == hostID }?.name ?? hostID) } ?? "尚未连接计分主机").font(.caption)
            Note(text: device.readiness(for: rackets.context?.hostID, at: now))
            if let battery = device.battery, (0...100).contains(battery) { Label("电量 \(battery)%", systemImage: "battery.100").font(.caption) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(16)
    }
}

struct RacketAddPage: View {
    @EnvironmentObject var rackets: RacketStore
    @State private var source = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "添加拍底")
            if rackets.capabilities.hostDiscovery {
                Button("从计分主机选择") { source = "host"; Task { await rackets.refresh() } }.buttonStyle(PrimaryStyle())
            }
            if rackets.canUseBluetooth {
                Button("搜索附近拍底") { source = "ble"; Task { await rackets.scan() } }.buttonStyle(PrimaryStyle())
                Note(text: "蓝牙发现需要靠近拍底；发现和连接不代表认证或关联完成。")
            }
            if source == "host" {
                RacketHostPicker()
                ForEach(rackets.devices.filter { $0.authenticated }) { device in
                    Button { Task { await rackets.choose(device) } } label: { RacketRow(device: device) }.buttonStyle(.plain).disabled(rackets.preparing)
                }
            } else if source == "ble" {
                ForEach(rackets.nearby) { candidate in
                    Button(candidate.label + " · " + String(candidate.id.suffix(6))) { Task { await rackets.chooseNearby(candidate) } }.disabled(rackets.preparing)
                }
                Button("停止 / 取消连接") { rackets.cancelDiscovery() }
                Button("重新扫描") { Task { await rackets.scan() } }.disabled(rackets.preparing)
            }
            if rackets.preparing { ProgressView("正在确认设备…") }
            Note(text: rackets.message)
        }.padding(22) }.background(Palette.background.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { rackets.selected != nil }, set: { if !$0 { rackets.cancelDiscovery() } })) { RacketAssociationPage() }
        .onDisappear { rackets.finishDiscovery() }
    }
}

struct RacketAssociationPage: View {
    @State private var archive = false
    @State private var modeConfiguration = false
    @EnvironmentObject var rackets: RacketStore
    @State private var remove = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "拍底使用者")
            if let device = rackets.selected {
                RacketRow(device: device)
                Text("关联到：" + (rackets.context?.userName.isEmpty == false ? rackets.context!.userName : "当前已验证用户")).font(.headline)
                Text("身份编号 · " + String((rackets.context?.userID ?? "").suffix(8))).font(.caption)
                Note(text: "关联对象由服务端根据当前登录会话确定，名字只用于展示。")
                if device.matchActive { Note(text: RacketFailure.pauseRequired.localizedDescription) }
                if device.user == nil {
                    if rackets.capabilities.binding {
                        Button("关联到我") { Task { await rackets.bindSelf() } }.buttonStyle(PrimaryStyle()).disabled(!rackets.canBind)
                    } else {
                        Note(text: "当前无法关联使用者，请查看下方设备结果；可复制诊断信息交给开发者。")
                        if let ble = rackets.bluetooth as? RacketBLEService { Button("蓝灯定位拍底") { Task { try? await ble.transport.locate() } } }
                    }
                    if !rackets.preparing && !rackets.capabilities.directConnection { Button("重新确认设备") { Task { await rackets.choose(device) } } }
                } else if device.user?.kind == .user && device.user?.stableID == rackets.context?.userID {
                    if !rackets.capabilities.unbinding { Note(text: "已关联到我。此测试固件暂不支持解绑，尚未连接计分主机。") }
                    else {
                    Button("解除关联", role: .destructive) { remove = true }.disabled(device.matchActive || rackets.operation(for: "device:" + device.id)?.state.unresolved == true)
                    }
                } else { Note(text: RacketFailure.ownedByOther.localizedDescription) }
                if let op = rackets.operation(for: "device:" + device.id) { RacketOperationView(operation: op) }
            }
            if rackets.preparing { ProgressView("正在验证设备…") }
            Note(text: rackets.message)
            Button("拍底回执维护") { archive = true }
            Button("拍底计分主机") { modeConfiguration = true }
            RacketDiagnosticButton()
            Button("刷新实际关联") { Task { await rackets.refresh() } }.disabled(rackets.loading)
        }.padding(22) }.background(Palette.background.ignoresSafeArea())
        .sheet(isPresented:$archive) { RacketArchivePage(context:rackets.context) }
        .sheet(isPresented:$modeConfiguration) { RacketModePage(context:rackets.context) }
        .confirmationDialog("解除拍底与我的关联？", isPresented: $remove, titleVisibility: .visible) {
            Button("解除关联", role: .destructive) { if let device = rackets.selected { Task { await rackets.unbind(device) } } }
        } message: { Text("需等待设备确认；结束比赛或退出 App 不会自动解除关联。") }
    }
}
struct RacketOperationView: View {
    @EnvironmentObject var rackets: RacketStore
    let operation: RacketOperation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(operation.state.label).font(.headline)
            if !operation.message.isEmpty { Note(text: operation.message) }
            Text("操作 · " + String(operation.id.uuidString.suffix(8))).font(.caption.monospaced())
            if operation.state.unresolved { Button("查询结果（不重新提交）") { Task { await rackets.query(operation.id) } } }
            if [.conflict, .expired, .rejected].contains(operation.state) { Button("刷新实际状态") { Task { await rackets.refresh() } } }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.soft).cornerRadius(14)
    }
}

struct RacketRosterPage: View {
    @EnvironmentObject var rackets: RacketStore
    @Environment(\.dismiss) private var dismiss
    let matchKey: String
    var requiredHostID: String? = nil
    var fixtureID: String? = nil
    var fixed: [RacketAssignment]? = nil
    var maySubmit = true
    var onConfirmed: (([RacketAssignment]) -> Void)? = nil
    @State private var doubles = false
    @State private var slots = ["", "", "", ""]
    private var choices: [RacketPerson] { rackets.people.filter { fixtureID == nil || $0.kind == .user } }
    private var lineup: [RacketAssignment] {
        fixed ?? (doubles ? [0,1,2,3] : [0,2]).compactMap { i in
            choices.first { $0.id == slots[i] }.map { RacketAssignment(person: $0, team: i < 2 ? .red : .blue) }
        }
    }
    private var draft: RacketRoster { RacketRoster(matchKey: matchKey, fixtureID: fixtureID, expectedVersion: 0, players: lineup) }
    private var valid: Bool { draft.valid && (fixed != nil || lineup.count == (doubles ? 4 : 2)) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "球员与拍底")
            if rackets.simulated { Text("模拟名单 · 不启动真实比赛").foregroundColor(.orange) }
            Note(text: "没有拍底也能参与并通过 App 计分。关联不等于报名；本场换队不改变拍底使用者。")
            if requiredHostID == nil { Note(text: "请先在设备与连接中选择本场计分主机。") }
            if !rackets.capabilities.roster { EmptyCard(icon: "person.2", title: "手机拍底计分尚未接入", detail: "拍底绑定与比赛计分是两个步骤。当前版本还不能通过敲击拍底计分；你可以继续使用现有手动计分。") }
            if fixed == nil && rackets.capabilities.roster {
                Picker("形式", selection: $doubles) { Text("单打").tag(false); Text("双打").tag(true) }.pickerStyle(.segmented)
                ForEach(doubles ? [0,1,2,3] : [0,2], id: \.self) { i in
                    Picker(i < 2 ? "红方球员" : "蓝方球员", selection: $slots[i]) {
                        Text("选择球员").tag("")
                        ForEach(choices) { p in Text("\(p.name) · \(p.kind == .guest ? "访客" : "用户") · \(p.stableID.suffix(6))").tag(p.id) }
                    }
                }
            }
            ForEach(Array(lineup.enumerated()), id: \.offset) { _, assignment in
                VStack(alignment: .leading, spacing: 6) {
                    Text((assignment.team == .red ? "红方 · " : "蓝方 · ") + assignment.person.name).font(.headline)
                    Text(assignment.person.id).font(.caption.monospaced())
                    let devices = rackets.devices.filter { $0.user?.id == assignment.person.id }
                    if devices.isEmpty { Note(text: rackets.capabilities.roster && rackets.message.isEmpty ? "未发现关联拍底，可通过 App 计分" : "拍底状态尚未获取") }
                    ForEach(devices) { device in RacketRow(device: device) }
                }
            }
            if rackets.capabilities.roster {
                Button("提交名单，等待主机确认") { rackets.setRoster(draft); Task { await rackets.submitRoster() } }
                    .buttonStyle(PrimaryStyle()).disabled(!maySubmit || !valid || requiredHostID == nil || rackets.context?.hostID != requiredHostID || rackets.operation(for: "match:" + matchKey)?.state.unresolved == true)
                if let op = rackets.operation(for: "match:" + matchKey) { RacketOperationView(operation: op) }
                if rackets.rosterConfirmed && rackets.rosterDraft == draft {
                    Label("主机已确认本场名单", systemImage: "checkmark.shield")
                    if let onConfirmed { Button("使用已确认名单") {
                        guard rackets.rosterConfirmed, rackets.rosterDraft == draft else { return }
                        onConfirmed(lineup); dismiss()
                    }.buttonStyle(PrimaryStyle()) }
                }
            }
            if rackets.capabilities.roster { Note(text: rackets.message) }
            Button("刷新球员和拍底状态") { Task { await rackets.refresh() } }
        }.padding(22) }.background(Palette.background.ignoresSafeArea()).task {
            if let host = requiredHostID, rackets.context?.hostID != host { rackets.selectHost(host) }
            else { await rackets.refresh() }
        }
    }
}

#if DEBUG
struct RacketDemoPage: View {
    @StateObject private var store: RacketStore
    @State private var roster = false
    init() {
        let service = MockRacketService()
        let store = RacketStore(service: service, bluetooth: MockRacketBluetooth(service: service), simulated: true)
        store.configure(RacketContext(origin: "mock://rackets", userID: "mock-me", token: "mock-session", hostID: "mock-host", userName: "模拟球友"))
        _store = StateObject(wrappedValue: store)
    }
    var body: some View {
        VStack { Button("模拟比赛选人") { roster = true }; RacketPage() }.environmentObject(store)
            .sheet(isPresented: $roster) { RacketRosterPage(matchKey: "mock-match-1", requiredHostID: "mock-host").environmentObject(store) }
    }
}
#endif
