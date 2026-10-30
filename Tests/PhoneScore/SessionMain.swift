import Foundation
func check(_ ok: Bool, _ label: String) { if !ok { print("FAIL: \(label)"); exit(1) } }
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
final class FaultStore: PhoneMatchPersistence {
    enum Fault { case none, before, after, uncertainBefore }
    var namespace: String { real.namespace }
    let real: PhoneMatchStore; var fault = Fault.none
    init(_ real: PhoneMatchStore) { self.real = real }
    func read() throws -> PhoneMatchDatabase { try real.read() }
    func reopen() throws { try real.reopen() }
    func transaction(_ body: (inout PhoneMatchDatabase) throws -> Void) throws {
        let f = fault; fault = .none
        if f == .before { throw PhoneScoreError.storageFailed }
        if f == .uncertainBefore { throw PhoneScoreError.storageUncertain }
        try real.transaction(body)
        if f == .after { throw PhoneScoreError.storageUncertain }
    }
}
@main struct SessionChecks {
    @MainActor static func main() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("phone-session-\(UUID()).sqlite")
        defer { for s in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path.path+s) } }
        let scope = PhoneMatchScope(origin:"https://test.invalid",account:"account-a",installation:UUID().uuidString.lowercased())
        let storage = FaultStore(try PhoneMatchStore(url:path,scope:scope.key))
        let session = try PhoneMatchSession(storage:storage,scope:scope)
        let owner = UUID().uuidString.lowercased()
        let players = [PhoneParticipant(id:owner,name:"同名",side:.red),PhoneParticipant(id:UUID().uuidString.lowercased(),name:"同名",side:.blue)]
        try session.start(participants:players,doubles:false)
        check(try session.current()?.revision == 1,"start saved")
        check(rejects { try session.start(participants:players,doubles:false) },"cannot overwrite unfinished match")
        let info = RacketScoreInfo(capabilities:3,device:"d40592412074",boot:"0102030405060708")
        let connection = UUID()
        check(rejects { _ = try session.prepare(info:info,authenticatedDevice:info.device,owner:owner,associationRevision:1,side:.red,connection:connection,subscribed:false) },"subscription gate")
        let configure = try session.prepare(info:info,authenticatedDevice:info.device,owner:owner,associationRevision:1,side:.red,connection:connection,subscribed:true)
        let context = configure.text("context")
        check(rejects { _ = try session.ready(now:0) },"ATT configure is not configured ACK")
        try session.configured(RacketScoreWire.message("configured",text:["context":context,"status":"ok"]),connection:connection)
        check(!session.readyForScoring,"configured alone cannot display ready")
        let ready = try session.ready(now:0); try session.readyDelivered(lease:ready.number("lease"),now:0)
        check(session.readyForScoring,"ready displayed after lease delivery")
        func event(_ seq: UInt32, _ lease: UInt32 = 1, _ action: String = "add") throws -> RacketScoreMessage {
            try RacketScoreWire.message("event",text:["context":context,"action":action],numbers:["seq":seq,"lease":lease,"detected_ms":100])
        }
        let first = try session.receive(event(1),connection:connection,now:100)
        check(first.status == "committed" && first.revision == 2,"BLE commit")
        check(try session.current()?.score.red == 1,"one point")
        let duplicate = try session.receive(event(1),connection:connection,now:101)
        check(try duplicate == first && (session.current()?.revision) == 2,"duplicate keeps original ACK and revision")
        let stale = try session.receive(event(2),connection:connection,now:110)
        check(stale.reason == "stale_lease" && stale.revision == 2,"new event old lease rejected")
        let manualID = UUID().uuidString.lowercased()
        try session.manual(.blue,id:manualID)
        try session.manual(.blue,id:manualID)
        check(try session.current()?.score.blue == 1,"manual operation ID idempotent")
        check(rejects { try session.manual(.red,id:manualID) },"manual ID collision")
        let renewed = try session.ready(now:150); try session.readyDelivered(lease:renewed.number("lease"),now:150)
        let undo = try session.receive(event(3,renewed.number("lease"),"undo"),connection:connection,now:200)
        check(try undo.status == "committed" && (session.current()?.score.blue) == 0,"BLE undo includes opposite manual point")
        storage.fault = .before
        let failed = try session.receive(event(4,renewed.number("lease")+1),connection:connection,now:210)
        check(try failed.reason == "storage_failed" && (session.current()?.revision) == 4,"failed save never successful ACK")
        check(try session.receive(event(4,renewed.number("lease")+1),connection:connection,now:211) == failed,"failed terminal receipt persists")
        // Existing payload conflict must stop readiness without modifying prior result.
        check(rejects { _ = try session.receive(event(1,1,"undo"),connection:connection,now:220) },"same ID changed payload")
        check(session.needsReview,"protocol conflict locks readiness")
        session.stop(); try session.confirmReview()
        let c2 = try session.prepare(info:info,authenticatedDevice:info.device,owner:owner,associationRevision:1,side:.red,connection:connection,subscribed:true)
        let ctx2 = c2.text("context")
        try session.configured(RacketScoreWire.message("configured",text:["context":ctx2,"status":"ok"]),connection:connection)
        let r2 = try session.ready(now:300); try session.readyDelivered(lease:r2.number("lease"),now:300)
        let e2 = try RacketScoreWire.message("event",text:["context":ctx2,"action":"add"],numbers:["seq":1,"lease":1,"detected_ms":300])
        storage.fault = .after
        let unknown = try session.receive(e2,connection:connection,now:301)
        check(unknown.status == "unknown" && session.storageUncertain,"commit response lost locks all writes")
        check(rejects { try session.manual(.red) },"uncertain cannot manually write")
        let recovered = try session.recoverStorage()
        check(try recovered?.status == "committed" && (session.current()?.score.red) == 2,"query committed event after reopen without replay")
        check(session.needsReview && rejects { _ = try session.ready(now:302) },"recovery requires explicit review/new context")
        session.stop(); try session.confirmReview()
        let c3 = try session.prepare(info:info,authenticatedDevice:info.device,owner:owner,associationRevision:1,side:.red,connection:connection,subscribed:true)
        let ctx3 = c3.text("context")
        try session.configured(RacketScoreWire.message("configured",text:["context":ctx3,"status":"ok"]),connection:connection)
        let r3 = try session.ready(now:400); try session.readyDelivered(lease:r3.number("lease"),now:400)
        let e3 = try RacketScoreWire.message("event",text:["context":ctx3,"action":"add"],numbers:["seq":1,"lease":1,"detected_ms":400])
        storage.fault = .uncertainBefore
        check(try session.receive(e3,connection:connection,now:401).status == "unknown","unknown without commit")
        check(try session.recoverStorage()?.reason == "storage_failed","absence becomes persistent rejection, no replay")
        check(try session.current()?.score.red == 2,"recovery never reexecutes")
        session.background()
        let e4 = try RacketScoreWire.message("event",text:["context":ctx3,"action":"add"],numbers:["seq":2,"lease":1,"detected_ms":500])
        check(try session.receive(e4,connection:connection,now:500).status == "rejected","background event rejected")
        session.foreground(); try session.confirmReview()
        let before = try session.current()!
        let restarted = try PhoneMatchSession(storage:storage,scope:scope)
        check(try restarted.current()?.score == before.score && restarted.needsReview,"relaunch preserves score, no auto ready")
        check(rejects { try session.manual(.red) },"old writer fenced")
        try restarted.confirmReview(); try restarted.manual(.undo)
        check(try restarted.current()?.score.red == 1,"undo survives restart")
        check(try storage.read().outbox.count == Int(restarted.current()!.revision),"one durable outbox per committed revision")
        check(try storage.read().outbox.allSatisfy { $0.state == "pending" },"no fake sync")
        try restarted.manual(.end)
        check(rejects { try restarted.manual(.red) },"ended match closed")
        let four = players + [PhoneParticipant(id:UUID().uuidString.lowercased(),name:"同名",side:.red),PhoneParticipant(id:UUID().uuidString.lowercased(),name:"同名",side:.blue)]
        try restarted.start(participants:four,doubles:true)
        check(try restarted.current()?.participants.count == 4,"doubles stable distinct identities")
        try restarted.manual(.end)
        let compact = "11111111111111111111111111111111"
        let compactPlayers = [PhoneParticipant(id:compact,name:"球友",side:.red),PhoneParticipant(id:"22222222222222222222222222222222",name:"对手",side:.blue)]
        try restarted.start(participants:compactPlayers,doubles:false)
        let compactConfig = try restarted.prepare(info:info,authenticatedDevice:info.device,owner:compact,associationRevision:1,side:.red,connection:UUID(),subscribed:true,controlOwner:"33333333-3333-3333-3333-333333333333")
        check(compactConfig.text("owner") == "33333333-3333-3333-3333-333333333333","backend compact UUID converts only at wire boundary")
        check(try restarted.current()?.participants.first?.id == compact,"business identity preserved")
        print("PASS phone session: durable ACK, replay, leases, faults, recovery, lifecycle, ownership, outbox")
    }
}
