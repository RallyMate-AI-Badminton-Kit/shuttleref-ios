import SwiftUI
import UIKit

struct GatheringInvitationEntry: View {
    @EnvironmentObject var social: GatheringStore
    let login: () -> Void
    @State private var text = ""
    @State private var preview: GatheringPreview?
    @State private var resolvedCode = ""
    @State private var error = ""
    @State private var loading = false
    @State private var retry = 0
    private var lookupID: String { text + "|" + social.origin + "|" + social.userID + "|" + String(retry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("粘贴邀请链接、邀请码或整段分享文案", text: $text)
                .autocapitalization(.none).disableAutocorrection(true).inputStyle()
                .accessibilityIdentifier("gathering-invitation-input")
            Button("粘贴并识别") {
                // Clipboard is accessed only following this explicit user gesture.
                if let content = UIPasteboard.general.string, !content.isEmpty { text = content }
                else { error = "剪贴板没有文字，请复制朋友发来的邀请" }
            }
            if loading { ProgressView("正在查看邀请…") }
            if !error.isEmpty { Note(text: error); Button("重试识别") { retry += 1 }.disabled(loading) }
            if let invite = preview, !resolvedCode.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(invite.title).font(.headline)
                    Text(invite.location)
                    Text(Date(timeIntervalSince1970: invite.starts_at).formatted())
                    if let mode = GatheringFormat(rawValue: invite.format ?? "free") { Label(mode.title, systemImage: mode.icon).foregroundColor(Palette.green) }
                    Note(text: "\(invite.organizer) 邀请你 · \(invite.remaining > 0 ? "还剩 \(invite.remaining) 个名额" : "已满员，可加入候补")")
                    if let user = social.credentials?.user { Note(text: "以 " + user.name + " 的身份报名") }
                    Button(social.needsLogin ? "登录后加入" : invite.remaining > 0 ? "加入球局" : "加入候补") {
                        guard !social.needsLogin else { login(); return }
                        let code = resolvedCode
                        social.run { try await social.join(code); clear() }
                    }.buttonStyle(PrimaryStyle()).disabled(social.busy)
                    Button("暂不加入") { clear() }.frame(maxWidth: .infinity, minHeight: 44)
                }.padding(18).background(Palette.soft).cornerRadius(18)
            }
        }
        .onChange(of: lookupID) { _ in preview = nil; resolvedCode = ""; error = "" }
        .task(id: lookupID) {
            preview = nil; resolvedCode = ""; error = ""; loading = false
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let input = text
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                let code = try InvitationText.code(from: input)
                loading = true
                let value: GatheringPreview = try await social.request("/invites/" + code)
                try Task.checkCancellation()
                preview = value; resolvedCode = code; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                loading = false; self.error = error.localizedDescription
            }
        }
    }
    private func clear() { text = ""; preview = nil; resolvedCode = ""; error = "" }
}
