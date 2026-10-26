import Foundation

struct GatheringUser: Codable, Identifiable { let id: String; let name: String }
struct GatheringCredentials: Codable { let user: GatheringUser; let token: String; let expires_at: Double; var recovery: String?; var auth_provider: String? = nil }
struct GatheringMember: Codable, Identifiable {
    var id: String { user_id }
    let user_id: String; let name: String; let status: String
}
struct GatheringFixture: Codable, Identifiable {
    let id: String; let number: Int; let status: String
    let red: [String]; let blue: [String]; let names: [String: String]; let referee_id: String
    var end_reason: String?; var mvp_user_id: String?; var mvp_name: String?
    var court: String?
    var device_id: String?; var match_id: String?; var installation_id: String?; var snapshot: MatchSnapshot?
    var label: String { red.map { names[$0] ?? "球友" }.joined(separator: " / ") + " 对 " + blue.map { names[$0] ?? "球友" }.joined(separator: " / ") }
    var stateLabel: String { if end_reason == "early" { return "提前结束" }; return ["scheduled":"待开赛", "starting":"等待设备确认", "live":"比赛中", "paused":"已暂存", "completed":"已完成", "abandoned":"已放弃", "unplayed":"未进行", "reconciliation_required":"待核对"][status] ?? status }
}
struct Gathering: Codable, Identifiable {
    let id: String; let title: String; let location: String; let starts_at: Double; let capacity: Int
    let owner_id: String; let organizer: String; let status: String; let signup_open: Bool
    var ends_at: Double?
    let notes: String; let court: String; let members: [GatheringMember]; let fixtures: [GatheringFixture]
    var stateLabel: String { ["draft":"草稿", "open":"报名中", "in_progress":"进行中", "ended":"已结束", "cancelled":"已取消"][status] ?? status }
    var terminal: Bool { ["ended", "cancelled"].contains(status) }
}
struct GatheringList: Decodable { let gatherings: [Gathering] }
struct GatheringInvite: Decodable { let code: String; let expires_at: Double }
struct GatheringPreview: Decodable { let id: String; let title: String; let location: String; let starts_at: Double; let organizer: String; let remaining: Int }
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
