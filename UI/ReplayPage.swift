import SwiftUI
import AVKit

struct ReplayRecordsSection:View {
    @EnvironmentObject private var replays:ReplayStore
    @State private var selected:ReplayMatch?
    @State private var pendingReference:CoachReference?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("演示比赛").font(.title2.bold());Spacer();if replays.context != nil { Button("刷新回放") { Task { await replays.refresh() } }.font(.caption).disabled(replays.loading) } }
            Text("用于验证回放链路，不计入战绩统计").font(.caption).foregroundColor(Palette.muted)
            if replays.loading { ProgressView("正在读取回放…") }
            if !replays.error.isEmpty { Note(text:replays.error) }
            if replays.context==nil { Text("登录后查看当前账号的回放").font(.subheadline).foregroundColor(Palette.muted) }
            ForEach(replays.matches) { match in
                Button { selected=match } label: {
                    VStack(alignment:.leading,spacing:12) {
                        HStack { Text(match.title).font(.headline);Spacer();Text("演示").font(.caption.bold()).foregroundColor(Palette.green) }
                        HStack { Text("比分为设定 · 视频为实拍").font(.caption).foregroundColor(Palette.muted);Spacer();Image(systemName:"play.circle.fill").font(.title2).foregroundColor(Palette.green) }
                        Text("第三局最后一分 · 可回放").font(.subheadline)
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color.white).cornerRadius(20)
                }.buttonStyle(.plain).accessibilityIdentifier("replay-demo-match")
            }
            if replays.context != nil && !replays.loading && replays.error.isEmpty && replays.matches.isEmpty { Text("当前账号暂无演示回放").font(.caption).foregroundColor(Palette.muted) }
        }.sheet(item:$selected,onDismiss:{
            if let reference=pendingReference { pendingReference=nil;replays.requestCoach(reference) }
        }) { match in
            ReplayMatchDetail(match:match) { reference in pendingReference=reference;selected=nil }.environmentObject(replays)
        }
        .onChange(of:replays.context) { _ in selected=nil;pendingReference=nil }
    }
}

struct ReplayMatchDetail:View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var replays:ReplayStore
    let match:ReplayMatch
    let ask:(CoachReference)->Void
    @State private var clip:ReplayClipPresentation?
    var body:some View {
        NavigationView {
            ScrollView { VStack(alignment:.leading,spacing:22) {
                Text(match.title).font(.title2.bold())
                Note(text:"演示比赛 · 比分与最后一分关联为设定，视频为真实录像")
                HStack(alignment:.top) {
                    team("red",title:"红方")
                    VStack(spacing:5) { Text("\(match.result.red_games) : \(match.result.blue_games)").font(.system(size:36,weight:.bold,design:.rounded));Text("局数 · 演示").font(.caption).foregroundColor(Palette.muted) }
                    team("blue",title:"蓝方")
                }.padding(20).background(Palette.soft).cornerRadius(22)
                ForEach(match.games) { game in HStack { Text("第 \(game.number) 局");Spacer();Text("\(game.red) : \(game.blue)").font(.headline.monospacedDigit()) } }
                Button("引用这场问教练") { ask(match.reference) }.buttonStyle(PrimaryStyle()).accessibilityIdentifier("replay-ask-match")
                Divider()
                ForEach(match.points) { point in
                    VStack(alignment:.leading,spacing:15) {
                        Text("第三局 · 最后一分").font(.title2.bold())
                        Text("\(point.before.red) : \(point.before.blue) → \(point.after.red) : \(point.after.blue)").font(.title3.monospacedDigit())
                        Text("演示设定 · 红方取得最后一分").font(.caption).foregroundColor(Palette.muted)
                        Button { clip=ReplayClipPresentation(clip:point.video.reference,title:"第三局 · 最后一分",context:replays.context) } label: {
                            Label("播放这一分的视频 · 48.66 秒",systemImage:"play.circle.fill").frame(maxWidth:.infinity).padding(.vertical,14)
                        }.background(Palette.soft).cornerRadius(15).accessibilityIdentifier("replay-play-final")
                        Button("引用这一分问教练") { ask(match.reference(to:point)) }.font(.subheadline.weight(.semibold)).frame(minHeight:44).accessibilityIdentifier("replay-ask-point")
                        Text("当前仅关联这一分的视频；整段作为演示片段，未做视觉回合分割。尚未导入动作分析。").font(.caption).foregroundColor(Palette.muted)
                    }
                }
                Note(text:"其余得分没有逐分过程或录像。演示参赛角色不代表已识别视频中的人物。")
            }.padding(22) }.background(Palette.background)
            .navigationTitle("比赛回放").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.fullScreenCover(item:$clip) { item in ReplayPlayerPage(presentation:item).environmentObject(replays) }
        .onChange(of:replays.context) { _ in clip=nil;dismiss() }
    }
    private func team(_ side:String,title:String)->some View {
        VStack(spacing:8) { Text(title).font(.caption).foregroundColor(Palette.muted);ForEach(match.participants.filter { $0.side==side },id:\.id) { Text($0.name).font(.headline).multilineTextAlignment(.center) } }.frame(maxWidth:.infinity)
    }
}

struct ReplayClipPresentation:Identifiable {
    let id=UUID()
    let clip:CoachVideoReference
    let title:String
    let context:CoachContext?
}

private struct NativeReplayPlayer:UIViewControllerRepresentable {
    let player:AVPlayer
    func makeUIViewController(context:Context)->AVPlayerViewController { let view=AVPlayerViewController();view.player=player;view.allowsPictureInPicturePlayback=false;return view }
    func updateUIViewController(_ view:AVPlayerViewController,context:Context) { view.player=player }
}

struct ReplayPlayerPage:View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var replays:ReplayStore
    let presentation:ReplayClipPresentation
    @StateObject private var model=ReplayPlayerModel()
    @State private var attempt=0
    private var preview:Bool {
        #if UI_PREVIEW && DEBUG
        return ReplayPreviewFixture.enabled
        #else
        return false
        #endif
    }
    var body:some View {
        NavigationView {
            VStack(alignment:.leading,spacing:20) {
                Text("演示比赛 · 视频为实拍").font(.caption).foregroundColor(Palette.muted)
                if preview {
                    if attempt==0 { Text("界面演示 · 模拟加载失败");Button("重试播放") { attempt+=1 }.accessibilityIdentifier("replay-retry") }
                    else { Text("界面演示 · 播放器状态");Text("仅验证交互，不播放真实录像").font(.caption).foregroundColor(Palette.muted) }
                } else {
                    if let player=model.player { NativeReplayPlayer(player:player).frame(maxWidth:.infinity).aspectRatio(16/9,contentMode:.fit).background(Color.black).accessibilityIdentifier("replay-player") }
                    if model.loading { ProgressView("正在加载视频…") }
                    if model.progressed { Text("实拍录像").font(.caption).accessibilityIdentifier("replay-playing") }
                    if !model.error.isEmpty { Note(text:model.error);Button("重试播放") { attempt+=1 }.buttonStyle(PrimaryStyle()).accessibilityIdentifier("replay-retry") }
                }
                Text(presentation.title).font(.headline)
                Text("比分与最后一分关联为演示设定，尚未导入视觉分析。").font(.caption).foregroundColor(Palette.muted)
                Spacer()
            }.padding(22).background(Palette.background)
                .navigationTitle("视频回放").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("关闭") { model.stop();dismiss() }.accessibilityIdentifier("replay-close") } }
        }.task(id:attempt) {
            guard !preview else { return }
            guard let context=presentation.context,context==replays.context else { dismiss();return }
            await model.load(context:context,clip:presentation.clip)
        }.onChange(of:replays.context) { context in if context != presentation.context { model.stop();dismiss() } }
        .onChange(of:scenePhase) { phase in if phase != .active { model.pause() } }
        .onDisappear { model.stop() }
    }
}

struct ReplayReferencePicker:View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var replays:ReplayStore
    let select:(CoachReference)->Void
    var body:some View {
        NavigationView {
            List {
                if replays.loading { ProgressView() }
                if !replays.error.isEmpty { Text(replays.error) }
                ForEach(replays.matches) { match in
                    Section(header:Text("演示比赛 · 不计入战绩")) {
                        Button(match.title) { select(match.reference);dismiss() }
                        ForEach(match.points) { point in Button("第三局 · 最后一分") { select(match.reference(to:point));dismiss() } }
                    }
                }
                if !replays.loading && replays.matches.isEmpty { Text("当前账号暂无可引用回放") }
            }.navigationTitle("引用比赛").toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
        }.task { await replays.refresh() }
    }
}
