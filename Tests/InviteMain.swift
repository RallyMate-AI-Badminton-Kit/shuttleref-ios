import Foundation
@main struct InviteChecks {
    static func main() throws {
        let code = "Abcdefghijklmnopqrst_-9Z"
        precondition(code.count == 24)
        precondition(try! InvitationText.code(from: code) == code)
        precondition(try! InvitationText.code(from: "https://example.com/invite/\(code)?source=share") == code)
        let text = "🏸 周六打球，一起来！\nhttps://example.com/invite/\(code)\n邀请码：\(code)\n复制整段到羽小裁"
        precondition(try! InvitationText.code(from: text) == code)
        precondition(try! InvitationText.code(from: "邀请码：\(code)，复制到羽小裁。") == code)
        for bad in ["", "普通聊天内容", code + "x", "邀请码：" + code + "\n邀请码：" + String(repeating:"a",count:24), "https://example.com/other/" + code] {
            do { _ = try InvitationText.code(from: bad); fatalError("Must reject invalid/ambiguous invitation") } catch {}
        }
        print("PASS: raw code, URL, full share text, punctuation, invalid and ambiguous invitation")
    }
}
