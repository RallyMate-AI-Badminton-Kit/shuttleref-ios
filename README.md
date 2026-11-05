# RallyMate · 随芯拍 iOS

<!-- team-handbook:start -->
> 团队协作：[成员入口](https://github.com/RallyMate-AI-Badminton-Kit/.github-private/blob/main/profile/README.md) · [开发与合并规范](https://github.com/RallyMate-AI-Badminton-Kit/.github-private/blob/main/handbook/workflow.md) · [负责人认领](https://github.com/RallyMate-AI-Badminton-Kit/.github-private/blob/main/handbook/ownership.md)
<!-- team-handbook:end -->


闭源团队项目的原生 iPhone 客户端，SwiftUI / CoreBluetooth / 涂鸦 Smart Life App SDK。最低 iOS 15，iPhone 竖屏。此仓库维护 App、客户端业务逻辑、资源及测试。

## 开发入口

```sh
# 不需要专属 SDK 或真实账号的主机侧检查
python3 Tools/verify_support.py
bash Tools/test_phone_score.sh

# 配置真实 SDK 构建；编辑目标文件，填入你自己的值
mkdir -p config/local
cp config/ios-sdk.env.example config/local/ios-sdk.env
python3 Tools/prepare_local.py
pod install
open ShuttleRef.xcworkspace
```

真实 App 选择 `ShuttleRef` scheme。SDK-free 预览选择 `ShuttleRefPreview`；预览不代表真实设备验证。Bundle ID 继续使用 `com.yahabib.shuttleref`，当前工程名称、协议与 App 显示名称沿用迁移前版本。

`Local/`、`ios_core_sdk/`、`config/local/`、`Pods/`、构建产物与签名文件不进入 Git。专属 SDK ZIP 和签名凭据由有权成员自行配置，迁移未上传或重新分发。

可用独立配置路径：`python3 Tools/prepare_local.py --config /path/to/ios-sdk.env`。

## 功能与状态

- 业务账号、拍底发现/认证/关联、模式切换与 Wi-Fi 配置。
- 手机蓝牙计分、树莓派开赛/结束请求、比赛副本同步与观赛。
- 战绩、比赛回放、个人展示统计和视频引用。
- 复盘教练、流式回答及手机本地的新建/历史对话。

展示资料中的 MVP 和部分统计是预设资料；录像及已导入观测具有独立来源。对话历史目前不跨手机同步。

计分状态区分“已连接、已认证、已配置、本场ready、最终ACK”；操作结果未知时保持保护并查询原请求，不自动重复加分。Pi未决事件跨重启恢复补丁尚未完成实机闭环，迁移不会改变该部署状态。

## 目录

```text
App/                 SDK、业务客户端与状态管理
Core/                协议、计分、存储及数据模型
UI/                  SwiftUI页面
Resources/           图标与展示资源
Tests/               Swift与跨语言主机测试
Tests/Support/       固定版本测试对照代码与来源清单
UITests/             模拟器交互检查
Tools/               本地环境准备、工程生成、测试
config/              公开配置模板；local/不提交
docs/                协议向量与迁移说明
```

## 依赖与仓库边界

运行时访问业务服务器、BLE设备及涂鸦 SDK；不需要将后端、树莓派或传感器源码放在本仓库旁边。`Tests/Support/provenance.json` 固定最小测试依赖来源，后续 contracts/edge/racket 仓库就绪后再统一调整维护来源。

`Tools/generate_project.rb` 可重建 Xcode 工程（需要 xcodeproj Ruby gem）；随后重新 `pod install`。签名设置放在 `Local/Signing.xcconfig`。

## 迁移来源

原仓库：`https://github.com/yahabibib/shuttleref`，源提交 `64889f4916aa63ef249572203a53b9c0c3e5b6d7`，原路径 `source/ios`。保留该目录的 Git 提交历史，子目录抽取后的提交 SHA 会变化。完整项目架构与历史交接继续保留在原仓库。迁移计划和验收结果见 `docs/superpowers/plans/2026-11-04-ios-repository-migration.md`。
