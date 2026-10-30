import SwiftUI

struct SharedMatchesPage: View {
    @EnvironmentObject var social: GatheringStore
    @StateObject private var model=LocalMatchBrowser()
    @State private var spectatorID=""
    @Environment(\.scenePhase) private var phase
    private var scope:String { social.origin+"|"+social.userID+"|"+(social.credentials?.token ?? "") }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            SheetHeader(title:model.selected == nil ? "同步比赛":"比赛现场")
            if let match=model.selected {
                Button("返回比赛列表") { model.stopWatching();Task { await model.refresh() } }
                Text(match.authority_type == "pi" ? "树莓派计分":"手机计分").font(.headline)
                Text(lifecycle(match)).foregroundColor(Palette.muted)
                CourtScene(live:true,compact:false,doubles:match.doubles,names:match.names,
                           scores:[UInt8(clamping:match.snapshot.red),UInt8(clamping:match.snapshot.blue),UInt8(clamping:match.snapshot.redGames),UInt8(clamping:match.snapshot.blueGames),match.snapshot.server == .red ? 0:1],
                           scoreContext:match.id,scoreEventsEnabled:false,visible:phase == .active,actionable:false) { _ in }.frame(height:390)
                Text("只读观赛 · 比分由原计分主机确认").font(.caption)
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
                Text("进入已存在的比赛，不会重新开赛。树莓派需先上传本场名单和比分。")
                Button("刷新比赛") { Task { await model.refresh() } }
                ForEach(model.matches) { match in
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
        .task(id:scope) {
            guard let c=social.credentials,social.verifiedBusiness else { model.close();return }
            await model.open(RacketContext(origin:social.origin,userID:c.user.id,token:c.token,hostID:nil,userName:c.user.name))
        }
        .onChange(of:phase) { p in if p == .background { model.stopWatching() } }
        .onDisappear { model.close() }
    }
    private func lifecycle(_ match: SharedMatch) -> String {
        switch match.lifecycle { case "completed":return "比赛已完成";case "aborted":return "提前结束";case "paused":return "比赛暂停";default:return "比赛进行中" }
    }
}
