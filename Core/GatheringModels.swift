import Foundation

struct GatheringUser: Codable, Identifiable { let id: String; let name: String; var login_name: String? = nil; var has_password: Bool? = nil }
struct GatheringCredentials: Codable { let user: GatheringUser; let token: String; let expires_at: Double; var recovery: String?; var auth_provider: String? = nil }
struct GatheringMember: Codable, Identifiable {
    var id: String { user_id }
    let user_id: String; let name: String; let status: String
}
struct GatheringFixture: Codable, Identifiable {
    let id: String; let number: Int; let status: String
    let red: [String]; let blue: [String]; let names: [String: String]; let referee_id: String
    var observations: [MatchObservation]? = nil
    var round: Int? = nil
    var stage: String? = nil
    var pool: String? = nil
    var end_reason: String?; var mvp_user_id: String?; var mvp_name: String?
    var court: String?
    var device_id: String?; var match_id: String?; var installation_id: String?; var snapshot: MatchSnapshot?
    var label: String { red.map { names[$0] ?? "球友" }.joined(separator: " / ") + " 对 " + blue.map { names[$0] ?? "球友" }.joined(separator: " / ") }
    var stateLabel: String { if end_reason == "early" { return "提前结束" }; return ["scheduled":"待开赛", "starting":"等待设备确认", "live":"比赛中", "paused":"已暂存", "completed":"已完成", "abandoned":"已放弃", "unplayed":"未进行", "reconciliation_required":"待核对"][status] ?? status }
}
struct Gathering: Codable, Identifiable {
    let id: String; let title: String; let location: String; let starts_at: Double; let capacity: Int
    let owner_id: String; let organizer: String; let status: String; let signup_open: Bool
    var format: String? = nil
    var playFormat: GatheringFormat { GatheringFormat(rawValue: format ?? "free") ?? .free }
    var ends_at: Double?
    let notes: String; let court: String; let members: [GatheringMember]; let fixtures: [GatheringFixture]
    var stateLabel: String { ["draft":"草稿", "open":"报名中", "in_progress":"进行中", "ended":"已结束", "cancelled":"已取消"][status] ?? status }
    var terminal: Bool { ["ended", "cancelled"].contains(status) }
}
struct GatheringList: Decodable { let gatherings: [Gathering] }
struct GatheringInvite: Decodable { let code: String; let expires_at: Double }
struct GatheringPreview: Decodable { let id: String; let title: String; let location: String; let starts_at: Double; let organizer: String; let remaining: Int; var format: String? = nil }
struct SocialOK: Decodable { let ok: Bool }
struct GatheringContext: Codable {
    let gatheringID: String; let fixtureID: String; let deviceID: String; let matchID: String; let installationID: String
    let red: [String]; let blue: [String]
    var redIDs: [String]? = nil; var blueIDs: [String]? = nil
    var path: String { "/gatherings/\(gatheringID)/fixtures/\(fixtureID)" }
}
struct GatheringEvent: Codable, Identifiable {
    let id: String; let context: GatheringContext; let op: String; let snapshot: MatchSnapshot; var mvpUserID: String? = nil
}

struct GatheringResult: Codable, Identifiable {
    var id: String { fixture.id }
    let gathering_id: String; let title: String; let fixture: GatheringFixture
    var played_at: Double? = nil
}
struct GatheringResults: Decodable { let results: [GatheringResult] }

/// Derived only from the server's ordered membership list, never from preview capacity.
enum GatheringRegistration: Equatable {
    case notJoined, confirmed, waitlisted(Int)
    var title: String {
        switch self {
        case .notJoined: return "未报名"
        case .confirmed: return "已报名"
        case .waitlisted(let position): return "候补第 \(position) 位"
        }
    }
    var explanation: String {
        switch self {
        case .notJoined: return "你还没有加入这场活动。"
        case .confirmed: return "已在正式名单中，按活动时间到场即可。"
        case .waitlisted: return "暂未占用正式名额。有人退出后按候补顺序递补，刷新活动查看最新状态。"
        }
    }
}
extension Gathering {
    func registration(for userID: String) -> GatheringRegistration {
        guard let index = members.firstIndex(where: { $0.user_id == userID }) else { return .notJoined }
        if members[index].status == "confirmed" { return .confirmed }
        if members[index].status == "waitlisted" {
            return .waitlisted(members.prefix(index + 1).filter { $0.status == "waitlisted" }.count)
        }
        return .notJoined
    }
}

struct PersonalRecord: Codable, Identifiable {
    let deviceID: String
    let result: LocalMatchResult
    var id: String { deviceID + ":" + result.id }
}
struct PersonalRecords: Decodable { let records: [PersonalRecord] }
struct RecordsJournal: Codable {
    var uploaded: [PersonalRecord] = []
    var pending: [PersonalRecord] = []
    var groups: [GatheringResult] = []
}


enum GatheringFormat: String, CaseIterable, Identifiable {
    case free, singles_round_robin, doubles_round_robin, eight_rotation, four_rotation, family_doubles, doubles_knockout, doubles_swiss, doubles_groups
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return "自由约球"
        case .singles_round_robin: return "单打循环"
        case .doubles_round_robin: return "固定搭档循环"
        case .eight_rotation: return "八人转"
        case .four_rotation: return "四人换搭"
        case .family_doubles: return "亲子搭档"
        case .doubles_knockout: return "双打晋级赛"
        case .doubles_swiss: return "双打瑞士制"
        case .doubles_groups: return "分组循环淘汰赛"
        }
    }
    var subtitle: String {
        switch self {
        case .free: return "随到随打，自由安排单打或双打"
        case .singles_round_robin: return "每人都交手一次，轮流上场"
        case .doubles_round_robin: return "搭档不变，每组相遇一次"
        case .eight_rotation: return "8 人 · 14 场 · 每人 7 位不同搭档"
        case .four_rotation: return "4 人 · 3 场 · 和每个人搭档一次"
        case .family_doubles: return "大手牵小手，以家庭组合轮流交手"
        case .doubles_knockout: return "2 / 4 / 8 组 · 胜者晋级，直到决赛"
        case .doubles_swiss: return "4 / 6 / 8 组 · 三轮比赛，优先相近战绩交手"
        case .doubles_groups: return "4 / 8 组 · 两组循环，前二交叉晋级"
        }
    }
    var explanation: String {
        if self == .family_doubles { return "每组由一位家长与一位孩子搭档，由组织者确认组合。每位参赛者需在正式报名名单中；本版不支持代建儿童身份。重在共同参与，不强制年龄分组。" }
        if staged { return "确认固定搭档后按顺序排赛。每轮正常完赛后，组织者生成下一轮；提前结束不作晋级依据。循环与瑞士制按胜场、净胜局、初始组队顺序依次排序；瑞士制避免重复交手。" }
        if self == .free { return "报名后手动安排对阵，不自动生成赛程。" }
        return fixedTeams ? "从正式报名名单中选择球员并确认固定搭档，生成循环赛程。" : "选择正式报名球员，先预览赛程，再确认生成。每个活动依次进行比赛。"
    }
    var staged: Bool { [.doubles_knockout, .doubles_swiss, .doubles_groups].contains(self) }
    var fixedTeams: Bool { self == .doubles_round_robin || self == .family_doubles || staged }
    var minimum: Int { self == .eight_rotation ? 8 : (self == .singles_round_robin || self == .free ? 2 : 4) }
    var requiredCount: Int? { self == .eight_rotation ? 8 : (self == .four_rotation ? 4 : nil) }
    var icon: String {
        switch self {
        case .free: return "sparkles"
        case .singles_round_robin: return "person.fill"
        case .doubles_round_robin: return "person.2.fill"
        case .eight_rotation: return "arrow.triangle.2.circlepath"
        case .four_rotation: return "shuffle"
        case .family_doubles: return "heart.fill"
        case .doubles_knockout: return "trophy.fill"
        case .doubles_swiss: return "square.grid.2x2.fill"
        case .doubles_groups: return "list.number"
        }
    }
}
struct GatheringSchedulePreview: Decodable { let fixtures: [GatheringFixture] }

struct GatheringStanding: Identifiable {
    let id: String
    var name: String
    var played = 0
    var won = 0
    var setDifference = 0
}
extension Gathering {
    var canAdvance: Bool {
        guard playFormat.staged, !terminal, !fixtures.isEmpty,
              fixtures.allSatisfy({ $0.status == "completed" && $0.end_reason != "early" }) else { return false }
        let last = fixtures.compactMap(\.round).max() ?? 1
        if playFormat == .doubles_swiss { return last < 3 }
        if playFormat == .doubles_groups && fixtures.allSatisfy({ $0.stage == "group" }) { return true }
        return fixtures.filter { $0.round == last }.count > 1
    }
    var standings: [GatheringStanding] {
        var entries: [String: GatheringStanding] = [:]
        for f in fixtures where f.status == "completed" && f.end_reason != "early" {
            guard let scores = f.snapshot?.scores, scores.count >= 4 else { continue }
            for (team, wins, losses) in [(f.red, scores[2], scores[3]), (f.blue, scores[3], scores[2])] {
                for id in team {
                    var entry = entries[id] ?? GatheringStanding(id: id, name: f.names[id] ?? "球友")
                    entry.played += 1; entry.won += wins > losses ? 1 : 0
                    entry.setDifference += Int(wins) - Int(losses); entries[id] = entry
                }
            }
        }
        return entries.values.sorted {
            if $0.won != $1.won { return $0.won > $1.won }
            if $0.setDifference != $1.setDifference { return $0.setDifference > $1.setDifference }
            return $0.id < $1.id
        }
    }
}

// Calendar intervals are half-open, so midnight belongs to exactly one period.
enum RecordPeriod: String, CaseIterable, Identifiable {
    case week = "周", month = "月", year = "年"
    var id: String { rawValue }
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4
        return c
    }
    var component: Calendar.Component { self == .week ? .weekOfYear : self == .month ? .month : .year }
    func contains(_ date: Date, anchor: Date) -> Bool {
        guard let interval = Self.calendar.dateInterval(of: component, for: anchor) else { return false }
        return date >= interval.start && date < interval.end
    }
    func title(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.calendar = Self.calendar
        formatter.dateFormat = self == .year ? "yyyy 年" : "yyyy 年 M 月"
        if self != .week { return formatter.string(from: date) }
        guard let interval = Self.calendar.dateInterval(of: .weekOfYear, for: date) else { return "本周" }
        formatter.dateFormat = "yyyy/M/d"
        let last = Self.calendar.date(byAdding: .day, value: -1, to: interval.end)!
        return formatter.string(from: interval.start) + " – " + formatter.string(from: last)
    }
}

struct RecordEntry: Identifiable {
    let id: String
    let title: String
    let date: Date
    let red: [String]
    let blue: [String]
    let snapshot: MatchSnapshot
    let mvp: String
    let early: Bool
    let source: String
    let observations: [MatchObservation]
    var importable: PersonalRecord? = nil
    var setScore: String { "\(snapshot.scores[2]) : \(snapshot.scores[3])" }
    init(personal: PersonalRecord, source: String, importable: Bool = false) {
        let r = personal.result
        id = personal.id; title = r.doubles ? "双打" : "单打"; date = r.date; snapshot = r.snapshot
        red = (r.doubles ? [0, 1] : [0]).map { r.names.indices.contains($0) ? r.names[$0] : "球友" }
        blue = (r.doubles ? [2, 3] : [2]).map { r.names.indices.contains($0) ? r.names[$0] : "球友" }
        mvp = r.mvpName; early = r.earlyEnded == true; self.source = source
        observations = r.observations ?? []; self.importable = importable ? personal : nil
    }
    init?(group: GatheringResult) {
        guard let snapshot = group.fixture.snapshot, snapshot.scores.count == 5 else { return nil }
        let f = group.fixture
        id = "group:" + group.id; title = group.title; date = Date(timeIntervalSince1970: group.played_at ?? 0)
        red = f.red.map { f.names[$0] ?? "球友" }; blue = f.blue.map { f.names[$0] ?? "球友" }
        self.snapshot = snapshot; mvp = f.mvp_name ?? "未评选"; early = f.end_reason == "early"
        source = "组局成绩 · 已同步"; observations = f.observations ?? []
    }
}
