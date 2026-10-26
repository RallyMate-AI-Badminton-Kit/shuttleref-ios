import SwiftUI

enum Palette {
    static let background = Color(hex: 0xf6f7f2)
    static let ink = Color(hex: 0x172c28)
    static let green = Color(hex: 0x254e41)
    static let muted = Color(hex: 0x62736b)
    static let soft = Color(hex: 0xe9eee3)
    static let line = Color(hex: 0xe0e7d9)
    static let blue = Color(hex: 0x6c8698)
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) }
}
struct PrimaryStyle: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundColor(secondary ? Palette.green : .white)
            .background(secondary ? Palette.soft : Palette.green).cornerRadius(17)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
struct PageHeader: View {
    let title: String
    var back: (() -> Void)? = nil
    var deviceAction: (() -> Void)? = nil
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            if let back = back { Button(action: back) { Image(systemName: "chevron.left").font(.system(size: 21, weight: .semibold)).frame(width: 36, height: 44) }.accessibilityLabel("返回") }
            Text(title).font(.system(size: 28, weight: .bold)).minimumScaleFactor(0.8).lineLimit(1)
            Spacer(minLength: 4)
            if let deviceAction = deviceAction {
                Button(action: deviceAction) {
                    HStack(spacing: 5) { Circle().fill(store.session?.online == true ? Palette.green : Palette.muted).frame(width: 5, height: 5); Text(store.connection).font(.system(size: 11, weight: .medium)) }
                        .padding(.horizontal, 11).frame(minHeight: 44).background(Palette.soft).clipShape(Capsule())
                }.accessibilityIdentifier("device-entry")
            }
        }.foregroundColor(Palette.ink).padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
    }
}
struct MenuRow: View {
    let icon: String; let title: String; var subtitle: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24).foregroundColor(Palette.green)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 16, weight: .semibold)); if let subtitle = subtitle { Text(subtitle).font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true) } }
                Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.muted)
            }.foregroundColor(Palette.ink).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white).cornerRadius(18)
        }.buttonStyle(.plain)
    }
}
struct EmptyCard: View {
    let icon: String; let title: String; let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 33, weight: .light)).foregroundColor(Palette.green).frame(width: 74, height: 74).background(Palette.soft).clipShape(Circle())
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundColor(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
        }.padding(28).frame(maxWidth: .infinity).background(Color.white).cornerRadius(24)
    }
}
struct Note: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
}
struct SheetHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View { HStack { Text(title).font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }.accessibilityLabel("关闭") }.foregroundColor(Palette.ink) }
}
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View { content.padding(16).background(Color.white).cornerRadius(13).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line)).foregroundColor(Palette.ink) }
}
extension View { func inputStyle() -> some View { modifier(FieldStyle()) } }
