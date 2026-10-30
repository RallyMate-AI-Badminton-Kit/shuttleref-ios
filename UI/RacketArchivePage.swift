import SwiftUI

@MainActor final class RacketArchiveController: ObservableObject {
 @Published var message="请保持设备连接。比赛需先暂停，再维护回执。"
 @Published var busy=false
 @Published var eligible=false
 private var summaryID:String?
 private var device:String?
 private var session:String?
 private func key(_ c:RacketContext)->String { "racket.archive.pending."+c.origin+":"+c.userID+":"+(device ?? "") }
 func check(_ context:RacketContext) async {
  guard !busy else { return };busy=true;eligible=false;defer{busy=false}
  let service=RacketBLEConnectionHub.shared.service(for:context)
  do {
   let info=try await service.transport.currentInfo();device=info.deviceID;session=info.session
   if let batch=UserDefaults.standard.string(forKey:key(context)) {
    var result=try await service.archiveResult(batch,context:context)
    if !RacketArchiveWire.isTerminal(result["status"] as? String) {
     result=try await service.archiveRoundtrip("/status",body:["operation_id":UUID().uuidString.lowercased(),"device_id":info.deviceID,"session":info.session,"subject_archive":batch],context:context)
    }
    guard let state=result["status"] as? String, RacketArchiveWire.isTerminal(state) else { message="归档结果尚未确认，请再次查询原批次。若连接已超时，请重新连接后查询，不会重复释放容量。";return }
    UserDefaults.standard.removeObject(forKey:key(context))
    message=state=="confirmed" ? "设备检查点已确认归档。":"原批次确认未改变设备，已退休；可以重新检查容量。"
   }
   let id=UUID().uuidString.lowercased()
   let result=try await service.archiveRoundtrip("/summary",body:["operation_id":id,"device_id":info.deviceID,"session":info.session],context:context)
   if result["device_status"] as? Int == 5 {message="连接认证窗口已过期，请重新连接拍底后检查容量。";return}
   if result["status"] as? String == "history_unavailable" { eligible=false;message="后端历史待恢复，已冻结归档。不会释放任何设备记录。";return }
   guard result["status"] as? String == "observed",let used=result["used"] as? Int,let capacity=result["capacity"] as? Int else { message="设备快照未确认，无法进行维护。";return }
   summaryID=id;eligible=used>=8 && result["reclaim_enabled"] as? Bool == true
   message="设备回执 \(used)/\(capacity) · 关联版本 \(result["revision"] as? Int ?? 0)。归档保持使用者和关联版本不变。"
   if result["reclaim_enabled"] as? Bool != true {message += " 服务端尚未开放回收，当前仅检查容量。"}
  } catch { eligible=false;message=error.localizedDescription }
 }
 func archive(_ context:RacketContext) async {
  guard !busy,eligible,let summaryID,let device,let session else{return}
  busy=true;defer{busy=false}
  guard UserDefaults.standard.string(forKey:key(context))==nil else {message="请先查询原归档批次。";return}
  let batch=UUID().uuidString.lowercased()
  UserDefaults.standard.set(batch,forKey:key(context)) // Record before submitting; never generate a new archive on timeout.
  var forwarded=false
  do {
   let service=RacketBLEConnectionHub.shared.service(for:context)
   let result=try await service.archiveRoundtrip("/prepare",body:["operation_id":batch,"device_id":device,"session":session,"summary_id":summaryID],context:context,willForward:{forwarded=true})
   if result["status"] as? String == "confirmed" { UserDefaults.standard.removeObject(forKey:key(context));message="回执归档已确认，设备容量已回收。";eligible=false }
   else if result["status"] as? String == "rejected" {UserDefaults.standard.removeObject(forKey:key(context));message="设备拒绝本次归档，未确认容量回收。";eligible=false}
   else {message="归档结果尚未确认，请查询原批次。"}
  } catch {
   // A known disabled gate did not issue a command. Other network failures remain unknown.
   if !forwarded, let diagnostic=error as? RacketDiagnostic,diagnostic.stage == "回执维护" { UserDefaults.standard.removeObject(forKey:key(context)) }
   message=error.localizedDescription
  }
 }
}
struct RacketArchivePage: View {
 let context:RacketContext?
 @StateObject private var model=RacketArchiveController()
 var body:some View {
  VStack(alignment:.leading,spacing:20) {
   SheetHeader(title:"拍底回执维护")
   Text(model.message).fixedSize(horizontal:false,vertical:true)
   Button("检查容量 / 查询原结果") { if let context {Task{await model.check(context)}} }.disabled(model.busy || context==nil)
   Button("归档已保存回执") { if let context {Task{await model.archive(context)}} }.buttonStyle(PrimaryStyle()).disabled(model.busy || !model.eligible)
   if model.busy {ProgressView("正在核对设备与服务端…")}
   Text("仅后端保存并验证的历史可被归档。当前固件和服务端开关未开放时，不会释放设备记录。").font(.caption).foregroundColor(Palette.muted)
   RacketDiagnosticButton();Spacer()
  }.padding(22).background(Palette.background).task { if let context {await model.check(context)} }
 }
}
