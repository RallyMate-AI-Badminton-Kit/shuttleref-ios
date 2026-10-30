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
