import Foundation

final class RecordsVault: GatheringStorage {
    var credentials: GatheringCredentials?
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func load(_ origin: String) -> GatheringCredentials? { credentials }
    func save(_ value: GatheringCredentials?, origin: String) throws { credentials = value }
    func journalFile(_ origin: String, user: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(GatheringPersistence.partition(origin, user))
    }
}
final class RecordsHTTP: URLProtocol {
    static var offline = true
    static var records: [String: [PersonalRecord]] = [:]
    static var postOwners: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let owner = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let path = request.url!.path
        var data = Data("{}".utf8)
        if path.hasSuffix("/records") {
            if request.httpMethod == "POST" {
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
                }
                let record = try! JSONDecoder().decode(PersonalRecord.self, from: body)
                Self.postOwners.append(owner)
                if !(Self.records[owner] ?? []).contains(where: { $0.id == record.id }) { Self.records[owner, default: []].append(record) }
                data = Data("{\"ok\":true}".utf8)
            } else {
                let encoded = try! JSONEncoder().encode(Self.records[owner] ?? [])
                data = Data("{\"records\":".utf8) + encoded + Data("}".utf8)
            }
        } else if path.hasSuffix("/results") { data = Data("{\"results\":[]}".utf8) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
@main struct RecordsChecks {
    @MainActor static func main() async throws {
        let vault = RecordsVault(), endpoint = "https://records.invalid"
        func account(_ id: String) -> GatheringCredentials { GatheringCredentials(user: GatheringUser(id: id, name: id), token: id, expires_at: 4102444800) }
        vault.credentials = account("alice")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecordsHTTP.self]
        let http = URLSession(configuration: config)
        func store() -> GatheringStore { GatheringStore(origin: endpoint, storage: vault, http: http, connectivity: nil) }
        let a = store()
        let snap = MatchSnapshot("@1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:00000001:p:5,3,0,0,0:0")!
        let result = LocalMatchResult(id: snap.id, snapshot: snap, names: ["A", "B", "C", "D"], doubles: false, mvpSlot: 0, date: Date(), earlyEnded: true)
        try a.queueRecord(result, deviceID: "board")
        try a.queueRecord(result, deviceID: "board")
        await a.uploadRecords()
        precondition(a.recordsJournal.pending.count == 1 && !a.recordsMessage.isEmpty, "Offline result remains durable and duplicate queueing is ignored")
        let relaunched = store()
        precondition(relaunched.recordsJournal.pending.count == 1, "Relaunch recovers pending record")
        vault.credentials = account("bob")
        let b = store()
        precondition(b.recordsJournal.pending.isEmpty && b.recordsJournal.uploaded.isEmpty, "Other accounts cannot inherit Alice's pending record")
        RecordsHTTP.offline = false
        try await b.refreshRecords()
        precondition(RecordsHTTP.postOwners.isEmpty, "Bob must never upload Alice's record")
        try await relaunched.refreshRecords()
        precondition(relaunched.recordsJournal.pending.isEmpty && relaunched.recordsJournal.uploaded.count == 1)
        precondition(RecordsHTTP.postOwners == ["Bearer alice"])
        try relaunched.queueRecord(result, deviceID: "board")
        await relaunched.uploadRecords()
        precondition(RecordsHTTP.postOwners.count == 1, "Re-importing synced history does not upload twice")
        vault.credentials = account("alice")
        let cached = store()
        precondition(cached.recordsJournal.uploaded.count == 1, "Synced cache survives relaunch")
        let otherServer = GatheringStore(origin: "https://other.invalid", storage: vault, http: http, connectivity: nil)
        precondition(otherServer.recordsJournal.uploaded.isEmpty, "Server namespaces are isolated")
        print("PASS: offline persistence, relaunch, account/server isolation, retry, duplicate prevention and synced cache")
    }
}
