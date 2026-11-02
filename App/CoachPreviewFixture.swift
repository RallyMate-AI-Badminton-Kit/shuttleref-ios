#if UI_PREVIEW && DEBUG
import Foundation
import SwiftUI
import UIKit

/// Explicit UI-only fixture. Neither this identity nor these replies reach a server.
@MainActor enum CoachPreviewFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--coach-demo") || richEnabled || streamEnabled || ReplayPreviewFixture.enabled }
    static var emptyStream: Bool { ProcessInfo.processInfo.arguments.contains("--coach-empty-stream-demo") }
    static var streamEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--coach-stream-demo") || emptyStream }
    static var richEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--coach-rich-demo") }
    static let context = CoachContext(origin: "https://coach-preview.invalid", userID: "ui-preview", token: "not-a-real-session")
    /// Exercises the actual UITextView coordinator with an active IME marked range.
    static func checkComposition() -> Bool {
        let store = CoachStore(defaults: UserDefaults(suiteName: "shuttleref.coach.input-check")!)
        let prefix = String(repeating: "羽", count: 599)
        store.draft = prefix
        let input = CoachGrowingInput(text: Binding(get: { store.draft }, set: { store.draft = $0 }),
                                      focused: .constant(false), height: .constant(44), editable: true)
        let coordinator = input.makeCoordinator()
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        view.delegate = coordinator
        coordinator.synchronize(view)
        view.selectedRange = NSRange(location: 599, length: 0)
        view.setMarkedText("qiu", selectedRange: NSRange(location: 3, length: 0))
        guard view.markedTextRange != nil else { return false }
        coordinator.textViewDidChange(view)
        coordinator.synchronize(view)
        guard view.markedTextRange != nil, view.text == prefix + "qiu", store.draft == prefix else { return false }
        view.setMarkedText("球", selectedRange: NSRange(location: 1, length: 0))
        view.unmarkText()
        coordinator.textViewDidChange(view)
        coordinator.synchronize(view)
        guard view.text == prefix + "球", store.draft == prefix + "球" else { return false }
        view.setMarkedText("qiu", selectedRange: NSRange(location: 3, length: 0))
        store.draft = "账号已切换"
        coordinator.synchronize(view)
        return view.text == "账号已切换" && view.markedTextRange == nil
    }
    static func makeStore() -> CoachStore {
        let defaults = UserDefaults(suiteName: "shuttleref.coach.ui-preview")!
        var messages: [CoachMessage] = []
        for question in ["打球前怎么热身？", "怎么练习启动步伐？", "高远球总是打不远怎么办？"] {
            messages.append(CoachMessage(role: "user", content: question))
            messages.append(CoachMessage(role: "assistant", content: "界面演示：我们先从一个小目标开始。\n\n先观察自己的准备姿势，放松肩膀，让身体保持能够随时移动的状态。每一组只关注一个动作，不需要一开始就追求速度。\n\n练习时可以分成三步：\n1. 用慢速找到稳定的动作。\n2. 每组重复几次，留意动作是否一致。\n3. 休息后再增加一点速度。\n\n下一次练习时，告诉我哪一步最难，我们再一起调整。"))
        }
        if richEnabled {
            let markdown = """
            ## 今日练习建议

            **先站稳，再挥拍。** 以下为界面演示，不是你的真实比赛分析。

            1. 分腿垫步，保持放松。
            2. 找到击球点，再增加速度。

            > 每次只关注一个动作，休息后再练。

            | 练习 | 组数 | 每组 |
            | --- | ---: | --- |
            | 启动步伐 | 3 | 8 次 |
            | 后场移动 | 2 | 6 次 |
            """
            messages = [CoachMessage(role: "user", content: "看看练习建议和比赛片段的展示效果"),
                CoachMessage(role: "assistant", content: markdown, blocks: [
                    .markdown(id: "advice", text: markdown),
                    CoachContentBlock(id: "demo-stats", type: "metrics", title: "演示数据 · 本局回顾", metrics: [
                        .init(label: "回合数", value: "18", unit: "次"),
                        .init(label: "最长回合", value: "12", unit: "拍")
                    ], source: .init(id: "preview-match", label: "界面演示 · 非真实比赛", kind: "match")),
                    CoachContentBlock(id: "demo-clip", type: "video_clip", title: "演示片段 · 第 3 回合",
                        video: .init(assetID: "preview-asset", startSeconds: 72, endSeconds: 86),
                        source: .init(id: "preview-rally", label: "界面演示 · 未接入视频", kind: "rally"))
                ])]
        }
        if emptyStream || ReplayPreviewFixture.enabled { messages = [] }
        defaults.set(try! JSONEncoder().encode(CoachHistory(messages: messages)), forKey: context.storageKey)
        let store: CoachStore
        if ReplayPreviewFixture.enabled {
            store=CoachStore(defaults:defaults,referencedStreaming:{ _,_,references,onDelta,onMetadata in
                let text="这是演示比赛。红方以 2:1 获胜，第三局最后一分从 20:19 到 21:19。尚未分析视频动作。"
                let point=ReplayPreviewFixture.match.points[0]
                let blocks=[CoachContentBlock(id:"preview-replay-clip",type:"video_clip",title:"演示比赛 · 第三局最后一分",video:point.video.reference,source:.init(id:ReplayPreviewFixture.match.id,label:"演示比分 · 真实录像 · 未导入视觉分析",kind:"match"))]
                onMetadata(references,blocks);onDelta(text)
                try await Task.sleep(nanoseconds:300_000_000)
                return CoachReply(reply:text,blocks:[.markdown(id:"answer",text:text)]+blocks,references:references)
            })
        } else if streamEnabled {
            store = CoachStore(defaults:defaults, streaming: { _, _, onDelta in
                let first = "界面演示：第一段已到达。"
                onDelta(first)
                try await Task.sleep(nanoseconds:3_000_000_000)
                let second = emptyStream
                    ? "\n\n" + (1...16).map { "练习第 \($0) 组：放松肩膀，找到稳定的准备姿势，再轻松移动。" }.joined(separator:"\n\n") + "\n\n完成前最后一段。"
                    : "\n\n## 下一步\n\n先练习分腿垫步，再做两组轻松的移动。"
                onDelta(second)
                try await Task.sleep(nanoseconds:emptyStream ? 10_000_000_000 : 3_000_000_000)
                return CoachReply(reply:first+second)
            })
        } else {
            store = CoachStore(defaults: defaults) { _, _ in
                try await Task.sleep(nanoseconds: 600_000_000)
                return "界面演示回复：先练习分腿垫步，再做两组轻松的移动。"
            }
        }
        store.bind(context)
        return store
    }
}

@MainActor enum ReplayPreviewFixture {
    static var enabled:Bool { ProcessInfo.processInfo.arguments.contains("--replay-demo") }
    static let match:ReplayMatch = try! JSONDecoder().decode(ReplayMatch.self,from:Data(#"""
{
  "schema_version": 1,
  "seed_key": "binbin-final-point-replay-20261030-v1",
  "match_id": "bc268761d8e55466a17a47853fbe3dff",
  "owner_id": "ui-preview",
  "is_demo": true,
  "title": "止戈 / 简宁 vs 玉琮 / Clio",
  "played_at": "2026-10-30T03:00:00Z",
  "date_source": "demo_fixture",
  "round": {
    "index": 1,
    "label": "决胜轮（演示）"
  },
  "mode": "doubles",
  "rules": "badminton-21-cap30-best3-v1",
  "status": "completed",
  "participants": [
    {
      "id": "red-1",
      "name": "止戈",
      "user_id": "ui-preview",
      "side": "red"
    },
    {
      "id": "red-2",
      "name": "简宁",
      "user_id": null,
      "side": "red"
    },
    {
      "id": "blue-1",
      "name": "玉琮",
      "user_id": null,
      "side": "blue"
    },
    {
      "id": "blue-2",
      "name": "Clio",
      "user_id": null,
      "side": "blue"
    }
  ],
  "games": [
    {
      "game_id": "bc268761d8e55466a17a47853fbe3dff-g1",
      "number": 1,
      "red": 21,
      "blue": 18,
      "winner_side": "red"
    },
    {
      "game_id": "bc268761d8e55466a17a47853fbe3dff-g2",
      "number": 2,
      "red": 18,
      "blue": 21,
      "winner_side": "blue"
    },
    {
      "game_id": "bc268761d8e55466a17a47853fbe3dff-g3",
      "number": 3,
      "red": 21,
      "blue": 19,
      "winner_side": "red"
    }
  ],
  "result": {
    "red_games": 2,
    "blue_games": 1,
    "winner_side": "red",
    "mvp": null
  },
  "points": [
    {
      "point_id": "e5751187f13c587f8acd8c801447a04c",
      "game_id": "bc268761d8e55466a17a47853fbe3dff-g3",
      "game_number": 3,
      "point_number": 40,
      "before": {
        "red": 20,
        "blue": 19
      },
      "after": {
        "red": 21,
        "blue": 19
      },
      "winner_side": "red",
      "is_match_point": true,
      "is_final_point": true,
      "score_source": "demo_fixture",
      "video": {
        "asset_id": "asset_a4364aa3d5d64f269b914c4b619b76cb",
        "start_seconds": 0,
        "end_seconds": 48.66,
        "association_source": "demo_fixture",
        "video_source": "user_recording",
        "analysis_status": "not_imported"
      }
    }
  ],
  "coverage": {
    "point_history": "final_point_only",
    "video": "final_point_only"
  },
  "score_source": "demo_fixture",
  "participant_to_video_track_mapping": null,
  "notice": "演示比赛：比分、MVP 与击球统计为模拟设定；视频为实拍，尚未进行视觉动作分析。",
  "demo_mvp": {
    "participant_id": "blue-1",
    "name": "玉琮",
    "source": "demo_fixture",
    "reason": "全场击球 186 次，杀球 52 次；攻防表现突出，获选本场 MVP。"
  },
  "demo_shot_stats": [
    {
      "participant_id": "red-1",
      "name": "止戈",
      "total": 176,
      "source": "demo_fixture",
      "shots": [
        {
          "type": "杀球",
          "count": 42
        },
        {
          "type": "高远球",
          "count": 48
        },
        {
          "type": "平抽球",
          "count": 35
        },
        {
          "type": "吊球",
          "count": 22
        },
        {
          "type": "挑球",
          "count": 18
        },
        {
          "type": "网前球",
          "count": 11
        }
      ]
    },
    {
      "participant_id": "red-2",
      "name": "简宁",
      "total": 174,
      "source": "demo_fixture",
      "shots": [
        {
          "type": "杀球",
          "count": 28
        },
        {
          "type": "高远球",
          "count": 45
        },
        {
          "type": "平抽球",
          "count": 38
        },
        {
          "type": "吊球",
          "count": 25
        },
        {
          "type": "挑球",
          "count": 24
        },
        {
          "type": "网前球",
          "count": 14
        }
      ]
    },
    {
      "participant_id": "blue-1",
      "name": "玉琮",
      "total": 186,
      "source": "demo_fixture",
      "shots": [
        {
          "type": "杀球",
          "count": 52
        },
        {
          "type": "高远球",
          "count": 46
        },
        {
          "type": "平抽球",
          "count": 41
        },
        {
          "type": "吊球",
          "count": 20
        },
        {
          "type": "挑球",
          "count": 17
        },
        {
          "type": "网前球",
          "count": 10
        }
      ]
    },
    {
      "participant_id": "blue-2",
      "name": "Clio",
      "total": 176,
      "source": "demo_fixture",
      "shots": [
        {
          "type": "杀球",
          "count": 31
        },
        {
          "type": "高远球",
          "count": 42
        },
        {
          "type": "平抽球",
          "count": 39
        },
        {
          "type": "吊球",
          "count": 28
        },
        {
          "type": "挑球",
          "count": 23
        },
        {
          "type": "网前球",
          "count": 13
        }
      ]
    }
  ]
}
"""#.utf8))
    static func makeStore()->ReplayStore {
        let store=ReplayStore(load:{ _ in [match] });store.configure(CoachPreviewFixture.context);return store
    }
}
#endif
