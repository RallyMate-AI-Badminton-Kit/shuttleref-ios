import Foundation

let domain = "shuttleref.session.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName:domain)!
defer { defaults.removePersistentDomain(forName:domain) }
var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) };count += 1
}
let zero = String(repeating:"0",count:32)
func frame(_ id:String, _ token:UInt32, _ state:String, _ scores:String="0,0,0,0,0", _ code:Int=0)->String {
    "@1:\(id):\(String(format:"%08x",token)):\(state):\(scores):\(code)"
}
var wires:[String] = []
let session = MatchSession(accountID:"account",deviceID:"board",online:true,cache:frame(zero,42,"i"),defaults:defaults) { wire, completion in wires.append(wire);completion(nil) }
check(!session.can("B"),"cache is not fresh")
session.send("Q")
check(session.pending?.token == 43,"query follows device watermark")
session.send("Q");check(wires.count == 1,"one in-flight command")
session.receive(frame(zero,43,"i"))
check(session.fresh && session.can("B"),"query confirms fresh state")
session.send("B");let matchID = session.pending!.id
check(matchID.count == 32 && matchID != zero,"new UUID")
check(session.lastConfirmed == nil,"send callback is not confirmation")
session.receive(frame(matchID,44,"a"))
check(session.lastConfirmed == "B" && session.can("r"),"start confirmed")
session.send("r");session.receive(frame(matchID,44,"a"))
check(session.pending != nil,"old snapshot cannot acknowledge new point")
session.receive(frame(matchID,45,"a","1,0,0,0,0"))
check(session.current?.scores[0] == 1 && session.lastConfirmed == "r","point confirmed")
session.send("P");session.receive(frame(matchID,46,"p","1,0,0,0,0"))
check(session.saved?.scores[0] == 1 && !session.can("r") && session.can("R"),"paused saved and blocked")
let restored = MatchSession(accountID:"account",deviceID:"board",online:true,cache:frame(zero,46,"i"),defaults:defaults) {_,_ in}
check(restored.saved?.id == matchID,"saved match survives session recreation")
let other = MatchSession(accountID:"other",deviceID:"board",online:true,cache:nil,defaults:defaults) {_,_ in}
check(other.saved == nil,"account isolation")
restored.send("Q");restored.receive(frame(zero,47,"i"));restored.send("R")
check(restored.pending?.token == 48,"sequence survives recreation")
restored.receive(frame(matchID,48,"a","1,0,0,0,0"))
check(restored.saved == nil && restored.lastConfirmed == "R","restored snapshot cleared only after ack")
restored.send("U");restored.receive(frame(matchID,49,"a"))
check(restored.lastConfirmed == "U","undo confirmed")
restored.send("b");restored.expire()
check(!restored.fresh && !restored.can("r") && restored.can("Q"),"timeout blocks writes without retry")
restored.send("Q");restored.receive(frame(matchID,100,"a","0,0,0,0,0",3))
check(!restored.fresh,"stale sequence is not successful")
restored.send("Q");check(restored.pending?.token == 101,"query advances updated watermark")
restored.receive(frame(matchID,101,"a"));restored.send("P")
restored.receive(frame(String(repeating:"a",count:32),102,"a"))
check(!restored.fresh && restored.lastConfirmed == nil,"wrong match ack rejected")
restored.setOnline(false)
check(!restored.can("Q") && !restored.can("A"),"offline blocks all requests")
restored.setOnline(true);restored.send("Q");restored.receive(frame(matchID,103,"a","21,0,2,0,0"))
check(!restored.can("r") && !restored.can("P") && restored.can("A"),"finished game guard")
restored.send("A");restored.receive(frame(matchID,104,"i"))
check(restored.lastConfirmed == "A" && restored.can("B"),"abandon resets state")
restored.receive(frame(matchID,90,"a","8,8,0,0,0"))
check(restored.current?.token == 104,"late old snapshot ignored")
restored.disconnect();restored.receive(frame(matchID,105,"a"))
check(!restored.can("Q") && restored.current?.token == 104,"disconnected session ignores callbacks")
check(MatchSnapshot("@1:\(zero):00000001:i:0,bad,0,0,0,0:0") == nil,"malformed score count rejected")
check(MatchSnapshot(frame(zero,1,"i","31,0,0,0,0")) == nil,"score range enforced")
check(MatchWire.encode("R",id:matchID,sequence:1,scores:[30,0,0,0,0]) == nil,"invalid restore rejected")
let reserved = MatchSession(accountID:"reserved",deviceID:"board",online:true,cache:nil,defaults:defaults) {_,_ in}
reserved.send("Q"); reserved.receive(frame(zero,1,"i"))
reserved.send("B", matchID:String(repeating:"d",count:32))
check(reserved.pending?.id == String(repeating:"d",count:32),"server reserved match ID used in device command")
print("PASS: \(count) session and protocol checks")
let ended = MatchSnapshot(frame(matchID,110,"p","8,6,0,0,0"))!
let cleared = MatchSnapshot(frame(matchID,111,"i"))!
check(CourtHomeState(snapshot:ended,saved:ended,settled:true) == .ended,"settled paused match offers result")
check(CourtHomeState(snapshot:cleared,saved:nil,settled:true) == .ready,"retained historical ID after clear must offer preparation")
check(CourtHomeState(snapshot:cleared,saved:ended,settled:true) == .resume,"saved match remains resumable instead of historical settlement")
check(CourtHomeState(snapshot:ended,saved:nil,settled:false) == .resume,"unsettled match remains resumable")
check(CourtRoster.defaultName(account:" 球友 ",deviceAccount:"设备昵称") == "球友","business nickname has priority")
check(CourtRoster.defaultName(account:" ",deviceAccount:"设备昵称") == "设备昵称","Tuya nickname fallback")
check(CourtRoster.defaultName(account:nil,deviceAccount:"") == "我方球员","missing nickname keeps placeholder")
print("PASS: home state and default nickname regressions")
let abandonedID = String(repeating:"e",count:32)
let offlineSave = MatchSession(accountID:"abandon",deviceID:"board",online:false,cache:nil,defaults:defaults) { _,_ in fatalError("local discard must not send DP") }
offlineSave.receive(frame(abandonedID,393,"p","4,1,0,0,1"))
check(offlineSave.saved != nil,"4:1 saved locally")
offlineSave.discardLocalSave()
check(offlineSave.saved == nil,"offline discard clears saved match")
check(offlineSave.current?.id == abandonedID,"discard cannot pretend device cleared")
let reopened = MatchSession(accountID:"abandon",deviceID:"board",online:false,cache:nil,defaults:defaults) { _,_ in fatalError("no commands") }
check(reopened.saved == nil,"discard survives restart")
print("PASS: offline local discard without device mutation")
