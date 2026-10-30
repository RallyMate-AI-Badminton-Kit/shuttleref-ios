import Foundation
func check(_ ok: Bool, _ label: String) { if !ok { print("FAIL: \(label)"); exit(1) } }
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
@MainActor final class SwitchDuringSync: MatchSyncService {
    let change: () throws -> Void
    init(_ change: @escaping () throws -> Void) { self.change = change }
    func upload(_ e: PhoneSyncEnvelope,operationID: String,scope: PhoneMatchScope) async throws -> PhoneSyncResult {
        try change(); return .accepted(matchID:e.match_id,revision:e.revision,installation:e.installation_id)
    }
}
@main struct RecoveryChecks {
    @MainActor static func main() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("phone-recovery-\(UUID()).sqlite")
        defer { for s in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path.path+s) } }
        let scope = PhoneMatchScope(origin:"https://test.invalid",account:"a",installation:UUID().uuidString.lowercased())
        let store = try PhoneMatchStore(url:path,scope:scope.key)
        let s = try PhoneMatchSession(storage:store,scope:scope)
        let owner = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        try s.start(participants:[PhoneParticipant(id:owner,name:"A",side:.red),PhoneParticipant(id:other,name:"B",side:.blue)],doubles:false)
        let info = RacketScoreInfo(capabilities:3,device:"d40592412074",boot:"0102030405060708"), conn = UUID()
        let c = try s.prepare(info:info,authenticatedDevice:info.device,owner:owner,associationRevision:1,side:.red,connection:conn,subscribed:true)
        try s.configured(RacketScoreWire.message("configured",text:["context":c.text("context"),"status":"ok"]),connection:conn)
        let ready = try s.ready(now:0); try s.readyDelivered(lease:ready.number("lease"),now:0)
        // An ATT write finishing after the previous lease expired cannot silently reopen readiness.
        let renewal = try s.ready(now:2400)
        check(rejects { try s.readyDelivered(lease:renewal.number("lease"),now:2600) },"late ready completion cannot clear expiry")
        s.stop(); try s.confirmReview()
        for _ in 0..<41 { try s.manual(.red) }
        let c2 = try s.prepare(info:info,authenticatedDevice:info.device,owner:owner,associationRevision:1,side:.red,connection:conn,subscribed:true)
        try s.configured(RacketScoreWire.message("configured",text:["context":c2.text("context"),"status":"ok"]),connection:conn)
        let r2 = try s.ready(now:3000); try s.readyDelivered(lease:r2.number("lease"),now:3000)
        func event(_ seq: UInt32,_ lease: UInt32,_ action: String) throws -> RacketScoreMessage {
            try RacketScoreWire.message("event",text:["context":c2.text("context"),"action":action],numbers:["seq":seq,"lease":lease,"detected_ms":1])
        }
        check(try s.receive(event(1,1,"add"),connection:conn,now:3010).status == "committed","BLE match point")
        let r3 = try s.ready(now:3020); try s.readyDelivered(lease:r3.number("lease"),now:3020)
        check(try s.receive(event(2,2,"undo"),connection:conn,now:3030).status == "committed","BLE undo match point matches C core")
        check(try s.current()?.score.finished == false,"match reopened by undo")
        let before = try s.current()!.revision
        s.disconnected()
        check(rejects { _ = try s.receive(event(3,3,"add"),connection:conn,now:3040) },"late old connection cannot write")
        try s.manual(.blue)
        check(try s.current()?.revision == before+1,"manual scoring remains after disconnect")
        let adapter = SwitchDuringSync { _ = try PhoneMatchSession(storage:store,scope:scope) }
        var rejected = false
        do { try await s.synchronize(using:adapter) } catch { rejected = true }
        check(try rejected && (store.read()).outbox.allSatisfy { $0.state == "pending" },"late sync cannot mark new writer data")
        let different = PhoneMatchScope(origin:scope.origin,account:"other-account",installation:scope.installation)
        check(rejects { _ = try PhoneMatchSession(storage:store,scope:different) },"session cannot open another account namespace")
        print("PASS expiry, terminal undo, disconnect and late sync fencing")
    }
}
