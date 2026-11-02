import SwiftUI

struct ProfilePage:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var social: GatheringStore
    let openGatherings: () -> Void
    @State private var socialAccount = false
    let openDevices:()->Void
    @State private var sheet:String?
    @State private var nickname = "羽球新朋友"
    @State private var equipment = ""
    @State private var years = "刚刚开始"
    @AppStorage("ios.card.theme") private var theme = 0
    private var key:String { "ios.profile.business." + GatheringPersistence.partition(social.origin, social.userID) }
    var body:some View {
        VStack(spacing:0) {
            PageHeader(title:"我的")
            ScrollView {
                VStack(spacing:20) {
                    PlayerCard(name:nickname,years:years,equipment:equipment,theme:theme)
                    HStack(spacing:12) { Button("编辑资料") { sheet = "编辑资料" };Spacer();Button("装扮名片 ↗") { sheet = "装扮名片" } }.font(.system(size:14,weight:.semibold)).padding(.horizontal,8).frame(minHeight:44)
                    if !social.verifiedBusiness { Button("登录羽小裁") { socialAccount = true }.buttonStyle(PrimaryStyle()) }
                    VStack(spacing:10) {
                        MenuRow(icon:"person.2.fill",title:"我的组局",subtitle:"查看活动、报名与候补",action:openGatherings)
                            .accessibilityIdentifier("profile-gatherings")
                        MenuRow(icon:"person.crop.circle",title:"账号与安全",subtitle:"登录、退出与账号管理") { socialAccount = true }
                            .accessibilityIdentifier("profile-gathering-account")
                        MenuRow(icon:"medal",title:"荣誉墙",subtitle:"记录每一次小小的突破") { sheet = "荣誉墙" }
                        MenuRow(icon:"sensor.tag.radiowaves.forward",title:"我的设备",subtitle:store.selected?.name ?? "配网、连接与账号管理",action:openDevices)
                        MenuRow(icon:"photo.on.rectangle.angled",title:"我的高光",subtitle:"让精彩的回合，值得再看一次") { sheet = "我的高光" }
                        MenuRow(icon:"person.crop.square",title:"专属出场",subtitle:"属于你的球场名片与出场时刻") { sheet = "专属出场" }
                        MenuRow(icon:"speaker.wave.2",title:"音效偏好",subtitle:"球场氛围，按你的喜好来") { sheet = "音效偏好" }
                    }
                    Note(text:"羽小裁 · iPhone 原生版\n陪你打好每一场球").multilineTextAlignment(.center).padding(.top,12)
                }.padding(22)
            }
        }.onAppear { load() }.onChange(of:social.userID) { _ in load() }.onChange(of:social.origin) { _ in load() }
        .sheet(isPresented: $socialAccount) { AccountCenter().environmentObject(store).environmentObject(social) }
        .sheet(isPresented:Binding(get:{sheet != nil},set:{if !$0 { sheet = nil }})) {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    SheetHeader(title:sheet ?? "")
                    if sheet == "编辑资料" {
                        Text("球员名字").font(.headline);TextField("昵称",text:$nickname).inputStyle().onChange(of:nickname) { nickname = String($0.prefix(16)) }
                        Text("我的球龄").font(.headline);TextField("例如：打球 2 年",text:$years).inputStyle().onChange(of:years) { years = String($0.prefix(20)) }
                        Text("常用装备").font(.headline);TextField("球拍、球鞋…",text:$equipment).inputStyle().onChange(of:equipment) { equipment = String($0.prefix(60)) }
                        Note(text:"资料保存在本机，尚未同步到业务账号。")
                        Button("保存资料") { save();sheet = nil }.buttonStyle(PrimaryStyle()).disabled(nickname.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    } else if sheet == "装扮名片" {
                        PlayerCard(name:nickname,years:years,equipment:equipment,theme:theme)
                        ForEach(Array(["清新球场","赛场聚光","复古球票"].enumerated()),id:\.offset) { index,title in Button { theme = index } label: { HStack { Text(title);Spacer();Image(systemName:theme == index ? "checkmark.circle.fill":"circle") }.padding(18).background(Color.white).cornerRadius(14) } }
                        Note(text:"名片样式自动保存在本机。")
                    } else if sheet == "荣誉墙" { HonorsView() }
                    else if sheet == "音效偏好" { SoundPreferences() }
                    else { EmptyCard(icon:sheet == "我的高光" ? "play.rectangle":"person.crop.square",title:sheet == "我的高光" ? "精彩，值得被看见":"下一次登场，主角是你",detail:sheet == "我的高光" ? "录像与高光服务尚未接入。这里将展示你的真实比赛素材。":"专属出场素材制作尚未接入。你可以先在名片中设置自己的球员风格。") }
                }.padding(24)
            }.background(Palette.background.ignoresSafeArea())
        }
    }
    private func load() { let p = UserDefaults.standard.dictionary(forKey:key) as? [String:String] ?? [:];nickname = p["name"] ?? (social.credentials?.user.name ?? "羽球新朋友");years = p["years"] ?? "刚刚开始";equipment = p["equipment"] ?? "" }
    private func save() { UserDefaults.standard.set(["name":nickname.trimmingCharacters(in:.whitespacesAndNewlines),"years":years,"equipment":equipment],forKey:key) }
}
struct PlayerCard:View {
    let name:String;let years:String;let equipment:String;let theme:Int
    private var foreground:Color { theme == 1 ? Color(hex:0xf4ecd4):Palette.green }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack { Text(theme == 2 ? "PLAYER TICKET":"SHUTTLEREF  /  PLAYER").font(.system(size:10,weight:.semibold)).tracking(2);Spacer();Image(systemName:"figure.badminton") }
            HStack(spacing:18) {
                Text(String(name.prefix(1))).font(.system(size:32,weight:.medium)).frame(width:68,height:68).background(foreground.opacity(0.12)).clipShape(Circle())
                VStack(alignment:.leading,spacing:8) { Text(name).font(.system(size:25,weight:.bold)).lineLimit(2);Text(years).font(.system(size:13));if !equipment.isEmpty { Text(equipment).font(.system(size:12)).lineLimit(2) } }
            }.padding(.vertical,12)
            Rectangle().fill(foreground.opacity(0.2)).frame(height:1)
            HStack { Text("在球场，遇见更好的自己").font(.system(size:12));Spacer();Image(systemName:"sparkle") }
        }.foregroundColor(foreground).padding(24).frame(maxWidth:.infinity,alignment:.leading)
            .background(theme == 1 ? Color(hex:0x1c3228):theme == 2 ? Color(hex:0xf4e8cf):Color(hex:0xeef2e5))
            .overlay(RoundedRectangle(cornerRadius:theme == 2 ? 8:24).stroke(foreground.opacity(0.2),style:StrokeStyle(lineWidth:1,dash:theme == 2 ? [5]:[])))
            .cornerRadius(theme == 2 ? 8:24)
    }
}
struct HonorsView:View {
    @State private var expanded:String?
    private let medals = [("flag","初次上场","完成并归档你的第一场比赛"),("flame","坚持不懈","持续参加比赛，留下成长记录"),("bolt","关键一分","在关键比分中把握机会"),("person.2","默契搭档","与队友共同完成双打比赛"),("star","闪耀全场","在比赛中获得 MVP"),("trophy","突破自我","取得属于自己的新进步")]
    var body:some View {
        VStack(spacing:20) {
            Text("每一次认真，都有回响").font(.system(size:22,weight:.bold))
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:14) {
                ForEach(Array(medals.enumerated()),id:\.offset) { index,item in Button { expanded = expanded == item.1 ? nil:item.1 } label: { VStack(spacing:12) { Image(systemName:item.0).font(.system(size:28,weight:.light)).frame(width:62,height:62).foregroundColor(index < 3 ? Color.white : Palette.muted).background(index < 3 ? Palette.green : Palette.soft).clipShape(Circle());Text(item.1).font(.system(size:14,weight:.semibold));Text(index < 3 ? "已点亮" : "待解锁").font(.system(size:11)).foregroundColor(Palette.muted) }.frame(maxWidth:.infinity).padding(.vertical,22).background(Color.white).cornerRadius(20) } }
            }
            if let text = medals.first(where:{$0.1 == expanded})?.2 { Note(text:text) }
        }
    }
}
struct SoundPreferences:View {
    @AppStorage("ios.sound.enabled") private var enabled = true
    @AppStorage("ios.sound.volume") private var volume = 0.6
    @AppStorage("ios.sound.style") private var style = 0
    var body:some View {
        VStack(alignment:.leading,spacing:28) {
            Toggle("比赛音效",isOn:$enabled)
            Picker("音效风格",selection:$style) { Text("轻快").tag(0);Text("赛场").tag(1);Text("安静").tag(2) }.pickerStyle(.segmented)
            HStack { Text("音量");Spacer();Text("\(Int(volume*100))%") };Slider(value:$volume,in:0...1)
            Note(text:"偏好保存在本机，尚未下发设备，不会改变当前 T5 音量。")
        }
    }
}
