import SwiftUI
#if !UI_PREVIEW
import ThingSmartBaseKit
#endif

@main
struct ShuttleRefApp: App {
    @StateObject private var store: AppStore
    @Environment(\.scenePhase) private var phase
    init() {
        #if UI_PREVIEW
        if ProcessInfo.processInfo.arguments.contains("--reset-ui-state"), let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName:id) }
        #endif
        #if !UI_PREVIEW
        ThingSmartSDK.sharedInstance().start(withAppKey: AppKey.key, secretKey: AppKey.secret)
        #endif
        _store = StateObject(wrappedValue: AppStore())
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).preferredColorScheme(.light).accentColor(Palette.green)
                .onAppear { store.loadHomes() }
                .onChange(of: phase) { value in
                    if value == .background { store.background() }
                    if value == .active { store.foreground() }
                }
        }
    }
}
