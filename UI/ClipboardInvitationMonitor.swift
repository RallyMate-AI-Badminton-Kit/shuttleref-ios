import SwiftUI
import UIKit

/// Foreground-only, user-requested clipboard invitation discovery.
@MainActor final class ClipboardInvitationMonitor: ObservableObject {
    private var lastChange: Int?
    private var checking = false
    #if UI_PREVIEW
    private var seededTestClipboard = false
    #endif
    private let key = "social.clipboard.invites.seen.v1"
    private var policy = ClipboardInvitePolicy(seen: UserDefaults.standard.stringArray(forKey: "social.clipboard.invites.seen.v1") ?? [])

    func becameActive(social: GatheringStore) {
        guard !checking else { return }
        #if UI_PREVIEW
        guard ProcessInfo.processInfo.arguments.contains("--social-live-test") else { return }
        #endif
        checking = true
        Task { @MainActor in
            defer { checking = false }
            // Let initial presentation / foreground transitions settle before presenting UI.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard UIApplication.shared.applicationState == .active,
                  let presenter = Self.presenter(), !(presenter is UIAlertController),
                  !presenter.isBeingDismissed, !presenter.isBeingPresented else { return }
            let board = UIPasteboard.general
            #if UI_PREVIEW
            // UI automation seeds a known fixture after activation; absent from the device target.
            if !seededTestClipboard, let fixture = ProcessInfo.processInfo.environment["SHUTTLEREF_TEST_CLIPBOARD"] {
                seededTestClipboard = true; board.string = fixture
            }
            #endif
            guard board.changeCount != lastChange else { return }
            // Set before reading: an iOS paste-permission alert can trigger another active event.
            lastChange = board.changeCount
            guard board.hasStrings else { return }
            let clipboardText = board.string
            guard let text = clipboardText, let code = policy.candidate(text),
                  UIApplication.shared.applicationState == .active else { return }
            let alert = UIAlertController(title: "发现球局邀请", message: "剪贴板中有一份羽小裁邀请，要查看详情吗？查看不会自动报名。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "暂不查看", style: .cancel))
            alert.addAction(UIAlertAction(title: "查看邀请", style: .default) { _ in
                Task { @MainActor in
                    // UIAlertController dismisses itself after its action handler.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let current = Self.presenter(), !(current is UIAlertController), UIApplication.shared.applicationState == .active else { return }
                    let page = ClipboardInvitationPage(code: code).environmentObject(social)
                    let host = UIHostingController(rootView: page)
                    current.present(host, animated: true)
                }
            })
            // The fingerprint prevents repeated alerts across foreground events and relaunches.
            policy.markPresented(code)
            UserDefaults.standard.set(policy.seen, forKey: key)
            presenter.present(alert, animated: true)
        }
    }
    private static func presenter() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }.first { $0.isKeyWindow }
        var current = window?.rootViewController
        while let value = current {
            if let presented = value.presentedViewController { current = presented }
            else if let navigation = value as? UINavigationController { current = navigation.visibleViewController }
            else if let tabs = value as? UITabBarController { current = tabs.selectedViewController }
            else { break }
        }
        return current
    }
}

private struct ClipboardInvitationPage: View {
    @EnvironmentObject var social: GatheringStore
    @Environment(\.dismiss) private var dismiss
    let code: String
    @State private var preview: GatheringPreview?
    @State private var error = ""
    @State private var account = false
    @State private var joining = false
    @State private var joined: GatheringRegistration?
    @State private var retry = 0
    private var identity: String { social.origin + "|" + social.userID + "|" + String(retry) }
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let registration = joined {
                        Label(registration.title, systemImage: "checkmark.circle.fill").font(.title2.bold())
                        Text(registration.explanation)
                        Text("可在「我的 → 我的组局」中查看活动和最新报名状态。")
                        Button("完成") { dismiss() }.buttonStyle(PrimaryStyle())
                    } else if let invite = preview {
                        Text(invite.title).font(.title2.bold())
                        Text(invite.organizer + " 邀请你一起打球")
                        Label(invite.location, systemImage: "mappin.and.ellipse")
                        Text(Date(timeIntervalSince1970: invite.starts_at).formatted())
                        Note(text: invite.remaining > 0 ? "还剩 \(invite.remaining) 个名额" : "已满员，可以报名候补")
                        if let user = social.credentials?.user { Text("以 \(user.name) 的身份加入").font(.caption) }
                        Button(social.credentials == nil ? "登录后加入" : invite.remaining > 0 ? "加入球局" : "加入候补") {
                            guard social.credentials != nil else { account = true; return }
                            joining = true; error = ""
                            Task { @MainActor in
                                defer { joining = false }
                                do {
                                    let result: Gathering = try await social.request("/invites/\(code)/join", body: ["operation_id": UUID().uuidString])
                                    joined = result.registration(for: social.userID)
                                    try? await social.refresh()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(PrimaryStyle()).disabled(joining || social.busy)
                        Button("暂不加入") { dismiss() }.disabled(joining)
                    } else if error.isEmpty { ProgressView("正在加载邀请…") }
                    if !error.isEmpty { Note(text: error); Button("重新加载邀请") { retry += 1 }.disabled(joining); Button("关闭") { dismiss() } }
                }.padding(24)
            }.background(Palette.background.ignoresSafeArea())
                .navigationTitle("球局邀请").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() }.disabled(joining) } }
                .sheet(isPresented: $account) { GatheringAccount().environmentObject(social) }
                .task(id: identity) {
                    guard joined == nil else { return }
                    preview = nil; error = ""
                    do {
                        let value: GatheringPreview = try await social.request("/invites/" + code)
                        try Task.checkCancellation(); preview = value
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
        }.navigationViewStyle(.stack).tint(Palette.green).interactiveDismissDisabled(joining)
    }
}
