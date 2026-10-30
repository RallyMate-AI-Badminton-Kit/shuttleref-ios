import SwiftUI
import UIKit

/// Native content slots. Media navigation can be injected once authorized asset resolution exists.
struct CoachMessageContent: View {
    let message: CoachMessage
    var onOpenVideo: ((CoachVideoReference) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Index identity also tolerates duplicate IDs from future payload versions.
            ForEach(Array(message.displayBlocks.enumerated()), id: \.offset) { _, block in
                switch block.type {
                case "markdown":
                    CoachMarkdownView(block.text ?? "")
                case "metrics":
                    metricsCard(block)
                case "video_clip":
                    videoCard(block)
                default:
                    Label(block.title ?? "此内容暂不支持显示", systemImage: "square.stack.3d.up")
                        .font(.subheadline).foregroundColor(Palette.muted).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Palette.soft).cornerRadius(14)
                }
            }
        }
    }

    private func sourceLabel(_ source: CoachSourceReference?) -> some View {
        Text(source.map { "来源：" + $0.label } ?? "未提供数据来源")
            .font(.caption).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
    private func metricsCard(_ block: CoachContentBlock) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(block.title ?? "比赛数据", systemImage: "chart.bar.xaxis").font(.headline)
            if let metrics = block.metrics, !metrics.isEmpty {
                ForEach(Array(metrics.prefix(32).enumerated()), id: \.offset) { _, metric in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(metric.label).foregroundColor(Palette.muted)
                        Spacer(minLength: 8)
                        Text(metric.value + (metric.unit.map { " " + $0 } ?? "")).fontWeight(.semibold).multilineTextAlignment(.trailing)
                    }.font(.subheadline)
                }
            } else { Text("暂无可显示的指标").font(.subheadline).foregroundColor(Palette.muted) }
            Divider()
            sourceLabel(block.source)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white).cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
            .accessibilityIdentifier("coach-metrics-card")
    }
    private func videoCard(_ block: CoachContentBlock) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle").font(.system(size: 28)).foregroundColor(Palette.green)
                VStack(alignment: .leading, spacing: 5) {
                    Text(block.title ?? "视频片段").font(.headline)
                    if let clip = block.video, clip.isValid {
                        Text("\(time(clip.startSeconds)) – \(time(clip.endSeconds))").font(.caption.monospacedDigit()).foregroundColor(Palette.muted)
                    }
                }
            }
            sourceLabel(block.source)
            if let clip = block.video, clip.isValid, let onOpenVideo {
                Button("查看片段") { onOpenVideo(clip) }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            } else {
                Text(block.video?.isValid == true ? "视频播放尚未接入" : "片段信息不可用")
                    .font(.caption).foregroundColor(Palette.muted)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.soft).cornerRadius(16).accessibilityIdentifier("coach-video-card")
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct CoachMarkdownView: View {
    private let root: CoachMarkdownNode
    init(_ source: String) { root = CoachMarkdown.document(source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(root.children) { CoachMarkdownBlock(node: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .tint(Palette.green)
        .environment(\.openURL, OpenURLAction { url in CoachMarkdown.safeLink(url) ? .systemAction : .discarded })
    }
}

private struct CoachMarkdownBlock: View {
    let node: CoachMarkdownNode
    var body: some View {
        // Type erasure bounds the recursive View type for nested lists and quotes.
        rendered
    }
    private var children: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(node.children) { CoachMarkdownBlock(node: $0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var text: some View {
        Text(node.text).font(.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var rendered: AnyView {
        switch node.kind {
        case .header(let level):
            return AnyView(Text(node.text).font(.system(size: level <= 1 ? 25 : level == 2 ? 21 : 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader).padding(.top, 3))
        case .orderedList, .unorderedList:
            return AnyView(VStack(alignment: .leading, spacing: 9) {
                ForEach(node.children) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(marker(item)).font(.body.monospacedDigit()).foregroundColor(Palette.green)
                            .frame(minWidth: 18, alignment: .trailing)
                        CoachMarkdownBlock(node: item)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading))
        case .listItem:
            return AnyView(children)
        case .blockQuote:
            return AnyView(HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Palette.green.opacity(0.4)).frame(width: 3)
                children
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 5).foregroundColor(Palette.muted))
        case .codeBlock(let language):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty { Text(language).font(.caption).foregroundColor(Palette.muted) }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(String(node.text.characters)).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true).padding(.bottom, 5)
                }
            }.padding(14).background(Palette.soft).cornerRadius(12))
        case .table:
            return AnyView(ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(node.children) { row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(row.children) { cell in
                                Text(cell.text).font(.subheadline).fontWeight(isHeader(row) ? .semibold : .regular)
                                    .lineSpacing(4).frame(width: 132, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true).padding(12)
                            }
                        }.background(isHeader(row) ? Palette.soft : Color.white)
                        Divider()
                    }
                }.overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1)).cornerRadius(10).padding(.bottom, 6)
            }.accessibilityIdentifier("coach-markdown-table"))
        case .thematicBreak:
            return AnyView(Divider().padding(.vertical, 5))
        default:
            return node.children.isEmpty ? AnyView(text) : AnyView(children)
        }
    }
    private func isHeader(_ row: CoachMarkdownNode) -> Bool {
        if case .tableHeaderRow = row.kind { return true }; return false
    }
    private func marker(_ item: CoachMarkdownNode) -> String {
        if case .orderedList = node.kind, case .listItem(let ordinal) = item.kind { return "\(ordinal)." }
        return "•"
    }
}

struct CoachLiveMarkdown: View {
    let text: String
    var body: some View {
        let parts = CoachStreamingMarkdown.split(text)
        VStack(alignment:.leading, spacing:14) {
            if !parts.prefix.isEmpty { CoachMarkdownView(parts.prefix) }
            if !parts.tail.isEmpty {
                Text(verbatim:parts.tail).font(.body).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal:false, vertical:true).frame(maxWidth:.infinity, alignment:.leading)
            }
        }
    }
}
