import SwiftUI

@MainActor final class PhoneMatchController: ObservableObject {
    @Published var match: PhoneLocalMatch?
    @Published var nearby: [RacketNearby] = []
    @Published var message = "请选择手机比赛，数据保存在本机。"
    @Published var busy = false
    @Published var syncMessage = "比分已保存本机，等待同步。"
    private var syncPump: PhoneSyncPump?
    private var syncAPI: LocalMatchAPI?
    @Published var connectedDeviceID: String?
    @Published var selectedCandidate: RacketNearby?
    private(set) var service = RacketBLEConnectionHub.shared.service()
    private var session: PhoneMatchSession?
    private var link: PhoneScoreLink?
    private var timer: Task<Void,Never>?
    private var context: RacketContext?
    private var side: PhoneSide = .red
    func usePreparedConnection() async {
        if let candidate = service.connectedCandidate { await connect(candidate) }
    }
    func open(_ context: RacketContext, installation: String) {
        guard self.context != context else { return }
        if let previous=self.context, previous.origin==context.origin, previous.userID==context.userID,
           session?.scope.installation==installation, let session {
            self.context=context
            // Renew upload credentials without recreating the scoring writer or BLE context.
            syncAPI?.cancel();let api=LocalMatchAPI(context);syncAPI=api
            if let syncPump { syncPump.update(service:api) }
            else { syncPump=PhoneSyncPump(session:session,service:api) }
            syncPump?.start { [weak self] in self?.syncMessage=$0 }
            return
        }
        if self.context != nil { close() }; self.context = context
        service = RacketBLEConnectionHub.shared.service(for:context)
        do {
            let scope = PhoneMatchScope(origin:context.origin,account:context.userID,installation:installation)
            let directory = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            let local = try PhoneMatchSession(storage:PhoneMatchStore(url:directory.appendingPathComponent("phone-matches.sqlite"),scope:scope.key),scope:scope)
            session=local
            let api=LocalMatchAPI(context);syncAPI=api
            syncPump=PhoneSyncPump(session:local,service:api)
            refresh()
            syncPump?.start { [weak self] in self?.syncMessage=$0 }
        } catch { message = "本机比赛读取失败，请保留数据后重试。" }
    }
    func refreshAssociations() async {
        guard let context else { return }
        do {
            _ = try await service.hosts(context); _ = try await service.inventory(context)
            if link == nil { _ = await service.confirmConnection(context) }
        }
        catch { /* Keep last confirmed association, never mark its connection online. */ }
    }
    func refresh() {
        do { match = try session?.current(); if let syncPump { syncMessage = try syncPump.currentMessage() } }
        catch { message = "本机比赛读取失败，请保留数据，不要重复开赛。" }
    }
    func start(name: String, side: PhoneSide, doubles: Bool = false, partner: String = "我方队友", opponentPartner: String = "对方队友") {
        guard let context, let session else { return }
        do {
            self.side = side
            let other: PhoneSide = side == .red ? .blue:.red
            var players = [PhoneParticipant(id:context.userID.lowercased(),name:context.userName,side:side),PhoneParticipant(id:UUID().uuidString.lowercased(),name:name,side:other)]
            if doubles { players += [PhoneParticipant(id:UUID().uuidString.lowercased(),name:partner,side:side),PhoneParticipant(id:UUID().uuidString.lowercased(),name:opponentPartner,side:other)] }
            try session.start(participants:players,doubles:doubles)
            refresh(); message = "比赛已保存本机，可手动计分或连接拍底。"
        } catch {
            refresh()
            if let match, match.phase != .ended { message = "已恢复本机未结束比赛，请继续或结束该比赛。" }
            else if RacketScoreWire.identityUUID(context.userID.lowercased()) == nil { message = "账号身份格式不支持，请检查当前登录账号。" }
            else { message = "开赛未保存成功，请重试；如持续失败请检查本机存储。" }
        }
    }
    func scan() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        await suspend()
        do { nearby = try await service.scan(); message = "请选择已关联到你的拍底。" }
        catch { message = error.localizedDescription }
    }
    func connect(_ candidate: RacketNearby) async {
        guard !busy, let context, let session, let match, match.phase == .active else { return }
        busy = true; defer { busy = false }
        stopLink()
        do {
            let verified = try await service.verifyAndPrepare(candidate,hostID:nil,context:context)
            guard verified.device.user?.stableID == context.userID else { throw RacketFailure.ownedByOther }
            guard let controlOwner = service.authenticatedScoreOwner else { throw RacketDiagnostic(stage:"比赛身份映射",detail:"认证未返回拍底绑定的使用者身份，请重新认证。") }
            let binding = try await service.transport.currentInfo()
            let info = try await service.transport.scoreInfo()
            guard self.context == context, binding.deviceID == info.device else { throw RacketFailure.cancelled }
            session.foreground(); session.stop(); try session.confirmReview()
            guard let participant = match.participants.first(where: { $0.id == context.userID.lowercased() }) else { throw PhoneScoreError.invalidState }
            let connection = UUID()
            let link = PhoneScoreLink(session:session,transport:service.transport,connection:connection,clock:{ DispatchTime.now().uptimeNanoseconds / 1_000_000 })
            self.link = link; selectedCandidate = candidate; connectedDeviceID = verified.device.id
            service.transport.scoreNotification = { [weak self, weak link] data in
                Task { @MainActor in
                    guard let self, let link, self.link === link else { return }
                    do { try await link.notification(data); self.message = session.needsReview ? "请核对比分后重新连接拍底。" : session.readyForScoring ? "拍底已就绪 · 双敲加分，三敲撤回" : "正在等待拍底确认比赛配置…" }
                    catch { self.message = "拍底需重新确认：" + error.localizedDescription }
                    self.refresh()
                }
            }
            service.transport.scoreDisconnected = { [weak self] in self?.link?.disconnected(); self?.message = "拍底已断开：" + (self?.service.transport.scoreDisconnectReason ?? "") + "；可继续手动计分。" }
            let config = try session.prepare(info:info,authenticatedDevice:verified.device.id,owner:context.userID.lowercased(),associationRevision:UInt32(binding.revision),side:participant.side,connection:connection,subscribed:true,controlOwner:controlOwner)
            try await link.send(config)
            message = "正在等待拍底确认比赛配置…"
            Task { [weak self, weak link] in
                try? await Task.sleep(nanoseconds:5_000_000_000)
                guard let self, let link, self.link === link, !session.readyForScoring else { return }
                self.stopLink(); self.message = "拍底配置未确认，请重新连接；本机比分已保留。"
            }
            timer = Task { [weak self, weak link] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                    guard !Task.isCancelled, let self, let link, self.link === link else { return }
                    guard session.readyForScoring else { if session.needsReview { self.message = "请核对比分后重新连接拍底。" }; continue }
                    do { try await link.tick(); if session.needsReview { self.message = "请核对比分后重新连接拍底。" } }
                    catch { self.message = "拍底计分需核对：" + error.localizedDescription + "；比分已保存，可重新连接。"; return }
                }
            }
        } catch { stopLink(); message = "连接未完成：" + error.localizedDescription }
    }
    func action(_ action: PhoneAction) async {
        guard !busy, let session else { return }; busy = true; defer { busy = false }
        if [.pause,.resume,.end].contains(action) { await suspend() }
        do { session.foreground(); try session.manual(action); refresh(); message = "比分已保存本机 · 待云端同步"; if let link { do { try await link.tick() } catch { message = "比分已保存，拍底需重新连接。" } } }
        catch { message = "操作未完成，请核对比分。"; refresh() }
    }
    func recover() { do { _ = try session?.recoverStorage(); refresh(); message = "已读取本机结果，请核对后重新连接。" } catch { message = "结果仍未确认，请保留本机数据。" } }
    func suspend() async { timer?.cancel(); timer = nil; await link?.background(); stopLink() }
    private func stopLink() { connectedDeviceID = nil; timer?.cancel(); timer = nil; link?.disconnected(); link = nil; service.transport.scoreNotification = nil; service.transport.scoreDisconnected = nil }
    func close() { syncPump?.stop(); syncPump = nil; syncAPI?.cancel(); syncAPI = nil; stopLink(); session = nil; match = nil; context = nil }
}

struct PhoneMatchPage: View {
    @EnvironmentObject var social: GatheringStore
    @Environment(\.scenePhase) private var phase
    @ObservedObject var model: PhoneMatchController
    var inline = false
    var leave: (() -> Void)? = nil
    @State private var opponent = "对方球员"
    @State private var red = true
    @State private var end = false
    @State private var doubles = false
    @State private var partner = "我方队友"
    @State private var opponentPartner = "对方队友"
    private var identity: String { social.origin + "|" + social.userID + "|" + (social.credentials?.token ?? "") }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            if inline { HStack { Text("本局得分").font(.title.bold()); Spacer(); Button("返回球局") { Task { await model.suspend(); leave?() } } } }
            else { SheetHeader(title:"手机计分") }
            Text("手机计分 · 比赛时请保持 App 在前台").font(.caption).foregroundColor(.orange)
            if !social.verifiedBusiness { Text("请先登录羽小裁账号。") }
            else if let match = model.match, match.phase != .ended {
                Text(match.phase == .paused ? "比赛已暂停" : match.score.finished ? "比赛已结束，可撤回或保存结束":"21 分 · 三局两胜").font(.headline)
                CourtScene(live:true,compact:false,doubles:match.doubles,names:courtNames(match),
                           scores:[UInt8(match.score.red),UInt8(match.score.blue),UInt8(match.score.redGames),UInt8(match.score.blueGames),match.score.server == .red ? 0:1],
                           scoreContext:match.id,scoreEventsEnabled:true,visible:phase == .active,
                           actionable:!model.busy && match.phase == .active) { index in Task { await model.action(index >= 2 ? .blue:.red) } }
                    .frame(height:455)
                HStack { command("红方 +1",.red); command("蓝方 +1",.blue) }
                command("撤回最近一分",.undo)
                command(match.phase == .paused ? "继续比赛":"暂停比赛",match.phase == .paused ? .resume:.pause)
                if model.message.contains("尚未确认") { Button("核对存储结果") { model.recover() } }
                if let candidate = model.selectedCandidate { Button("重新连接拍底") { Task { await model.connect(candidate) } }.disabled(model.busy || match.phase != .active) }
                Button("搜索附近拍底") { Task { await model.scan() } }.disabled(model.busy)
                ForEach(model.nearby) { candidate in Button(candidate.label + " · 连接计分") { Task { await model.connect(candidate) } }.disabled(model.busy || match.phase != .active) }
                Button("结束比赛",role:.destructive) { end = true }
            } else {
                if let ended = model.match, ended.phase == .ended {
                    VStack(alignment:.leading,spacing:8) { Text("上场成绩已保存").font(.headline); Text("红方 \(ended.score.redGames) : \(ended.score.blueGames) 蓝方"); Text("结束时比分 \(ended.score.red) : \(ended.score.blue)").foregroundColor(Palette.muted) }.padding().frame(maxWidth:.infinity,alignment:.leading).background(Palette.soft).cornerRadius(16)
                }
                Picker("比赛形式",selection:$doubles) { Text("单打").tag(false); Text("双打").tag(true) }.pickerStyle(.segmented)
                TextField("对方姓名",text:$opponent).inputStyle()
                if doubles { TextField("我方队友",text:$partner).inputStyle(); TextField("对方队友",text:$opponentPartner).inputStyle() }
                Toggle("我的拍底为红方加分",isOn:$red)
                Button("开始手机比赛") { model.start(name:opponent,side:red ? .red:.blue,doubles:doubles,partner:partner,opponentPartner:opponentPartner) }.buttonStyle(PrimaryStyle()).disabled(!social.verifiedBusiness || opponent.trimmingCharacters(in:.whitespaces).isEmpty)
            }
            Text(model.message).foregroundColor(Palette.muted)
            RacketDiagnosticButton()
            Text(model.syncMessage).font(.caption).foregroundColor(Palette.muted)
        }.padding(22) }.background(Palette.background)
        .task(id:identity) { if let c = social.credentials, social.verifiedBusiness { model.open(RacketContext(origin:social.origin,userID:c.user.id,token:c.token,hostID:nil,userName:c.user.name),installation:social.installationID) } else { model.close() } }
        .onChange(of:phase) { p in if p == .background { Task { await model.suspend() } } }
        .onDisappear { Task { await model.suspend() } }
        .confirmationDialog("结束后保留本机成绩",isPresented:$end) { Button("结束比赛",role:.destructive) { Task { await model.action(.end) } } }
    }
    private func courtNames(_ match: PhoneLocalMatch) -> [String] {
        let red = match.participants.filter { $0.side == .red }.map(\.name)
        let blue = match.participants.filter { $0.side == .blue }.map(\.name)
        return [red.first ?? "红方球员",red.count > 1 ? red[1]:"",blue.first ?? "蓝方球员",blue.count > 1 ? blue[1]:""]
    }
    private func command(_ title:String,_ action:PhoneAction) -> some View { Button(title) { Task { await model.action(action) } }.disabled(model.busy) }
    private func score(_ title:String,_ points:Int,_ games:Int) -> some View { VStack { Text(title); Text(String(points)).font(.system(size:60,weight:.bold)); Text("局分 \(games)") } }
}
