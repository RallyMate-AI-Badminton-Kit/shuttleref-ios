import SwiftUI

struct RacketDiagnosticButton: View {
    @ObservedObject private var log = RacketDiagnosticLog.shared
    @State private var copied = false
    var body: some View {
        Button { UIPasteboard.general.string = log.report; copied = true } label: {
            Label(copied ? "已复制诊断信息" : "复制诊断信息",systemImage:copied ? "checkmark":"doc.on.doc")
        }.font(.system(size:14)).accessibilityIdentifier("copy-racket-diagnostics")
    }
}
