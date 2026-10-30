import Foundation
@MainActor final class UploadProbe: MatchSyncService {
 var available=false
 var uploaded=[UInt32]()
 func upload(_ e:PhoneSyncEnvelope,operationID:String,scope:PhoneMatchScope) async throws -> PhoneSyncResult {
  if !available { return .unavailable }
  uploaded.append(e.revision)
  return .accepted(matchID:e.match_id,revision:e.revision,installation:scope.installation)
 }
}
@main struct SyncLifecycleTests {
 @MainActor static func main() async throws {
  func check(_ value:Bool) { assert(value) }
  let path=FileManager.default.temporaryDirectory.appendingPathComponent("sync-lifecycle-\(UUID()).sqlite")
  defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path.path+suffix) } }
  let scope=PhoneMatchScope(origin:"https://test.invalid",account:UUID().uuidString.lowercased(),installation:"phone")
  let session=try PhoneMatchSession(storage:PhoneMatchStore(url:path,scope:scope.key),scope:scope)
  try session.start(participants:[PhoneParticipant(id:scope.account,name:"A",side:.red),PhoneParticipant(id:UUID().uuidString.lowercased(),name:"B",side:.blue)],doubles:false)
  let old=UploadProbe();let sync=PhoneSyncPump(session:session,service:old)
  try await sync.flush()
  check(try session.syncState()=="pending")
  try session.manual(.end)
  session.background() // UI leaves, but durable outbox must still be uploadable.
  let renewed=UploadProbe();renewed.available=true
  sync.update(service:renewed) // token renewal retains same match/session and pending IDs
  try await sync.flush()
  check(renewed.uploaded == [1,2])
  check(try session.current()?.phase == .ended)
  check(try session.syncState()=="synced")
  session.foreground()
  try session.start(participants:[PhoneParticipant(id:scope.account,name:"A",side:.red),PhoneParticipant(id:UUID().uuidString.lowercased(),name:"B",side:.blue)],doubles:false)
  check(try session.syncState()=="pending") // a new commit cannot inherit prior receipt state
  sync.stop()
  print("sync lifecycle: offline end, UI departure, credential refresh and new revision passed")
 }
}
