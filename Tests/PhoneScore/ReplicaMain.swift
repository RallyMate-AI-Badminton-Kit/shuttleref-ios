import Foundation
@main struct ReplicaTests {
 static func main() throws {
  func check(_ value: Bool) { assert(value) }
  func packet(_ revision:String,_ points:Int=1) throws -> SharedMatch {
   let value:[String:Any] = ["match_id":"11111111-1111-1111-1111-111111111111","authority_type":"phone","authority_id":"installation","origin":"local","rules_version":"badminton-21-cap30-best3-v1","participants":[],"doubles":false,"revision":revision,"snapshot":["red":points,"blue":0,"redGames":0,"blueGames":0,"server":"r","points":["r"]],"lifecycle":"active","received_at":1,"role":"viewer","can_score":false,"archived":false,"sync_state":"cloud_received"]
   return try JSONDecoder().decode(SharedMatch.self,from:JSONSerialization.data(withJSONObject:value))
  }
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
