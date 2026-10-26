import SwiftUI

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
    @EnvironmentObject var store:AppStore
    @State private var draft = ""
    @State private var options = false
    @State private var history = false
    @AppStorage("ios.companion.name") private var name = "小羽"
    @AppStorage("ios.companion.color") private var colorIndex = 0
    @AppStorage("ios.companion.visible") private var visible = true
    private let prompts = ["我的后场高远球总是打不远","双打时，应该怎样和队友轮转？","帮我安排一次基础步伐练习"]
    var body:some View {
        VStack(spacing:0) {
            PageHeader(title:"教练")
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack { Text("你的场边伙伴").font(.system(size:13)).foregroundColor(Palette.muted);Spacer();Button("历史对话  ›") { history = true }.font(.system(size:13)) }
                    if visible { HStack { Spacer();Button { options = true } label: { ShuttleCompanion(color:[Palette.green,Palette.blue,Color(hex:0xa98963)][min(max(colorIndex,0),2)]) }.buttonStyle(.plain);Spacer() } }
                    VStack(alignment:.leading,spacing:10) { Text("今天，想练好哪一拍？").font(.system(size:25,weight:.bold));Text("我是\(name)，陪你拆解动作，也陪你慢慢进步。").font(.system(size:14)).foregroundColor(Palette.muted).lineSpacing(5) }
                    ForEach(prompts,id:\.self) { prompt in Button { draft = prompt } label: { HStack { Text(prompt).font(.system(size:14));Spacer();Image(systemName:"arrow.up.right").font(.system(size:12)) }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color.white).cornerRadius(16) }.buttonStyle(.plain) }
                    Button("设置教练伙伴") { options = true }.font(.system(size:13)).frame(minHeight:44)
                    VStack(alignment:.leading,spacing:12) {
                        HStack { Label("我的问题",systemImage:"text.bubble").font(.system(size:14,weight:.semibold));Spacer();Text("本机草稿").font(.system(size:11)).foregroundColor(Palette.muted) }
                        TextEditor(text:$draft).frame(minHeight:90).padding(8).background(Color.white).cornerRadius(12).onChange(of:draft) { value in draft = String(value.prefix(600));UserDefaults.standard.set(draft,forKey:"ios.coach.draft.\(store.accountID)") }.accessibilityLabel("教练问题草稿")
                        Note(text:"问题会保存在本机。AI 对话与球局分析尚未接入，暂不发送。")
                    }.padding(17).background(Palette.soft).cornerRadius(20)
                }.padding(22)
            }
        }.onAppear { loadDraft() }.onChange(of:store.accountID) { _ in loadDraft() }
        .sheet(isPresented:$options) { CompanionSettings() }
        .sheet(isPresented:$history) { VStack(spacing:24) { SheetHeader(title:"历史对话");EmptyCard(icon:"bubble.left.and.bubble.right",title:"还没有对话",detail:"AI 服务接入后，你与教练的对话会在这里出现。");Spacer() }.padding(22).background(Palette.background.ignoresSafeArea()) }
    }
    private func loadDraft() { draft = UserDefaults.standard.string(forKey:"ios.coach.draft.\(store.accountID)") ?? "" }
}
struct CompanionSettings:View {
    @AppStorage("ios.companion.name") private var name = "小羽"
    @AppStorage("ios.companion.color") private var color = 0
    @AppStorage("ios.companion.visible") private var visible = true
    var body:some View { VStack(alignment:.leading,spacing:24) { SheetHeader(title:"教练伙伴");HStack { Spacer();ShuttleCompanion(color:[Palette.green,Palette.blue,Color(hex:0xa98963)][min(max(color,0),2)]);Spacer() };TextField("伙伴名字",text:$name).inputStyle().onChange(of:name) { name = String($0.prefix(12)) };Picker("外观",selection:$color) { Text("森林绿").tag(0);Text("雾蓝").tag(1);Text("暖砂").tag(2) }.pickerStyle(.segmented);Toggle("显示教练伙伴",isOn:$visible);Note(text:"外观设置自动保存在本机。");Spacer() }.padding(24).background(Palette.background.ignoresSafeArea()) }
}
