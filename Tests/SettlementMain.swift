import Foundation
@main struct SettlementChecks {
    static func main() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = MatchSession(accountID:"a",deviceID:"d",online:true,cache:nil,defaults:defaults) { _,_ in }
        let names = ["A","B","C","D"]
        do { try session.settle(names:names,doubles:false,mvpSlot:0); preconditionFailure("unconfirmed must fail") } catch {}
        session.send("Q"); session.receive("@1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:00000001:a:21,10,2,0,0:0")
        do { try session.settle(names:names,doubles:false,mvpSlot:1); preconditionFailure("singles partner must fail") } catch {}
        try session.settle(names:names,doubles:true,mvpSlot:3)
        precondition(session.completedResults.count == 1 && session.completedResults.first?.mvpName == "D")
        try session.settle(names:names,doubles:true,mvpSlot:0)
        precondition(session.completedResults.count == 1 && session.completedResults.first?.mvpSlot == 3)
        let restored = MatchSession(accountID:"a",deviceID:"d",online:false,cache:nil,defaults:defaults) { _,_ in }
        precondition(restored.completedResults.first?.mvpName == "D")
        let other = MatchSession(accountID:"b",deviceID:"d",online:false,cache:nil,defaults:defaults) { _,_ in }
        precondition(other.completedResults.isEmpty)
        let earlySession = MatchSession(accountID:"early",deviceID:"d",online:true,cache:nil,defaults:defaults) { _,_ in }
        earlySession.send("Q"); earlySession.receive("@1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:00000001:a:3,5,0,0,0:0")
        do { try earlySession.settle(names:names,doubles:false,mvpSlot:nil,early:true); preconditionFailure("active must be paused first") } catch {}
        earlySession.send("P"); earlySession.receive("@1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:00000002:p:3,5,0,0,0:0")
        try earlySession.settle(names:names,doubles:false,mvpSlot:nil,early:true)
        precondition(earlySession.completedResults.first?.earlyEnded == true)
        precondition(earlySession.completedResults.first?.mvpSlot == nil)
        precondition(earlySession.completedResults.first?.snapshot.scores == [3,5,0,0,0])
        print("PASS: confirmed finished snapshot only, singles roster guard, doubles fourth player, immutable duplicate, relaunch, account isolation")
    }
}
