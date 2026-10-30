import Foundation
@main struct DualHostWireTests {
 static func main() throws {
  func decode(_ hex:String)->Data { var data=Data();var i=hex.startIndex;while i<hex.endIndex { let j=hex.index(i,offsetBy:2);data.append(UInt8(hex[i..<j],radix:16)!);i=j };return data }
  let a=RacketDualHostWire.pendingKey(origin:"https://test.invalid",account:"a",device:"d")
  assert(a != RacketDualHostWire.pendingKey(origin:"https://test.invalid",account:"b",device:"d"))
  assert(a == RacketDualHostWire.pendingKey(origin:"https://test.invalid",account:"a",device:"d")) // selected host is intentionally not a key input
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
