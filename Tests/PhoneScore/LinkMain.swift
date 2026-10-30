import Foundation
func check(_ ok: Bool, _ label: String) { if !ok { print("FAIL: \(label)"); exit(1) } }
@MainActor final class CaptureLink: RacketScoreTransport {
    var sent: [RacketScoreMessage] = []; var assembler = RacketScoreAssembler()
    var onFrame: (() -> Void)?
    var reads = 0
    var pauseRead: CheckedContinuation<Void,Never>?
    var gateRead = false
    var onRead: ((Int) -> Void)?
    func readScoreState() async throws -> Data {
        reads += 1; onRead?(reads)
        if gateRead && reads == 1 { await withCheckedContinuation { pauseRead = $0 } }
        return Data([1,2,0,0,0,0,0,0,0,1,1,2,3,4,5,6,7,8,0,0]) }
    func writeControlFrame(_ frame: Data) async throws {
        onFrame?()
        if let raw = try assembler.append(frame,now:0) { sent.append(try RacketScoreWire.decode(raw)) }
    }
}
@MainActor final class SyncMock: MatchSyncService {
    var seen: [String:PhoneSyncEnvelope] = [:]; var loseFirstReply = true; var conflict = false
    func upload(_ e: PhoneSyncEnvelope, operationID: String, scope: PhoneMatchScope) async throws -> PhoneSyncResult {
        if let old = seen[operationID] { check(old == e,"outbox retry keeps exact envelope") }
        seen[operationID] = e
        if loseFirstReply { loseFirstReply = false; throw URLError(.timedOut) }
        if conflict { return .conflict }
        return .accepted(matchID:e.match_id,revision:e.revision,installation:e.installation_id)
    }
}
@main struct LinkChecks {
    @MainActor static func main() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("phone-link-\(UUID()).sqlite")
        defer { for s in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path.path+s) } }
        let scope = PhoneMatchScope(origin:"https://test.invalid",account:"a",installation:UUID().uuidString.lowercased())
        let store = try PhoneMatchStore(url:path,scope:scope.key)
        let s = try PhoneMatchSession(storage:store,scope:scope)
        let owner = UUID().uuidString.lowercased()
        try s.start(participants:[PhoneParticipant(id:owner,name:"A",side:.red),PhoneParticipant(id:UUID().uuidString.lowercased(),name:"B",side:.blue)],doubles:false)
        let transport = CaptureLink(), connection = UUID()
        var clock: UInt64 = 0
        let link = PhoneScoreLink(session:s,transport:transport,connection:connection,clock:{clock})
        let c = try s.prepare(info:RacketScoreInfo(capabilities:3,device:"d40592412074",boot:"0102030405060708"),authenticatedDevice:"d40592412074",owner:owner,associationRevision:1,side:.red,connection:connection,subscribed:true)
        try await link.send(c)
        check(transport.sent.map(\.type) == ["configure"],"no ready before configured")
        let configured = try RacketScoreWire.message("configured",text:["context":c.text("context"),"status":"ok"])
        for f in try RacketScoreWire.frames(RacketScoreWire.encode(configured),transaction:0) { try await link.notification(f) }
        check(transport.sent.last?.type == "ready","configured enables ready")
        let event = try RacketScoreWire.message("event",text:["context":c.text("context"),"action":"add"],numbers:["seq":1,"lease":1,"detected_ms":1])
        clock = 100
        for f in try RacketScoreWire.frames(RacketScoreWire.encode(event),transaction:1) { try await link.notification(f) }
        check(Array(transport.sent.suffix(2)).map(\.type) == ["ack","ready"],"ACK before new lease ready")
        check(transport.sent.suffix(2).first?.text("status") == "committed","durable ACK")
        clock = 600
        for f in try RacketScoreWire.frames(RacketScoreWire.encode(event),transaction:2) { try await link.notification(f) }
        check(try s.current()?.score.red == 1,"lost ACK/retransmit once")
        transport.gateRead = true; transport.reads = 0
        transport.onRead = { n in if n == 2 { try! s.manual(.blue) } }
        let firstTick = Task { try await link.tick() }
        while transport.pauseRead == nil { await Task.yield() }
        let secondTick = Task { try await link.tick() }
        for _ in 0..<10 { await Task.yield() }
        transport.pauseRead?.resume(); transport.pauseRead = nil
        try await firstTick.value; try await secondTick.value
        check(!s.needsReview,"concurrent heartbeat uses current lease at send time")
        transport.onRead = nil; transport.gateRead = false
        var changed = false
        transport.onFrame = { if !changed { changed = true; try! s.manual(.blue) } }
        try await link.tick()
        transport.onFrame = nil
        check(!s.needsReview,"manual commit during ready fragments does not interrupt message")
        clock = 4000
        try await link.tick()
        check(s.needsReview,"lease lapse locks, does not renew automatically")
        let prior = transport.sent.count
        for f in try RacketScoreWire.frames(RacketScoreWire.encode(event),transaction:3) { try await link.notification(f) }
        check(transport.sent.count == prior+1 && transport.sent.last?.type == "ack","late ACK without new ready")
        await link.background()
        check(transport.sent.last?.type == "stop","background stop")
        let count = transport.sent.count
        for f in try RacketScoreWire.frames(RacketScoreWire.encode(event),transaction:4) { try await link.notification(f) }
        check(transport.sent.count == count,"retired context ACK not sent")
        s.foreground(); try s.confirmReview()
        let sync = SyncMock()
        do { try await s.synchronize(using:sync) } catch {}
        check(try store.read().outbox.allSatisfy { $0.state == "pending" },"lost upload reply stays pending")
        try await s.synchronize(using:sync)
        check(try store.read().outbox.allSatisfy { $0.state == "synced" },"mock accepted marks only matching revisions")
        try s.manual(.blue); sync.conflict = true
        try await s.synchronize(using:sync)
        check(try store.read().outbox.last?.state == "conflict","conflict visible and retained")
        try s.manual(.blue); try await s.synchronize(using:sync)
        check(try store.read().outbox.last?.state == "pending","do not upload past revision conflict")
        print("PASS mock notification link and outbox retry/conflict")
    }
}
