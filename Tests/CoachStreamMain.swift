import Foundation

@main struct CoachStreamChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 2 {
            let origin = CommandLine.arguments[1]
            precondition(URL(string:origin)?.host == "127.0.0.1")
            var request = URLRequest(url:URL(string:origin+"/api/social/session/register")!)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject:["username":"stream_"+UUID().uuidString.prefix(8),"password":"local stream test password","name":"stream test"])
            let (data, _) = try await URLSession.shared.data(for:request)
            let session = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let user = session["user"] as! [String:Any]
            let context = CoachContext(origin:origin,userID:user["id"] as! String,token:session["token"] as! String)
            let client = CoachClient()
            let start = Date(); var first:Date?, partial = ""
            let answer = try await client.stream(context:context,messages:[.init(role:"user",content:"normal")]) { delta in
                if first == nil { first = Date() }; partial += delta
            }
            precondition(answer.reply == "中文🏸第二段" && partial == answer.reply)
            precondition(first != nil && Date().timeIntervalSince(first!) >= 0.5 && first!.timeIntervalSince(start) < 1)
            do {
                _ = try await client.stream(context:context,messages:[.init(role:"user",content:"error")]) { _ in }
                preconditionFailure("Midstream error must not succeed")
            } catch { precondition(error is CoachFailure) }
            var stoppedText = ""
            let task = Task { try await client.stream(context:context,messages:[.init(role:"user",content:"cancel")]) { stoppedText += $0 } }
            while stoppedText.isEmpty { try await Task.sleep(nanoseconds:10_000_000) }
            let cancelStart = Date(); task.cancel()
            do { _ = try await task.value; preconditionFailure("Expected cancellation") } catch { precondition(error is CancellationError) }
            precondition(Date().timeIntervalSince(cancelStart) < 1)
            print("PASS: real Swift URLSession SSE → business auth/Python route, early Unicode delta, error, cancellation")
            return
        }
        var decoder = CoachSSEDecoder()
        var events: [CoachSSEEvent] = []
        let wire = ": ping\r\nevent: text_delta\r\ndata: {\"text\":\"中文🏸\"}\r\n\r\nevent: done\ndata: {}\n\n"
        for byte in wire.utf8 { if let event = try decoder.feed(byte) { events.append(event) } }
        precondition(events.count == 2 && events[0].name == "text_delta")
        let decoded = try JSONSerialization.jsonObject(with:Data(events[0].data.utf8)) as? [String:String]
        precondition(decoded == ["text":"中文🏸"])
        var oversized = CoachSSEDecoder()
        do { for _ in 0..<65537 { _ = try oversized.feed(65) }; preconditionFailure("oversize accepted") } catch {}
        let suite = "coach-stream-check-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let a = CoachContext(origin:"https://a.example",userID:"a",token:"token")
        let b = CoachContext(origin:"https://a.example",userID:"b",token:"other")
        var gate: CheckedContinuation<Void,Never>?
        var callback: (@MainActor (String)->Void)?
        let store = CoachStore(defaults:defaults, streaming: { _, _, onDelta in
            callback = onDelta; onDelta("先练习🏸")
            await withCheckedContinuation { gate = $0 }
            onDelta("再移动")
            return CoachReply(reply:"先练习🏸再移动")
        })
        store.bind(a); store.draft = "如何练习？"
        let sending = Task { await store.send() }
        while gate == nil { await Task.yield() }
        precondition(store.sending && store.pendingAnswer == "先练习🏸" && store.messages.isEmpty)
        store.stop()
        precondition(!store.sending && store.messages.last?.completion == "stopped")
        precondition(store.messages.last?.content == "先练习🏸")
        precondition(CoachHistory.context(store.messages, question:"继续").count == 1)
        store.bind(b); callback?("不能串账号"); gate!.resume(); await sending.value
        precondition(store.messages.isEmpty && store.pendingAnswer.isEmpty)
        store.bind(a); precondition(store.messages.last?.content == "先练习🏸")
        let failure = CoachStore(defaults:defaults, streaming: { _, _, onDelta in
            onDelta("部分内容"); throw CoachFailure("连接中断")
        })
        failure.bind(b); failure.draft = "保留问题"; await failure.send()
        precondition(failure.messages.last?.completion == "interrupted" && failure.draft == "保留问题")
        precondition(!failure.error.isEmpty && !failure.sending)
        let complete = CoachStore(defaults:defaults, streaming: { _, _, onDelta in
            onDelta("完整"); onDelta("回复"); return CoachReply(reply:"完整回复")
        })
        complete.bind(b); complete.draft="再试一次"; await complete.send()
        precondition(complete.messages.last?.completion == nil && complete.messages.last?.content == "完整回复")
        precondition(CoachHistory.context(complete.messages,question:"继续").count == 3)
        let parts = CoachStreamingMarkdown.split("## 标题\n\n段落\n\n```swift\nlet x =\n\n")
        precondition(parts.prefix == "## 标题\n\n段落\n\n" && parts.tail.hasPrefix("```"))
        for text in ["1. First\n\n   continuation\n\n", "1. First\n\n   ```swift\n   line\n\n   more"] {
            precondition(CoachStreamingMarkdown.split(text).prefix.isEmpty, "Do not split an active loose list")
        }
        print("PASS: SSE UTF-8/bounds, incremental state, stop/partial history, failures, account isolation, Markdown tail")
    }
}
