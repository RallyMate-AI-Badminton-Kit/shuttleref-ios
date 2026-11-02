import Foundation
@main struct ReplicaTests {
 static func main() throws {
  func check(_ value: Bool) { assert(value) }
  func packet(_ revision:String,_ points:Int=1) throws -> SharedMatch {
   let value:[String:Any] = ["match_id":"11111111-1111-1111-1111-111111111111","authority_type":"phone","authority_id":"installation","origin":"local","rules_version":"badminton-21-cap30-best3-v1","participants":[],"doubles":false,"revision":revision,"snapshot":["red":points,"blue":0,"redGames":0,"blueGames":0,"server":"r","points":["r"]],"lifecycle":"active","received_at":1,"role":"viewer","can_score":false,"archived":false,"sync_state":"cloud_received"]
   return try JSONDecoder().decode(SharedMatch.self,from:JSONSerialization.data(withJSONObject:value))
  }
  func host(_ lifecycle:String, authority:String="pi") throws -> SharedMatch {
   var value = try JSONSerialization.jsonObject(with:JSONEncoder().encode(packet("5"))) as! [String:Any]
   value["authority_type"]=authority;value["tuya_device_id"]="host-one";value["lifecycle"]=lifecycle
   return try JSONDecoder().decode(SharedMatch.self,from:JSONSerialization.data(withJSONObject:value))
  }
  let ended=try host("aborted")
  check(ended.matchesHost(deviceID:"host-one",matchID:String(repeating:"1",count:32)))
  check(!ended.matchesHost(deviceID:"host-two",matchID:ended.id))
  check(!ended.matchesHost(deviceID:"host-one",matchID:String(repeating:"2",count:32)))
  check(try !host("completed",authority:"phone").matchesHost(deviceID:"host-one",matchID:ended.id))
  check(ended.isTerminal && ended.lifecycleTitle == "已提前结束")
  check(try host("completed").isTerminal)
  check(try !host("paused").isTerminal)
  check(try host("paused").lifecycleTitle == "比赛暂停")
  let active=try host("active"), paused=try host("paused"), phone=try packet("1")
  check(SharedMatchSelection.visible([ended,phone,active,paused],piOnly:true,deviceID:"host-one").count==2)
  check(SharedMatchSelection.visible([active],piOnly:true,deviceID:"host-two").isEmpty)
  check(SharedMatchSelection.visible([ended,phone],piOnly:true,deviceID:nil).isEmpty)
  check(SharedMatchSelection.visible([ended,phone],piOnly:false,deviceID:nil).count==2)
  check(SharedMatchSelection.visible([ended,phone],piOnly:true,deviceID:"host-one",matchID:ended.id).count==1)
  check(SharedMatchSelection.visible([ended],piOnly:true,deviceID:"host-two",matchID:ended.id).isEmpty)
  check(SharedMatchSelection.visible([ended],piOnly:true,deviceID:"host-one",matchID:String(repeating:"2",count:32)).isEmpty)
  check(active.can_end == nil && !active.canEndFromPhone)
  var controllable=active;controllable.can_end=true;check(controllable.canEndFromPhone)
  var terminal=ended;terminal.can_end=true;check(!terminal.canEndFromPhone)
  var phoneControl=phone;phoneControl.can_end=true;check(!phoneControl.canEndFromPhone)
  var replica=MatchReplica();let epoch=replica.reset(scope:"account-a")
  check(try replica.accept(packet("9007199254740993"),epoch:epoch))
  check(try !replica.accept(packet("9007199254740992"),epoch:epoch))
  check(try replica.accept(packet("9007199254740993"),epoch:epoch))
  do { _ = try replica.accept(packet("9007199254740993",2),epoch:epoch);fatalError("same revision changed score") } catch {}
  _=replica.reset(scope:"account-b")
  check(try !replica.accept(packet("9007199254740994"),epoch:epoch))
  assert(replica.match == nil)
  var parser=MatchEventParser()
  check(try parser.line("event: snapshot") == nil)
  check(try parser.line("data: {\"revision\":\"2\"}") == nil)
  check(try parser.line("")?.event == "snapshot")
  print("match replica: version, conflict, scope and SSE checks passed")
 }
}
