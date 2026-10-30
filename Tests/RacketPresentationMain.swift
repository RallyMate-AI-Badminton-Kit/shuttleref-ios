import Foundation
@MainActor final class PresentationBluetooth: RacketBluetoothDiscovery {
 let available = true
 var cancellations = 0
 var retained = false
 func retainsConnection(for context:RacketContext) -> Bool { retained }
 func cancel() { cancellations += 1; retained = false }
 func scan() async throws -> [RacketNearby] { [] }
 func verifyAndPrepare(_ candidate:RacketNearby,hostID:String?,context:RacketContext) async throws -> RacketVerifiedNearby {
  retained = true
  let d=RacketDevice(id:"device",name:"拍底",version:1,user:RacketPerson(kind:.user,stableID:context.userID,name:"球友"),hostID:nil,authenticated:true,connection:.online,observedAt:Date(),matchActive:false)
  return RacketVerifiedNearby(device:d,confirmation:RacketDeviceConfirmation(deviceID:d.id,proof:"verified",expiresAt:Date().addingTimeInterval(60)))
 }
}
@main struct PresentationChecks {
 @MainActor static func main() async {
  let bluetooth=PresentationBluetooth(), service=MockRacketService()
  let store=RacketStore(service:service,bluetooth:bluetooth,simulated:true)
  let context=RacketContext(origin:"mock://presentation",userID:"me",token:"token",hostID:nil)
  store.configure(context,disconnect:false)
  precondition(bluetooth.cancellations == 0,"opening view does not cancel shared connection")
  await store.chooseNearby(RacketNearby(id:"peripheral",label:"拍底"))
  store.finishPresentation()
  precondition(bluetooth.cancellations == 0,"closing owned authenticated view retains BLE connection")
  precondition(store.context == nil && store.selected == nil,"old view detached")
  store.finishDiscovery(); store.finishPresentation()
  precondition(bluetooth.cancellations == 0,"late child disappearance cannot cancel retained parent connection")
  store.configure(context,disconnect:false)
  store.finishDiscovery()
  store.finishPresentation()
  precondition(bluetooth.cancellations == 0,"nested page teardown keeps existing confirmed connection")
  store.configure(context,disconnect:false)
  store.cancelDiscovery()
  precondition(bluetooth.cancellations == 1,"explicit cancellation releases connection")
  print("PASS presentation lifecycle: retained authenticated connection, detached UI, explicit cancellation")
 }
}
