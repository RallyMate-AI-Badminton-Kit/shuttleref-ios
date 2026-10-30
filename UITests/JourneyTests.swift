import XCTest
import UIKit

final class JourneyTests:XCTestCase {
    private var app:XCUIApplication!
    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset-ui-state"]
        app.launch()
    }
    private func capture(_ name:String) {
        let attachment = XCTAttachment(screenshot:app.screenshot());attachment.name = name;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testDemoReplayFromRecordsAndCoachReference() {
        app.terminate();app.launchArguments=["--reset-ui-state","--replay-demo","--screen","records"];app.launch()
        let demo=app.buttons["replay-demo-match"]
        for _ in 0..<8 { if demo.isHittable { break };app.swipeUp() }
        XCTAssertTrue(demo.waitForExistence(timeout:5));demo.tap()
        XCTAssertTrue(app.staticTexts["第三局 · 最后一分"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["20 : 19 → 21 : 19"].exists)
        capture("回放-演示比赛最后一分")
        app.buttons["replay-play-final"].tap()
        XCTAssertTrue(app.buttons["replay-retry"].waitForExistence(timeout:5))
        app.buttons["replay-retry"].tap()
        XCTAssertTrue(app.staticTexts["界面演示 · 播放器状态"].waitForExistence(timeout:5))
        capture("回放-播放器重试状态")
        app.buttons["replay-close"].tap()
        app.buttons["replay-ask-point"].tap()
        XCTAssertTrue(app.buttons["coach-remove-reference"].waitForExistence(timeout:5))
        capture("回放-引用最后一分问教练")
        app.buttons["coach-send"].tap()
        XCTAssertTrue(app.buttons["查看片段"].waitForExistence(timeout:8))
        capture("回放-教练引用卡片")
        app.buttons["查看片段"].tap()
        XCTAssertTrue(app.buttons["replay-retry"].waitForExistence(timeout:5))
    }
    func testRecordsPeriodNavigation() {
        app.buttons["tab-1"].tap()
        XCTAssertTrue(app.staticTexts["每一次上场，都算数"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["年"].tap()
        XCTAssertTrue(app.buttons["1 月"].exists || app.staticTexts["1 月"].exists)
        capture("战绩-年度")
        app.segmentedControls.buttons["周"].tap()
        capture("战绩-周视图")
        app.buttons["上一个周期"].tap()
        app.segmentedControls.buttons["月"].tap()
        capture("战绩-月日历")
    }
    func testRacketEntryFromDevicesAndNestedAccount() {
        app.buttons["tab-3"].tap()
        let devices = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的设备")).firstMatch
        XCTAssertTrue(devices.waitForExistence(timeout: 5)); devices.tap()
        XCTAssertTrue(app.staticTexts["设备与连接"].waitForExistence(timeout: 5))
        let rackets = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "球拍与拍底")).firstMatch
        XCTAssertTrue(rackets.waitForExistence(timeout: 5)); rackets.tap()
        XCTAssertTrue(app.staticTexts["请先登录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["添加拍底"].exists)
        app.buttons["账号与安全"].tap()
        XCTAssertTrue(app.staticTexts["账号与安全"].waitForExistence(timeout: 5))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["请先登录"].waitForExistence(timeout: 5))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["设备与连接"].waitForExistence(timeout: 5))
        rackets.tap()
        XCTAssertTrue(app.staticTexts["请先登录"].waitForExistence(timeout: 5))
        capture("拍底-真实设备入口与账号返回")
    }
    func testRacketAssociationRequiresDeviceConfirmation() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--racket-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["模拟环境 · 不连接真实设备"].waitForExistence(timeout: 10))
        let row = app.buttons["racket-row-mock-racket-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let bind = app.buttons["关联到我"]
        XCTAssertTrue(bind.waitForExistence(timeout: 5))
        XCTAssertTrue(bind.isEnabled)
        capture("拍底-关联确认")
        bind.tap()
        XCTAssertTrue(app.staticTexts["正在等待设备确认"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["已关联到我"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["解除关联"].exists)
        capture("拍底-设备确认后关联成功")
    }
    func testRacketBluetoothDiscoverySharesAssociationScreen() {
        app.terminate(); app.launchArguments = ["--reset-ui-state", "--racket-demo"]; app.launch()
        let add = app.buttons["添加拍底"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        for _ in 0..<5 { if add.isHittable { break }; app.swipeUp() }
        add.tap()
        let search = app.buttons["搜索附近拍底"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        let candidate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模拟附近拍底")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5)); candidate.tap()
        XCTAssertTrue(app.staticTexts["拍底使用者"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["关联到我"].isEnabled)
        capture("拍底-蓝牙验证后共用关联页")
    }
    func testClipboardInvitationOnLaunchAndDeduplication() {
        app.terminate()
        let code = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        app.launchEnvironment["SHUTTLEREF_TEST_CLIPBOARD"] = "🏸 一起打球｜邀请测试\nhttps://example.com/invite/" + code
        app.launchArguments = ["--reset-ui-state", "--social-live-test"]
        let handler = addUIInterruptionMonitor(withDescription: "Paste permission") { alert in
            for title in ["Allow Paste", "允许粘贴"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        defer { removeUIInterruptionMonitor(handler) }
        app.launch()
        let invitation = app.alerts["发现球局邀请"]
        if !invitation.waitForExistence(timeout: 3) { app.tap() }
        XCTAssertTrue(invitation.waitForExistence(timeout: 10))
        invitation.buttons["暂不查看"].tap()
        app.terminate(); app.launchArguments = ["--social-live-test"]; app.launch()
        XCTAssertFalse(invitation.waitForExistence(timeout: 3), "Same invitation must not repeatedly prompt after relaunch")
        app.terminate()
        app.launchEnvironment["SHUTTLEREF_TEST_CLIPBOARD"] = "邀请码：" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        app.launch()
        XCTAssertTrue(invitation.waitForExistence(timeout: 10))
        invitation.buttons["查看邀请"].tap()
        XCTAssertTrue(app.navigationBars["球局邀请"].waitForExistence(timeout: 10))
    }
    func testProfileGatheringAccountEntry() {
        app.buttons["tab-3"].tap()
        let account = app.buttons["profile-gathering-account"]
        if !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.waitForExistence(timeout: 5)); account.tap()
        XCTAssertTrue(app.staticTexts["账号与安全"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["手机号（不含国家区号）"].exists)
        app.buttons["关闭"].firstMatch.tap()
        let gatherings = app.buttons["profile-gatherings"]
        XCTAssertTrue(gatherings.waitForExistence(timeout: 5)); gatherings.tap()
        XCTAssertTrue(app.navigationBars["约朋友打球"].waitForExistence(timeout: 5))
    }
    func testLoginMethodsAndGuestAccountCenter() {
        app.buttons["tab-3"].tap()
        app.buttons["登录羽小裁"].tap()
        XCTAssertTrue(app.staticTexts["账号与安全"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["手机号（不含国家区号）"].exists)
        XCTAssertFalse(app.buttons["登录"].isEnabled)
        app.segmentedControls.buttons["邮箱验证码"].tap()
        XCTAssertTrue(app.textFields["邮箱"].exists)
        XCTAssertTrue(app.textFields["验证码"].exists)
        XCTAssertFalse(app.secureTextFields["密码"].exists)
        app.segmentedControls.buttons["邮箱密码"].tap()
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        XCTAssertFalse(app.textFields["验证码"].exists)
        app.segmentedControls.buttons["注册"].tap()
        XCTAssertTrue(app.textFields["验证码"].exists)
        app.segmentedControls.buttons["手机验证码"].tap()
        XCTAssertFalse(app.secureTextFields["密码"].exists)
        XCTAssertFalse(app.buttons["登录"].isEnabled)
        capture("账号中心-手机邮箱登录")
    }
    func testEarlyEndShowsMVPBeforeAndAfterPause() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "live", "--settlement-ui-test"]
        app.launch()
        app.scrollViews["court-scroll"].swipeUp()
        let exit = app.buttons["暂存 / 提前结束"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5)); exit.tap()
        app.buttons["提前结束，可选 MVP"].tap()
        XCTAssertTrue(app.staticTexts["提前结束本场"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mvp-2"].exists)
        app.buttons["mvp-2"].tap()
        app.buttons["确认提前结束"].tap()
        XCTAssertTrue(app.staticTexts["本场 MVP"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["mvp-portrait-animation"].exists)
        app.buttons["跳过动画"].tap()
        XCTAssertTrue(app.staticTexts["celebration-player"].exists)
        XCTAssertFalse(app.staticTexts["人像素材未就绪，请重新安装完整 App"].exists)
        capture("提前结束-MVP-展示")
        app.buttons["查看本场结果"].tap()
        XCTAssertTrue(app.staticTexts["成绩与 MVP 已保存到本机"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["提前结束本场"].exists)
        capture("提前结束-MVP-保存后")
        app.buttons["replay-settlement"].tap()
        XCTAssertTrue(app.staticTexts["本场 MVP"].waitForExistence(timeout: 5))
        app.buttons["跳过动画"].tap()
        XCTAssertTrue(app.staticTexts["celebration-player"].exists)
        app.buttons["查看本场结果"].tap()
        XCTAssertTrue(app.staticTexts["提前结束本场"].waitForExistence(timeout: 5))
    }
    func testPortraitMVPOriginalKeyframes() {
        for frame in ["1.0", "1.7", "3.6", "7.8"] {
            app.terminate()
            app.launchArguments = ["--reset-ui-state", "--screen", "live", "--settlement-ui-test"]
            app.launchEnvironment["MVP_FRAME_TEST"] = frame
            app.launch()
            app.scrollViews["court-scroll"].swipeUp()
            app.buttons["暂存 / 提前结束"].tap()
            app.buttons["提前结束，可选 MVP"].tap()
            XCTAssertTrue(app.buttons["mvp-2"].waitForExistence(timeout: 5))
            app.buttons["mvp-2"].tap()
            app.buttons["确认提前结束"].tap()
            XCTAssertTrue(app.otherElements["mvp-portrait-animation"].waitForExistence(timeout: 5))
            capture("MVP原设计-" + frame + "秒")
            XCTAssertFalse(app.staticTexts["人像素材未就绪，请重新安装完整 App"].exists)
        }
    }
    func testEarlyEndWithoutMVPShowsPlainResult() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "live", "--settlement-ui-test"]
        app.launch()
        app.scrollViews["court-scroll"].swipeUp()
        app.buttons["暂存 / 提前结束"].tap()
        app.buttons["提前结束，可选 MVP"].tap()
        XCTAssertTrue(app.buttons["不评选 MVP"].waitForExistence(timeout: 5))
        app.buttons["不评选 MVP"].tap()
        app.buttons["确认提前结束"].tap()
        XCTAssertTrue(app.staticTexts["本场已结束"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["本场 MVP"].exists)
        XCTAssertTrue(app.staticTexts["8 : 6"].exists)
        app.buttons["查看本场结果"].tap()
        XCTAssertTrue(app.staticTexts["提前结束本场"].waitForExistence(timeout: 5))
        app.swipeUp()
        let clear = app.buttons["清空设备比分，准备下一场"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5)); clear.tap()
        let entry = app.buttons["prepare-match"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.label, "准备开赛", "Idle device retaining the ended match ID must not show ended-match text")
        XCTAssertFalse(app.staticTexts["本场已结束，精彩已留下"].exists)
        entry.tap()
        XCTAssertTrue(app.staticTexts["准备开赛"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["开始比赛"].exists)
    }
    func testGatheringLocalCreatePublishAndOfflineDeviceGuard() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--social-live-test"]
        app.launch()
        app.scrollViews["court-scroll"].swipeUp()
        let entry = app.buttons["gathering-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout:5)); entry.tap()
        let name = app.textFields["你的球场昵称"]
        if name.waitForExistence(timeout:2) {
            name.tap(); name.typeText("UITest")
            app.buttons["创建组局身份"].tap()
            XCTAssertTrue(app.staticTexts["组局身份与服务器"].waitForExistence(timeout:20), "Status: " + (app.staticTexts["gathering-message"].exists ? app.staticTexts["gathering-message"].label : "no message"))
            app.buttons["关闭"].firstMatch.tap()
        }
        let create = app.buttons["gathering-create"]
        XCTAssertTrue(create.waitForExistence(timeout:15)); create.tap()
        let title = "UI Local Gathering"
        app.textFields["活动名称（最多30字）"].tap()
        app.textFields["活动名称（最多30字）"].typeText(title)
        app.textFields["球馆或地点"].tap()
        app.textFields["球馆或地点"].typeText("Local Court")
        app.swipeUp()
        app.buttons["保存草稿"].tap()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout:20))
        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.buttons["确认发布"].waitForExistence(timeout:5))
        app.buttons["确认发布"].tap()
        XCTAssertTrue(app.buttons["生成新邀请并分享"].waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["报名名单 · 1/8"].exists)
        capture("组局-真实本地服务-已发布")
    }
    func testCourtPreparationAndOfflineGuard() {
        let start = app.buttons["prepare-match"]
        XCTAssertTrue(start.waitForExistence(timeout:10));capture("球局首页")
        start.tap()
        XCTAssertTrue(app.staticTexts["准备开赛"].waitForExistence(timeout:3))
        app.segmentedControls.buttons["双打"].tap()
        XCTAssertTrue(app.buttons["编辑我方队友"].exists)
        app.segmentedControls.buttons["单打"].tap()
        XCTAssertFalse(app.buttons["编辑我方队友"].exists)
        XCTAssertTrue(app.buttons["编辑我方球员"].exists)
        app.segmentedControls.buttons["双打"].tap()
        app.buttons["编辑我方球员"].tap()
        XCTAssertTrue(app.textFields["输入名字"].waitForExistence(timeout:3))
        app.buttons["关闭"].tap()
        app.scrollViews["court-scroll"].swipeUp()
        XCTAssertTrue(app.buttons["开始比赛"].exists)
        XCTAssertFalse(app.buttons["开始比赛"].isEnabled)
        capture("准备开赛-离线")
    }
    func testCourtMotionPreview() {
        app.buttons["prepare-match"].tap()
        app.segmentedControls.buttons["双打"].tap()
        app.scrollViews["court-scroll"].swipeUp()
        app.buttons["preview-start"].tap()
        app.scrollViews["court-scroll"].swipeDown()
        XCTAssertTrue(app.staticTexts["本局得分"].waitForExistence(timeout:3))
        XCTAssertEqual(app.staticTexts["court-score-0"].label,"8")
        app.buttons["红方加一分"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["court-score-0"].label,"9")
        app.buttons["蓝方加一分"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["court-score-1"].label,"7")
        capture("球场-双打得分")
        app.scrollViews["court-scroll"].swipeUp()
        app.buttons["预览撤销红方一分"].tap()
        app.scrollViews["court-scroll"].swipeDown()
        XCTAssertEqual(app.staticTexts["court-score-0"].label,"8")
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["prepare-match"].waitForExistence(timeout:3))
        capture("球场-收起")
    }
    func testLiveSinglesAndDoublesLabelsAndRules() {
        for doubles in [false,true] {
            app.buttons["prepare-match"].tap()
            app.segmentedControls.buttons[doubles ? "双打":"单打"].tap()
            app.scrollViews["court-scroll"].swipeUp()
            app.buttons["preview-start"].tap()
            app.scrollViews["court-scroll"].swipeDown()
            XCTAssertTrue(app.staticTexts["本局得分"].waitForExistence(timeout:3))
            for index in doubles ? [0,1,2,3]:[0,2] {
                let name = app.staticTexts["court-player-name-\(index)"]
                XCTAssertTrue(name.exists)
                // SwiftUI exposes the enclosing player's 100pt touch region here,
                // not the rendered text bounds. Inspect label separation in captures.
            }
            let rules = app.staticTexts["live-match-rules"]
            XCTAssertTrue(rules.exists)
            XCTAssertGreaterThan(rules.frame.minY,app.staticTexts["court-score-0"].frame.maxY)
            capture(doubles ? "双打-姓名比分分离":"单打-姓名比分分离")
            app.buttons["返回"].tap()
        }
    }
    func testTabsCalendarAndProfileThemes() {
        app.buttons["tab-1"].tap()
        XCTAssertTrue(app.staticTexts["把每一场，留在这里"].waitForExistence(timeout:3))
        app.buttons["上个月"].tap();app.buttons["下个月"].tap()
        app.segmentedControls.buttons["未完成"].tap();capture("战绩日历")
        app.buttons["tab-3"].tap()
        XCTAssertTrue(app.buttons["装扮名片 ↗"].waitForExistence(timeout:3))
        app.buttons["装扮名片 ↗"].tap()
        app.buttons["赛场聚光"].tap();capture("名片-赛场聚光")
        app.buttons["复古球票"].tap();capture("名片-复古球票")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["编辑资料"].exists)
    }
    func testCoachDraftAndAccountEntry() {
        app.buttons["tab-2"].tap()
        let prompt = "我的后场高远球总是打不远"
        XCTAssertTrue(app.buttons[prompt].waitForExistence(timeout:3));app.buttons[prompt].tap()
        XCTAssertTrue(app.buttons["coach-back"].waitForExistence(timeout:3))
        XCTAssertFalse(app.buttons["tab-0"].isHittable)
        XCTAssertTrue((app.textViews["coach-question"].value as? String)?.contains(prompt) == true)
        capture("教练草稿")
        app.buttons["coach-send"].tap()
        XCTAssertTrue(app.staticTexts["账号与安全"].waitForExistence(timeout:3))
        XCTAssertTrue(app.textFields["手机号（不含国家区号）"].exists)
        capture("教练-登录入口")
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue((app.textViews["coach-question"].value as? String)?.contains(prompt) == true)
        app.buttons["coach-back"].tap()
        XCTAssertTrue(app.buttons["tab-0"].waitForExistence(timeout:3))
        app.buttons["coach-open-chat"].tap()
        XCTAssertTrue((app.textViews["coach-question"].value as? String)?.contains(prompt) == true)
    }
    func testCoachFullscreenComposerAndHistory() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "coach", "--coach-demo"]
        app.launch()
        let open = app.buttons["coach-open-chat"]
        XCTAssertTrue(open.waitForExistence(timeout:5))
        capture("教练-首页")
        open.tap()
        XCTAssertTrue(app.buttons["coach-back"].waitForExistence(timeout:3))
        XCTAssertFalse(app.buttons["tab-2"].isHittable)
        let input = app.textViews["coach-question"]
        XCTAssertTrue(input.exists)
        capture("教练-全屏聊天")
        app.scrollViews["coach-messages"].swipeDown()
        XCTAssertTrue(app.buttons["coach-latest"].waitForExistence(timeout:3))
        app.buttons["coach-latest"].tap()
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        input.typeText("How should I practice?\nKeep it simple.\nLine three.\nLine four.\nLine five.\nLine six.")
        XCTAssertLessThanOrEqual(input.frame.maxY, app.frame.maxY)
        XCTAssertLessThan(input.frame.height, 150)
        XCTAssertTrue(app.buttons["coach-send"].isHittable)
        capture("教练-多行输入")
        app.buttons["coach-send"].tap()
        XCTAssertTrue(app.staticTexts["界面演示回复：先练习分腿垫步，再做两组轻松的移动。"].waitForExistence(timeout:5))
        XCTAssertTrue((input.value as? String ?? "").isEmpty)
        app.buttons["coach-history"].tap()
        XCTAssertTrue(app.staticTexts["历史对话"].waitForExistence(timeout:3))
        app.buttons["关闭"].firstMatch.tap()
        app.buttons["coach-back"].tap()
        XCTAssertTrue(open.waitForExistence(timeout:3));open.tap()
        XCTAssertTrue(app.staticTexts["界面演示回复：先练习分腿垫步，再做两组轻松的移动。"].waitForExistence(timeout:3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
    func testCoachChineseCompositionAtLimit() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "coach", "--coach-input-check"]
        app.launch()
        let result = app.staticTexts["coach-input-check"]
        XCTAssertTrue(result.waitForExistence(timeout:5))
        XCTAssertEqual(result.label, "PASS")
    }
    func testCoachSoftwareKeyboardLayout() throws {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "coach", "--coach-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["coach-open-chat"].waitForExistence(timeout:5))
        app.buttons["coach-open-chat"].tap()
        let input = app.textViews["coach-question"]
        XCTAssertTrue(input.waitForExistence(timeout:3)); input.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout:3))
        // Headless simulators may expose an accessibility keyboard below the screen.
        // That is hardware-keyboard mode, not evidence of successful keyboard avoidance.
        guard keyboard.frame.intersection(app.frame).height > 200 else {
            throw XCTSkip("屏幕键盘未显示在模拟器可见区域，需在启用软件键盘的模拟器或真机验证。")
        }
        input.typeText("First line\nSecond line\nThird line\nFourth line\nFifth line")
        XCTAssertLessThan(keyboard.frame.minY, app.frame.maxY - 200)
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY + 2)
        XCTAssertTrue(app.buttons["coach-send"].isHittable)
        let shot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        shot.name = "教练-屏幕键盘"; shot.lifetime = .keepAlways; add(shot)
    }
    func testCoachMarkdownAndRichCards() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "coach", "--coach-rich-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["coach-open-chat"].waitForExistence(timeout:5))
        app.buttons["coach-open-chat"].tap()
        XCTAssertTrue(app.staticTexts["演示数据 · 本局回顾"].waitForExistence(timeout:3))
        XCTAssertTrue(app.staticTexts["演示片段 · 第 3 回合"].exists)
        XCTAssertTrue(app.staticTexts["01:12 – 01:26"].exists)
        XCTAssertTrue(app.staticTexts["视频播放尚未接入"].exists)
        XCTAssertFalse(app.buttons["查看片段"].exists)
        capture("教练-富消息卡片")
        app.scrollViews["coach-messages"].swipeDown()
        XCTAssertTrue(app.staticTexts["今日练习建议"].exists)
        XCTAssertFalse(app.staticTexts["## 今日练习建议"].exists)
        XCTAssertTrue(app.staticTexts["启动步伐"].exists)
        XCTAssertTrue(app.staticTexts["后场移动"].exists)
        capture("教练-Markdown排版")
        app.buttons["coach-history"].tap()
        XCTAssertTrue(app.staticTexts["今日练习建议"].waitForExistence(timeout:3))
        capture("教练-富消息历史")
    }
    func testCoachStreamingStopAndReading() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "coach", "--coach-stream-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["coach-open-chat"].waitForExistence(timeout:5))
        app.buttons["coach-open-chat"].tap()
        let input = app.textViews["coach-question"]
        input.tap(); input.typeText("First question")
        app.buttons["coach-send"].tap()
        XCTAssertTrue(app.staticTexts["界面演示：第一段已到达。"].waitForExistence(timeout:2))
        XCTAssertTrue(app.buttons["coach-stop"].exists)
        capture("教练-流式首段")
        app.buttons["coach-stop"].tap()
        XCTAssertTrue(app.staticTexts["已停止 · 回复未完成"].waitForExistence(timeout:3))
        capture("教练-已停止保留内容")
        input.tap(); input.typeText("Second question")
        app.buttons["coach-send"].tap()
        XCTAssertTrue(app.buttons["coach-stop"].waitForExistence(timeout:2))
        let scroll = app.scrollViews["coach-messages"]
        let old = app.staticTexts["打球前怎么热身？"]
        for _ in 0..<5 { if old.isHittable { break }; scroll.swipeDown() }
        XCTAssertTrue(old.isHittable)
        let finished = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"), object:app.buttons["coach-stop"])
        XCTAssertEqual(XCTWaiter.wait(for:[finished],timeout:10), .completed)
        XCTAssertTrue(old.isHittable, "Receiving a reply must not drag the reader away from history")
        app.buttons["coach-latest"].tap()
        XCTAssertTrue(app.staticTexts["下一步"].waitForExistence(timeout:3))
        capture("教练-流式完成Markdown")
    }
    func testCoachFirstStreamKeepsLatestAndCompletionPosition() {
        app.terminate()
        app.launchArguments = ["--reset-ui-state", "--screen", "coach", "--coach-empty-stream-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["coach-open-chat"].waitForExistence(timeout:5)); app.buttons["coach-open-chat"].tap()
        let input=app.textViews["coach-question"]; input.tap(); input.typeText("Long answer")
        app.buttons["coach-send"].tap()
        let ending=app.staticTexts["完成前最后一段。"]
        XCTAssertTrue(ending.waitForExistence(timeout:6))
        app.scrollViews["coach-messages"].swipeDown()
        XCTAssertTrue(app.buttons["coach-latest"].waitForExistence(timeout:2), "First stream also needs a latest button")
        app.buttons["coach-latest"].tap()
        XCTAssertTrue(ending.isHittable)
        let finished=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.buttons["coach-stop"])
        XCTAssertEqual(XCTWaiter.wait(for:[finished],timeout:15),.completed)
        XCTAssertTrue(ending.isHittable, "Completing a streamed answer must stay at its end")
        capture("教练-长回答完成位置")
    }
}
