import Foundation

final class TestVault: GatheringStorage {
    var credentials: GatheringCredentials?
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func load(_ origin: String) -> GatheringCredentials? { credentials }
    func save(_ value: GatheringCredentials?, origin: String) throws { credentials = value }
    func journalFile(_ origin: String, user: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(GatheringPersistence.partition(origin, user))
    }
}
final class SocialProtocol: URLProtocol {
    static var restored = 0
    static var uploadedMVP = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        if path.hasSuffix("/confirm"), let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
            if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], body["mvp_user_id"] as? String == "player-b" { Self.uploadedMVP = true }
        }
        var status = 200
        var json = "{}"
        if path.hasSuffix("/session/restore") {
            Self.restored += 1
            json = "{\"user\":{\"id\":\"same-user\",\"name\":\"Tester\"},\"token\":\"renewed\",\"expires_at\":4102444800}"
        } else if request.value(forHTTPHeaderField: "Authorization") != "Bearer renewed" {
            status = 401; json = "{\"error\":\"expired\"}"
        } else if path.hasSuffix("/session/renew") {
            json = "{\"user\":{\"id\":\"same-user\",\"name\":\"Tester\"},\"token\":\"renewed\",\"expires_at\":4102444800}"
        } else if path.hasSuffix("/gatherings") { json = "{\"gatherings\":[]}" }
        else if path.hasSuffix("/records") { json = "{\"records\":[]}" }
        else if path.hasSuffix("/results") { json = "{\"results\":[]}" }
        else { json = "{\"id\":\"fixture\",\"number\":1,\"status\":\"completed\",\"red\":[],\"blue\":[],\"names\":{},\"referee_id\":\"same-user\"}" }
        let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}
@main struct SocialChecks {
    @MainActor static func main() async throws {
        for terminalOp in ["complete", "early_end"] {
        SocialProtocol.restored = 0; SocialProtocol.uploadedMVP = false
        let vault = TestVault()
        vault.credentials = GatheringCredentials(user: GatheringUser(id:"same-user",name:"Tester"),token:"expired",expires_at:1,recovery:"stored-recovery")
        let context = GatheringContext(gatheringID:"group",fixtureID:"fixture",deviceID:"board",matchID:String(repeating:"a",count:32),installationID:"phone",red:["A"],blue:["B"])
        let finished = MatchSnapshot("@1:\(context.matchID):0000000a:a:21,10,2,0,0:0")!
        let event = GatheringEvent(id:"completion",context:context,op:terminalOp,snapshot:finished,mvpUserID:"player-b")
        let pending = GatheringJournal(context:context,events:[event],archived:false)
        let endpoint = "https://social-tests.invalid"
        try JSONEncoder().encode(pending).write(to:vault.journalFile(endpoint,user:"same-user"))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SocialProtocol.self]
        let store = GatheringStore(origin:endpoint,storage:vault,http:URLSession(configuration:configuration),connectivity:nil)
        let defaults = UserDefaults(suiteName:UUID().uuidString)!
        let session = MatchSession(accountID:"test",deviceID:"board",online:true,cache:nil,defaults:defaults) {_,_ in}
        store.bind(session,deviceID:"board")
        session.send("Q");session.receive("@1:\(context.matchID):00000001:a:21,10,2,0,0:0")
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(store.journal.events.count == 1,"Q after relaunch must not append score after completion")
        try await store.refresh()
        precondition(SocialProtocol.restored == 1,"Expired credentials must restore the same identity automatically")
        precondition(store.userID == "same-user" && store.context?.matchID == context.matchID,"Recovery must preserve match context")
        precondition(SocialProtocol.uploadedMVP,"MVP must survive durable queue relaunch and upload")
        precondition(store.journal.events.isEmpty && store.journal.archived,"Completion must upload and queue must drain")
        vault.credentials = GatheringCredentials(user:GatheringUser(id:"same-user",name:"Tester"),token:"revoked-after-lost-renewal",expires_at:Date().timeIntervalSince1970+60,recovery:"stored-recovery")
        let retry = GatheringStore(origin:endpoint,storage:vault,http:URLSession(configuration:configuration),connectivity:nil)
        try await retry.refresh()
        precondition(SocialProtocol.restored == 2 && retry.credentials?.token == "renewed", "Lost renewal response must recover even before old token expiration")
        print("PASS: expired identity recovery with pending context; offline completion/relaunch/Q/flush")
        }
    }
}
