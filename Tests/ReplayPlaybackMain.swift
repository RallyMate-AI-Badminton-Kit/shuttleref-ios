import Foundation
import AVFoundation
import CoreVideo
import CoreImage

/// Explicit integration probe for the production player model; session file is private and temporary.
@main struct ReplayPlaybackCheck {
    struct Session:Decodable { let origin:String;let user_id:String;let token:String;let match_id:String }
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count==2 else { throw CoachFailure("Expected private verification session file") }
            let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
            let session=try JSONDecoder().decode(Session.self,from:data)
            let context=CoachContext(origin:session.origin,userID:session.user_id,token:session.token)
            let match=try await ReplayClient().match(context,id:session.match_id)
            guard let point=match.points.last,match.is_demo else { throw CoachFailure("Expected authorized demo final point") }
            let model=ReplayPlayerModel()
            await model.load(context:context,clip:point.video.reference)
            model.player?.isMuted=true
            guard let item=model.player?.currentItem else { throw CoachFailure("No player item: "+model.error) }
            let video=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            item.add(video)
            let deadline=Date().addingTimeInterval(35)
            var frame:CVPixelBuffer?
            while Date()<deadline && model.error.isEmpty {
                if let time=model.player?.currentTime(),video.hasNewPixelBuffer(forItemTime:time) {
                    frame=video.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:nil)
                }
                if frame != nil && model.progressed { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            guard model.error.isEmpty,model.progressed,let frame else {
                model.stop();throw CoachFailure("No decoded frame/progress: "+model.error)
            }
            let seconds=model.player?.currentTime().seconds ?? 0
            let width=CVPixelBufferGetWidth(frame),height=CVPixelBufferGetHeight(frame)
            let image=CIImage(cvPixelBuffer:frame)
            try CIContext().writePNGRepresentation(of:image,to:URL(fileURLWithPath:"/private/tmp/replay-real-frame.png"),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
            model.stop()
            try await Task.sleep(nanoseconds:200_000_000)
            guard model.player==nil else { throw CoachFailure("Player did not stop") }
            let receipt:[String:Any]=["actual_player_model":true,"business_auth":true,"decoded_frame":true,"frame_width":width,"frame_height":height,"progress_seconds":seconds,"stop_verified":true]
            print(String(data:try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys),encoding:.utf8)!)
        } catch {
            print("FAIL: "+((error as? CoachFailure)?.message ?? "Playback verification failed"));exit(1)
        }
    }
}
