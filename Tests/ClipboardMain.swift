import Foundation
@main struct ClipboardChecks {
    static func main() {
        let code = "Abcdefghijklmnopqrst_-9Z"
        var policy = ClipboardInvitePolicy()
        precondition(policy.candidate("普通聊天内容") == nil)
        precondition(policy.candidate("邀请码：" + code) == code)
        policy.markPresented(code)
        precondition(policy.candidate("https://example.com/invite/" + code) == nil)
        precondition(ClipboardInvitePolicy(seen: policy.seen).candidate(code) == nil)
        precondition(!policy.seen.contains(code))
        precondition(policy.candidate("Zbcdefghijklmnopqrst_-9Z") != nil)
        print("PASS: ignore unrelated text, detect invitation, deduplicate across formats/relaunch, allow new invite, persist only hash")
    }
}
