import SwiftUI
import RealityKit
import Combine

/// Centimetre-scale product scene, matching the approved browser prototype.
struct RacketProductScene: UIViewRepresentable {
    var reduceMotion = false
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.965, green: 0.973, blue: 0.949, alpha: 1))
        context.coordinator.build(view, reduceMotion: reduceMotion)
        return view
    }
    func updateUIView(_ view: ARView, context: Context) { context.coordinator.reduceMotion = reduceMotion }
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) { coordinator.subscription?.cancel(); coordinator.subscription = nil }
    final class Coordinator {
        var subscription: Cancellable?
        var reduceMotion = false
        private var elapsed: Float = 0
        private let root = Entity(), racket = Entity(), camera = PerspectiveCamera()
        private func material(_ hex: UInt32, roughness: Float = 0.4, metallic: Bool = false) -> SimpleMaterial {
            SimpleMaterial(color: UIColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1), roughness: .float(roughness), isMetallic: metallic)
        }
        @discardableResult private func add(_ mesh: MeshResource, _ mat: SimpleMaterial, to parent: Entity, at position: SIMD3<Float> = .zero) -> ModelEntity {
            let entity = ModelEntity(mesh: mesh, materials: [mat]); entity.position = position; parent.addChild(entity); return entity
        }
        private func cylinder(height: Float, radius: Float) -> MeshResource {
            var vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
            func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ normal: SIMD3<Float>) {
                let i=UInt32(vertices.count); vertices += [a,b,c]; normals += [normal,normal,normal]; indices += [i,i+1,i+2]
            }
            for i in 0..<20 {
                let a=Float(i)*2*Float.pi/20, b=Float(i+1)*2*Float.pi/20
                let p=SIMD3<Float>(radius*cos(a),-height/2,radius*sin(a)), q=SIMD3<Float>(radius*cos(b),-height/2,radius*sin(b))
                let r=q+SIMD3<Float>(0,height,0), s=p+SIMD3<Float>(0,height,0), n=SIMD3<Float>(cos((a+b)/2),0,sin((a+b)/2))
                triangle(p,r,q,n); triangle(p,s,r,n)
                triangle([0,-height/2,0],p,q,[0,-1,0]); triangle([0,height/2,0],r,s,[0,1,0])
            }
            var d=MeshDescriptor(name:"Cylinder"); d.positions=MeshBuffers.Positions(vertices); d.normals=MeshBuffers.Normals(normals); d.primitives = .triangles(indices)
            return (try? MeshResource.generate(from:[d])) ?? .generateBox(size:[radius*2,height,radius*2])
        }
        private func rod(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, mat: SimpleMaterial) {
            let d = b-a
            let entity = add(cylinder(height: simd_length(d), radius: radius), mat, to: racket, at: (a+b)/2)
            entity.orientation = simd_quatf(from: SIMD3<Float>(0,1,0), to: simd_normalize(d))
        }
        private func capMesh() throws -> MeshResource {
            let outline: [SIMD2<Float>] = [[-1.35,-1.9],[1.35,-1.9],[2.1,-1.15],[2.1,1.15],[1.35,1.9],[-1.35,1.9],[-2.1,1.15],[-2.1,-1.15]]
            var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
            func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
                let normal = simd_normalize(simd_cross(b-a,c-a)), start = UInt32(positions.count)
                positions += [a,b,c]; normals += [normal,normal,normal]; indices += [start,start+1,start+2]
            }
            let heights: [Float] = [-0.92,-0.80,-0.12,0], scales: [Float] = [0.94,1,1,0.94]
            for ring in 0..<3 {
                for i in 0..<8 {
                    let j = (i+1)%8
                    let a = SIMD3<Float>(outline[i].x*scales[ring],heights[ring],outline[i].y*scales[ring])
                    let b = SIMD3<Float>(outline[j].x*scales[ring],heights[ring],outline[j].y*scales[ring])
                    let c = SIMD3<Float>(outline[j].x*scales[ring+1],heights[ring+1],outline[j].y*scales[ring+1])
                    let d = SIMD3<Float>(outline[i].x*scales[ring+1],heights[ring+1],outline[i].y*scales[ring+1])
                    triangle(a,c,b); triangle(a,d,c)
                }
            }
            for i in 0..<8 {
                let j = (i+1)%8, a = outline[i]*0.94, b = outline[j]*0.94
                triangle([0,0,0],[b.x,0,b.y],[a.x,0,a.y])
                triangle([0,-0.92,0],[a.x,-0.92,a.y],[b.x,-0.92,b.y])
            }
            var descriptor = MeshDescriptor(name: "OctagonalButtCap")
            descriptor.positions = MeshBuffers.Positions(positions); descriptor.normals = MeshBuffers.Normals(normals); descriptor.primitives = .triangles(indices)
            return try MeshResource.generate(from: [descriptor])
        }
        func build(_ view: ARView, reduceMotion: Bool) {
            self.reduceMotion = reduceMotion
            let anchor = AnchorEntity(world: .zero); view.scene.addAnchor(anchor); anchor.addChild(root); anchor.addChild(camera)
            root.addChild(racket)
            racket.scale = .one
            let cap = Entity(); cap.scale = [0.72,1,0.72]; root.addChild(cap)
            if let mesh = try? capMesh() { add(mesh,material(0xb5c9ae),to:cap) }
            add(.generateBox(size:[2.65,0.035,2.65]),material(0x1e302b),to:cap,at:[0,-0.95,0])
            let led = material(0xe1d8b6,roughness:0.5), ledMesh = MeshResource.generateBox(size:[0.235,0.025,0.235])
            for x in 0..<8 { for z in 0..<8 { add(ledMesh,led,to:cap,at:[(Float(x)-3.5)*0.305,-0.98,(Float(z)-3.5)*0.305]) } }
            add(.generateBox(size:[0.85,0.25,0.12]),material(0x25302b),to:cap,at:[0,-0.42,1.92])
            let frame = material(0xb9b7b0,roughness:0.28,metallic:true), grip = material(0x858780,roughness:0.8)
            add(cylinder(height:15,radius:1.30),grip,to:racket,at:[0,7.5,0])
            let band = material(0xb0b1a9,roughness:0.7)
            for i in 0..<18 { add(cylinder(height:0.10,radius:1.32),band,to:racket,at:[0,0.45+Float(i)*0.78,0]) }
            rod([0,15,0],[0,39,0],radius:0.23,mat:frame)
            for i in 0..<96 {
                let a=Float(i)*2*Float.pi/96, b=Float(i+1)*2*Float.pi/96
                rod([9.4*cos(a),50+12*sin(a),0],[9.4*cos(b),50+12*sin(b),0],radius:0.40,mat:frame)
            }
            let strings = material(0xd9ddd1,roughness:0.6)
            for i in -9...9 {
                let x=Float(i)*0.9, h=12*sqrt(1-x*x/(9.4*9.4))
                rod([x,50-h,0],[x,50+h,0],radius:0.025,mat:strings)
            }
            for i in -12...12 {
                let y=Float(i)*0.9, w=9.4*sqrt(1-y*y/144)
                rod([-w,50+y,0],[w,50+y,0],radius:0.025,mat:strings)
            }
            let lightPositions: [SIMD3<Float>] = [[-20,40,40],[25,-25,-25],[0,-30,30]]
            for position in lightPositions {
                let light=DirectionalLight(); light.light.intensity=2500; light.look(at:[0,20,0],from:position,relativeTo:nil); anchor.addChild(light)
            }
            pose()
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                guard let self else { return }; self.elapsed = min(6,self.elapsed+Float(event.deltaTime)); self.pose()
            }
        }
        private func smooth(_ value: Float) -> Float { let v=max(0,min(1,value)); return v*v*(3-2*v) }
        private func pose() {
            let t=reduceMotion ? 6 : elapsed, tilt=smooth((t-0.45)/1.5), entry=smooth((t-1.65)/1.9), zoom=smooth((t-1.35)/2)
            root.orientation = simd_quatf(angle:-0.12-0.45*tilt,axis:[1,0,0])*simd_quatf(angle:-0.35,axis:[0,1,0])*simd_quatf(angle:-0.18*tilt,axis:[0,0,1])
            racket.isEnabled=t>1.65; racket.position=[0,20*(1-entry),0]
            // Look from the cap toward the shaft: foreground cap, receding racket.
            let distance=18+6*zoom, target=1.5*zoom
            camera.camera.fieldOfViewInDegrees=31
            camera.look(at:[0,target,0],from:[distance*0.16,target-distance*(0.48+0.42*zoom),distance*(0.78-0.44*zoom)],relativeTo:nil)
        }
    }
}

struct RacketBLEEntryPage: View {
    @Environment(\.dismiss) private var dismiss
    let context: RacketContext?
    let preferredID: String?
    @StateObject private var local: RacketStore
    @State private var completed = false
    init(context: RacketContext?, preferredID: String? = nil) {
        self.context = context
        self.preferredID = preferredID
        let adapter = RacketBLEConnectionHub.shared.service(for:context)
        _local = StateObject(wrappedValue: RacketStore(service: adapter, bluetooth: adapter))
    }
    private var directContext: RacketContext? {
        guard var context else { return nil }; context.hostID = nil; return context
    }
    var body: some View {
        VStack(spacing: 0) {
            if preferredID != nil, directContext != nil {
                connectionCard
            } else if directContext == nil {
                SheetHeader(title: "手机直连拍底").padding()
                Text("请先完成业务账号登录，再进行设备认证。").padding()
                Spacer()
            } else {
                Text("拍底 v2 联调 · 仅限隔离测试设备").font(.caption).foregroundColor(.orange).padding()
                RacketAddPage().environmentObject(local)
            }
        }.background(Palette.background.ignoresSafeArea())
            .onAppear { local.configure(directContext,disconnect:false) }
            .task {
                guard let preferredID, directContext != nil else { return }
                local.configure(directContext,disconnect:false)
                await local.scan()
                if let nearby = local.nearby.first(where: { $0.id == preferredID }) {
                    await local.chooseNearby(nearby)
                    if local.canBind { await local.bindSelf() }
                }
                completed = true
            }
            .onChange(of: directContext) { local.configure($0) }
            .onDisappear { local.finishPresentation() }
    }
    private var connectionCard: some View {
        VStack(spacing: 15) {
            HStack { Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(Palette.muted).padding(10).background(Palette.soft).clipShape(Circle()) }.accessibilityLabel("关闭") }
            Spacer(minLength: 10)
            RacketConnectionArtwork()
            Text(connectionTitle).font(.system(size: 25, weight: .bold)).foregroundColor(Palette.ink)
            Text(connectionDetail).font(.system(size: 15)).foregroundColor(Palette.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !completed { ProgressView().tint(Palette.green).padding(.top, 8) }
            if completed { RacketDiagnosticButton() }
            if completed, let device = local.selected, let operation = local.operation(for: "device:" + device.id), operation.state.unresolved {
                Button("查询结果") { Task { await local.query(operation.id) } }.buttonStyle(PrimaryStyle())
            } else if completed {
                Button("完成") { dismiss() }.buttonStyle(PrimaryStyle())
            }
            Spacer(minLength: 20)
        }.padding(25).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
    }
    private var connectionTitle: String {
        guard completed else { return local.selected == nil ? "正在连接拍底" : "正在关联拍底" }
        guard let device = local.selected else { return "连接未完成" }
        if let op = local.operation(for: "device:" + device.id), op.state != .confirmed { return op.state.label }
        guard let owner = device.user else { return "关联未完成" }
        return owner.stableID == directContext?.userID ? "已关联到你" : "拍底已关联其他用户"
    }
    private var connectionDetail: String {
        guard completed else { return "正在验证设备身份与当前账号，请稍候。" }
        guard let device = local.selected else { return local.message.isEmpty ? "未找到刚才的拍底，请靠近设备后重试。" : local.message }
        if let op = local.operation(for: "device:" + device.id), op.state != .confirmed { return op.message.isEmpty ? op.state.label : op.message }
        guard let owner = device.user else { return local.message }
        return owner.stableID == directContext?.userID ? "使用者：\(owner.name) · 比赛换队无需重新关联" : "当前使用者：\(owner.name)。请由使用者解除关联后再连接。"
    }
}
