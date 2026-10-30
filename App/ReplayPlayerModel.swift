import Foundation
import Combine
import AVFoundation

@MainActor final class ReplayPlayerModel:ObservableObject {
    @Published var player:AVPlayer?
    @Published var loading=false
    @Published var error=""
    @Published var progressed=false
    private var state=ReplayPlaybackState()
    private var observation:NSKeyValueObservation?
    private var controlObservation:NSKeyValueObservation?
    private var notifications:[NSObjectProtocol]=[]
    private var boundary:Any?
    private var progress:Any?
    private var request:Task<ReplayGrant,Error>?
    private var deadline:Task<Void,Never>?
    private var position=0.0
    private var scope:CoachContext?
    private func fail(_ run:UUID,_ message:String) {
        guard state.fail(run) else { return }
        loading=false;error=message;deadline?.cancel();request?.cancel()
        observation=nil;controlObservation=nil;player?.pause()
    }
    private func watchDeadline(_ run:UUID) {
        deadline?.cancel()
        deadline=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:30_000_000_000) } catch { return }
            self?.fail(run,"视频加载或缓冲超时，请重试获取播放授权")
        }
    }
    private func waiting(_ run:UUID) {
        guard state.accepts(run) else { return }
        if state.phase == .waiting && deadline != nil { return }
        guard state.waiting(run) else { return }
        loading=true;watchDeadline(run)
    }
    func load(context:CoachContext,clip:CoachVideoReference) async {
        stop(keepPosition:scope==context);scope=context
        guard clip.isValid else { error="片段范围无效";return }
        loading=true;error="";progressed=false
        let run=state.begin()
        let task=Task { try await ReplayClient().playback(context,assetID:clip.assetID) };request=task
        do {
            let grant=try await task.value
            guard state.accepts(run),!Task.isCancelled else { return }
            guard clip.endSeconds<=grant.duration_seconds+0.01 else { throw CoachFailure("片段超出视频范围") }
            let item=AVPlayerItem(url:grant.url)
            item.forwardPlaybackEndTime=CMTime(seconds:clip.endSeconds,preferredTimescale:600)
            item.reversePlaybackEndTime=CMTime(seconds:clip.startSeconds,preferredTimescale:600)
            let player=AVPlayer(playerItem:item);self.player=player
            let seek=max(clip.startSeconds,min(position,clip.endSeconds-0.05))
            watchDeadline(run)
            observation=item.observe(\.status,options:[.initial,.new]) { [weak self,weak player] item,_ in
                let status=item.status
                Task { @MainActor [weak self,weak player] in
                    guard let self,self.state.accepts(run) else { return }
                    if status == .readyToPlay {
                        guard self.state.ready(run) else { return }
                        self.deadline?.cancel();self.deadline=nil;self.waiting(run)
                        player?.seek(to:CMTime(seconds:seek,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self,weak player] finished in
                            Task { @MainActor in if finished,self?.state.accepts(run)==true { player?.play() } }
                        }
                    } else if status == .failed { self.fail(run,"视频暂时无法播放，请重试获取播放授权") }
                }
            }
            controlObservation=player.observe(\.timeControlStatus,options:[.new]) { [weak self] player,_ in
                let status=player.timeControlStatus
                Task { @MainActor [weak self] in
                    guard let self,self.state.accepts(run) else { return }
                    if status == .waitingToPlayAtSpecifiedRate { self.waiting(run) }
                    else if status == .playing || (status == .paused && self.state.phase == .waiting) {
                        _=self.state.playing(run);self.loading=false;self.deadline?.cancel();self.deadline=nil
                    }
                }
            }
            notifications.append(NotificationCenter.default.addObserver(forName:.AVPlayerItemFailedToPlayToEndTime,object:item,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.fail(run,"播放连接中断或授权已过期，请重试") }
            })
            notifications.append(NotificationCenter.default.addObserver(forName:.AVPlayerItemPlaybackStalled,object:item,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.waiting(run) }
            })
            boundary=player.addBoundaryTimeObserver(forTimes:[NSValue(time:CMTime(seconds:clip.endSeconds,preferredTimescale:600))],queue:.main) { [weak player] in player?.pause() }
            progress=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.25,preferredTimescale:600),queue:.main) { [weak self] time in
                Task { @MainActor in if let self,self.state.accepts(run),time.seconds>seek+0.2 { self.progressed=true } }
            }
        } catch {
            guard !(error is CancellationError) else { return }
            fail(run,(error as? CoachFailure)?.message ?? "视频加载失败，请稍后重试")
        }
    }
    func pause() { player?.pause() }
    func stop(keepPosition:Bool=false) {
        if keepPosition,let seconds=player?.currentTime().seconds,seconds.isFinite { position=seconds }
        else if !keepPosition { position=0 }
        state.stop();request?.cancel();request=nil;deadline?.cancel();deadline=nil
        observation=nil;controlObservation=nil
        for token in notifications { NotificationCenter.default.removeObserver(token) };notifications=[]
        player?.pause()
        if let boundary { player?.removeTimeObserver(boundary) };boundary=nil
        if let progress { player?.removeTimeObserver(progress) };progress=nil
        player?.replaceCurrentItem(with:nil);player=nil;loading=false
    }
}
