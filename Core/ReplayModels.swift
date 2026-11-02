import Foundation

/// A failed/stopped attempt is terminal: asynchronous ready callbacks cannot revive it.
struct ReplayPlaybackState {
    enum Phase { case idle,loading,ready,waiting,failed }
    private(set) var id=UUID()
    private(set) var phase:Phase = .idle
    mutating func begin()->UUID { id=UUID();phase = .loading;return id }
    func accepts(_ value:UUID)->Bool { value==id && phase != .idle && phase != .failed }
    mutating func ready(_ value:UUID)->Bool { guard accepts(value) else { return false };phase = .ready;return true }
    mutating func waiting(_ value:UUID)->Bool { guard accepts(value),phase != .loading else { return false };phase = .waiting;return true }
    mutating func playing(_ value:UUID)->Bool { ready(value) }
    mutating func fail(_ value:UUID)->Bool { guard accepts(value) else { return false };phase = .failed;return true }
    mutating func stop() { id=UUID();phase = .idle }
}

struct ReplayMatch: Codable, Identifiable {
    let match_id: String
    let owner_id: String
    let is_demo: Bool
    let title: String
    let played_at: String
    let mode: String
    let status: String
    let participants: [ReplayParticipant]
    let games: [ReplayGame]
    let result: ReplayResult
    let points: [ReplayPoint]
    let notice: String
    var demo_shot_stats: [ReplayShotStats]? = nil
    var demo_mvp: ReplayDemoMVP? = nil
    var demo_duration_seconds: Int? = nil
    var demo_timeline: [ReplayDemoEvent]? = nil
    var id: String { match_id }
    var reference: CoachReference { .init(type:"match",id:match_id,match_id:match_id,label:title,is_demo:is_demo) }
    func reference(to point:ReplayPoint) -> CoachReference {
        .init(type:"point",id:point.point_id,match_id:match_id,label:"第三局 · 最后一分",is_demo:is_demo)
    }
}
struct ReplayDemoMVP: Codable {
    let participant_id:String
    let name:String
    let source:String
    let reason:String
}
struct ReplayDemoEvent: Codable, Identifiable {
    let id:String
    let game_number:Int
    let point_number:Int
    let red:Int
    let blue:Int
    let winner_side:String
    let elapsed_seconds:Int
    let source:String
}
struct ReplayParticipant: Codable { let id:String;let name:String;let user_id:String?;let side:String }
struct ReplayGame: Codable,Identifiable { let game_id:String;let number:Int;let red:Int;let blue:Int;let winner_side:String;var id:String { game_id } }
struct ReplayResult: Codable { let red_games:Int;let blue_games:Int;let winner_side:String }
struct ReplayScore: Codable { let red:Int;let blue:Int }
struct ReplayPoint: Codable,Identifiable {
    let point_id:String;let game_id:String;let game_number:Int;let point_number:Int
    let before:ReplayScore;let after:ReplayScore;let winner_side:String
    let is_final_point:Bool;let video:ReplayVideo
    var id:String { point_id }
}
struct ReplayVideo: Codable {
    let asset_id:String;let start_seconds:Double;let end_seconds:Double
    var reference:CoachVideoReference { .init(assetID:asset_id,startSeconds:start_seconds,endSeconds:end_seconds) }
}
struct ReplayList: Decodable { let matches:[ReplayMatch];var next_cursor:String? = nil }
struct ReplayGrant: Decodable {
    let asset_id:String;let url:URL;let expires_at:Double;let duration_seconds:Double
    func validate(assetID:String,now:Double=Date().timeIntervalSince1970) throws {
        guard asset_id==assetID,url.scheme=="https",url.host=="shuttle-oss.tos-cn-beijing.volces.com",
              url.user==nil,url.password==nil,url.fragment==nil,(url.port==nil || url.port==443),
              expires_at.isFinite,expires_at>now,expires_at<=now+3600,
              duration_seconds.isFinite,duration_seconds>0,duration_seconds<=86400 else {
            throw CoachFailure("视频播放授权无效或已过期，请重试")
        }
    }
}

final class ReplayClient {
    private let transport:CoachClient
    init(session:URLSession?=nil) { transport=CoachClient(session:session) }
    func matches(_ context:CoachContext) async throws -> [ReplayMatch] {
        let result:ReplayList=try await request(context,path:"/api/replay/matches",post:false)
        guard result.matches.count<=50 else { throw CoachFailure("比赛列表过大") }
        return result.matches
    }
    func match(_ context:CoachContext,id:String) async throws -> ReplayMatch {
        guard Self.validID(id) else { throw CoachFailure("比赛引用无效") }
        return try await request(context,path:"/api/replay/matches/"+id,post:false)
    }
    func playback(_ context:CoachContext,assetID:String) async throws -> ReplayGrant {
        guard Self.validID(assetID) else { throw CoachFailure("视频引用无效") }
        let grant:ReplayGrant=try await request(context,path:"/api/media/assets/"+assetID+"/playback",post:true)
        try grant.validate(assetID:assetID)
        return grant
    }
    private static func validID(_ value:String)->Bool { value.range(of:"^[A-Za-z0-9_-]{1,96}$",options:.regularExpression) != nil }
    private func request<T:Decodable>(_ context:CoachContext,path:String,post:Bool) async throws -> T {
        var request=try transport.makeRequest(context:context,messages:[],path:path)
        request.httpMethod=post ? "POST" : "GET";request.httpBody=post ? Data("{}".utf8) : nil
        request.timeoutInterval=30
        let (data,response)=try await transport.session.data(for:request)
        try Task.checkCancellation()
        guard let http=response as? HTTPURLResponse else { throw CoachFailure("回放服务响应无效") }
        guard http.statusCode==200 else {
            if http.statusCode==401 || http.statusCode==403 { throw CoachFailure("登录已过期，请重新登录后查看回放") }
            if http.statusCode==404 { throw CoachFailure("比赛或视频不可用，或当前账号没有权限") }
            if http.statusCode==409 { throw CoachFailure("视频文件已变化，请重新核验后播放") }
            throw CoachFailure("回放服务暂不可用，请稍后重试")
        }
        guard data.count<=262144 else { throw CoachFailure("回放服务响应过大") }
        return try JSONDecoder().decode(T.self,from:data)
    }
}

struct ReplayShotStats: Codable, Identifiable {
    let participant_id:String; let name:String; let total:Int; let source:String; let shots:[ReplayShotCount]
    var id:String { participant_id }
}
struct ReplayShotCount: Codable { let type:String; let count:Int }
