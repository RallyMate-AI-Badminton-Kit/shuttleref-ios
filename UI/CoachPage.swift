import SwiftUI
import UIKit

struct ShuttleCompanion: View {
    var color: Color = Palette.green
    var body:some View {
        ZStack {
            Ellipse().fill(color.opacity(0.08)).frame(width:150,height:30).offset(y:72)
            ForEach(-2..<3,id:\.self) { i in
                Capsule().fill(LinearGradient(colors:[Color.white,Palette.soft],startPoint:.top,endPoint:.bottom)).overlay(Capsule().stroke(color.opacity(0.18),lineWidth:1)).frame(width:27,height:92).rotationEffect(.degrees(Double(i)*16),anchor:.bottom).offset(y:-30)
            }
            RoundedRectangle(cornerRadius:25).fill(color).frame(width:83,height:65).offset(y:30)
            HStack(spacing:23) { Capsule().fill(Color.white).frame(width:5,height:10);Capsule().fill(Color.white).frame(width:5,height:10) }.offset(y:25)
            Image(systemName:"chevron.down").font(.system(size:13,weight:.semibold)).foregroundColor(.white.opacity(0.8)).offset(y:43)
        }.frame(width:180,height:190).accessibilityLabel("羽毛球教练伙伴")
    }
}
struct CoachPage: View {
    @EnvironmentObject var social: GatheringStore
    @EnvironmentObject private var replays:ReplayStore
    @StateObject private var coach: CoachStore
    @State private var historyList = false
    @State private var openHistorySelection = false
    @State private var options = false
    @State private var chat = false
    @State private var focusOnOpen = false
    #if UI_PREVIEW && DEBUG
    @State private var inputCheck: Bool?
    #endif
    @AppStorage("ios.companion.name") private var name = "小羽"
    @AppStorage("ios.companion.color") private var colorIndex = 0
    @AppStorage("ios.companion.visible") private var visible = true
    private let prompts = ["我的后场高远球总是打不远", "双打时，应该怎样和队友轮转？", "帮我安排一次基础步伐练习"]

    init() {
        #if UI_PREVIEW && DEBUG
        _coach = StateObject(wrappedValue: CoachPreviewFixture.enabled ? CoachPreviewFixture.makeStore() : CoachStore())
        #else
        _coach = StateObject(wrappedValue: CoachStore())
        #endif
    }
    private var context: CoachContext? {
        #if UI_PREVIEW && DEBUG
        if CoachPreviewFixture.enabled { return CoachPreviewFixture.context }
        #endif
        guard social.verifiedBusiness, let credentials = social.credentials else { return nil }
        return CoachContext(origin: social.origin, userID: credentials.user.id, token: credentials.token)
    }
    private func openChat(prompt: String? = nil, focus: Bool = false) {
        coach.bind(context)
        if let prompt { coach.draft = prompt }
        focusOnOpen = focus
        chat = true
    }
    private func consumeLaunch() {
        guard let reference=replays.consumeLaunch(for:context) else { return }
        coach.bind(context);coach.selectReference(reference)
        openChat(prompt:reference.type == "match" ? "请优先结合这场比赛已关联的视频观测，复盘当前分析球员的移动与姿态变化，指出值得回看的时间段，并给出具体训练建议。" : "请介绍引用的最后一分，并告诉我回看这段视频时可以重点留意什么。",focus:false)
    }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "教练")
            #if UI_PREVIEW && DEBUG
            if let inputCheck { Text(inputCheck ? "PASS" : "FAIL").accessibilityIdentifier("coach-input-check") }
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("你的场边伙伴").font(.subheadline).foregroundColor(Palette.muted)
                        Spacer()
                        Button { coach.bind(context); historyList = true } label: { Label("历史会话", systemImage: "clock") }.font(.subheadline)
                    }
                    if visible {
                        HStack { Spacer(); ShuttleCompanion(color: [Palette.green, Palette.blue, Color(hex: 0xa98963)][min(max(colorIndex, 0), 2)]); Spacer() }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("今天，想练好哪一拍？").font(.system(size: 25, weight: .bold))
                        Text("我是\(name)，陪你拆解动作，也陪你慢慢进步。")
                            .font(.subheadline).foregroundColor(Palette.muted).lineSpacing(5)
                    }
                    Button { openChat(focus: coach.messages.isEmpty) } label: {
                        HStack { Text(coach.messages.isEmpty ? "和\(name)聊聊" : "继续和\(name)聊"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 20)
                    }.buttonStyle(PrimaryStyle()).accessibilityIdentifier("coach-open-chat")
                    Button { coach.bind(context); coach.newConversation(); openChat(focus: true) } label: { Label("新建对话", systemImage: "square.and.pencil") }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("也可以从这里聊起").font(.caption).foregroundColor(Palette.muted)
                        ForEach(prompts, id: \.self) { prompt in
                            Button { openChat(prompt: prompt, focus: true) } label: {
                                HStack(spacing: 12) { Text(prompt).font(.subheadline).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }
                                    .padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(16)
                            }.buttonStyle(.plain)
                        }
                    }
                    Button("设置教练伙伴") { options = true }.font(.subheadline).frame(minHeight: 44)
                }.padding(22)
            }
        }
        .sheet(isPresented: $historyList, onDismiss: {
            if openHistorySelection { openHistorySelection = false; openChat() }
        }) { CoachHistoryPage(coach: coach, name: name, onSelect: { openHistorySelection = true }) }
        .onAppear { coach.bind(context);consumeLaunch() }
        .onChange(of:replays.launch?.id) { _ in consumeLaunch() }
        #if UI_PREVIEW && DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--coach-input-check") { inputCheck = CoachPreviewFixture.checkComposition() }
        }
        #endif
        .onChange(of: context) { coach.bind($0) }
        .onDisappear { if !chat { coach.cancel() } }
        .sheet(isPresented: $options) { CompanionSettings() }
        .fullScreenCover(isPresented: $chat, onDismiss: { coach.cancel() }) {
            CoachChatPage(coach: coach, name: name, focusOnOpen: focusOnOpen)
                .environmentObject(social)
        }
    }
}

private struct CoachChatPage: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var social: GatheringStore
    @ObservedObject var coach: CoachStore
    let name: String
    let focusOnOpen: Bool
    @EnvironmentObject private var replays:ReplayStore
    @State private var referencePicker=false
    @State private var history = false
    @State private var account = false
    @State private var loginDraft: String?
    @State private var inputFocused = false
    @State private var inputHeight: CGFloat = 44
    @State private var followLatest = true
    @State private var nearBottom = true
    @State private var userScrolling = false
    private var context: CoachContext? {
        #if UI_PREVIEW && DEBUG
        if CoachPreviewFixture.enabled { return CoachPreviewFixture.context }
        #endif
        guard social.verifiedBusiness, let credentials = social.credentials else { return nil }
        return CoachContext(origin: social.origin, userID: credentials.user.id, token: credentials.token)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { inputFocused = false; dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
                }.accessibilityLabel("返回教练首页").accessibilityIdentifier("coach-back")
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text("羽毛球教练伙伴").font(.caption).foregroundColor(Palette.muted)
                    #if UI_PREVIEW && DEBUG
                    if CoachPreviewFixture.enabled { Text("界面演示 · 不调用模型").font(.caption2).foregroundColor(Palette.muted) }
                    #endif
                }
                Spacer()
                Button { inputFocused = false; coach.newConversation() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 20)).frame(width: 44, height: 44)
                }.accessibilityLabel("新建对话").accessibilityIdentifier("coach-new-conversation")
                Button { inputFocused = false; history = true } label: {
                    Image(systemName: "clock").font(.system(size: 20)).frame(width: 44, height: 44)
                }.accessibilityLabel("历史对话").accessibilityIdentifier("coach-history")
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider().overlay(Palette.line)
            conversation
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .background(Palette.background.ignoresSafeArea()).foregroundColor(Palette.ink)
        .onChange(of: context) { value in
            coach.bind(value)
            if value != nil, let draft = loginDraft { coach.draft = draft; loginDraft = nil }
        }
        .sheet(isPresented:$referencePicker) { ReplayReferencePicker { coach.selectReference($0) }.environmentObject(replays) }
        .sheet(isPresented: $history) { CoachHistoryPage(coach: coach, name: name) }
        .sheet(isPresented: $account) { AccountCenter() }
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if coach.messages.isEmpty && !coach.sending {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "sparkles").font(.title2).foregroundColor(Palette.green)
                                Text("想聊聊哪一拍？").font(.title2.bold())
                                Text("说说你遇到的问题，我们一起找到下一步。")
                                    .font(.subheadline).foregroundColor(Palette.muted)
                                Text(coach.references.isEmpty ? "AI 建议供参考 · 可添加比赛引用" : "已选择演示比赛引用，发送时读取记录")
                                    .font(.caption).foregroundColor(Palette.muted).padding(.top, 4)
                            }.padding(.vertical, 28)
                        }
                        ForEach(coach.messages) { message in
                            CoachBubble(message: message, name: name).id(message.id)
                        }
                        if coach.sending {
                            CoachBubble(message: CoachMessage(role: "user", content: coach.pendingQuestion), name: name)
                            if coach.pendingAnswer.isEmpty {
                                HStack(spacing: 10) { ProgressView(); Text("\(name)正在思考…").font(.subheadline).foregroundColor(Palette.muted) }
                                    .id("coach-pending").accessibilityIdentifier("coach-waiting")
                            } else {
                                CoachBubble(message:CoachMessage(id:coach.pendingID, role:"assistant", content:coach.pendingAnswer), name:name, isStreaming:true)
                                    .id("coach-live").accessibilityIdentifier("coach-live-answer")
                            }
                        }
                        Color.clear.frame(height: 1).id("coach-bottom")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: CoachBottomPosition.self, value: geometry.frame(in: .named("coach-conversation")).maxY)
                            })
                    }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16)
                }
                .coordinateSpace(name: "coach-conversation")
                .accessibilityIdentifier("coach-messages")
                .onPreferenceChange(CoachBottomPosition.self) { bottom in
                    nearBottom = bottom > 0 && bottom < viewport.size.height + 80
                    if nearBottom && !userScrolling { followLatest = true }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                    followLatest = false
                    userScrolling = true
                    inputFocused = false
                }.onEnded { _ in userScrolling = false; followLatest = nearBottom })
                .onAppear {
                    proxy.scrollTo("coach-bottom", anchor: .bottom)
                    if focusOnOpen {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { inputFocused = true }
                    }
                }
                .onChange(of: coach.messages.last?.id) { id in
                    if followLatest, let id {
                        // Persisting a stream clears pendingAnswer in the same update.
                        // Its stable ID, rather than transient text, identifies promotion.
                        if id == coach.pendingID { proxy.scrollTo("coach-bottom", anchor:.bottom) }
                        else { proxy.scrollTo(id, anchor:.top) }
                    }
                }
                .onChange(of: coach.pendingAnswer) { text in
                    if followLatest && !userScrolling && !text.isEmpty { proxy.scrollTo("coach-bottom", anchor:.bottom) }
                }
                .onChange(of: coach.sending) { sending in
                    if sending { followLatest = true; withAnimation { proxy.scrollTo("coach-bottom", anchor: .bottom) } }
                }
                .onChange(of: inputFocused) { focused in
                    if focused && followLatest {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo("coach-bottom", anchor: .bottom) } }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !nearBottom && (!coach.messages.isEmpty || !coach.pendingAnswer.isEmpty) {
                        Button { followLatest = true; withAnimation { proxy.scrollTo("coach-bottom", anchor: .bottom) } } label: {
                            Image(systemName: "arrow.down").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                                .background(Color.white).clipShape(Circle()).shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                        }.accessibilityLabel("回到最新消息").accessibilityIdentifier("coach-latest").padding(14)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment:.top,spacing:10) {
                Button { inputFocused=false;referencePicker=true } label: { Label("引用比赛",systemImage:"plus.circle").font(.caption) }
                    .disabled(coach.sending || context==nil).accessibilityIdentifier("coach-add-reference")
                if let reference=coach.references.first {
                    Text(reference.label ?? "比赛引用").font(.caption).lineLimit(2)
                    Spacer(minLength:0)
                    Button { coach.selectReference(nil) } label: { Image(systemName:"xmark.circle.fill").frame(width:30,height:30) }
                        .disabled(coach.sending).accessibilityLabel("移除比赛引用").accessibilityIdentifier("coach-remove-reference")
                } else { Spacer() }
            }
            if !coach.error.isEmpty {
                Text(coach.error).font(.caption).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("coach-error")
            }
            HStack(alignment: .bottom, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if coach.draft.isEmpty || coach.sending {
                        Text(coach.sending ? "等待教练回复…" : "问问\(name)…").font(.body).foregroundColor(Palette.muted)
                            .padding(.leading, 12).padding(.top, 11).allowsHitTesting(false)
                    }
                    CoachGrowingInput(text: Binding(get: { coach.sending ? "" : coach.draft }, set: { coach.draft = $0 }),
                                      focused: $inputFocused, height: $inputHeight, editable: !coach.sending)
                        .id(context?.storageKey)
                        .frame(height: inputHeight)
                }
                Button {
                    if coach.sending { coach.stop() }
                    else if context == nil { loginDraft = coach.draft; inputFocused = false; account = true }
                    else { followLatest = true; Task { await coach.send() } }
                } label: {
                    ZStack {
                        Circle().fill(coach.sending || context == nil || coach.canSend ? Palette.green : Palette.muted.opacity(0.25)).frame(width: 36, height: 36)
                        if coach.sending { Image(systemName:"stop.fill").font(.system(size:14)).foregroundColor(.white) }
                        else { Image(systemName: context == nil ? "person.crop.circle" : "arrow.up").font(.system(size: 18, weight: .semibold)).foregroundColor(.white) }
                    }.frame(width: 44, height: 44)
                }
                .disabled(!coach.sending && context != nil && !coach.canSend)
                .accessibilityLabel(coach.sending ? "停止生成" : context == nil ? "登录后发送" : "发送消息")
                .accessibilityIdentifier(coach.sending ? "coach-stop" : "coach-send")
                .padding(.trailing, 4)
            }.padding(.vertical, 4).background(Color.white).cornerRadius(24)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.line, lineWidth: 1))
            if coach.draft.unicodeScalars.count >= 550 && !coach.sending {
                Text("\(coach.draft.unicodeScalars.count)/600").font(.caption2).foregroundColor(Palette.muted).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
            .background(Palette.background)
    }
}

private struct CoachBottomPosition: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct CoachBubble: View {
    let message: CoachMessage
    let name: String
    var isStreaming = false
    @EnvironmentObject private var replays:ReplayStore
    @State private var clip:ReplayClipPresentation?
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == "user" { Spacer(minLength: 38) }
            VStack(alignment: .leading, spacing: 8) {
                if message.role != "user" {
                    Label(name, systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundColor(Palette.muted)
                }
                if message.role == "user" {
                    if let reference=message.references?.first { Text("引用："+(reference.label ?? "比赛回放")).font(.caption).foregroundColor(Palette.muted) }
                    Text(message.content).font(.body).lineSpacing(6).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if isStreaming {
                        CoachLiveMarkdown(text:message.content)
                        Label("正在生成…", systemImage:"ellipsis").font(.caption).foregroundColor(Palette.muted)
                    } else {
                        CoachMessageContent(message:message,onOpenVideo:(message.references?.isEmpty == false) ? { video in
                            clip=ReplayClipPresentation(clip:video,title:"引用片段 · 演示比赛",context:replays.context)
                        } : nil)
                        if let completion = message.completion {
                            Text(completion == "stopped" ? "已停止 · 回复未完成" : "连接中断 · 回复未完成")
                                .font(.caption).foregroundColor(Palette.muted).accessibilityIdentifier("coach-incomplete")
                        }
                        Button { UIPasteboard.general.string = message.content } label: {
                            Label("复制原文", systemImage: "doc.on.doc").font(.caption).foregroundColor(Palette.muted)
                        }.frame(minHeight: 36).accessibilityLabel("复制教练回复原文")
                    }
                }
            }
            .padding(message.role == "user" ? 14 : 0)
            .background(message.role == "user" ? Palette.soft : Color.clear).cornerRadius(18)
            if message.role != "user" { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .fullScreenCover(item:$clip) { item in ReplayPlayerPage(presentation:item).environmentObject(replays) }
    }
}

private struct CoachHistoryPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coach: CoachStore
    let name: String
    var onSelect: () -> Void = {}
    private var items: [CoachConversation] {
        coach.conversations.filter { !$0.history.messages.isEmpty || !$0.history.draft.isEmpty || !($0.history.references ?? []).isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        VStack(spacing: 20) {
            SheetHeader(title: "历史会话")
            Text("此账号的对话保存在这台手机上").font(.caption).foregroundColor(Palette.muted)
            Button { coach.newConversation(); onSelect(); dismiss() } label: {
                Label("新建对话", systemImage: "square.and.pencil").frame(maxWidth: .infinity).padding()
            }.background(Palette.soft).cornerRadius(16)
            if items.isEmpty {
                EmptyCard(icon: "bubble.left.and.bubble.right", title: "还没有对话", detail: "发送问题后，可以在这里找回并继续聊。")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { item in
                            Button { coach.openConversation(item.id); onSelect(); dismiss() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(item.title).font(.headline).lineLimit(2)
                                        Text(item.updatedAt, style: .date).font(.caption).foregroundColor(Palette.muted)
                                        Text(item.history.messages.last?.content ?? "草稿").font(.subheadline).foregroundColor(Palette.muted).lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: item.id == coach.activeConversationID ? "checkmark.circle.fill" : "chevron.right")
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).background(Palette.soft).cornerRadius(16)
                        }
                    }
                }
            }
        }.padding(22).background(Palette.background.ignoresSafeArea()).foregroundColor(Palette.ink)
    }
}

/// UITextView keeps multiline sizing and keyboard behavior available on iOS 15.
struct CoachGrowingInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    let editable: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Palette.ink)
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityLabel = "教练问题草稿"
        view.accessibilityIdentifier = "coach-question"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize(view)
        // Keep the keyboard stable while waiting; the delegate blocks edits.
        if focused && !view.isFirstResponder { view.becomeFirstResponder() }
        else if !focused && view.isFirstResponder { view.resignFirstResponder() }
        context.coordinator.resize(view)
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CoachGrowingInput
        private var synchronizedText: String
        init(_ parent: CoachGrowingInput) { self.parent = parent; synchronizedText = parent.text }
        func synchronize(_ view: UITextView) {
            // Provisional Pinyin belongs to UIKit until the candidate is committed.
            // Explicit draft changes (send/account reset) must still replace it.
            if view.text != parent.text && (view.markedTextRange == nil || parent.text != synchronizedText) {
                view.text = parent.text
            }
            synchronizedText = parent.text
        }
        func textViewDidChange(_ view: UITextView) {
            if view.markedTextRange == nil { parent.text = view.text }
            resize(view)
        }
        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.focused { parent.focused = true }
        }
        func textViewDidEndEditing(_ view: UITextView) {
            if parent.focused { parent.focused = false }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool { parent.editable }
        func resize(_ view: UITextView) {
            guard view.bounds.width > 0 else { return }
            let measured = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
            let maximum = (view.font?.lineHeight ?? 22) * 4 + 20
            let target = max(44, min(maximum, measured))
            view.isScrollEnabled = measured > maximum
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = target }
            }
        }
    }
}

struct CompanionSettings:View {
    @AppStorage("ios.companion.name") private var name = "小羽"
    @AppStorage("ios.companion.color") private var color = 0
    @AppStorage("ios.companion.visible") private var visible = true
    var body:some View { VStack(alignment:.leading,spacing:24) { SheetHeader(title:"教练伙伴");HStack { Spacer();ShuttleCompanion(color:[Palette.green,Palette.blue,Color(hex:0xa98963)][min(max(color,0),2)]);Spacer() };TextField("伙伴名字",text:$name).inputStyle().onChange(of:name) { name = String($0.prefix(12)) };Picker("外观",selection:$color) { Text("森林绿").tag(0);Text("雾蓝").tag(1);Text("暖砂").tag(2) }.pickerStyle(.segmented);Toggle("显示教练伙伴",isOn:$visible);Note(text:"外观设置自动保存在本机。");Spacer() }.padding(24).background(Palette.background.ignoresSafeArea()) }
}
