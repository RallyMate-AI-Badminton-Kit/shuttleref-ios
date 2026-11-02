import Foundation

private final class CoachProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct CoachChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 2 {
            // Local-only integration fixture supplied by the developer's check.
            let origin = CommandLine.arguments[1]
            precondition(URL(string: origin)?.host == "127.0.0.1")
            var register = URLRequest(url: URL(string: origin + "/api/social/session/register")!)
            register.httpMethod = "POST"
            register.setValue("application/json", forHTTPHeaderField: "Content-Type")
            register.httpBody = try JSONSerialization.data(withJSONObject: ["username": "coach_integration", "password": "local test password", "name": "tester"])
            let (data, response) = try await URLSession.shared.data(for: register)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            let session = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let user = session["user"] as! [String: Any]
            let scope = CoachContext(origin: origin, userID: user["id"] as! String, token: session["token"] as! String)
            let suite = "coach-live-check-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = CoachStore(defaults: defaults)
            store.bind(scope); store.draft = "如何练习步伐？"; await store.send()
            precondition(store.messages.count == 2, store.error)
            store.draft = "下一步呢？"; await store.send()
            precondition(store.messages.count == 4, store.error)
            precondition(store.messages.last?.content == "本地模型替身：已收到三条上下文")
            print("PASS: Swift CoachStore → real HTTP business auth → Python coach route → model test double → Swift history")
            return
        }
        let suite = "coach-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = CoachContext(origin: "https://a.example", userID: "a", token: "test-token")
        let b = CoachContext(origin: "https://a.example", userID: "b", token: "other-token")
        var observed: [CoachWireMessage] = []
        let store = CoachStore(defaults: defaults) { context, messages in
            precondition(context == a)
            observed = messages
            return "先练习分腿垫步。"
        }
        store.bind(a); store.draft = "如何启动？"
        await store.send()
        precondition(store.messages.count == 2 && store.draft.isEmpty && !store.sending)
        store.draft = "然后呢？"; await store.send()
        precondition(observed.map(\.role) == ["user", "assistant", "user"])
        precondition(observed.last?.content == "然后呢？")
        let restored = CoachStore(defaults: defaults)
        restored.bind(a)
        precondition(restored.messages.count == 4)
        restored.bind(b); precondition(restored.messages.isEmpty && restored.draft.isEmpty)
        restored.bind(a); precondition(restored.messages.count == 4)
        let sameUserOtherServer = CoachContext(origin: "https://b.example", userID: "a", token: "test-token")
        restored.bind(sameUserOtherServer); precondition(restored.messages.isEmpty)

        let failed = CoachStore(defaults: defaults) { _, _ in throw CoachFailure("尚未配置") }
        failed.bind(b); failed.draft = "保留问题"; await failed.send()
        precondition(failed.messages.isEmpty && failed.draft == "保留问题" && failed.error == "尚未配置")
        // Completion ignores cancellation to simulate a response already in flight.
        var continuation: CheckedContinuation<String, Never>?
        let delayed = CoachStore(defaults: defaults) { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        delayed.bind(a); delayed.draft = "old request"
        let pending = Task { await delayed.send() }
        while continuation == nil { await Task.yield() }
        delayed.bind(b); continuation!.resume(returning: "must not leak")
        await pending.value
        precondition(delayed.messages.isEmpty && delayed.draft == "保留问题" && !delayed.sending)

        // Independent conversations retain drafts and migrate the previous single history.
        let migratedContext = CoachContext(origin: a.origin, userID: "legacy", token: "test")
        let legacy = CoachHistory(messages: [CoachMessage(role: "user", content: "旧问题"), CoachMessage(role: "assistant", content: "旧回答")], draft: "旧草稿")
        defaults.set(try JSONEncoder().encode(legacy), forKey: migratedContext.storageKey)
        var inputs: [[CoachWireMessage]] = []
        let multi = CoachStore(defaults: defaults) { _, messages in inputs.append(messages); return "新回答" }
        multi.bind(migratedContext)
        let oldReference = CoachReference(type: "match", id: "match-a")
        multi.selectReference(oldReference)
        let originalID = multi.activeConversationID
        precondition(multi.messages.count == 2 && multi.draft == "旧草稿")
        multi.newConversation()
        let newID = multi.activeConversationID
        precondition(newID != originalID && multi.messages.isEmpty && multi.draft.isEmpty && multi.references.isEmpty)
        multi.newConversation(); precondition(multi.activeConversationID == newID)
        multi.draft = "全新问题"; await multi.send()
        precondition(inputs.last?.count == 1)
        multi.draft = "第二场草稿"
        multi.openConversation(originalID)
        precondition(multi.messages.first?.content == "旧问题" && multi.draft == "旧草稿" && multi.references == [oldReference])
        multi.openConversation(newID)
        precondition(multi.messages.first?.content == "全新问题" && multi.draft == "第二场草稿")
        let reopened = CoachStore(defaults: defaults)
        reopened.bind(migratedContext)
        precondition(reopened.activeConversationID == newID && reopened.conversations.count == 2)
        reopened.bind(b); precondition(!reopened.conversations.contains(where: { $0.id == newID }))
        var late: CheckedContinuation<String, Never>?
        let switching = CoachStore(defaults: defaults) { _, _ in await withCheckedContinuation { late = $0 } }
        switching.bind(migratedContext); switching.draft = "迟到回复"
        let switchingTask = Task { await switching.send() }
        while late == nil { await Task.yield() }
        switching.newConversation(); late!.resume(returning: "旧会话迟到内容")
        await switchingTask.value
        precondition(switching.messages.isEmpty && switching.draft.isEmpty && !switching.sending)

        let pairs = (0..<20).flatMap { i in [CoachMessage(role: "user", content: "q\(i)"), CoachMessage(role: "assistant", content: String(repeating: "答", count: 4000))] }
        let context = CoachHistory.context(pairs, question: "下一步")
        precondition(context.count <= 13 && context.count % 2 == 1)
        precondition(context.reduce(0) { $0 + $1.content.unicodeScalars.count } <= 12000)
        precondition(context.first?.role == "user" && context.last?.content == "下一步")
        // Emoji sequences must also respect the backend's Unicode-scalar limit.
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 600)
        restored.bind(b); restored.draft = emoji
        precondition(restored.draft.unicodeScalars.count <= 600)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachProtocol.self]
        let client = CoachClient(session: URLSession(configuration: configuration))
        CoachProtocol.handler = { request in
            precondition(request.url!.absoluteString == "https://a.example/api/coach/chat")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (200, Data("{\"reply\":\"test reply\"}".utf8))
        }
        let reply = try await client.reply(context: a, messages: [CoachWireMessage(role: "user", content: "你好")])
        precondition(reply == "test reply")
        CoachProtocol.handler = { _ in
            (200, Data("{\"reply\":\"比赛摘要\",\"blocks\":[{\"id\":\"text\",\"type\":\"markdown\",\"text\":\"## 小结\"},{\"id\":\"data\",\"type\":\"metrics\",\"metrics\":[{\"label\":\"回合\",\"value\":\"12\"}]}]}".utf8))
        }
        let rich = try await client.response(context: a, messages: [])
        precondition(rich.reply == "比赛摘要" && rich.blocks?.count == 2)
        let history = CoachHistory(messages: [CoachMessage(role: "user", content: "看看比赛"),
            CoachMessage(role: "assistant", content: rich.reply, blocks: rich.blocks)])
        let richScope = CoachContext(origin: a.origin, userID: "rich-legacy", token: "test")
        defaults.set(try JSONEncoder().encode(history), forKey:richScope.storageKey)
        let richStore = CoachStore(defaults:defaults); richStore.bind(richScope)
        precondition(richStore.messages.last?.displayBlocks.last?.metrics?.first?.value == "12")
        precondition(CoachHistory.context(richStore.messages, question:"继续")[1].content == "比赛摘要")
        CoachProtocol.handler = { _ in (503, Data("{\"code\":\"COACH_NOT_CONFIGURED\",\"error\":\"secret upstream body\"}".utf8)) }
        do { _ = try await client.reply(context: a, messages: []); preconditionFailure("Expected configuration error") }
        catch { precondition(error.localizedDescription.contains("尚未配置") && !error.localizedDescription.contains("secret")) }
        print("PASS: coach context, persistence, scope isolation, late response, Unicode limits and HTTP contract")
    }
}
