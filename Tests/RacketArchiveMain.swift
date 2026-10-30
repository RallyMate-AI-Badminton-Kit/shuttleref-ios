import Foundation
@main struct ArchiveChecks {
 static func main() throws {
  let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
  let root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  func bytes(_ hex:String)->Data { let b=Array(hex);return Data(stride(from:0,to:b.count,by:2).map{UInt8(String(b[$0..<$0+2]),radix:16)!}) }
  for m in root["messages"] as! [[String:Any]] {
   let request=bytes(m["request_hex"] as! String),response=bytes(m["response_hex"] as! String)
   let frames=try RacketArchiveWire.frames(request,transaction:UInt8(m["transaction"] as! Int))
   precondition(frames == (m["request_frames_hex"] as! [String]).map(bytes))
   var assembler=RacketScoreAssembler();var assembled:Data?
   for f in (m["response_frames_hex"] as! [String]).map(bytes) { assembled=try assembler.append(f,now:0) }
   precondition(assembled==response)
   try RacketArchiveWire.response(response,command:request)
   var wrong=response;wrong[25] ^= 1
   do { try RacketArchiveWire.response(wrong,command:request);fatalError("accepted wrong query operation") } catch PhoneScoreError.invalidWire {}
  }
  for status in ["unknown","pending","history_unavailable","observed","ALREADY_APPLIED"] { precondition(!RacketArchiveWire.isTerminal(status)) }
  for status in ["confirmed","superseded","rejected"] { precondition(RacketArchiveWire.isTerminal(status)) }
  precondition(!RacketArchiveWire.isTerminal(nil))
  print("PASS App archive public vectors, 196/281 byte framing and request correlation")
 }
}
