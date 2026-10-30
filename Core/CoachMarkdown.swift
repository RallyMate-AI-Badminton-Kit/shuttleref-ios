import Foundation

/// Foundation parses Markdown into semantic intents; SwiftUI renders the tree below.
/// Identity comes from the parser, so inline style runs stay in the same paragraph/cell.
final class CoachMarkdownNode: Identifiable {
    let id: Int
    let kind: PresentationIntent.Kind?
    var text = AttributedString()
    var children: [CoachMarkdownNode] = []
    init(id: Int, kind: PresentationIntent.Kind? = nil) { self.id = id; self.kind = kind }
}

enum CoachMarkdown {
    private static let cache: NSCache<NSString, CoachMarkdownNode> = {
        let value = NSCache<NSString, CoachMarkdownNode>()
        value.countLimit = 64; value.totalCostLimit = 1_000_000
        return value
    }()
    static func document(_ source: String) -> CoachMarkdownNode {
        if let value = cache.object(forKey: source as NSString) { return value }
        let value = parse(source)
        cache.setObject(value, forKey: source as NSString, cost: source.utf8.count * 4)
        return value
    }
    static func safeLink(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }

    static func parse(_ source: String) -> CoachMarkdownNode {
        let root = CoachMarkdownNode(id: 0)
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full,
                                                                               failurePolicy: .returnPartiallyParsedIfPossible)) else {
            let plain = CoachMarkdownNode(id: 1); plain.text = AttributedString(source); root.children = [plain]; return root
        }
        var nodes: [Int: CoachMarkdownNode] = [0: root]
        for run in parsed.runs {
            var parent = root
            for component in (run.presentationIntent?.components ?? []).reversed() {
                if let node = nodes[component.identity] { parent = node }
                else {
                    let node = CoachMarkdownNode(id: component.identity, kind: component.kind)
                    parent.children.append(node); nodes[node.id] = node; parent = node
                }
            }
            if parent === root {
                let node = CoachMarkdownNode(id: -(root.children.count + 1))
                root.children.append(node); parent = node
            }
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if let link = run.link, !safeLink(link) { text.link = nil }
            parent.text.append(text)
        }
        if root.children.isEmpty && !source.isEmpty {
            let plain = CoachMarkdownNode(id: 1); plain.text = AttributedString(source); root.children = [plain]
        }
        return root
    }
}
