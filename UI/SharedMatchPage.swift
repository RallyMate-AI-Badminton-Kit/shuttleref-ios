import SwiftUI

struct SharedMatchesPage: View {
    var piOnly=false
    var hostDeviceID:String?=nil
    var requestedMatchID:String?=nil
    @EnvironmentObject var social: GatheringStore
    @StateObject private var model=LocalMatchBrowser()
    @State private var spectatorID=""
    @State private var endMatch:SharedMatch?
    @State private var automaticEntryUsed=false
    @Environment(\.scenePhase) private var phase
    private var scope:String { social.origin+"|"+social.userID+"|"+(social.credentials?.token ?? "") }
    private var visibleMatches:[SharedMatch] { SharedMatchSelection.visible(model.matches,piOnly:piOnly,deviceID:hostDeviceID,matchID:requestedMatchID) }
    private func enterSingleHostMatch() {
        if piOnly,!automaticEntryUsed,model.selected == nil,visibleMatches.count==1,let match=visibleMatches.first { automaticEntryUsed=true;model.watch(match) }
    }
    private func refresh() async { await model.refresh();enterSingleHostMatch() }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            SheetHeader(title:model.selected == nil ? (piOnly ? "树莓派比赛":"同步比赛"):"比赛现场")
            if let match=model.selected {
                Button("返回比赛列表") { model.stopWatching();Task { await model.refresh() } }
                Text(match.authority_type == "pi" ? "树莓派计分":"手机计分").font(.headline)
                Text(lifecycle(match)).foregroundColor(Palette.muted)
                CourtScene(live:true,compact:false,doubles:match.doubles,names:match.names,
                           scores:[UInt8(clamping:match.snapshot.red),UInt8(clamping:match.snapshot.blue),UInt8(clamping:match.snapshot.redGames),UInt8(clamping:match.snapshot.blueGames),match.snapshot.server == .red ? 0:1],
                           scoreContext:match.id,scoreEventsEnabled:false,visible:phase == .active,actionable:false) { _ in }.frame(height:390)
                Text(match.canEndFromPhone ? "比分由树莓派确认 · 管理员可结束本场":"只读观赛 · 比分由原计分主机确认").font(.caption)
                if match.canEndFromPhone { Button("结束比赛") { endMatch=match }.buttonStyle(PrimaryStyle()) }
                TimelineView(.periodic(from:.now,by:5)) { tick in
                    Text(tick.date.timeIntervalSince1970 - Double(match.received_at) > 15
                         ? "主机暂无新的上传，显示最后确认比分；云端连接不代表主机在线。"
                         : "已收到主机最新提交。")
                    .font(.caption).foregroundColor(Palette.muted)
                }
                Text("比赛编号："+match.id).font(.caption).textSelection(.enabled)
                Text("已确认版本："+match.revision).font(.caption)
                if match.role == "owner" || match.role == "host_member" {
                    Text("邀请观赛").font(.headline)
                    TextField("球友的业务身份编号（完整 ID）",text:$spectatorID).inputStyle().textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("授权一小时") { Task { await model.share(userID:spectatorID.trimmingCharacters(in:.whitespacesAndNewlines),revoke:false) } }
                        Spacer()
                        Button("撤销授权") { Task { await model.share(userID:spectatorID.trimmingCharacters(in:.whitespacesAndNewlines),revoke:true) } }
                    }.disabled(spectatorID.isEmpty)
                    Text("由计分手机账号或主机管理员授权。临时球员不会按昵称合并到账户战绩。").font(.caption).foregroundColor(Palette.muted)
                }
            } else {
                Text(piOnly ? "这里进入树莓派确认的比赛，显示同一场名单、比分和结束状态。" : "进入已存在的比赛或获授权观赛。")
                if piOnly && visibleMatches.isEmpty {
                    Text(requestedMatchID == nil ? "尚未收到这台树莓派未结束的比赛":"暂未读取到本场比赛").font(.headline)
                    Text("如果树莓派已经开赛，请检查比赛上传服务。拍底在线、主机地址同步成功，并不代表名单和比分已上传。").font(.subheadline).foregroundColor(Palette.muted)
                }
                Button("刷新比赛") { Task { await refresh() } }
                ForEach(visibleMatches) { match in
                    Button { model.watch(match) } label: {
                        VStack(alignment:.leading,spacing:8) {
                            Text(match.names[0]+" 对 "+match.names[2]).font(.headline)
                            Text("\(match.snapshot.red) : \(match.snapshot.blue) · "+lifecycle(match))
                            Text(match.authority_type == "pi" ? "树莓派比赛":"手机比赛").font(.caption)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding().background(Palette.soft).cornerRadius(16)
                    }.buttonStyle(.plain)
                }
            }
            Text(model.message).foregroundColor(Palette.muted)
        }.padding(22) }.background(Palette.background)
        .sheet(item:$endMatch) { PiEndPage(match:$0).environmentObject(social) }
        .task(id:scope) {
            automaticEntryUsed=false
            guard let c=social.credentials,social.verifiedBusiness else { model.close();return }
            await model.open(RacketContext(origin:social.origin,userID:c.user.id,token:c.token,hostID:nil,userName:c.user.name))
            enterSingleHostMatch()
            while piOnly && !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                if phase == .active && model.selected == nil { await refresh() }
            }
        }
        .onChange(of:phase) { p in if p == .background { model.stopWatching() } }
        .onDisappear { model.close() }
    }
    private func lifecycle(_ match: SharedMatch) -> String {
        switch match.lifecycle { case "completed":return "比赛已完成";case "aborted":return "提前结束";case "paused":return "比赛暂停";default:return "比赛进行中" }
    }
}

struct PiStartPage:View {
    let deviceID:String
    let names:[String]
    let doubles:Bool
    var racketDevices:[RacketDevice]=[]
    @State private var selectedRacket=""
    @EnvironmentObject var social:GatheringStore
    @StateObject private var model=PiStartController()
    @State private var enter=false
    @State private var entryMatchID:String?
    @Environment(\.scenePhase) private var phase
    private var scope:String { social.origin+social.userID+(social.credentials?.token ?? "")+deviceID }
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            SheetHeader(title:"树莓派开赛")
            Text(doubles ? "双打 · 21 分 · 三局两胜":"单打 · 21 分 · 三局两胜").font(.headline)
            Text(names.enumerated().filter { doubles || $0.offset==0 || $0.offset==2 }.map(\.element).joined(separator:" / "))
            if !racketDevices.isEmpty && model.result == nil && !model.hasOriginalRequest {
                Picker("红方第一位使用的拍底",selection:$selectedRacket) {
                    Text("暂不连接拍底").tag("")
                    ForEach(racketDevices) { racket in Text(racket.name).tag(racket.id) }
                }
                Text("仅可选择已关联到自己的拍底；会沿用其归属和网络配置。").font(.caption)
            }
            if model.matchID != nil {
                Text("可查看本场比赛的最新比分与状态。")
                Button("进入树莓派比赛") { entryMatchID=model.matchID;enter=true }.buttonStyle(PrimaryStyle())
            } else {
                Button(model.hasOriginalRequest ? "重试原开赛请求":"在树莓派开始比赛") {
                    Task { await model.start(names:names,doubles:doubles,racketID:selectedRacket.isEmpty ? nil:selectedRacket) }
                }.buttonStyle(PrimaryStyle()).disabled(model.busy || (!model.hasOriginalRequest && model.host?.can_start != true))
                if model.host?.online == true && model.host?.can_start == false && model.result == nil {
                    Text("请先结束旧比赛，并在树莓派屏幕上准备下一场。手机不会自动清除原比赛。")
                }
            }
            Text(model.message).foregroundColor(Palette.muted)
            Button("刷新主机 / 查询原请求") { Task { await model.refresh() } }.disabled(model.busy)
            Text("选择拍底后，主机会在开赛后确认其红方第一位映射。接收器忙碌时继续等待，不会重复开赛。").font(.caption).foregroundColor(Palette.muted)
        }.padding(22) }.background(Palette.background)
        .sheet(isPresented:$enter) { SharedMatchesPage(piOnly:true,hostDeviceID:deviceID,requestedMatchID:entryMatchID).environmentObject(social) }
        .task(id:scope) {
            guard let c=social.credentials,social.verifiedBusiness else { model.close();return }
            await model.open(RacketContext(origin:social.origin,userID:c.user.id,token:c.token,hostID:nil,userName:c.user.name),deviceID:deviceID)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { return }
                if phase == .active { await model.refresh() }
            }
        }.onDisappear { model.close() }
    }
}

struct PiEndPage:View {
    let match:SharedMatch
    @EnvironmentObject var social:GatheringStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model=PiEndController()
    private var scope:String { social.origin+social.userID+(social.credentials?.token ?? "")+match.id }
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:22) {
            SheetHeader(title:"结束树莓派比赛")
            let current=model.match ?? match
            Text(current.names[0]+" 对 "+current.names[2]).font(.headline)
            Text("\(current.snapshot.red) : \(current.snapshot.blue)").font(.system(size:48,weight:.bold))
            Text("局数 \(current.snapshot.redGames) : \(current.snapshot.blueGames)").foregroundColor(Palette.muted)
            Text(model.message).fixedSize(horizontal:false,vertical:true)
            if model.result?.status == "succeeded" || current.isTerminal && !model.waiting {
                Button("完成") { dismiss() }.buttonStyle(PrimaryStyle())
            } else if model.waiting {
                HStack { ProgressView();Text("等待主机确认与结果同步") }
            } else {
                Button(model.hasOriginalRequest ? "重试原结束请求":"确认结束比赛") { Task { await model.end() } }
                    .buttonStyle(PrimaryStyle()).disabled(model.busy || !current.canEndFromPhone)
            }
            Button("刷新比分 / 查询结束结果") { Task { await model.refresh() } }.disabled(model.busy)
            Text("确认结束只影响这场比赛，保留比赛记录。关闭此页不会取消已经提交的请求。").font(.caption).foregroundColor(Palette.muted)
        }.padding(22) }.background(Palette.background)
        .task(id:scope) {
            guard let c=social.credentials,social.verifiedBusiness else { model.close();return }
            await model.open(RacketContext(origin:social.origin,userID:c.user.id,token:c.token,hostID:nil,userName:c.user.name),match:match)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { return }
                if phase == .active { await model.refresh() }
            }
        }.onDisappear { model.close() }
    }
}
