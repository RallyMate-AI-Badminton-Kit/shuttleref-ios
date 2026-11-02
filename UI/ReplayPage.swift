import SwiftUI
import AVKit

struct ReplayRecordsSection:View {
    @EnvironmentObject private var replays:ReplayStore
    @State private var selected:ReplayMatch?
    @State private var pendingReference:CoachReference?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("比赛回放").font(.title2.bold());Spacer();if replays.context != nil { Button("刷新回放") { Task { await replays.refresh() } }.font(.caption).disabled(replays.loading) } }
            if replays.loading { ProgressView("正在读取回放…") }
            if !replays.error.isEmpty { Note(text:replays.error) }
            if replays.context==nil { Text("登录后查看当前账号的回放").font(.subheadline).foregroundColor(Palette.muted) }
            ForEach(replays.matches.filter { !$0.points.isEmpty }.sorted { $0.played_at > $1.played_at }) { match in
                Button { selected=match } label: {
                    VStack(alignment:.leading,spacing:12) {
                        HStack { Text(match.title).font(.headline);Spacer();Text("回放").font(.caption.bold()).foregroundColor(Palette.green) }
                        HStack {
                            Text(match.mode=="singles" ? "单打" : "双打").font(.caption).foregroundColor(Palette.muted)
                            Spacer()
                            Text("\(match.result.red_games) : \(match.result.blue_games)").font(.title2.bold().monospacedDigit())
                            Text(match.result.winner_side==match.participants.first(where: { $0.user_id==match.owner_id })?.side ? "胜" : "负").font(.headline)
                        }
                        Text(match.games.map { "\($0.red):\($0.blue)" }.joined(separator:"  ·  ")).font(.subheadline)
                        Text(match.points.isEmpty ? "比分记录 · 无录像" : "第三局最后一分 · 可回放").font(.caption).foregroundColor(Palette.muted)
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color.white).cornerRadius(20)
                }.buttonStyle(.plain).accessibilityIdentifier("replay-demo-match")
            }
            if replays.context != nil && !replays.loading && replays.error.isEmpty && replays.matches.isEmpty { Text("当前账号暂无回放").font(.caption).foregroundColor(Palette.muted) }
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
    @State private var celebration:MatchCelebration?
    var body:some View {
        NavigationView {
            ScrollView { VStack(alignment:.leading,spacing:22) {
                Text(match.title).font(.title2.bold())
                HStack(alignment:.top) {
                    team("red",title:"红方")
                    VStack(spacing:5) { Text("\(match.result.red_games) : \(match.result.blue_games)").font(.system(size:36,weight:.bold,design:.rounded));Text("局数").font(.caption).foregroundColor(Palette.muted) }
                    team("blue",title:"蓝方")
                }.padding(20).background(Palette.soft).cornerRadius(22)
                ForEach(match.games) { game in HStack { Text("第 \(game.number) 局");Spacer();Text("\(game.red) : \(game.blue)").font(.headline.monospacedDigit()) } }
                if let mvp=match.demo_mvp {
                    Button {
                        celebration=MatchCelebration(player:mvp.name,
                            scores:[0,0,UInt8(clamping:match.result.red_games),UInt8(clamping:match.result.blue_games)],
                            early:false,storage:"本场 MVP")
                    } label: { HStack(spacing:16) {
                        Image(systemName:"star.circle.fill").font(.system(size:40)).foregroundColor(Palette.green)
                        VStack(alignment:.leading,spacing:6) {
                            Text("本场 MVP").font(.caption).foregroundColor(Palette.muted)
                            Text(mvp.name).font(.title2.bold())
                            Text(mvp.reason).font(.caption).foregroundColor(Palette.muted)
                            Label("查看 MVP 结算",systemImage:"play.circle.fill").font(.subheadline).foregroundColor(Palette.green)
                        }
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color.white).cornerRadius(20)
                    }.buttonStyle(.plain).accessibilityIdentifier("replay-mvp-settlement")
                }
                if let player=match.demo_shot_stats?.first(where: { $0.participant_id == match.demo_mvp?.participant_id }) ?? match.demo_shot_stats?.first {
                    ReplayShotDashboard(player:player)
                }
                if let events=match.demo_timeline,!events.isEmpty {
                    Text("比赛进程").font(.title2.bold())
                    if let duration=match.demo_duration_seconds {
                        Text("比赛时长 \(duration/60) 分 \(duration%60) 秒 · 共 \(events.count) 分").font(.subheadline).foregroundColor(Palette.muted)
                    }
                    ForEach(match.games) { game in
                        DisclosureGroup("第 \(game.number) 局 · \(game.red) : \(game.blue)") {
                            LazyVStack(spacing:12) {
                                ForEach(events.filter { $0.game_number==game.number }) { event in
                                    HStack {
                                        VStack(alignment:.leading,spacing:4) {
                                            Text("第 \(event.point_number) 分 · \(event.winner_side=="red" ? "红方" : "蓝方")得分").font(.caption)
                                            Text("\(event.red) : \(event.blue)").font(.headline.monospacedDigit())
                                        }
                                        Spacer()
                                        Text(String(format:"%02d:%02d",event.elapsed_seconds/60,event.elapsed_seconds%60)).font(.caption.monospacedDigit()).foregroundColor(Palette.muted)
                                    }
                                }
                            }.padding(.vertical,12)
                        }.padding(16).background(Color.white).cornerRadius(16)
                    }
                }
                if !match.points.isEmpty { Button("引用这场问教练") { ask(match.reference) }.buttonStyle(PrimaryStyle()).accessibilityIdentifier("replay-ask-match") }
                Divider()
                ForEach(match.points) { point in
                    VStack(alignment:.leading,spacing:15) {
                        Text("第三局 · 最后一分").font(.title2.bold())
                        Text("\(point.before.red) : \(point.before.blue) → \(point.after.red) : \(point.after.blue)").font(.title3.monospacedDigit())
                        Text("红方取得最后一分").font(.caption).foregroundColor(Palette.muted)
                        Button { clip=ReplayClipPresentation(clip:point.video.reference,title:"第三局 · 最后一分",context:replays.context) } label: {
                            Label("播放这一分的视频 · 48.66 秒",systemImage:"play.circle.fill").frame(maxWidth:.infinity).padding(.vertical,14)
                        }.background(Palette.soft).cornerRadius(15).accessibilityIdentifier("replay-play-final")
                        Button("引用这一分问教练") { ask(match.reference(to:point)) }.font(.subheadline.weight(.semibold)).frame(minHeight:44).accessibilityIdentifier("replay-ask-point")
                    }
                }
            }.padding(22) }.background(Palette.background)
            .navigationTitle(match.points.isEmpty ? "比赛回顾" : "比赛回放").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.fullScreenCover(item:$clip) { item in ReplayPlayerPage(presentation:item).environmentObject(replays) }
        .fullScreenCover(item:$celebration) { result in PortraitMVPView(result:result) }
        .onChange(of:replays.context) { _ in clip=nil;celebration=nil;dismiss() }
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
                Text("比赛视频").font(.caption).foregroundColor(Palette.muted)
                if preview {
                    if attempt==0 { Text("视频加载失败");Button("重试播放") { attempt+=1 }.accessibilityIdentifier("replay-retry") }
                    else { Text("播放器状态");Text("仅验证交互，不播放真实录像").font(.caption).foregroundColor(Palette.muted) }
                } else {
                    if let player=model.player { NativeReplayPlayer(player:player).frame(maxWidth:.infinity).aspectRatio(16/9,contentMode:.fit).background(Color.black).accessibilityIdentifier("replay-player") }
                    if model.loading { ProgressView("正在加载视频…") }
                    if model.progressed { Text("实拍录像").font(.caption).accessibilityIdentifier("replay-playing") }
                    if !model.error.isEmpty { Note(text:model.error);Button("重试播放") { attempt+=1 }.buttonStyle(PrimaryStyle()).accessibilityIdentifier("replay-retry") }
                }
                Text(presentation.title).font(.headline)
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
                ForEach(replays.matches.filter { !$0.points.isEmpty }) { match in
                    Section(header:Text("比赛回放")) {
                        Button(match.title) { select(match.reference);dismiss() }
                        ForEach(match.points) { point in Button("第三局 · 最后一分") { select(match.reference(to:point));dismiss() } }
                    }
                }
                if !replays.loading && replays.matches.isEmpty { Text("当前账号暂无可引用回放") }
            }.navigationTitle("引用比赛").toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
        }.task { await replays.refresh() }
    }
}

private struct ReplayShotDashboard: View {
    let player: ReplayShotStats
    @State private var selected: String?
    private let colors: [Color] = [Palette.green, Color(hex:0x78a692), Color(hex:0x98b8c6), Color(hex:0xc4aa78), Color(hex:0xa9b58c), Color(hex:0xd1cec2)]
    private var maximum: Int { max(1, player.shots.map(\.count).max() ?? 1) }
    private var focused: ReplayShotCount? { player.shots.first { $0.type == selected } }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { VStack(alignment:.leading,spacing:5) { Text("击球分析").font(.title2.bold());Text(player.name).font(.subheadline).foregroundColor(Palette.muted) };Spacer();Text("\(player.total) 次").font(.title2.bold().monospacedDigit()) }
            LazyVGrid(columns:[GridItem(.flexible(),spacing:12),GridItem(.flexible(),spacing:12)],spacing:12) {
                tile("击球类型") { radar.frame(height:150) }
                tile("类型占比") {
                    ZStack {
                        ForEach(Array(player.shots.enumerated()),id:\.offset) { index,shot in
                            let start=Double(player.shots.prefix(index).reduce(0) { $0+$1.count })/Double(max(1,player.total))
                            let end=start+Double(shot.count)/Double(max(1,player.total))
                            Circle().trim(from:start,to:max(start,end-0.008)).stroke(colors[index % colors.count],style:StrokeStyle(lineWidth:16)).rotationEffect(.degrees(-90))
                        }
                        VStack(spacing:4) { Text(focused.map { "\(Int((Double($0.count)/Double(max(1,player.total))*100).rounded()))%" } ?? "\(player.shots.count)").font(.title.bold());Text(focused?.type ?? "击球类型").font(.caption).foregroundColor(Palette.muted) }
                    }.padding(22).frame(height:150)
                }
                tile("击球分布") {
                    VStack(spacing:10) {
                        ForEach(Array(player.shots.enumerated()),id:\.offset) { index,shot in
                            VStack(spacing:3) {
                                HStack { Text(shot.type);Spacer();Text("\(shot.count)").monospacedDigit() }.font(.system(size:10))
                                GeometryReader { g in ZStack(alignment:.leading) { Capsule().fill(Palette.soft);Capsule().fill(colors[index % colors.count]).frame(width:g.size.width*CGFloat(shot.count)/CGFloat(maximum)) } }.frame(height:5)
                            }
                        }
                    }.frame(height:180)
                }
                tile("本场表现") {
                    VStack(alignment:.leading,spacing:17) {
                        metric("累计击球",value:"\(player.total)",unit:"次")
                        metric("最常使用",value:player.shots.max(by:{$0.count<$1.count})?.type ?? "—",unit:"")
                        metric("杀球次数",value:"\(player.shots.first(where:{$0.type=="杀球"})?.count ?? 0)",unit:"次")
                    }.frame(maxWidth:.infinity,alignment:.leading).frame(height:180)
                }
            }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:8) {
                    ForEach(Array(player.shots.enumerated()),id:\.offset) { index,shot in
                        Button { selected = selected == shot.type ? nil : shot.type } label: {
                            HStack(spacing:5) { Circle().fill(colors[index % colors.count]).frame(width:7,height:7);Text(shot.type) }.font(.caption).padding(.horizontal,11).padding(.vertical,9).background(selected==shot.type ? Palette.soft : Color.white).clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.accessibilityIdentifier("replay-shot-dashboard")
    }
    private func tile<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:8) { Text(title).font(.system(size:13,weight:.semibold));content() }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.white).cornerRadius(18)
    }
    private func metric(_ label:String,value:String,unit:String)->some View {
        VStack(alignment:.leading,spacing:3) { Text(label).font(.caption).foregroundColor(Palette.muted);HStack(alignment:.firstTextBaseline,spacing:4) { Text(value).font(.system(size:25,weight:.bold,design:.rounded)).minimumScaleFactor(0.65).lineLimit(1);Text(unit).font(.caption) } }
    }
    private var radar: some View {
        Canvas { ctx,size in
            let count=player.shots.count
            guard count>=3 else { return }
            let center=CGPoint(x:size.width/2,y:size.height/2)
            let radius=max(1,min(size.width,size.height)/2-26)
            func point(_ index:Int,_ scale:Double)->CGPoint {
                let angle=Double(index)*2*Double.pi/Double(count)-Double.pi/2
                return CGPoint(x:center.x+CGFloat(cos(angle)*scale)*radius,y:center.y+CGFloat(sin(angle)*scale)*radius)
            }
            for level in 1...4 {
                var polygon=Path();polygon.move(to:point(0,Double(level)/4))
                for i in 1..<count { polygon.addLine(to:point(i,Double(level)/4)) };polygon.closeSubpath()
                ctx.stroke(polygon,with:.color(Palette.green.opacity(0.12)),lineWidth:1)
            }
            var shape=Path()
            for i in 0..<count {
                var axis=Path();axis.move(to:center);axis.addLine(to:point(i,1));ctx.stroke(axis,with:.color(Palette.green.opacity(0.12)),lineWidth:1)
                let p=point(i,Double(player.shots[i].count)/Double(maximum))
                if i==0 { shape.move(to:p) } else { shape.addLine(to:p) }
                ctx.draw(Text(player.shots[i].type).font(.system(size:9)).foregroundColor(Palette.muted),at:point(i,1.4))
            }
            shape.closeSubpath();ctx.fill(shape,with:.color(Palette.green.opacity(0.2)));ctx.stroke(shape,with:.color(Palette.green),lineWidth:2)
        }.accessibilityLabel("\(player.name)的击球类型雷达图")
    }
}
