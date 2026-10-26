import Foundation

/// Parses an invitation only; never follows a pasted URL or changes the API origin.
enum InvitationText {
    struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    static func code(from text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 8192 else { throw Invalid("请粘贴羽小裁邀请链接、邀请码或完整分享文案") }
        let token = "[A-Za-z0-9_-]{24}"
        var found = Set<String>()
        for pattern in ["^(\(token))$", "(?:邀请码|羽小裁口令)\\s*[：:]\\s*(\(token))(?![A-Za-z0-9_-])", "https?://[^\\s/<>]+/invite/(\(token))(?![A-Za-z0-9_-])"] {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        guard found.count == 1, let value = found.first else {
            throw Invalid(found.count > 1 ? "发现多个不同邀请，请只粘贴一场活动的邀请" : "未识别到羽小裁邀请，请复制完整分享内容后重试")
        }
        return value
    }
}
