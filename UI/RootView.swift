import SwiftUI
import CoreBluetooth

/// Foreground discovery only. A BLE advertisement is never an ownership proof.
@MainActor final class NearbyRacketPrompt: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published var candidate: RacketNearby?
    private var central: CBCentralManager?
    var context: RacketContext?
    private var enabled = false
    private var dismissedUntil = Date.distantPast
    func update(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { central?.stopScan(); candidate = nil; return }
        guard CBManager.authorization == .allowedAlways else { return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        startIfPossible()
    }
    func dismiss() {
        candidate = nil
        dismissedUntil = Date().addingTimeInterval(120)
        central?.stopScan()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            self?.startIfPossible()
        }
    }
    private func startIfPossible() {
        guard enabled, candidate == nil, Date() >= dismissedUntil, central?.state == .poweredOn else { return }
        central?.scanForPeripherals(withServices: [CBUUID(string: RacketBLEWireV2.service)])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startIfPossible() }
        else { central.stopScan(); candidate = nil }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let context, KnownRacketRegistry.isKnown(peripheral:peripheral.identifier.uuidString,context:context) { return }
        guard enabled, candidate == nil, Date() >= dismissedUntil, RSSI.intValue != 127, RSSI.intValue >= -65 else { return }
        central.stopScan()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            candidate = RacketNearby(id: peripheral.identifier.uuidString, label: peripheral.name ?? "附近拍底")
        }
    }
}

struct RacketConnectionArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RacketProductScene(reduceMotion: reduceMotion)
            .frame(maxWidth: .infinity).frame(height: 260)
            .allowsHitTesting(false)
            .accessibilityLabel("羽毛球拍与拍底三维连接动画")
    }
}

private struct NearbyRacketCard: View {
    let device: RacketNearby
    let context: RacketContext?
    let close: () -> Void
    @StateObject private var local: RacketStore
    @State private var started = false
    @State private var finished = false
    @State private var archive = false
    @State private var modeConfiguration = false
    init(device: RacketNearby, context: RacketContext?, close: @escaping () -> Void) {
        self.device = device; self.context = context; self.close = close
        let adapter = RacketBLEConnectionHub.shared.service(for:context)
        _local = StateObject(wrappedValue: RacketStore(service: adapter, bluetooth: adapter))
    }
    private var directContext: RacketContext? {
        guard var context else { return nil }; context.hostID = nil; return context
    }
    private var operation: RacketOperation? {
        guard let selected = local.selected else { return nil }
        return local.operation(for: "device:" + selected.id)
    }
    private var title: String {
        if !started { return "发现附近拍底" }
        if !finished { return local.selected == nil ? "正在连接拍底" : "正在关联拍底" }
        if let operation, operation.state != .confirmed { return operation.state.label }
        if let owner = local.selected?.user { return owner.stableID == context?.userID ? "已关联到你" : "拍底已有使用者" }
        return "连接未完成"
    }
    private var detail: String {
        if !started { return "连接后验证设备，并关联到当前账号" }
        if !finished { return "请保持拍底在附近，正在确认连接。" }
        if let operation, operation.state != .confirmed { return operation.message.isEmpty ? operation.state.label : operation.message }
        if let owner = local.selected?.user { return "当前使用者：" + owner.name }
        return local.message.isEmpty ? "未找到拍底，请靠近后重新连接。" : local.message
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(Palette.muted).padding(10).background(Palette.soft).clipShape(Circle()) }.accessibilityLabel("关闭附近拍底提示") }
            RacketConnectionArtwork()
            Text(title).font(.system(size: 23, weight: .bold)).foregroundColor(Palette.ink)
            Text(device.label).font(.system(size: 14, weight: .medium)).foregroundColor(Palette.muted).padding(.top, 6)
            Text(detail).font(.system(size: 13)).foregroundColor(Palette.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if finished { HStack { RacketDiagnosticButton(); Button("回执维护") { archive = true }; Button("计分主机") { modeConfiguration = true } }.padding(.top,12) }
            if started && !finished {
                ProgressView().tint(Palette.green).frame(height: 50).padding(.top, 14)
            } else if let operation, operation.state.unresolved {
                Button("查询结果") { Task { await local.query(operation.id) } }.buttonStyle(PrimaryStyle()).padding(.top, 22)
            } else if finished {
                Button("完成", action: close).buttonStyle(PrimaryStyle()).padding(.top, 22)
            } else {
                Button("连接拍底") { started = true }.buttonStyle(PrimaryStyle()).padding(.top, 22)
            }
        }.padding(22).padding(.bottom, 8).frame(maxWidth: 420)
            .background(Palette.background).clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 25, y: 12)
            .task(id: started) {
                guard started, !finished, let directContext else { return }
                local.configure(directContext,disconnect:false)
                await local.scan()
                guard !Task.isCancelled, local.context == directContext else { return }
                if let nearby = local.nearby.first(where: { $0.id == device.id }) {
                    await local.chooseNearby(nearby)
                    guard !Task.isCancelled, local.context == directContext else { return }
                    if local.canBind { await local.bindSelf() }
                }
                finished = true
            }
            .sheet(isPresented:$archive) { RacketArchivePage(context:directContext) }
            .sheet(isPresented:$modeConfiguration) { RacketModePage(context:directContext) }
            .onChange(of: context) { _ in local.configure(nil); close() }
            .onDisappear { local.finishPresentation() }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var replays:ReplayStore
    init() {
        #if UI_PREVIEW && DEBUG
        _replays=StateObject(wrappedValue:ReplayPreviewFixture.enabled ? ReplayPreviewFixture.makeStore() : ReplayStore())
        #else
        _replays=StateObject(wrappedValue:ReplayStore())
        #endif
    }
    private var replayContext:CoachContext? {
        #if UI_PREVIEW && DEBUG
        if ReplayPreviewFixture.enabled { return CoachPreviewFixture.context }
        #endif
        guard social.verifiedBusiness,let credentials=social.credentials else { return nil }
        return CoachContext(origin:social.origin,userID:credentials.user.id,token:credentials.token)
    }
    @StateObject private var social = GatheringStore()
    @StateObject private var rackets = RacketStore()
    private var racketContext: RacketContext? {
        guard social.verifiedBusiness, let credentials = social.credentials else { return nil }
        return RacketContext(origin: social.origin, userID: credentials.user.id, token: credentials.token, hostID: store.selected?.id, userName: credentials.user.name)
    }
    @StateObject private var clipboardInvites = ClipboardInvitationMonitor()
    @StateObject private var nearbyRackets = NearbyRacketPrompt()
    @State private var gatherings = false
    @State private var tab = 0
    @State private var devices = false
    @State private var focused = false
    #if UI_PREVIEW && DEBUG
    @State private var racketDemo = false
    #endif
    @State private var resumeRequest = UUID()
    private let labels = ["球局", "战绩", "教练", "我的"]
    private let icons = ["sportscourt", "chart.bar.xaxis", "sparkles", "person.crop.circle"]
    var body: some View {
        VStack(spacing: 0) {
            #if UI_PREVIEW
            Text("界面预览 · 不连接设备").font(.system(size: 10)).foregroundColor(Palette.muted).padding(.top, 4)
            #endif
            ZStack {
                CourtPage(focused: $focused, visible: tab == 0 && !devices, resumeRequest: resumeRequest, openDevices: { devices = true }, openRecords: { tab = 1 }, openGatherings: { gatherings = true }).opacity(tab == 0 ? 1 : 0).allowsHitTesting(tab == 0).accessibilityHidden(tab != 0)
                if tab == 1 { RecordsPage(openMatch: { resumeRequest = UUID(); tab = 0 }) }
                if tab == 2 { CoachPage() }
                if tab == 3 { ProfilePage(openGatherings: { gatherings = true }, openDevices: { devices = true }) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !(tab == 0 && focused) {
                HStack(spacing: 7) {
                    ForEach(0..<4) { index in
                        Button { tab = index } label: {
                            VStack(spacing: 5) { Image(systemName: icons[index]).font(.system(size: 18, weight: .medium)); Text(labels[index]).font(.system(size: 13, weight: tab == index ? .semibold : .regular)) }
                                .frame(maxWidth: .infinity).padding(.vertical, 10).background(tab == index ? Palette.soft : Color.clear).cornerRadius(15)
                        }.foregroundColor(tab == index ? Palette.green : Palette.muted).accessibilityIdentifier("tab-\(index)")
                    }
                }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4).background(Palette.background)
            }
        }.background(Palette.background.ignoresSafeArea()).foregroundColor(Palette.ink)
            .overlay(alignment: .bottom) {
                if let candidate = nearbyRackets.candidate {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { nearbyRackets.dismiss() }
                        NearbyRacketCard(device: candidate, context: racketContext, close: { nearbyRackets.dismiss() }).padding(.horizontal, 18).padding(.bottom, 12)
                    }.transition(.opacity.combined(with: .move(edge: .bottom))).zIndex(20)
                }
            }
            .environmentObject(replays)
            .environmentObject(social)
            .environmentObject(rackets)
            .task(id:replayContext) { replays.configure(replayContext);await replays.refresh() }
            .onChange(of:replays.launch?.id) { id in if id != nil { tab=2 } }
            .onChange(of: racketContext) { value in if value == nil { RacketBLEConnectionHub.shared.reset() }; rackets.configure(value); Task { await rackets.refresh() } }
            .onChange(of: racketContext) { _ in updateNearbyRackets() }
            .onChange(of: scenePhase) { _ in updateNearbyRackets() }
            .onChange(of: tab) { _ in updateNearbyRackets() }
            .onChange(of: focused) { _ in updateNearbyRackets() }
            .onChange(of: devices) { _ in updateNearbyRackets() }
            .onChange(of: gatherings) { _ in updateNearbyRackets() }
            .onChange(of: store.selected?.online) { _ in Task { await rackets.refresh() } }
            .onChange(of: scenePhase) { phase in if phase == .active { rackets.configure(racketContext); Task { await rackets.refresh() } } }
            .onChange(of: store.session.map { ObjectIdentifier($0) }) { _ in social.bind(store.session, deviceID: store.selected?.id) }
            .onChange(of: scenePhase) { phase in if phase == .active { social.run { try await social.refresh() }; clipboardInvites.becameActive(social: social, app: store) } }
            .onChange(of: store.accountID) { _ in social.bind(store.session, deviceID: store.selected?.id); social.checkDevicePairIdentity(app: store) }
            .onChange(of: store.loggedIn) { loggedIn in if loggedIn { Task { await social.loginWithTuyaTicket(app: store) } } }
            .onChange(of: store.identityFingerprint) { _ in social.checkDevicePairIdentity(app: store); Task { await social.loginWithTuyaTicket(app: store) } }
            // These modal roots sit outside the content's environment modifiers.
            // Share the root-owned stores with their entire nested presentation trees.
            .sheet(isPresented: $gatherings) { GatheringPage(openCourt: { gatherings = false; tab = 0; resumeRequest = UUID() }).environmentObject(social).environmentObject(store).environmentObject(rackets) }
            .sheet(isPresented: $devices) { DevicePage().environmentObject(store).environmentObject(social).environmentObject(rackets) }
            #if UI_PREVIEW && DEBUG
            .fullScreenCover(isPresented: $racketDemo) { RacketDemoPage() }
            #endif
            .onAppear {
                Task { await social.loginWithTuyaTicket(app: store) }
                rackets.configure(racketContext)
                updateNearbyRackets()
                social.bind(store.session, deviceID: store.selected?.id)
                clipboardInvites.becameActive(social: social, app: store)
                #if UI_PREVIEW
                let args = ProcessInfo.processInfo.arguments
                #if DEBUG
                racketDemo = args.contains("--racket-demo")
                #endif
                if let i = args.firstIndex(of: "--screen"), args.count > i+1 { tab = ["records":1,"coach":2,"profile":3][args[i+1]] ?? 0 }
                #endif
            }
    }
    private func updateNearbyRackets() {
        nearbyRackets.context = racketContext
        #if DEBUG && !UI_PREVIEW
        nearbyRackets.update(enabled: scenePhase == .active && racketContext != nil && tab == 0 && !focused && !devices && !gatherings)
        #else
        nearbyRackets.update(enabled: false)
        #endif
    }
}
