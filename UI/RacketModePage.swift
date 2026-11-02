import SwiftUI

@MainActor final class RacketModeController: ObservableObject {
    struct Pending: Codable { let id:String; let device:String; let session:String; var command:Data? }
    @Published var message="连接并验证拍底后，可查询当前计分主机模式。"
    @Published var busy=false
    @Published var enabled=false
    @Published var selectedProfile=""
    @Published var manualAddress=false
    @Published var hostNetworkSupported=false
    @Published var wifiSSID=""
    @Published var wifiPassword=""
    @Published var wifiSupported=false
    @Published var targetHost=""
    @Published var targetPort="8888"
    @Published var currentMode=""
    @Published var addressSupported=false
    @Published var profiles=[[String:String]]()
    @Published var nearby=[RacketNearby]()
    @Published var network:RacketNetworkSnapshot?
    @Published var networkTime:Date?
    @Published var networkMessage="点击刷新，读取拍底当前网络状态。"
    private var networkDevice:String?
    var networkReport:String {
        guard let network,let networkTime else { return "" }
        return "羽小裁 · 拍底网络诊断 v\(network.version)\n设备：\(networkDevice ?? "未知")\n采集时间：\(ISO8601DateFormatter().string(from:networkTime))\n只读运行快照，非签名回执；不含密码或密钥。\n"+network.report
    }
    var selectedHost:[String:String]? { profiles.first { $0["id"]==selectedProfile } }
    var hostStatus:String {
        if currentMode=="phone" { return "当前使用手机蓝牙计分；以下设置仅用于切换到树莓派。" }
        guard let host=selectedHost else { return "请先查询并选择已授权计分主机。" }
        guard host["network_status"]=="online" else { return "等待树莓派上报当前地址。请确认主机联网且已安装网络同步服务。" }
        let address=(host["auto_target_host"] ?? "")+":"+(host["auto_target_port"] ?? "")
        switch host["receiver_sync"] {
        case "applied":return "主机地址："+address+"。接收器已同步配置代次 "+(host["confirmed_generation"] ?? "")+"；计分是否就绪请查看下方网络状态。"
        case "rejected":return "主机地址："+address+"。接收器拒绝同步，请核对主机身份、关联版本与运行配置；不会自动重置比赛。"
        case "pending":return "主机地址："+address+"。等待接收器同步配置代次 "+(host["confirmed_generation"] ?? "")+"。"
        default:return "主机地址："+address+"。等待本次配置确认与接收器同步。"
        }
    }
    func fillAutomaticAddress() {
        guard !manualAddress else { return }
        targetHost=selectedHost?["auto_target_host"] ?? ""
        targetPort=selectedHost?["auto_target_port"] ?? "8888"
    }
    private func applyHostSettings(_ settings:[String:Any]) {
        hostNetworkSupported=settings["host_network_supported"] as? Bool == true
        profiles=(settings["profiles"] as? [[String:String]] ?? []).filter { $0["device_id"]==device }
        if !profiles.contains(where: { $0["id"]==selectedProfile }) { selectedProfile=profiles.first?["id"] ?? "" }
        fillAutomaticAddress()
    }
    private func refreshHostInventory(_ context:RacketContext) async {
        do {
            let settings=try await RacketBLEConnectionHub.shared.service(for:context).modeRequest("/profiles",context:context)
            guard scope==context else { return };applyHostSettings(settings)
        } catch {
            guard scope==context else { return }
            // Do not keep showing a cached lease as current when refresh fails.
            for i in profiles.indices { profiles[i]["network_status"]="offline";profiles[i].removeValue(forKey:"auto_target_host");profiles[i].removeValue(forKey:"auto_target_port") }
            fillAutomaticAddress()
        }
    }
    private func readNetwork(_ context:RacketContext) async {
        // Keep network observation separate from the signed configuration result.
        do {
            let service=RacketBLEConnectionHub.shared.service(for:context)
            let info=try await service.transport.currentInfo()
            let snapshot=try await service.transport.readModeDiagnostics()
            guard scope==context else { return }
            if device != nil && device != info.deviceID { enabled=false;summary=nil;profiles=[] }
            if networkDevice != nil && networkDevice != info.deviceID { targetHost="";targetPort="8888" }
            network=snapshot;networkTime=Date();networkDevice=info.deviceID
            if manualAddress && targetHost.isEmpty { targetHost=snapshot.targetHost;targetPort=String(snapshot.targetPort) }
            networkMessage="最近读取的设备快照；断线或网络变化后请重新刷新。"
        } catch {
            guard scope==context else { return }
            network=nil;networkTime=nil;networkDevice=nil
            if case RacketFailure.protocolUnavailable = error {
                networkMessage="当前固件未提供网络诊断，请升级支持诊断的固件。"
            } else { networkMessage="网络状态未能读取："+error.localizedDescription }
        }
    }
    func refreshNetwork(_ context:RacketContext) async {
        guard !busy,scope==context else { return }
        let service=RacketBLEConnectionHub.shared.service(for:context)
        guard service.connectedCandidate != nil else {
            network=nil;networkTime=nil
            await check(context)
            return
        }
        busy=true;defer { busy=false }
        await readNetwork(context)
    }
    private var summary:String?
    private var device:String?
    private var session:String?
    private var scope:RacketContext?
    func reset(_ context:RacketContext?) {
        guard scope != context else { return };scope=context;enabled=false;summary=nil;profiles=[];nearby=[];device=nil;session=nil
        selectedProfile="";manualAddress=false;hostNetworkSupported=false
        wifiSSID="";wifiPassword="";wifiSupported=false
        network=nil;networkTime=nil;networkDevice=nil;targetHost="";targetPort="8888";currentMode="";addressSupported=false;networkMessage="点击刷新，读取拍底当前网络状态。"
        message="连接并验证拍底后，可查询当前计分主机模式。"
    }
    private func key(_ c:RacketContext,_ device:String)->String { RacketDualHostWire.pendingKey(origin:c.origin,account:c.userID,device:device) }
    func check(_ context:RacketContext, candidate selected:RacketNearby? = nil) async {
        guard !busy else { return };busy=true;enabled=false;scope=context;defer { busy=false }
        do {
            let service=RacketBLEConnectionHub.shared.service(for:context)
            let candidate:RacketNearby
            if let existing = selected ?? service.connectedCandidate { candidate=existing }
            else {
                message="正在搜索附近拍底…"
                let found=try await service.scan()
                guard scope==context else { return }
                nearby=found
                message=found.isEmpty ? "未发现附近拍底，请确认拍底已开机，且未被其他手机或 Mac 占用，然后重新搜索。" : "蓝牙当前未连接，请选择拍底重新连接并验证。"
                return
            }
            message="正在连接并验证拍底…"
            _=try await service.verifyForMode(candidate,context:context)
            guard scope==context else { return }
            nearby=[]
            network=nil;networkTime=nil
            let info=try await service.transport.currentInfo();device=info.deviceID;session=info.session
            let settings=try await service.modeRequest("/profiles",context:context)
            guard scope==context else { return }
            wifiSupported=settings["wifi_provisioning_supported"] as? Bool == true
            addressSupported=settings["address_update_supported"] as? Bool == true
            applyHostSettings(settings)
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
            currentMode=result["mode"] as? String ?? ""
            let guardState=result["guard"] as? Int ?? 2
            message="当前模式："+(result["mode"] as? String == "pi" ? "树莓派 Wi-Fi":"手机蓝牙")+" · 配置版本 \(result["generation"] as? Int ?? 0)"
            if guardState==1 { message += "。请先正常结束或暂停原计分会话并停止拍底连接。" }
            if guardState==2 { message += "。有未确认计分事件，需要原主机核对；不能直接清除或换主机。" }
            enabled=guardState==0 && settings["enabled"] as? Bool == true
            if settings["enabled"] as? Bool != true { message += result["mode"] as? String == "pi" ? "。模式切换暂未开放；不影响当前树莓派模式。" : "。已处于手机计分模式，无需重新配网。切换到树莓派暂未开放。" }
            await readNetwork(context)
        } catch { if scope==context { message=error.localizedDescription;network=nil;networkTime=nil } }
    }
    func observeNetwork(_ context:RacketContext) async {
        guard !busy,scope==context,device != nil,currentMode != "phone" else { return }
        busy=true;defer { busy=false }
        await refreshHostInventory(context)
        if RacketBLEConnectionHub.shared.service(for:context).connectedCandidate != nil { await readNetwork(context) }
    }
    func provisionWiFi(profile:String?,context:RacketContext) async {
        guard wifiSupported else { message="服务端尚未开放 Wi-Fi 配网。";return }
        guard !wifiSSID.contains("\0"),1...32 ~= wifiSSID.utf8.count,
              !wifiPassword.contains("\0"),8...63 ~= wifiPassword.utf8.count else {
            message="请填写 Wi-Fi 名称（最多 32 字节）和密码（8–63 字节）。名称与密码会原样发送，请核对大小写和空格。";return
        }
        if !manualAddress && selectedHost?["network_status"] != "online" { message="主机地址尚未上报或已过期，请等待树莓派同步。";return }
        guard let endpoint=validatedEndpoint() else { return }
        let credentials=(wifiSSID,wifiPassword)
        wifiPassword=""
        await configure("pi",profile:profile,context:context,target:endpoint,wifi:credentials)
    }
    private func validatedEndpoint()->(String,Int)? {
        let host=targetHost.trimmingCharacters(in:.whitespacesAndNewlines)
        let parts=host.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==4,parts.allSatisfy({ part in
            guard let value=Int(part),0...255 ~= value else { return false };return String(value)==part
        }),let port=Int(targetPort),1...65535 ~= port else {
            message="请填写 IPv4 地址（例如 172.20.10.2）和 1–65535 的端口。";return nil
        }
        return (host,port)
    }
    func updateAddress(profile:String?,context:RacketContext) async {
        if !manualAddress && selectedHost?["network_status"] != "online" { message="主机地址尚未上报或已过期，请等待树莓派同步。";return }
        guard let endpoint=validatedEndpoint() else { return }
        guard currentMode=="pi",addressSupported else { message="请先查询树莓派模式，再更新地址。";return }
        await configure("pi",profile:profile,context:context,target:endpoint)
    }
    func configure(_ mode:String,profile:String? = nil,context:RacketContext,target:(String,Int)? = nil,wifi:(String,String)? = nil) async {
        guard !busy,enabled,scope==context else { return }
        // The user may leave the selection screen open beyond the firmware's
        // 60-second connection lifetime. Renew AUTH + SUMMARY before signing,
        // never retry an already issued configuration as a new operation.
        await check(context)
        guard !busy,enabled,scope==context,let device,let session,let summary else { return }
        if mode=="pi" && !manualAddress {
            guard let host=profiles.first(where: { $0["id"]==profile }),host["network_status"]=="online",host["endpoint_revision"] != nil else {
                message="主机地址尚未上报或已过期，请稍后刷新。";return
            }
        }
        busy=true;enabled=false;defer { busy=false }
        var pending=Pending(id:UUID().uuidString.lowercased(),device:device,session:session,command:nil)
        do {
            let previous:Pending?=GatheringPersistence.loadValue(key(context,device))
            guard previous==nil else { throw RacketFailure.unknown }
            try GatheringPersistence.saveValue(pending,origin:key(context,device))
            var body:[String:Any]=["operation_id":pending.id,"device_id":device,"session":session,"summary_id":summary,"mode":mode]
            if let profile { body["profile_id"]=profile }
            if let target { body["target_host"]=target.0;body["target_port"]=target.1 }
            if mode=="pi",!manualAddress,let host=profiles.first(where: { $0["id"]==profile }) {
                body["target_host"]=host["auto_target_host"];body["target_port"]=Int(host["auto_target_port"] ?? "")
                body["endpoint_revision"]=host["endpoint_revision"]
            }
            if let wifi { body["wifi_ssid"]=wifi.0;body["wifi_password"]=wifi.1 }
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
                if status=="confirmed" {
                    currentMode=result["mode"] as? String ?? mode
                    if currentMode=="phone" {
                        message="当前模式：手机蓝牙 · 设备已确认配置代次 \(result["generation"] as? Int ?? 0)。请返回手机比赛，点击“重新连接拍底”；无需等待树莓派同步。"
                        network=nil;networkTime=nil
                    } else {
                        message="设备已确认配置代次 \(result["generation"] as? Int ?? 0)。正在等待树莓派接收器同步，页面会自动刷新；配置保存成功不代表主机已就绪。"
                    }
                } else { message="设备拒绝配置，请查询当前状态。" }
                await refreshHostInventory(context)
                if currentMode != "phone" { await readNetwork(context) }
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
    @FocusState private var editing:Bool
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            SheetHeader(title:"拍底计分主机")
            Text(model.message)
            Button("搜索拍底 / 查询当前模式与原配置结果") { if let context { Task { await model.check(context) } } }.disabled(model.busy || context==nil)
            ForEach(model.nearby) { candidate in
                Button("连接并查询 · "+candidate.label) {
                    if let context { Task { await model.check(context,candidate:candidate) } }
                }.frame(minHeight:44).disabled(model.busy || context==nil)
            }
            if !model.profiles.isEmpty {
                VStack(alignment:.leading,spacing:12) {
                    Text("选择计分主机").font(.headline)
                    Picker("树莓派",selection:$model.selectedProfile) {
                        ForEach(model.profiles.indices,id:\.self) { i in
                            Text(model.profiles[i]["name"] ?? "树莓派").tag(model.profiles[i]["id"] ?? "")
                        }
                    }
                    Text(model.hostStatus).font(.subheadline)
                    if let ssid=model.selectedHost?["wifi_ssid"],!ssid.isEmpty { Text("主机 Wi-Fi："+ssid).font(.caption).foregroundColor(Palette.muted) }
                    if model.currentMode=="pi" {
                        Button("使用当前 Wi-Fi 连接此主机") {
                            editing=false
                            if let context { Task { await model.updateAddress(profile:model.selectedProfile,context:context) } }
                        }.buttonStyle(PrimaryStyle()).disabled(model.busy || !model.enabled || (!model.manualAddress && model.selectedHost?["network_status"] != "online"))
                    }
                    Text("为拍底配置 Wi-Fi").font(.headline)
                    Text("首次配网或更换热点时填写 2.4 GHz Wi-Fi。主机地址由树莓派自动上报。").font(.subheadline)
                    TextField("Wi-Fi 名称（SSID）",text:$model.wifiSSID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).focused($editing)
                    SecureField("Wi-Fi 密码（8–63 字节）",text:$model.wifiPassword)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).focused($editing)
                    DisclosureGroup("高级设置 · 手动地址") {
                        Toggle("手动指定地址",isOn:$model.manualAddress)
                        if model.manualAddress {
                            TextField("树莓派 IPv4 地址",text:$model.targetHost).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).focused($editing)
                            TextField("端口",text:$model.targetPort).keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($editing)
                        }
                    }
                    Text("请先停止原比赛。当前配网仅用于受控测试，蓝牙配置链路尚未加密。").font(.caption).foregroundColor(Palette.muted)
                    Button("配置 Wi-Fi 并连接主机") {
                        editing=false
                        if let context { Task { await model.provisionWiFi(profile:model.selectedProfile,context:context) } }
                    }.buttonStyle(PrimaryStyle()).disabled(model.busy || !model.enabled || !model.wifiSupported || (!model.manualAddress && model.selectedHost?["network_status"] != "online"))
                    if !model.wifiSupported { Text("服务端 Wi-Fi 配网功能尚未开放。").font(.caption) }
                    Text("密码不会回显或写入诊断日志。配置保留使用者、关联版本和通道密钥；树莓派接收器会领取设备确认的配置代次；未接入同步服务时会保持等待状态。").font(.caption).foregroundColor(Palette.muted)
                }.padding(16).background(Color.white).cornerRadius(16).disabled(model.busy)
            } else if !model.currentMode.isEmpty {
                Text("暂无已授权树莓派，请先登记计分主机。").font(.caption)
            }
            if model.enabled {
                Button("使用手机蓝牙计分") {
                    editing=false;model.wifiPassword=""
                    if let context { Task { await model.configure("phone",context:context) } }
                }.buttonStyle(PrimaryStyle()).disabled(model.busy)
            }
            VStack(alignment:.leading,spacing:12) {
                Text("网络与计分连接").font(.headline)
                if let network=model.network,let time=model.networkTime {
                    Text(network.headline).font(.headline)
                    Text(network.guidance).font(.subheadline)
                    Text(network.wifiAttemptSummary).font(.subheadline)
                    Text("计数表示本次开机以来的 SDK 连接请求，包含被拒绝的调用；不代表连接成功。").font(.caption).foregroundColor(Palette.muted)
                    Text("采集时间："+time.formatted(date:.omitted,time:.standard)).font(.caption).foregroundColor(Palette.muted)
                    DisclosureGroup("连接详情") { Text(network.report).font(.caption).textSelection(.enabled) }
                    Button("复制网络诊断") { UIPasteboard.general.string=model.networkReport }
                }
                Text(model.networkMessage).font(.caption).foregroundColor(Palette.muted)
                Button("刷新网络状态") { if let context { Task { await model.refreshNetwork(context) } } }
                    .disabled(model.busy || context==nil)
                Text("刷新只读取状态，不会切换主机或重新配网。最近断线原因是历史记录，不代表当前仍断线。").font(.caption).foregroundColor(Palette.muted)
            }.padding(16).background(Color.white).cornerRadius(16)
            if model.busy { ProgressView("正在核对设备…") }
            Text("已关联使用者、蓝牙已连接、本场计分就绪是不同状态。切换主机不会替你开赛。").font(.caption).foregroundColor(Palette.muted)
        }.padding(22) }.background(Palette.background)
        .toolbar { ToolbarItemGroup(placement:.keyboard) { Spacer();Button("完成") { editing=false } } }
        .onDisappear { model.wifiPassword="" }
        .task(id:context) {
            guard let context else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                if !editing { await model.observeNetwork(context) }
            }
        }
        .onChange(of:model.selectedProfile) { _ in model.fillAutomaticAddress() }
        .onChange(of:model.manualAddress) { _ in model.fillAutomaticAddress() }
        .onAppear { model.reset(context) }
        .onChange(of:context) { model.reset($0) }
    }
}
