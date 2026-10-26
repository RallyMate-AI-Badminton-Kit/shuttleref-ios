import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

/// The broker returns a one-time assertion; only the business server can turn it into a session.
@MainActor final class NativeOAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var busy = false
    @Published var message = ""
    private var session: ASWebAuthenticationSession?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<URL, Error>?
    private var browserID: UUID?
    private struct Start: Decodable { let request_id: String; let url: String }
    private struct Grant: Decodable { let grant: String }
    var origin: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "ios.oauth.origin") ?? (Bundle.main.object(forInfoDictionaryKey: "OAuthBrokerOrigin") as? String ?? "")
        #else
        return Bundle.main.object(forInfoDictionaryKey: "OAuthBrokerOrigin") as? String ?? ""
        #endif
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    private func finishBrowser(_ id: UUID, _ result: Result<URL, Error>) {
        guard browserID == id, let pending = continuation else { return }
        continuation = nil; browserID = nil
        timeout?.cancel(); timeout = nil; session = nil
        pending.resume(with: result)
    }
    func cancel() {
        guard let id = browserID else { return }
        session?.cancel()
        finishBrowser(id, .failure(SocialClientError("授权已取消，请重新开始")))
    }
    private func browser(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID(); self.browserID = id; self.continuation = continuation
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: "shuttleref-auth") { [weak self] callback, _ in
                Task { @MainActor in
                    if let callback = callback { self?.finishBrowser(id, .success(callback)) }
                    else { self?.finishBrowser(id, .failure(SocialClientError("授权已取消或未完成，请重试"))) }
                }
            }
            session = web; web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = true
            if !web.start() { finishBrowser(id, .failure(SocialClientError("无法打开授权页面，请重试"))); return }
            timeout = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 600_000_000_000)
                    if self?.browserID == id { self?.cancel() }
                } catch {}
            }
        }
    }
    private func post<T: Decodable>(_ origin: String, _ path: String, _ body: [String: String]) async throws -> T {
        guard let url = URL(string: origin + path) else { throw SocialClientError("授权地址无效") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
            throw SocialClientError(error?["error"] ?? "授权服务暂不可用，请稍后重试")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func signIn(app: AppStore, social: GatheringStore, link: Bool) async {
        guard !busy, !social.busy, !social.oauthBusy else { return }
        let actionState = AccountActionState(loggedIn: app.loggedIn, deviceBusy: app.busy,
            businessBusy: social.busy, authorizing: busy || social.oauthBusy,
            businessContext: social.context != nil, pendingEvents: !social.journal.events.isEmpty,
            pendingRecords: !social.recordsJournal.pending.isEmpty)
        if let reason = actionState.businessAuthorizationBlockReason { message = reason; return }
        message = ""; busy = true; social.oauthBusy = true
        defer { busy = false; social.oauthBusy = false }
        do {
            guard app.loggedIn, !app.identityFingerprint.isEmpty else { throw SocialClientError("请先登录设备账号") }
            guard social.context == nil, social.journal.events.isEmpty, social.recordsJournal.pending.isEmpty else { throw SocialClientError("请先结束当前球局并上传待同步记录") }
            let brokerOrigin = origin, apiOrigin = social.origin, priorToken = social.credentials?.token
            let fingerprint = app.identityFingerprint
            guard let base = URLComponents(string: brokerOrigin), base.scheme == "https", base.host != nil,
                  base.path.isEmpty, base.query == nil, base.fragment == nil, base.user == nil, base.password == nil else { throw SocialClientError("请先配置 HTTPS 授权服务地址") }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SocialClientError("无法创建安全授权请求") }
            let verifier = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let challenge = SHA256.hash(data: Data(verifier.utf8)).map { String(format: "%02x", $0) }.joined()
            message = "正在打开涂鸦授权…"
            let start: Start = try await post(brokerOrigin, "/app/begin", ["challenge": challenge, "fingerprint": fingerprint])
            guard let url = URL(string: start.url), url.scheme == base.scheme, url.host == base.host, url.port == base.port, url.path == "/app/authorize" else { throw SocialClientError("授权服务返回了无效地址") }
            let callback = try await browser(url)
            let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
            let ids = parts?.queryItems?.filter { $0.name == "request_id" }.compactMap { $0.value } ?? []
            guard callback.scheme == "shuttleref-auth", callback.host == "oauth", ids == [start.request_id] else { throw SocialClientError("授权回调不匹配") }
            guard app.loggedIn, app.identityFingerprint == fingerprint, origin == brokerOrigin, social.origin == apiOrigin, social.credentials?.token == priorToken else { throw SocialClientError("账号或服务器已改变，请重新授权") }
            let grant: Grant = try await post(brokerOrigin, "/app/complete", ["request_id": start.request_id, "verifier": verifier])
            guard app.loggedIn, app.identityFingerprint == fingerprint, social.origin == apiOrigin, social.credentials?.token == priorToken else { throw SocialClientError("账号已改变，请重新授权") }
            try await social.finishOAuth(grant: grant.grant, verifier: verifier, link: link, name: app.nickname) {
                app.loggedIn && app.identityFingerprint == fingerprint && self.origin == brokerOrigin
            }
            message = link ? "已关联当前战绩账号，原有成绩和组局已保留" : "战绩与组局已登录"
        } catch { message = error.localizedDescription }
    }
}
