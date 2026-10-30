import Foundation

struct CoachContext: Equatable {
    let origin: String
    let userID: String
    let token: String
    var storageKey: String {
        let scope = (try? JSONEncoder().encode([origin, userID])) ?? Data()
        return "ios.coach.v1." + scope.base64EncodedString()
    }
}

struct CoachMessage: Codable, Identifiable {
    var id = UUID()
    let role: String
    let content: String
    var date = Date()
    var blocks: [CoachContentBlock]? = nil
    var references: [CoachReference]? = nil
    var completion: String? = nil // nil is a complete legacy/successful answer.
    var displayBlocks: [CoachContentBlock] {
        let usable = (blocks ?? []).filter { block in
            block.type != "markdown" || !(block.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        return usable.isEmpty ? [.markdown(id: id.uuidString, text: content)] : usable
    }
}

struct CoachWireMessage: Codable {
    let role: String
    let content: String
}

struct CoachHistory: Codable {
    var messages: [CoachMessage] = []
    var draft = ""
    var references: [CoachReference]? = nil

    static func context(_ messages: [CoachMessage], question: String) -> [CoachWireMessage] {
        var result = [CoachWireMessage(role: "user", content: question)]
        var total = question.unicodeScalars.count
        let recent = messages
        var pairs = 0
        guard recent.count >= 2 else { return result }
        for index in stride(from: recent.count - 2, through: 0, by: -2) {
            let user = recent[index], assistant = recent[index + 1]
            guard user.role == "user", assistant.role == "assistant", assistant.completion == nil else { continue }
            if pairs == 6 { break }; pairs += 1
            let size = user.content.unicodeScalars.count + assistant.content.unicodeScalars.count
            guard user.role == "user", assistant.role == "assistant", total + size <= 12000 else { break }
            result.insert(contentsOf: [CoachWireMessage(role: user.role, content: user.content),
                                       CoachWireMessage(role: assistant.role, content: assistant.content)], at: 0)
            total += size
        }
        return result
    }
}

struct CoachFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class CoachNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class CoachClient {
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: config, delegate: CoachNoRedirect(), delegateQueue: nil)
    }
    func reply(context: CoachContext, messages: [CoachWireMessage]) async throws -> String {
        try await response(context: context, messages: messages).reply
    }
    func response(context: CoachContext, messages: [CoachWireMessage], references:[CoachReference] = []) async throws -> CoachReply {
        let request = try makeRequest(context:context, messages:messages, path:"/api/coach/chat", references:references)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw CoachFailure("连接中断或回复超时，问题已保留。上次请求可能已处理，请稍后再发送。") }
        guard let http = response as? HTTPURLResponse else { throw CoachFailure("教练服务响应无效") }
        guard http.statusCode == 200 else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if http.statusCode == 401 { throw CoachFailure("登录已过期，请到「账号与安全」重新登录") }
            if object?["code"] as? String == "COACH_NOT_CONFIGURED" { throw CoachFailure("教练服务尚未配置，暂时无法回答；问题已保留") }
            if http.statusCode == 429 { throw CoachFailure("教练服务繁忙，请稍后再发送") }
            if http.statusCode == 504 { throw CoachFailure("模型回复超时，问题已保留；可稍后再次发送") }
            if http.statusCode == 404 { throw CoachFailure("服务器尚未启用教练服务，请稍后再试") }
            throw CoachFailure("教练服务暂不可用，问题已保留；请稍后再发送")
        }
        guard data.count <= 262144, let decoded = try? JSONDecoder().decode(CoachReply.self, from: data),
              !decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.reply.unicodeScalars.count <= 8000,
              (decoded.blocks?.count ?? 0) <= 32 else { throw CoachFailure("教练未返回有效回复，问题已保留") }
        if !references.isEmpty && decoded.references?.first?.id != references.first?.id { throw CoachFailure("服务器尚未支持这条比赛引用") }
        return decoded
    }
    func makeRequest(context:CoachContext, messages:[CoachWireMessage], path:String, references:[CoachReference] = []) throws -> URLRequest {
        guard let origin = URL(string: context.origin), origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, ["", "/"].contains(origin.path),
              let url = URL(string: context.origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CoachFailure("教练服务地址无效")
        }
        #if DEBUG
        guard ["https", "http"].contains(origin.scheme ?? "") else { throw CoachFailure("教练服务地址无效") }
        #else
        guard origin.scheme == "https" else { throw CoachFailure("教练服务需要 HTTPS") }
        #endif
        guard !context.token.isEmpty else { throw CoachFailure("请先登录业务账号") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + context.token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject:["messages":messages.map { ["role":$0.role,"content":$0.content] },"references":references.map { $0.wire }])
        return request
    }
    static func failure(status:Int, code:String?) -> CoachFailure {
        if status == 401 || code == "COACH_UNAUTHENTICATED" { return CoachFailure("登录已过期，请到「账号与安全」重新登录") }
        if status == 403 { return CoachFailure("请先完成业务账号登录") }
        if code == "COACH_NOT_CONFIGURED" { return CoachFailure("教练服务尚未配置，问题已保留") }
        if status == 429 || code == "COACH_BUSY" { return CoachFailure("教练服务繁忙，请稍后再发送") }
        if status == 504 || code == "COACH_TIMEOUT" { return CoachFailure("模型回复超时，已收到的内容已保留") }
        return CoachFailure("回复中断，问题和已收到的内容已保留；请稍后重试")
    }

}
