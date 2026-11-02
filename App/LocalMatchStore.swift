import Foundation
import Combine

/// No redirects: never forward a business bearer credential to a different origin.
private final class MatchNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct LocalMatchHTTPError: LocalizedError {
    let status: Int; let code: String
    var errorDescription: String? {
        switch code {
        case "UNAUTHENTICATED": return "登录已过期，请重新登录。"
        case "NOT_FOUND", "FORBIDDEN": return "比赛不存在，或观赛权限已撤销。"
        case "ACTIVE_MATCH": return "云端仍有这台手机未结束的比赛，请保留本机记录并核对。"
        case "AUTHORITY_CONFLICT", "HISTORY_CONFLICT", "OPERATION_ID_REUSED", "REVISION_GAP", "SNAPSHOT_MISMATCH": return "比赛同步冲突，本机比分已保留，请核对原比赛。"
        default: return "比赛同步暂不可用（\(code)），本机数据已保留。"
        }
    }
}
@MainActor final class LocalMatchAPI: MatchSyncService {
    let context: RacketContext
    let http=URLSession(configuration:.ephemeral,delegate:MatchNoRedirect(),delegateQueue:nil)
    init(_ context: RacketContext) { self.context=context }
    func cancel() { http.invalidateAndCancel() }
    func request(_ suffix: String, body: [String:Any]? = nil) throws -> URLRequest {
        guard let base=URL(string:context.origin),base.scheme == "https",base.host != nil,base.user == nil,base.password == nil,
              let url=URL(string:context.origin+"/api/social/local-matches"+suffix) else { throw LocalMatchHTTPError(status:0,code:"HTTPS_REQUIRED") }
        var r=URLRequest(url:url);r.timeoutInterval=35
        r.setValue("Bearer "+context.token,forHTTPHeaderField:"Authorization")
        r.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let body { r.httpMethod="POST";r.httpBody=try JSONSerialization.data(withJSONObject:body) }
        return r
    }
    func check(_ response: URLResponse,_ data: Data = Data()) throws {
        guard let h=response as? HTTPURLResponse,h.statusCode==200 else {
            let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let code=(object?["error"] as? [String:Any])?["code"] as? String ?? "HTTP_\((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw LocalMatchHTTPError(status:(response as? HTTPURLResponse)?.statusCode ?? 0,code:code)
        }
    }
    func get<T: Decodable>(_ suffix: String, body: [String:Any]? = nil) async throws -> T {
        let (data,response)=try await http.data(for:request(suffix,body:body));try check(response,data)
        return try JSONDecoder().decode(T.self,from:data)
    }
    func upload(_ envelope: PhoneSyncEnvelope, operationID: String, scope: PhoneMatchScope) async throws -> PhoneSyncResult {
        guard scope.account==context.userID,scope.origin==context.origin,scope.installation==envelope.installation_id else { throw MatchReplicaError.conflict }
        let snapshot=try JSONSerialization.jsonObject(with:JSONEncoder().encode(envelope.final_snapshot))
        let journal=try envelope.journal.map { entry -> [String:Any] in
            var value=(try JSONSerialization.jsonObject(with:JSONEncoder().encode(entry))) as! [String:Any]
            value["revision"]=String(entry.revision);return value
        }
        let body:[String:Any] = ["operation_id":operationID,"envelope":[
            "schema_version":1,"match_id":envelope.match_id,"authority_type":"phone","authority_id":envelope.installation_id,
            "origin":"local","rules_version":envelope.rules_version,"doubles":envelope.doubles,
            "participants":envelope.participants.map { ["id":$0.id,"name":$0.name,"side":$0.side.rawValue,"kind":$0.id==context.userID.lowercased() ? "user":"guest"] },
            "revision":String(envelope.revision),"journal":journal,"snapshot":snapshot,
            "lifecycle":envelope.phase == .ended ? (envelope.final_snapshot.finished ? "completed":"aborted"):envelope.phase.rawValue]]
        struct Receipt: Decodable { let match_id:String; let revision:String; let authority_id:String; let status:String }
        do {
            let receipt:Receipt=try await get("/upload",body:body)
            guard receipt.status=="accepted",let revision=UInt32(receipt.revision) else { throw MatchReplicaError.malformed }
            return .accepted(matchID:receipt.match_id,revision:revision,installation:receipt.authority_id)
        } catch let error as LocalMatchHTTPError where error.status==409 { return .conflict }
    }
}

@MainActor final class LocalMatchBrowser: ObservableObject {
    @Published var matches=[SharedMatch]()
    @Published var selected: SharedMatch?
    @Published var message=""
    @Published var streaming=false
    private var api: LocalMatchAPI?
    private var generation=UUID()
    private var subscription: Task<Void,Never>?
    private var replica=MatchReplica()
    func open(_ context: RacketContext) async {
        if api?.context != context { close();api=LocalMatchAPI(context) }
        await refresh()
    }
    func refresh() async {
        guard let api else { return };let epoch=generation
        do {
            let list:SharedMatchList=try await api.get("")
            guard generation==epoch else { return };matches=list.matches;message=matches.isEmpty ? "暂无获授权的同步比赛。":""
        } catch { if generation==epoch { message=error.localizedDescription } }
    }
    func watch(_ match: SharedMatch) {
        subscription?.cancel();selected=match;streaming=false
        guard let api else { return }
        let epoch=replica.reset(scope:api.context.origin+api.context.userID+match.id)
        let generation=self.generation
        subscription=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.generation==generation else { return }
                do {
                    let current:SharedMatch=try await api.get("/"+match.id)
                    guard !Task.isCancelled,self.generation==generation else { return }
                    if try self.replica.accept(current,epoch:epoch) { self.selected=current }
                    self.message="已同步 · 只读观赛"
                    let (bytes,response)=try await api.http.bytes(for:api.request("/"+match.id+"/events"))
                    try api.check(response)
                    guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("text/event-stream")==true else { throw MatchReplicaError.malformed }
                    var parser=MatchEventParser()
                    var lineBytes=Data()
                    for try await byte in bytes {
                        guard !Task.isCancelled,self.generation==generation else { return }
                        if byte != 10 {
                            lineBytes.append(byte)
                            guard lineBytes.count <= 131072 else { throw MatchReplicaError.malformed }
                            continue
                        }
                        if lineBytes.last == 13 { lineBytes.removeLast() }
                        guard let line=String(data:lineBytes,encoding:.utf8) else { throw MatchReplicaError.malformed }
                        lineBytes.removeAll(keepingCapacity:true)
                        if let event=try parser.line(line) {
                            if event.event=="access_revoked" { throw LocalMatchHTTPError(status:403,code:"FORBIDDEN") }
                            if event.event=="snapshot" {
                                let value=try JSONDecoder().decode(SharedMatch.self,from:event.data)
                                if try self.replica.accept(value,epoch:epoch) { self.selected=value }
                                self.streaming=true;self.message="实时连接 · 只读观赛"
                            }
                        }
                    }
                    self.streaming=false;self.message="正在重新同步…"
                } catch {
                    guard !Task.isCancelled,self.generation==generation else { return }
                    self.streaming=false;self.message="连接中断，显示最后确认比分。"+error.localizedDescription
                    if let e=error as? LocalMatchHTTPError,[401,403,404].contains(e.status) { self.selected=nil;return }
                    if error is MatchReplicaError { self.message="比赛版本冲突，请返回列表重新核对。";return }
                }
                try? await Task.sleep(nanoseconds:2_000_000_000)
            }
        }
    }
    func stopWatching() { subscription?.cancel();subscription=nil;streaming=false;selected=nil }
    func close() { generation=UUID();stopWatching();api?.cancel();api=nil;matches=[];message="" }
    func share(userID: String, revoke: Bool) async {
        guard let api,let selected else { return };let epoch=generation
        struct Receipt:Decodable { let ok:Bool }
        do {
            let _:Receipt=try await api.get("/"+selected.id+"/access",body:["user_id":userID,"expires_at":revoke ? 0:Int(Date().timeIntervalSince1970)+3600])
            guard epoch==generation else { return };message=revoke ? "观赛权限已撤销":"已授权观赛一小时"
        } catch { if epoch==generation { message=error.localizedDescription } }
    }
}

struct PiControlHost: Decodable, Identifiable {
    let host_id:String
    let tuya_device_id:String?
    let online:Bool
    let phase:String
    let current_match_id:String?
    let can_start:Bool
    var id:String { host_id }
}
struct PiStartResult: Codable {
    let operation_id:String
    let host_id:String
    let match_id:String
    let status:String
    let reason:String
    var kind:String? = nil
    var terminal:Bool { ["succeeded","rejected","expired"].contains(status) }
    var message:String {
        switch status {
        case "queued":return "开赛请求已保存，等待树莓派接收。"
        case "delivered":return "树莓派正在确认开赛，请勿重复创建。"
        case "awaiting_upload":return "树莓派已开赛，正在同步名单和比分。"
        case "succeeded":return "本次开赛已确认并同步；进入后查看比赛最新状态。"
        case "expired":return "树莓派未及时接收，本次请求已过期。"
        case "rejected":return reason == "match_ended" ? "这场比赛已结束并保存，旧拍底连接请求已关闭。可以准备下一场。" : "树莓派未允许开赛，请确认旧比赛已结束并在屏幕上准备下一场。（\(reason)）"
        default:return reason == "racket_mapping_pending" ? "树莓派已开赛，正在确认本场拍底位置。":"开赛结果待确认，正在查询原请求。"
        }
    }
}
@MainActor final class PiStartController: ObservableObject {
    @Published var host:PiControlHost?
    @Published var result:PiStartResult?
    @Published var message=""
    @Published var busy=false
    @Published var hasOriginalRequest=false
    private var api:LocalMatchAPI?
    private var deviceID=""
    private var key=""
    private var generation=UUID()
    private var original:[String:Any]?
    var matchID:String? { result?.status == "succeeded" ? result?.match_id : host?.current_match_id }
    func open(_ context:RacketContext,deviceID:String) async {
        close();api=LocalMatchAPI(context);self.deviceID=deviceID
        key="pi.start.v1."+context.origin+"|"+context.userID+"|"+deviceID
        if let data=UserDefaults.standard.data(forKey:key),let body=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            original=body;hasOriginalRequest=true
        }
        await refresh()
    }
    func refresh() async {
        guard let api,!busy else { return };let epoch=generation
        do {
            struct Hosts:Decodable { let hosts:[PiControlHost] }
            let list:Hosts=try await api.get("/control/hosts")
            guard epoch==generation else { return }
            host=list.hosts.first { $0.tuya_device_id==deviceID }
            if original==nil {
                struct Pending:Decodable { let operations:[PiStartResult] }
                let pending:Pending=try await api.get("/control/pending")
                guard epoch==generation else { return }
                if let found=pending.operations.first(where: { $0.host_id==host?.host_id && ($0.kind ?? "start") == "start" }) { result=found }
            }
            if let oid=original?["operation_id"] as? String ?? result?.operation_id {
                let value:PiStartResult=try await api.get("/control/starts/"+oid)
                guard epoch==generation else { return };accept(value)
            } else { message=host == nil ? "当前账号尚未关联这台计分主机。" : host?.online == true ? "名单会发送给树莓派，由主机确认开赛。" : "树莓派开赛服务尚未连接，请稍后刷新。" }
        } catch { if epoch==generation { message=explain(error) } }
    }
    func start(names:[String],doubles:Bool,racketID:String?=nil) async {
        guard let api,!busy,let host else { return }
        if original==nil {
            guard host.can_start,result==nil || result?.terminal==true,names.count==4 else { return }
            let values=names.enumerated().map { i,n in !doubles && (i==1 || i==3) ? "":n.trimmingCharacters(in:.whitespacesAndNewlines) }
            original=["operation_id":UUID().uuidString.lowercased(),"host_id":host.host_id,"mode":doubles ? "doubles":"singles","names":values]
            if let racketID { original?["racket_device_id"]=racketID }
            guard let data=try? JSONSerialization.data(withJSONObject:original!) else { original=nil;return }
            UserDefaults.standard.set(data,forKey:key);hasOriginalRequest=true
        }
        let epoch=generation;busy=true
        do {
            let value:PiStartResult=try await api.get("/control/starts",body:original)
            guard epoch==generation else { return };accept(value)
        } catch {
            if epoch==generation {
                message=explain(error)
                if let e=error as? LocalMatchHTTPError,["INVALID_ROSTER","RACKET_NOT_OWNED","RACKET_NOT_CONFIGURED","INVALID_RACKET","HOST_OFFLINE","HOST_NOT_IDLE","ACTIVE_MATCH","START_PENDING"].contains(e.code) {
                    original=nil;hasOriginalRequest=false;UserDefaults.standard.removeObject(forKey:key)
                }
            }
        }
        if epoch==generation { busy=false }
    }
    private func accept(_ value:PiStartResult) {
        if let oid=original?["operation_id"] as? String,oid != value.operation_id { return }
        guard host?.host_id == value.host_id else { return }
        result=value;message=value.message
        if value.terminal { original=nil;hasOriginalRequest=false;UserDefaults.standard.removeObject(forKey:key) }
    }
    private func explain(_ error:Error)->String {
        if let e=error as? LocalMatchHTTPError {
            switch e.code {
            case "RACKET_NOT_OWNED", "RACKET_NOT_CONFIGURED":return "拍底尚未关联到当前账号或未完成此主机配置，请先配置拍底。"
            case "HOST_OFFLINE":return "树莓派开赛服务离线，请连接后重试原请求。"
            case "HOST_NOT_IDLE", "ACTIVE_MATCH":return "树莓派还有当前比赛，请进入原比赛；结束后在屏幕上准备下一场。"
            case "START_PENDING":return "已有开赛请求待确认，请刷新查询。"
            case "INVALID_ROSTER":return "请核对双方球员名字，每个名字最多 96 个 UTF-8 字节。"
            default:break
            }
        }
        return "暂未确认开赛结果，请查询或重试原请求。"+error.localizedDescription
    }
    func close() { generation=UUID();api?.cancel();api=nil;host=nil;result=nil;original=nil;hasOriginalRequest=false;busy=false }
}

@MainActor final class PiEndController: ObservableObject {
    @Published var match:SharedMatch?
    @Published var result:PiStartResult?
    @Published var message=""
    @Published var busy=false
    @Published var hasOriginalRequest=false
    private var api:LocalMatchAPI?
    private var key=""
    private var epoch=UUID()
    private var original:[String:Any]?
    var waiting:Bool { result.map { !$0.terminal } ?? false }
    func open(_ context:RacketContext,match:SharedMatch) async {
        close();self.match=match;api=LocalMatchAPI(context)
        key="pi.end.v1."+context.origin+"|"+context.userID+"|"+match.authority_id+"|"+match.id
        if let data=UserDefaults.standard.data(forKey:key),let body=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
           body["match_id"] as? String == match.id,body["host_id"] as? String == match.authority_id {
            original=body;hasOriginalRequest=true
        }
        await refresh()
    }
    func refresh() async {
        guard let api,let target=match,!busy else { return };let current=epoch;busy=true
        defer { if epoch==current { busy=false } }
        do {
            let view:SharedMatch=try await api.get("/"+target.id)
            guard epoch==current,view.id==target.id,view.authority_id==target.authority_id else { return };match=view
            if original==nil && result==nil {
                struct Pending:Decodable { let operations:[PiStartResult] }
                let pending:Pending=try await api.get("/control/pending")
                guard epoch==current else { return }
                if let found=pending.operations.first(where: { $0.kind == "end" && $0.match_id==target.id && $0.host_id==target.authority_id }) { result=found }
            }
            if let oid=original?["operation_id"] as? String ?? result?.operation_id {
                let value:PiStartResult=try await api.get("/control/ends/"+oid)
                guard epoch==current else { return };accept(value)
            } else { message=view.isTerminal ? "本场已由树莓派结束并同步。":"结束后保留树莓派最终确认的比分；提前结束不计正常完赛胜负。" }
        } catch { if epoch==current { message=explain(error) } }
    }
    func end() async {
        guard let api,let match,!busy,!waiting,!match.isTerminal else { return }
        if original==nil {
            guard match.canEndFromPhone else { return }
            original=["operation_id":UUID().uuidString.lowercased(),"host_id":match.authority_id,"match_id":match.id]
            guard let data=try? JSONSerialization.data(withJSONObject:original!) else { original=nil;return }
            UserDefaults.standard.set(data,forKey:key);hasOriginalRequest=true
        }
        let current=epoch;busy=true
        defer { if epoch==current { busy=false } }
        do {
            let value:PiStartResult=try await api.get("/control/ends",body:original)
            guard epoch==current else { return };accept(value)
        } catch {
            guard epoch==current else { return };message=explain(error)
            if let e=error as? LocalMatchHTTPError,["HOST_OFFLINE","HOST_UPGRADE_REQUIRED","MATCH_CHANGED","MATCH_ALREADY_ENDED","CONTROL_PENDING","FORBIDDEN"].contains(e.code) { clearOriginal() }
        }
    }
    private func clearOriginal() { original=nil;hasOriginalRequest=false;UserDefaults.standard.removeObject(forKey:key) }
    private func accept(_ value:PiStartResult) {
        guard value.kind == "end",value.match_id==match?.id,value.host_id==match?.authority_id else { return }
        if let oid=original?["operation_id"] as? String,oid != value.operation_id { return }
        result=value
        switch value.status {
        case "queued":message="正在结束：等待树莓派接收。"
        case "delivered":message="正在结束：等待树莓派确认。"
        case "awaiting_upload":message="树莓派已确认结束，等待结果同步。"
        case "succeeded":message="比赛已结束，结果已由树莓派保存并同步。"
        case "expired":message="主机未及时接收，结束请求已过期；可以重新确认。"
        case "rejected":message=value.reason == "stale_version" ? "比分或状态已变化，本次未结束。请核对当前比分后重新确认。":"主机未执行本次结束，请刷新比赛后重试。（\(value.reason)）"
        default:message="结束结果待确认，正在查询原请求。请勿另开一场。"
        }
        if value.terminal { clearOriginal() }
    }
    private func explain(_ error:Error)->String {
        if let e=error as? LocalMatchHTTPError {
            switch e.code {
            case "HOST_OFFLINE":return "主机暂时离线，本次未下发；连接恢复后可重试。"
            case "HOST_UPGRADE_REQUIRED":return "树莓派结束控制服务尚未就绪，请稍后刷新。"
            case "MATCH_CHANGED":return "主机当前比赛已变化，本次未执行结束。请返回核对比赛。"
            case "MATCH_ALREADY_ENDED":return "本场已结束，请刷新查看最终结果。"
            case "CONTROL_PENDING":return "主机还有待确认操作，请先等待原操作结果。"
            case "FORBIDDEN":return "只有此主机的管理员可以结束比赛。"
            default:break
            }
        }
        return "暂未确认结束结果，请查询或重试原请求。"+error.localizedDescription
    }
    func close() { epoch=UUID();api?.cancel();api=nil;match=nil;result=nil;original=nil;hasOriginalRequest=false;busy=false }
}
