import SwiftUI

@MainActor final class RacketModeController: ObservableObject {
    struct Pending: Codable { let id:String; let device:String; let session:String; var command:Data? }
    @Published var message="连接并验证拍底后，可查询当前计分主机模式。"
    @Published var busy=false
    @Published var enabled=false
    @Published var profiles=[[String:String]]()
    private var summary:String?
    private var device:String?
    private var session:String?
    private var scope:RacketContext?
    func reset(_ context:RacketContext?) {
        guard scope != context else { return };scope=context;enabled=false;summary=nil;profiles=[]
        message="连接并验证拍底后，可查询当前计分主机模式。"
    }
    private func key(_ c:RacketContext,_ device:String)->String { RacketDualHostWire.pendingKey(origin:c.origin,account:c.userID,device:device) }
    func check(_ context:RacketContext) async {
        guard !busy else { return };busy=true;enabled=false;scope=context;defer { busy=false }
        do {
            let service=RacketBLEConnectionHub.shared.service(for:context)
            guard let candidate=service.connectedCandidate else { throw RacketFailure.interrupted }
            _=try await service.verifyAndPrepare(candidate,hostID:nil,context:context)
            let info=try await service.transport.currentInfo();device=info.deviceID;session=info.session
            let settings=try await service.modeRequest("/profiles",context:context)
            guard scope==context else { return }
            profiles=(settings["profiles"] as? [[String:String]] ?? []).filter { $0["device_id"]==info.deviceID }
            var pending:Pending?=GatheringPersistence.loadValue(key(context,info.deviceID))
            if let previous=pending {
                do {
                    let stored=try await service.modeRequest("/"+previous.id,context:context)
                    if ["confirmed","rejected","superseded"].contains(stored["status"] as? String ?? "") {
                        try GatheringPersistence.saveValue(Optional<Pending>.none,origin:key(context,info.deviceID));pending=nil
                    }
                } catch RacketFailure.operationNotFound where previous.command==nil {
                    // No command was ever durably received or forwarded by this phone.
                    try GatheringPersistence.saveValue(Optional<Pending>.none,origin:key(context,info.deviceID));pending=nil
                }
            }
            if pending==nil {
                let list=try await service.modeRequest("/pending",context:context)
                if let row=(list["operations"] as? [[String:Any]])?.first(where: { $0["device_id"] as? String == info.deviceID }),
                   let oid=row["operation_id"] as? String,let oldSession=row["session"] as? String {
                    pending=Pending(id:oid,device:info.deviceID,session:oldSession,command:nil)
                    try GatheringPersistence.saveValue(pending,origin:key(context,info.deviceID))
                }
            }
            let id=UUID().uuidString.lowercased()
            var body:[String:Any]=["operation_id":id,"device_id":info.deviceID,"session":info.session]
            if let pending { body["subject_operation"]=pending.id }
            let issued=try await service.modeRequest("/summary",body:body,context:context)
            guard let encoded=issued["command"] as? String,let command=Data(base64Encoded:encoded) else { throw RacketFailure.verificationFailed }
            let result=try await service.forwardMode(command,operation:id,context:context)
            guard scope==context else { return }
            let status=result["status"] as? String
            if pending != nil {
                guard ["confirmed","rejected","superseded"].contains(status ?? "") else { message="原配置结果尚未确认，请重新连接后查询原结果，不会重复提交。";return }
                try GatheringPersistence.saveValue(Optional<Pending>.none,origin:key(context,info.deviceID))
                message=status=="confirmed" ? "原配置已由设备确认，请再次查询当前模式。":"原配置未生效，可再次查询后选择。"
                return
            }
            guard status=="observed" else { throw RacketFailure.unknown }
            summary=id
            let guardState=result["guard"] as? Int ?? 2
            message="当前模式："+(result["mode"] as? String == "pi" ? "树莓派 Wi-Fi":"手机蓝牙")+" · 配置版本 \(result["generation"] as? Int ?? 0)"
            if guardState==1 { message += "。请先正常结束或暂停原计分会话并停止拍底连接。" }
            if guardState==2 { message += "。有未确认计分事件，需要原主机核对；不能直接清除或换主机。" }
            enabled=guardState==0 && settings["enabled"] as? Bool == true
            if settings["enabled"] as? Bool != true { message += result["mode"] as? String == "pi" ? "。模式切换暂未开放；不影响当前树莓派模式。" : "。已处于手机计分模式，无需重新配网。切换到树莓派暂未开放。" }
        } catch { if scope==context { message=error.localizedDescription } }
    }
    func configure(_ mode:String,profile:String? = nil,context:RacketContext) async {
        guard !busy,enabled,scope==context,let device,let session,let summary else { return }
        busy=true;enabled=false;defer { busy=false }
        var pending=Pending(id:UUID().uuidString.lowercased(),device:device,session:session,command:nil)
        do {
            let previous:Pending?=GatheringPersistence.loadValue(key(context,device))
            guard previous==nil else { throw RacketFailure.unknown }
            try GatheringPersistence.saveValue(pending,origin:key(context,device))
            var body:[String:Any]=["operation_id":pending.id,"device_id":device,"session":session,"summary_id":summary,"mode":mode]
            if let profile { body["profile_id"]=profile }
            let service=RacketBLEConnectionHub.shared.service(for:context)
            let issued=try await service.modeRequest("/configure",body:body,context:context)
            guard let encoded=issued["command"] as? String,let command=Data(base64Encoded:encoded) else { throw RacketFailure.verificationFailed }
            pending.command=command
            try GatheringPersistence.saveValue(pending,origin:key(context,device)) // Nonce and credential-bearing bytes in Keychain BEFORE BLE transmission.
            let result=try await service.forwardMode(command,operation:pending.id,context:context)
            guard scope==context else { return }
            let status=result["status"] as? String ?? "unknown"
            if ["confirmed","rejected","superseded"].contains(status) {
                try GatheringPersistence.saveValue(Optional<Pending>.none,origin:key(context,device))
                message=status=="confirmed" ? "计分主机配置已由设备确认。":"设备拒绝配置，请查询当前状态。"
            } else { message="配置结果尚未确认，请查询原结果。" }
        } catch {
            guard scope==context else { return }
            // An explicit server rejection before a command was received cannot have
            // reached BLE. Network/timeout and any post-command failure stay unknown.
            let denied:Bool
            if let failure=error as? RacketFailure {
                switch failure { case .forbidden,.ownedByOther,.conflict,.pauseRequired: denied=true;default:denied=false }
            } else if let diagnostic=error as? RacketDiagnostic { denied=diagnostic.stage=="主机配置" }
            else { denied=false }
            if pending.command==nil && denied {
                try? GatheringPersistence.saveValue(Optional<Pending>.none,origin:key(context,device))
                message="配置未提交："+error.localizedDescription
            } else { message="配置尚未确认，请保留原操作并查询："+error.localizedDescription }
        }
    }
}
struct RacketModePage: View {
    let context:RacketContext?
    @StateObject private var model=RacketModeController()
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            SheetHeader(title:"拍底计分主机")
            Text(model.message)
            Button("查询当前模式 / 原配置结果") { if let context { Task { await model.check(context) } } }.disabled(model.busy || context==nil)
            if model.enabled {
                Text("受控实验配置").font(.headline)
                Text("请确认原比赛已停止。切换不会改变使用者；当前实验配网尚无蓝牙链路加密，仅用于受控测试。").font(.caption)
                Button("使用手机蓝牙计分") { if let context { Task { await model.configure("phone",context:context) } } }.buttonStyle(PrimaryStyle())
                ForEach(model.profiles.indices,id:\.self) { i in
                    Button("使用 "+(model.profiles[i]["name"] ?? "树莓派")) {
                        if let context { Task { await model.configure("pi",profile:model.profiles[i]["id"],context:context) } }
                    }.buttonStyle(PrimaryStyle())
                }
                if model.profiles.isEmpty { Text("暂无已授权的树莓派网络配置，请由开发者登记主机和受控网络。").font(.caption) }
            }
            if model.busy { ProgressView("正在核对设备…") }
            Text("已关联使用者、蓝牙已连接、本场计分就绪是不同状态。切换主机不会替你开赛。").font(.caption).foregroundColor(Palette.muted)
        }.padding(22) }.background(Palette.background)
        .onAppear { model.reset(context) }
        .onChange(of:context) { model.reset($0) }
    }
}
