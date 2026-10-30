import Foundation
@main struct KnownChecks {
 static func main() {
  let name = "registry-test-"+UUID().uuidString
  let defaults = UserDefaults(suiteName:name)!
  defer { defaults.removePersistentDomain(forName:name) }
  let a=RacketContext(origin:"https://one.invalid",userID:"a",token:"secret",hostID:nil)
  let b=RacketContext(origin:a.origin,userID:"b",token:"other",hostID:nil)
  let d=RacketDevice(id:"d",name:"拍底",version:1,user:RacketPerson(kind:.user,stableID:"a",name:"同名"),hostID:nil,authenticated:true,connection:.online,observedAt:Date(),matchActive:false)
  KnownRacketRegistry.remember(d,peripheral:"p",context:a,defaults:defaults)
  precondition(KnownRacketRegistry.isKnown(peripheral:"p",context:a,defaults:defaults))
  precondition(!KnownRacketRegistry.isKnown(peripheral:"p",context:b,defaults:defaults))
  let cached=KnownRacketRegistry.devices(a,defaults:defaults)[0]
  precondition(cached.connection == .unknown && !cached.authenticated)
  let connection = UUID()
  KnownRacketRegistry.connected("d",context:a,connection:connection)
  precondition(KnownRacketRegistry.isConnected("d",context:a))
  precondition(!KnownRacketRegistry.isConnected("d",context:b))
  KnownRacketRegistry.disconnected(connection)
  precondition(!KnownRacketRegistry.isConnected("d",context:a))
  KnownRacketRegistry.replace([],context:a,defaults:defaults)
  precondition(!KnownRacketRegistry.isKnown(peripheral:"p",context:a,defaults:defaults))
  print("PASS confirmed association cache: account isolation, no false online/auth, unbind invalidation")
 }
}
