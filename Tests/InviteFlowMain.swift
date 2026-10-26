import Foundation

// Opt-in integration check against the local development server; creates test accounts/activity.
final class InviteFlowVault: GatheringStorage {
    var active: GatheringCredentials?
    var accounts: [GatheringCredentials] = []
    func load(_ origin: String) -> GatheringCredentials? { active }
    func save(_ value: GatheringCredentials?, origin: String) throws { active = value }
    func loadAccounts(_ origin: String) -> [GatheringCredentials] { accounts }
    func saveAccounts(_ values: [GatheringCredentials], origin: String) throws { accounts = values }
    func journalFile(_ origin: String, user: String) throws -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("invite-flow-" + user + ".json") }
}
@main struct InviteFlowChecks {
    @MainActor static func main() async throws {
        let social = GatheringStore(origin: "http://127.0.0.1:18100", storage: InviteFlowVault(), connectivity: nil)
        try await social.login(name: "邀请测试甲")
        let owner = social.userID
        try await social.create(["title":"账号切换邀请验证", "location":"本地测试球馆", "starts_at":Date().timeIntervalSince1970 + 3600, "capacity":2])
        let draft = social.gatherings.first!
        try await social.action("publish", gathering: draft)
        let text = try await social.invite(draft)
        let code = try InvitationText.code(from: text)
        try await social.login(name: "邀请测试乙")
        let guest = social.userID
        let preview: GatheringPreview = try await social.request("/invites/" + code)
        precondition(preview.id == draft.id && preview.remaining == 1)
        precondition(social.gatherings.isEmpty, "Preview must not register guest")
        try await social.join(code)
        precondition(social.detail?.members.contains(where: { $0.user_id == guest }) == true)
        try await social.switchAccount(owner)
        try await social.open(draft.id)
        precondition(social.detail?.members.count == 2)
        try await social.login(name: "邀请测试候补")
        let waiting = social.userID
        try await social.join(code)
        precondition(social.detail?.registration(for: waiting) == .waitlisted(1))
        try await social.switchAccount(guest)
        try await social.open(draft.id)
        try await social.action("leave", gathering: social.detail!)
        try await social.switchAccount(waiting)
        try await social.open(draft.id)
        precondition(social.detail?.registration(for: waiting) == .confirmed)
        try await social.logout()
        try await social.switchAccount(owner)
        try await social.open(draft.id)
        try await social.action("cancel", gathering: social.detail!)
        try await social.logout()
        print("PASS: real server A creates/shares, B previews without joining then joins, A sees two members, third account waitlists, guest leaves and waitlist promotes; test activity cancelled")
    }
}
