import Foundation
@main struct DiagnosticChecks {
 static func main() {
  var trace = RacketDiagnostics()
  let id="11111111-1111-1111-1111-111111111111"
  trace.record(.http,operation:id,device:"d40592412074",code:"INVALID_DEVICE_RESPONSE",status:409)
  trace.record(.bleReply,status:2,length:164,version:2,kind:2,bound:0,before:8,after:8)
  trace.record(.failed,operation:"Bearer SECRET_TOKEN",device:"SESSION_SECRET",code:"Authorization: Bearer PRIVATE")
  trace.record(.failed,code:"SECRETTOKENVALUE")
  let report=trace.report()
  precondition(report.contains(id) && report.contains("status=409") && report.contains("before_revision=8"))
  precondition(!report.contains("SECRET_TOKEN") && !report.contains("SESSION_SECRET") && !report.contains("Bearer PRIVATE") && !report.contains("SECRETTOKENVALUE"))
  for _ in 0..<205 { trace.record(.query,operation:id) }; precondition(trace.lines.count == 200)
  print("PASS structured diagnostics: useful failure fields, credential rejection and bounded history")
 }
}
