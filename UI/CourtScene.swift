import SwiftUI

private struct CourtMotionSample: Equatable {
    var scores: [UInt8]?
    var context: String
    var enabled: Bool
    var active: Bool
}

// Home/setup are strictly planar. Keep actor 0 mounted with the same identity:
// the small home ball grows and travels into the near court as the rectangle expands.
// Perspective, slab depth and the raised net belong exclusively to live play.
struct CourtScene: View {
    var live: Bool
    var compact: Bool
    var doubles: Bool
    var names: [String]
    var scores: [UInt8]?
    var scoreContext: String
    var scoreEventsEnabled: Bool
    var visible: Bool
    var actionable: Bool
    var tap: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var previous: CourtMotionSample?
    @State private var pulses: [Date?] = [nil,nil]
    @State private var deltas = [0,0]
    private var moving: Bool { visible && live && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:!moving)) { clock in
            GeometryReader { geo in
                scene(size:geo.size, date:clock.date)
            }
        }
        .onAppear { previous = sample }
        .onChange(of:sample) { new in observe(new) }
        .onDisappear { previous = nil; pulses = [nil,nil] }
    }
    private var sample: CourtMotionSample {
        CourtMotionSample(scores:scores,context:scoreContext,enabled:scoreEventsEnabled,active:moving)
    }
    private func observe(_ new: CourtMotionSample) {
        defer { previous = new }
        guard let old = previous, new.active, old.active, new.enabled, old.enabled,
              old.context == new.context else { pulses = [nil,nil]; return }
        guard let before = old.scores, let after = new.scores, before.count >= 2, after.count >= 2 else { return }
        let changes = [Int(after[0])-Int(before[0]),Int(after[1])-Int(before[1])]
        // One confirmed point/undo; restored, reset and multi-point totals don't celebrate.
        guard changes.filter({ $0 != 0 }).count == 1 else { return }
        for side in 0..<2 where abs(changes[side]) == 1 {
            deltas[side] = changes[side]; pulses[side] = Date()
        }
    }
    private func progress(_ side: Int, _ date: Date) -> Double {
        guard moving, let start = pulses[side] else { return 1 }
        return min(1,max(0,date.timeIntervalSince(start)/0.8))
    }
    private func scene(size: CGSize, date: Date) -> some View {
        CourtArtwork(expansion:compact ? 0:1, elevation:live ? 1:0, division:doubles ? 1:0,
                     availableWidth:size.width, names:names, scores:scores, deltas:deltas,
                     pulse:[progress(0,date),progress(1,date)],
                     breath:moving ? (1-cos(date.timeIntervalSinceReferenceDate*2*Double.pi/3.8))/2:0,
                     live:live, compact:compact, doubles:doubles, actionable:actionable, tap:tap)
            .animation(reduceMotion ? nil:.timingCurve(0.22,0.8,0.24,1,duration:0.95),value:compact)
            .animation(reduceMotion ? nil:.timingCurve(0.22,0.8,0.24,1,duration:0.95),value:live)
            .animation(reduceMotion ? nil:.timingCurve(0.4,0,0.2,1,duration:0.95),value:doubles)
    }
}

// One interpolated model drives the deck and the persistent player spheres.
// No matched copies, transitions or view replacement are involved.
private struct CourtArtwork: View, Animatable {
    var expansion: Double
    var elevation: Double
    var division: Double
    let availableWidth: CGFloat
    let names: [String]
    let scores: [UInt8]?
    let deltas: [Int]
    let pulse: [Double]
    let breath: Double
    let live: Bool
    let compact: Bool
    let doubles: Bool
    let actionable: Bool
    let tap: (Int) -> Void
    var animatableData: AnimatablePair<Double,AnimatablePair<Double,Double>> {
        get { .init(expansion,.init(elevation,division)) }
        set { expansion = newValue.first; elevation = newValue.second.first; division = newValue.second.second }
    }
    private var w: CGFloat { min(260,availableWidth)+(availableWidth-min(260,availableWidth))*expansion }
    private var h: CGFloat { 300+65*expansion+90*elevation }
    private var split: Double { division*expansion }
    private var camera: CourtCamera { CourtCamera(width:w,height:h,viewportWidth:availableWidth,lift:elevation) }
    private func blend(_ a: Double,_ b: Double,_ t: Double) -> Double { a+(b-a)*t }
    private func center(_ side: Int) -> CGPoint {
        let y = side == 0 ? blend(0.27,blend(0.72,0.83,elevation),expansion) : blend(-0.08,blend(0.31,0.27,elevation),expansion)
        return CGPoint(x:side == 0 ? blend(0.64,0.5,expansion):0.5,y:y)
    }
    var body: some View {
        ZStack(alignment:.topLeading) {
            ground
            ForEach(0..<4) { index in actor(index) }
            ForEach(0..<2) { side in score(side) }
            CourtNet(camera:camera).allowsHitTesting(false).accessibilityHidden(true)
            Text("21 分 · 三局两胜").font(.system(size:12,weight:.medium))
                .padding(.horizontal,12).padding(.vertical,7)
                .background(Color(hex:0xe6eddc).opacity(0.96)).cornerRadius(5)
                .opacity(expansion*(1-elevation)).position(camera.point(x:w/2,y:h/2+18))
                .accessibilityHidden(compact || live)
        }.frame(width:availableWidth,height:h)
    }
    private var ground: some View {
        Canvas { ctx,_ in
            let corners = [(0.0,0.0),(w,0.0),(w,h),(0.0,h)]
            let deck = polygon(corners.map { camera.point(x:$0.0,y:$0.1) })
            if elevation > 0 {
                let side = polygon([camera.point(x:0,y:h),camera.point(x:w,y:h),camera.point(x:w,y:h,z:-9*elevation),camera.point(x:0,y:h,z:-9*elevation)])
                ctx.fill(side,with:.color(Color(hex:0xa9bca0)))
            }
            ctx.fill(deck,with:.linearGradient(Gradient(colors:[Color(hex:0xeaf2e1),Color(hex:0xd1dfbf)]),startPoint:camera.point(x:0,y:0),endPoint:camera.point(x:w,y:h)))
            ctx.stroke(deck,with:.color(Color(hex:0xacbea1)),lineWidth:1.4)
            var lines = Path()
            func line(_ x1:Double,_ y1:Double,_ x2:Double,_ y2:Double) {
                lines.move(to:camera.point(x:w*x1,y:h*y1)); lines.addLine(to:camera.point(x:w*x2,y:h*y2))
            }
            line(0.07,0.05,0.93,0.05);line(0.93,0.05,0.93,0.95);line(0.93,0.95,0.07,0.95);line(0.07,0.95,0.07,0.05)
            line(0.5,0,0.5,1);line(0,0.29,1,0.29);line(0,0.71,1,0.71)
            ctx.stroke(lines,with:.color(.white.opacity(0.68)),lineWidth:1)
            var middle = Path();middle.move(to:camera.point(x:0,y:h/2));middle.addLine(to:camera.point(x:w,y:h/2))
            ctx.stroke(middle,with:.color(Color(hex:0x66895c).opacity(1-0.75*elevation)),lineWidth:2)
            for side in 0..<2 where deltas[side] > 0 && pulse[side] < 1 {
                let p = pulse[side]; let strength = p < 0.2 ? p/0.2:(1-p)/0.8
                let point = camera.point(x:w/2,y:h*(side == 0 ? 0.75:0.25))
                var glow = ctx;glow.clip(to:deck)
                glow.fill(Path(ellipseIn:CGRect(x:point.x-w/2,y:point.y-h/4,width:w,height:h/2)),with:.radialGradient(Gradient(colors:[Color(hex:side == 0 ? 0xd9f6a6:0xc7e6f3).opacity(strength*0.8),.clear]),center:point,startRadius:0,endRadius:w*0.5))
            }
        }.shadow(color:Palette.green.opacity(elevation*0.15),radius:18*elevation,x:0,y:20*elevation)
    }
    private func actor(_ index: Int) -> some View {
        let side = index/2, teammate = index%2 == 1
        let c = center(side)
        let point = camera.point(x:w*(c.x+(teammate ? 0.22: -0.22*split)),y:h*c.y)
        let depthScale = camera.scale(y:h*c.y)
        let diameter = (16+38*expansion)*depthScale
        let teammateScale = teammate ? 0.9+0.1*split:1
        let p = pulse[side]
        let hop = deltas[side] > 0 ? (p < 0.66 ? 24*sin(p/0.66*Double.pi):5*sin((p-0.66)/0.34*Double.pi)):0
        let bob = breath*3
        let opacity = (side == 0 ? 1:expansion)*(teammate ? split:1)
        let hidden = compact || (teammate && !doubles)
        return Button { if actionable && !hidden { tap(index) } } label: {
            ZStack {
                Ellipse().fill(Palette.green.opacity(0.18)).frame(width:diameter*0.85,height:9*depthScale)
                    .scaleEffect(1-breath*0.12-hop/100).offset(y:diameter/2+3).opacity(expansion)
                Circle().fill(RadialGradient(colors:side == 0 ? [Color(hex:0xb4c99f),Color(hex:0x688a5a)] : [Color(hex:0xb5ccd4),Palette.blue],center:.init(x:0.3,y:0.2),startRadius:0,endRadius:diameter))
                    .overlay(Text(String(names[index].prefix(1))).font(.system(size:23,weight:.medium)).foregroundColor(.white).opacity(expansion*(1-elevation)*(teammate ? min(1,split*2):1)))
                    .frame(width:diameter,height:diameter)
                    .background(Circle().fill(Color(hex:0xdbe8cc)).padding(-9*(1-expansion)).opacity(1-expansion))
                    .shadow(color:Palette.ink.opacity(0.13),radius:4,x:0,y:5)
                    .scaleEffect(teammateScale)
                    .offset(y:-hop-bob)
                Text(names[index]+(live ? "":" · 编辑")).font(.system(size:12,weight:.medium)).lineLimit(1)
                    .padding(.horizontal,9).padding(.vertical,5).background(Palette.background.opacity(0.94)).clipShape(Capsule())
                    .opacity(expansion*(teammate ? max(0,(split-0.55)/0.45):1))
                    // Keep names below their players, clear of the score above and the net.
                    // Names stay grounded while the ball celebrates a point.
                    .offset(y:blend(46,side == 0 ? 40:36,elevation))
                    .accessibilityIdentifier("court-player-name-\(index)")
            }.foregroundColor(Palette.green).frame(width:availableWidth*0.43,height:100).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!actionable).position(point).opacity(opacity)
            .allowsHitTesting(actionable && !hidden).accessibilityHidden(hidden)
            .accessibilityLabel(live ? "\(side == 0 ? "红方":"蓝方")加一分":"编辑\(names[index])")
    }
    private func score(_ side: Int) -> some View {
        let p = pulse[side], reveal = min(1,p*2)
        let point = camera.point(x:w/2,y:h*(side == 0 ? 0.65:0.10))
        return ZStack(alignment:.topLeading) {
            Text(scores.map{String($0[side])} ?? "—").font(.system(size:78,weight:.bold,design:.rounded)).monospacedDigit()
                .opacity(0.25+reveal*0.75).offset(y:(1-reveal)*20*Double(deltas[side] >= 0 ? 1:-1))
                .position(point).accessibilityIdentifier("court-score-\(side)")
            Text(deltas[side] > 0 ? "+1":"−1").font(.system(size:22,weight:.semibold,design:.rounded))
                .opacity(1-p).position(x:point.x+64,y:point.y-10-p*24).accessibilityHidden(true)
        }.foregroundColor(side == 0 ? Palette.green:Palette.blue).opacity(elevation)
            .allowsHitTesting(false).accessibilityHidden(!live)
    }
}

private func polygon(_ points:[CGPoint]) -> Path {
    Path { p in guard let first = points.first else { return };p.move(to:first);for point in points.dropFirst() { p.addLine(to:point) };p.closeSubpath() }
}

// Ground and vertical objects share a single camera. z is height above the court,
// not a screen-space offset: net tops are closer to the camera than their feet.
private struct CourtCamera {
    let width:CGFloat, height:CGFloat, viewportWidth:CGFloat, lift:Double
    private var angle:Double { lift*28*Double.pi/180 }
    // Extend only the far half as the camera lifts; net and near court stay anchored.
    private func groundDepth(_ y:CGFloat) -> CGFloat {
        let distance = y-height/2
        return distance < 0 ? distance*(1+0.28*lift):distance
    }
    func scale(y:CGFloat,z:CGFloat = 0) -> CGFloat {
        let depth = groundDepth(y)*sin(angle)+z*cos(angle)
        return (1-0.12*lift)*1100/(1100-depth)
    }
    func point(x:CGFloat,y:CGFloat,z:CGFloat = 0) -> CGPoint {
        let scale = scale(y:y,z:z)
        return CGPoint(x:viewportWidth/2+(x-width/2)*scale,y:height/2+(groundDepth(y)*cos(angle)-z*sin(angle))*scale)
    }
}

private struct CourtNet: View {
    let camera:CourtCamera
    var body: some View {
        Canvas { ctx,_ in
            let w = camera.width, y = camera.height/2, e = camera.lift
            guard e > 0.001 else { return }
            let left = w*0.025, right = w*0.975
            func top(_ t:Double)->CGPoint { camera.point(x:left+(right-left)*t,y:y,z:(98-5*sin(t*Double.pi))*e) }
            func bottom(_ t:Double)->CGPoint { camera.point(x:left+(right-left)*t,y:y,z:(34-3*sin(t*Double.pi))*e) }
            // Soft cast shadow lies ON the ground, with the same perspective as court lines.
            var shadow = ctx;shadow.addFilter(.blur(radius:3))
            shadow.fill(polygon([camera.point(x:left,y:y+5),camera.point(x:right,y:y+5),camera.point(x:right+6,y:y+28*e),camera.point(x:left+6,y:y+28*e)]),with:.color(Palette.green.opacity(0.13*e)))
            var face = Path();face.move(to:top(0))
            for i in 1...40 { face.addLine(to:top(Double(i)/40)) }
            for i in (0...40).reversed() { face.addLine(to:bottom(Double(i)/40)) };face.closeSubpath()
            ctx.fill(face,with:.color(Color(hex:0x3d554c).opacity(0.08*e)))
            var mesh = Path()
            for i in 0...38 { let t = Double(i)/38;mesh.move(to:top(t));mesh.addLine(to:bottom(t)) }
            for row in 1...5 {
                let v = Double(row)/6
                for i in 0...40 {
                    let t = Double(i)/40
                    let a = top(t), b = bottom(t)
                    let p = CGPoint(x:a.x+(b.x-a.x)*v,y:a.y+(b.y-a.y)*v)
                    if i == 0 { mesh.move(to:p) } else { mesh.addLine(to:p) }
                }
            }
            ctx.stroke(mesh,with:.color(Color(hex:0x344c43).opacity(0.48*e)),lineWidth:0.55)
            var band = Path();band.move(to:top(0));for i in 1...40 { band.addLine(to:top(Double(i)/40)) }
            ctx.stroke(band,with:.color(Color(hex:0x83948a).opacity(e)),lineWidth:4.5)
            ctx.stroke(band,with:.color(Color(hex:0xfffff5).opacity(e)),lineWidth:3)
            var lower = Path();lower.move(to:bottom(0));for i in 1...40 { lower.addLine(to:bottom(Double(i)/40)) }
            ctx.stroke(lower,with:.color(Color(hex:0x52665a).opacity(0.7*e)),lineWidth:1)
            for x in [left,right] {
                let foot = camera.point(x:x,y:y), cap = camera.point(x:x,y:y,z:104*e)
                ctx.fill(Path(ellipseIn:CGRect(x:foot.x-7,y:foot.y-2,width:14,height:5)),with:.color(Palette.green.opacity(0.2*e)))
                var post = Path();post.move(to:foot);post.addLine(to:cap)
                ctx.stroke(post,with:.linearGradient(Gradient(colors:[Color(hex:0x718478),Color(hex:0x344e43)]),startPoint:cap,endPoint:foot),style:StrokeStyle(lineWidth:4,lineCap:.round))
                var highlight = Path();highlight.move(to:CGPoint(x:foot.x-0.8,y:foot.y));highlight.addLine(to:CGPoint(x:cap.x-0.8,y:cap.y))
                ctx.stroke(highlight,with:.color(.white.opacity(0.55*e)),lineWidth:0.8)
            }
        }.opacity(camera.lift)
    }
}
