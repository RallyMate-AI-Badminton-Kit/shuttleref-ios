# 羽小裁 · Swift iPhone App

原生 SwiftUI 页面 + 涂鸦 Smart Life App SDK，蓝牙辅助配网沿用已验证的 UIKit 实现。当前只适配 iPhone 竖屏；无 RN、Android 或 Watch target。Bundle ID 保持 `com.yahabib.shuttleref`，最低系统 iOS 15。

## 在这台 Mac 运行

打开 **`source/ios/ShuttleRef.xcworkspace`**，选择 **ShuttleRef** scheme 和你的 iPhone，Stop → Run。现有签名 Team 已保存在被忽略的 `Local/Signing.xcconfig`。不要打开旧的 `/private/tmp` 验证工程。

同 Bundle ID、同签名覆盖安装可保留当前登录和本机数据。无需卸载 App，也无需重新烧录 T5。进入「我的 → 我的设备」，刷新家庭并选择之前绑定的设备；选定后将自动同步比分。首次从 v3 验证版迁移时需要选择一次设备。

`ShuttleRefPreview` 是独立的无 SDK 预览目标：可在模拟器运行，不加载凭据、不登录、不发 DP。顶部有预览标识；实时页的示例比分只存在于该目标。

## 已迁移

- 球局：首页、准备、单/双打球员布局与姓名、本局比分、撤销、暂存/恢复/放弃、设备结果展示、每日羽签。
- 战绩：日历翻月/日期与状态筛选、当前设备的本机暂存入口、无数据空态。
- 教练：羽毛球伙伴、三色/名字/显示设置、问题建议、后端文本对话、按账号保存本机历史；DeepSeek Key 待配置，见[链路验证记录](../../docs/product/ios-coach-chat-2026-10-29.md)。
- 我的：个人资料、三种名片风格、荣誉类别、账号设备入口、高光/出场空态、音效本机偏好。
- 账号设备：邮箱登录/注册、中国区验证码、家庭创建/查询、设备选择、蓝牙辅助 Wi-Fi 配网。

计分规则文案与固件一致：21 分、三局两胜。单/双打选择目前影响球员布局和本机名单，不会凭空添加固件尚未提供的双打发球轮转协议。

本机暂存兼容 v3 的 `shuttleref.spike.match.<uid>.<device>` 键，不跨手机同步；卸载会丢失。DP110 → DP101 匹配确认、超时结果未知、禁止自动重复加分的行为保持不变。

## 当前业务进度

战绩服务、熟人组局与邀请、MVP 展示以及 OAuth 业务身份关联已有实现。OAuth 真实网页兑换与 SDK 身份一致性已验证；最新原生授权回到 App 后出现请求超时，尚待排查，不能视为真机全链路通过。同步状态与配置说明见 [开发交接](../../docs/handoff/2026-10-26-development-sync.md) 与 [业务授权联调](../../docs/product/business-oauth-local.md)。

媒体完整链路和其他未接入页面仍需继续开发。AI 教练基础接线已完成本地验证，真实模型与真机对话待验证，以具体页面和验证记录为准。

## 新环境准备

1. 安装 Xcode 和 CocoaPods，准备用户自己的签名账号。
2. 在仓库根目录 `config/local/ios-sdk.env` 填写 `IOS_BUNDLE_ID`、`TUYA_IOS_APP_KEY`、`TUYA_IOS_APP_SECRET`、`APPLE_TEAM_ID`、`TUYA_IOS_SDK_ZIP`（专属 SDK ZIP 绝对路径）。该目录被忽略。
3. 从仓库根目录执行 `python3 source/ios/Tools/prepare_local.py`，安全生成被忽略的 `Local/AppKey.swift`、签名配置和专属 SDK 目录，不输出凭据。
4. `cd source/ios && pod install`。项目和 scheme 已入源码目录，不必重新生成。`Podfile.lock` 锁定已验证依赖，HomeKit 7.8.0.6、Cryption 5.0.0。
5. 打开 workspace，选择真实 iPhone。专属 SDK 缺少 LICENSE 的 CocoaPods 警告来自下载包，不伪造许可证。

`Tools/generate_project.rb` 只在需要重建工程或增加源文件时使用（需要 CocoaPods 的 xcodeproj Ruby gem），之后重新 `pod install`。它会覆盖工程级手工设置，签名请放 `Local/Signing.xcconfig`。本机 Homebrew 可执行：

```sh
GEM_HOME=/opt/homebrew/Cellar/cocoapods/1.17.0_1/libexec ruby Tools/generate_project.rb
pod install
```

## 结构与验证

- `Core/MatchWire.swift`：生产协议编码/快照解析。
- `Core/MatchSession.swift`：与视图、SDK 无关的设备确认和暂存状态。
- `App/AppStore.swift`：账号、家庭、设备、唯一 SDK 订阅与会话生命周期。
- `UI/`：SwiftUI 页面、球场绘制、主题组件。
- `Tests/main.swift`：27 项会话/协议检查；`UITests/JourneyTests.swift`：五个模拟器交互测试。

从仓库根目录运行会话检查：

```sh
swiftc -module-cache-path /private/tmp/shuttleref-swift-cache source/ios/Core/MatchWire.swift source/ios/Core/MatchSession.swift source/ios/Tests/main.swift -o /private/tmp/shuttleref-native-session-tests
/private/tmp/shuttleref-native-session-tests
```

在 Xcode 选择 `ShuttleRefPreview` 和模拟器后 Cmd+U 可运行 UI 测试。预览启动参数 `--screen prepare|live|records|coach|profile` 可指定截图页面。仅预览目标支持 `--reset-ui-state`，不会清理正式 App 数据。

真机回归清单和本轮证据见 [UI 交付记录](../../docs/product/swift-iphone-ui-validation-2026-10-25.md)。

## 球场动效预览

`ShuttleRefPreview` 的准备页增加「预览开赛动画」，实战预览中点击球员可演示加分，「预览撤销红方一分」演示减分。这些入口仅编译到预览目标，不连接设备，也不会修改正式 App 的球局。

启动参数 `--reset-ui-state --motion-tour` 可自动演示：首页展开 → 单打切双打 → 切回单打 → 再切双打 → 球网升起 → 双方加分 → 撤销 → 收起。真实 `ShuttleRef` 仍然等 DP101 确认才更新比分。

球场由原生 SwiftUI `Animatable` 的展开、抬升、分裂三个插值参数统一绘制。首页小球和准备页我方主球持续使用同一个 actor；单双打用主球横移与队友原位淡入淡出，已移除细颈分裂效果。正式开赛后远端半场加长 28%，远端球员后移；球网及近端半场保持原有设计。场地、球员落点、网面和网柱共用透视投影，无第三方动画依赖。

动画按系统「减少动态效果」设置关闭；离开球场、打开设备面板或 App 非活跃时暂停连续动画。首次同步、恢复、换球局、换设备和换局总分不会触发加分庆祝。

正式对局的姓名固定在球体下方，比分位于球体上方；规则说明移到球场下方独立显示。UI 回归覆盖单打和双打姓名可见、规则行位于近端比分下方，并保存截图核对文字遮挡。

## 熟人组局本地服务

球局首页新增「约朋友打球」。本地 Compose、API 地址配置、数据库迁移、身份恢复和真机清单见 [本地组局说明](../../docs/product/friends-gathering-local.md)。Debug 专用 ATS 允许局域网 HTTP；Release 通过 `SocialAPIOrigin` 注入 HTTPS 地址，`SocialInviteOrigin` 可选。新增源文件后使用上述 Ruby 命令重建工程，并重新 `pod install`。

## 手机作为比赛主机（2026-10-29，底层开发阶段）

新增独立 `PhoneMatchSession`、SQLite 事务存储、拍底 SCORE 协议与模拟 transport；原涂鸦主机模式不变。当前没有开放 UI 或真实 BLE 比赛入口，同步适配器明确不可用。实现范围、测试与后续接线见 [手机计分第一阶段交接](../../docs/handoff/2026-10-29-racket-phone-scoring-app-validation.md)。

```sh
bash source/ios/Tools/test_phone_score.sh
```
