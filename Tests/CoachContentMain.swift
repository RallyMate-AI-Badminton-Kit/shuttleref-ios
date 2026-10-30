import Foundation

@main struct CoachContentChecks {
    static func main() throws {
        let old = CoachMessage(role: "assistant", content: "## 旧回复\n\n**重点**")
        let restored = try JSONDecoder().decode(CoachMessage.self, from: JSONEncoder().encode(old))
        precondition(restored.displayBlocks.count == 1 && restored.displayBlocks[0].type == "markdown")
        let mixed = CoachMessage(role: "assistant", content: "文字摘要", blocks: [
            .markdown(id: "intro", text: "## 数据回顾"),
            CoachContentBlock(id: "stats", type: "metrics", title: "本局数据", metrics: [.init(label: "回合", value: "12", unit: "次")], source: .init(id: "match-1", label: "测试比赛")),
            CoachContentBlock(id: "video", type: "video_clip", title: "第 3 回合", video: .init(assetID: "asset-1", startSeconds: 10, endSeconds: 18), source: .init(id: "match-1", label: "测试比赛")),
            CoachContentBlock(id: "future", type: "future_card", title: "未来内容")
        ])
        let rich = try JSONDecoder().decode(CoachMessage.self, from: JSONEncoder().encode(mixed))
        precondition(rich.displayBlocks.map(\.type) == ["markdown", "metrics", "video_clip", "future_card"])
        precondition(rich.displayBlocks[2].video?.isValid == true)
        precondition(!CoachVideoReference(assetID: "asset", startSeconds: 20, endSeconds: 10).isValid)
        precondition(!CoachVideoReference(assetID: "", startSeconds: 0, endSeconds: 10).isValid)
        // Unknown/malformed future blocks degrade independently; they cannot erase a conversation.
        let future = Data("{\"id\":\"x\",\"type\":\"future\",\"video\":{\"unknown\":1}}".utf8)
        let unknown = try JSONDecoder().decode(CoachContentBlock.self, from: future)
        precondition(unknown.type == "future" && unknown.video == nil)
        for invalid: Any in [NSNull(), "", "   \n", 123] {
            let data = try JSONSerialization.data(withJSONObject: ["reply":"有效建议", "blocks":[["type":"markdown", "text":invalid]]])
            let response = try JSONDecoder().decode(CoachReply.self, from:data)
            let message = CoachMessage(role:"assistant", content:response.reply, blocks:response.blocks)
            let saved = try JSONDecoder().decode(CoachMessage.self, from:JSONEncoder().encode(message))
            precondition(saved.displayBlocks.first?.text == "有效建议", "Malformed Markdown must not hide a valid reply")
        }
        let missing = try JSONDecoder().decode(CoachReply.self, from:Data("{\"reply\":\"有效建议\",\"blocks\":[{\"type\":\"markdown\"}]}".utf8))
        precondition(CoachMessage(role:"assistant", content:missing.reply, blocks:missing.blocks).displayBlocks.first?.text == "有效建议")
        let root = CoachMarkdown.parse("## 启动练习\n\n**重点**和[链接](https://example.com)\n\n1. 一组\n2. 二组\n   - 放松\n\n> 引用\n\n| 项目 | 次数 |\n| --- | ---: |\n| 启动 | 8 |\n\n```swift\nlet x = 1\n```\n\n---")
        precondition(root.children.contains { if case .header(level: 2) = $0.kind { return true }; return false })
        precondition(root.children.contains { if case .table = $0.kind { return true }; return false })
        precondition(root.children.contains { if case .orderedList = $0.kind { return true }; return false })
        precondition(root.children.contains { if case .blockQuote = $0.kind { return true }; return false })
        precondition(root.children.contains { if case .codeBlock = $0.kind { return true }; return false })
        let linked = CoachMarkdown.parse("[安全](https://example.com) [危险](javascript:alert) [文件](file:///etc/passwd)")
        let links = linked.children.flatMap { $0.text.runs.compactMap(\.link) }
        precondition(links.count == 1 && links[0].scheme == "https")
        let partial = CoachMarkdown.parse("## 未完\n\n**准备\n\n```swift\nlet x =")
        precondition(!partial.children.isEmpty)
        print("PASS: legacy/rich messages, future blocks, clip bounds, Markdown blocks, safe links, incomplete syntax")
    }
}
