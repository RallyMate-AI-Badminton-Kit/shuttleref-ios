import Foundation
@main struct DualHostWireTests {
 static func main() throws {
  func decode(_ hex:String)->Data { var data=Data();var i=hex.startIndex;while i<hex.endIndex { let j=hex.index(i,offsetBy:2);data.append(UInt8(hex[i..<j],radix:16)!);i=j };return data }
  let a=RacketDualHostWire.pendingKey(origin:"https://test.invalid",account:"a",device:"d")
  assert(a != RacketDualHostWire.pendingKey(origin:"https://test.invalid",account:"b",device:"d"))
  assert(a == RacketDualHostWire.pendingKey(origin:"https://test.invalid",account:"a",device:"d")) // selected host is intentionally not a key input
  var raw=Data(repeating:0,count:65)
  raw[0]=1;raw[1]=6;raw[3]=15;raw[14]=25;raw[15]=1;raw[17]=128;raw[23]=1;raw[27]=11;raw[31]=11
  let offline=try RacketNetworkSnapshot(raw)
  assert(!offline.ready && offline.report.contains("安全握手超时") && offline.report.contains("11 / 11"))
  raw[1]=3;raw[14]=31;raw[15]=6;raw[19]=2
  let ready=try RacketNetworkSnapshot(raw); assert(ready.ready) // historical disconnect reason must not override current state
  raw[43]=1
  let pending=try RacketNetworkSnapshot(raw); assert(!pending.ready)
  var assembler=RacketNetworkAssembler()
  let skipped=try assembler.append(Data([7,2,4])+raw[34..<51]); assert(skipped == nil)
  for index in 0..<4 {
   let end=min(65,(index+1)*17)
   let result=try assembler.append(Data([7,UInt8(index),4])+raw[index*17..<end])
   assert((result != nil) == (index==3))
  }
  var mixed=RacketNetworkAssembler()
  _=try mixed.append(Data([7,0,4])+raw[0..<17])
  do { _=try mixed.append(Data([8,1,4])+raw[17..<34]);fatalError("mixed snapshot accepted") } catch {}
  do { _=try RacketNetworkSnapshot(raw.dropLast());fatalError("short snapshot accepted") } catch {}
  var v2=raw+Data(repeating:0,count:8);v2[0]=2;v2[68]=46
  v2[69]=0x12;v2[70]=0x34;v2[71]=0x56;v2[72]=0x78
  let snapshot2=try RacketNetworkSnapshot(v2)
  assert(snapshot2.report.contains("46") && snapshot2.report.contains("305419896"))
  var pages2=RacketNetworkAssembler()
  for index in 0..<5 {
   let result=try pages2.append(Data([9,UInt8(index),5])+v2[index*17..<min(73,(index+1)*17)])
   assert((result != nil)==(index==4))
  }
  var wrongCount=RacketNetworkAssembler()
  do { _=try wrongCount.append(Data([9,0,4])+v2[0..<17]);fatalError("v2 with v1 page count accepted") } catch {}
  var changingCount=RacketNetworkAssembler()
  _=try changingCount.append(Data([9,0,5])+v2[0..<17])
  do { _=try changingCount.append(Data([9,1,4])+v2[17..<34]);fatalError("changing page count accepted") } catch {}
  do { _=try RacketNetworkSnapshot(v2.dropLast());fatalError("truncated v2 accepted") } catch {}
  let file=CommandLine.arguments[1]
  let object=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:Any]
  let cmd=decode(object["request_hex"] as! String),response=decode(object["response_hex"] as! String)
  let frames=try RacketDualHostWire.frames(cmd,transaction:7)
  assert(frames.count==17 && frames.dropLast().allSatisfy{$0.count==20})
  try RacketDualHostWire.response(response,command:cmd)
  var wrong=response;wrong[24] ^= 1
  do { try RacketDualHostWire.response(wrong,command:cmd);fatalError("accepted different nonce") } catch {}
  print("dual host: public vector, 277/98 sizes, frame count and nonce checked")
 }
}
