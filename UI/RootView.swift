import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var social = GatheringStore()
    @StateObject private var clipboardInvites = ClipboardInvitationMonitor()
    @State private var gatherings = false
    @State private var tab = 0
    @State private var devices = false
    @State private var focused = false
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
            .environmentObject(social)
            .onChange(of: store.session.map { ObjectIdentifier($0) }) { _ in social.bind(store.session, deviceID: store.selected?.id) }
            .onChange(of: scenePhase) { phase in if phase == .active { social.run { try await social.refresh() }; clipboardInvites.becameActive(social: social) } }
            .onChange(of: store.accountID) { _ in social.bind(store.session, deviceID: store.selected?.id) }
            .sheet(isPresented: $gatherings) { GatheringPage(openCourt: { gatherings = false; tab = 0; resumeRequest = UUID() }).environmentObject(social).environmentObject(store) }
            .sheet(isPresented: $devices) { DevicePage().environmentObject(store) }
            .onAppear {
                social.bind(store.session, deviceID: store.selected?.id)
                clipboardInvites.becameActive(social: social)
                #if UI_PREVIEW
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "--screen"), args.count > i+1 { tab = ["records":1,"coach":2,"profile":3][args[i+1]] ?? 0 }
                #endif
            }
    }
}
