import Foundation
final class AccountsVault: GatheringStorage {
    var active: GatheringCredentials?
    var accounts: [GatheringCredentials] = []
    func load(_ origin: String) -> GatheringCredentials? { active }
    func save(_ value: GatheringCredentials?, origin: String) throws { active = value }
    func loadAccounts(_ origin: String) -> [GatheringCredentials] { accounts }
    func saveAccounts(_ values: [GatheringCredentials], origin: String) throws { accounts = values }
    func journalFile(_ origin: String, user: String) throws -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("account-test-" + user + UUID().uuidString) }
}
final class AccountsProtocol: URLProtocol {
    static var nextUser = "A"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        let payload: [String:Any]
        if path.contains("/session/logout") { payload = ["ok":true] }
        else if path.hasSuffix("/session/tuya") { payload = ["user":["id":Self.nextUser,"name":Self.nextUser],"token":"oauth-"+Self.nextUser,"auth_provider":"tuya","expires_at":4102444800] }
        else if path.contains("/session/") { payload = ["user":["id":Self.nextUser,"name":Self.nextUser],"token":"token-"+Self.nextUser,"recovery":"recovery-"+Self.nextUser,"expires_at":4102444800] }
        else if path.hasSuffix("/results") { payload = ["results":[]] }
        else if path.hasSuffix("/records") { payload = ["records":[]] }
        else { payload = ["gatherings":[]] }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:payload));client?.urlProtocolDidFinishLoading(self)
    }
}
@main struct AccountsChecks {
    @MainActor static func main() async throws {
        let vault = AccountsVault()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AccountsProtocol.self]
        let http = URLSession(configuration:configuration)
        let store = GatheringStore(origin:"https://accounts.invalid",storage:vault,http:http,connectivity:nil)
        try await store.login(name:"A")
        AccountsProtocol.nextUser = "B"; try await store.login(name:"B")
        precondition(Set(store.savedAccounts.map { $0.user.id }) == Set(["A","B"]))
        let restored = GatheringStore(origin:"https://accounts.invalid",storage:vault,http:http,connectivity:nil)
        precondition(restored.userID == "B" && restored.savedAccounts.count == 2)
        AccountsProtocol.nextUser = "A"; try await restored.switchAccount("A")
        precondition(restored.userID == "A" && restored.context == nil && restored.gatherings.isEmpty)
        try await restored.logout()
        precondition(restored.credentials == nil && restored.savedAccounts.map { $0.user.id } == ["B"])
        AccountsProtocol.nextUser = "B"; try await restored.switchAccount("B")
        restored.oauthBusy = true
        do { try restored.configure("https://changed.invalid"); preconditionFailure("Server changed during OAuth") } catch {}
        do { try await restored.logout(); preconditionFailure("Logged out during OAuth") } catch {}
        AccountsProtocol.nextUser = "different"
        do { try await restored.finishOAuth(grant:"proof", verifier:"verifier", link:true, name:"B"); preconditionFailure("Linked wrong user") } catch {}
        precondition(restored.userID == "B" && restored.credentials?.recovery != nil)
        AccountsProtocol.nextUser = "B"
        do { try await restored.finishOAuth(grant:"proof", verifier:"verifier", link:true, name:"B", stillCurrent: { false }); preconditionFailure("Installed stale SDK identity") } catch {}
        precondition(restored.credentials?.recovery != nil)
        try await restored.finishOAuth(grant:"proof", verifier:"verifier", link:true, name:"B")
        precondition(restored.userID == "B" && restored.credentials?.auth_provider == "tuya" && restored.credentials?.recovery == nil)
        precondition(vault.active?.recovery == nil && vault.accounts.first?.auth_provider == "tuya")
        try await restored.finishOAuth(grant:"renewed-proof", verifier:"verifier", link:false, name:"B")
        precondition(restored.userID == "B")
        restored.oauthBusy = false
        try await restored.logout()
        try await restored.finishOAuth(grant:"new-proof", verifier:"verifier", link:false, name:"B")
        precondition(restored.userID == "B" && restored.credentials?.auth_provider == "tuya")
        print("PASS: create A/B, persist account list, switch back to A, logout removes only current saved login")
        print("PASS: OAuth linking preserves user, clears recovery, rejects wrong user/server switch, and supports relogin")
    }
}
