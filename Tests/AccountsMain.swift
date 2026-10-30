import Foundation
final class AccountsVault: GatheringStorage {
    let directoryID = UUID().uuidString
    var active: GatheringCredentials?
    var accounts: [GatheringCredentials] = []
    func load(_ origin: String) -> GatheringCredentials? { active }
    func save(_ value: GatheringCredentials?, origin: String) throws { active = value }
    func loadAccounts(_ origin: String) -> [GatheringCredentials] { accounts }
    func saveAccounts(_ values: [GatheringCredentials], origin: String) throws { accounts = values }
    func journalFile(_ origin: String, user: String) throws -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("account-test-" + directoryID + user) }
}
final class AccountsProtocol: URLProtocol {
    static var nextUser = "A"
    static var rejectBusiness = false
    static var rejectPasswordChange = false
    static var connectionStatus = 401
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        if path.hasSuffix("/me") {
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            if Self.connectionStatus == -1 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.connectionStatus, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"请登录组局身份\"}".utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        if (Self.rejectBusiness && path.hasSuffix("/gatherings")) || (Self.rejectPasswordChange && path.hasSuffix("/change-password")) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        let payload: [String:Any]
        if path.contains("/session/logout") { payload = ["ok":true] }
        else if path.hasSuffix("/session/tuya") { payload = ["user":["id":Self.nextUser,"name":Self.nextUser],"token":"oauth-"+Self.nextUser,"auth_provider":"tuya","expires_at":4102444800] }
        else if ["register", "login", "set-password", "change-password", "recover-password"].contains(path.components(separatedBy: "/").last ?? "") {
            if path.hasSuffix("/login") || path.hasSuffix("/register") { precondition(request.value(forHTTPHeaderField: "Authorization") == nil) }
            payload = ["user":["id":Self.nextUser,"name":Self.nextUser,"has_password":true,"login_name":"tester"],"token":"password-"+Self.nextUser,"auth_provider":"password","expires_at":4102444800]
        }
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
        precondition(GatheringStore.defaultOrigin == "https://shuttleserver.wgine.com")
        let vault = AccountsVault()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AccountsProtocol.self]
        let http = URLSession(configuration:configuration)
        let store = GatheringStore(origin:"https://accounts.invalid",storage:vault,http:http,connectivity:nil)
        try await store.checkAuthorizationConnection()
        AccountsProtocol.connectionStatus = 403
        do { try await store.checkAuthorizationConnection(); preconditionFailure("Accepted denied server") } catch {}
        AccountsProtocol.connectionStatus = -1
        do { try await store.checkAuthorizationConnection(); preconditionFailure("Accepted timeout") } catch {
            precondition((error as? URLError)?.code == .timedOut)
        }
        AccountsProtocol.connectionStatus = 401
        precondition(store.credentials == nil)
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
        AccountsProtocol.rejectBusiness = true
        do { try await restored.refresh(); preconditionFailure("Accepted expired login") } catch {}
        precondition(restored.needsLogin && restored.authorizationExpired && restored.userID == "B")
        AccountsProtocol.rejectBusiness = false
        try await restored.finishOAuth(grant:"renew", verifier:"verifier", link:false, name:"B")
        precondition(!restored.needsLogin && !restored.authorizationExpired && restored.userID == "B")
        try await restored.passwordAction("set-password", username:"tester", password:"test password 123")
        precondition(restored.userID == "B" && restored.verifiedBusiness && restored.credentials?.user.has_password == true)
        try await restored.logout()
        try await restored.passwordAction("login", username:"tester", password:"test password 123")
        precondition(restored.verifiedBusiness && restored.credentials?.recovery == nil)
        AccountsProtocol.rejectBusiness = true
        do { try await restored.refresh(); preconditionFailure("Accepted expired password session") } catch {}
        precondition(restored.needsLogin)
        AccountsProtocol.rejectBusiness = false
        try await restored.passwordAction("login",username:"tester",password:"test password 123")
        AccountsProtocol.rejectPasswordChange = true
        do { try await restored.passwordAction("change-password",password:"test password 123",oldPassword:"wrong password"); preconditionFailure("wrong password accepted") } catch {}
        precondition(!restored.needsLogin, "wrong old password expired valid session")
        AccountsProtocol.rejectPasswordChange = false
        let pending = GatheringJournal(context:GatheringContext(gatheringID:"g",fixtureID:"f",deviceID:"d",matchID:"m",installationID:"i",red:["A"],blue:["B"]))
        try JSONEncoder().encode(pending).write(to:vault.journalFile("https://accounts.invalid",user:"B"))
        let withPending = GatheringStore(origin:"https://accounts.invalid",storage:vault,http:http,connectivity:nil)
        try await withPending.passwordAction("login",username:"tester",password:"test password 123")
        precondition(withPending.context?.matchID == "m" && withPending.userID == "B")
        AccountsProtocol.nextUser = "C"
        do { try await withPending.passwordAction("login",username:"other",password:"test password 123"); preconditionFailure("switched pending account") } catch {}
        precondition(withPending.userID == "B" && withPending.context?.matchID == "m")
        print("PASS: same-account reauthentication retains pending match; different identity rejected")
        print("PASS: native password upgrade, login and expiration")
        print("PASS: create A/B, persist account list, switch back to A, logout removes only current saved login")
        print("PASS: OAuth linking preserves user, clears recovery, rejects wrong user/server switch, and supports relogin")
    }
}
