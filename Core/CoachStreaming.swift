import Foundation

struct CoachSSEEvent {
    let name: String
    let data: String
}

/// Frames complete UTF-8 lines before decoding, including CRLF and multi-line data fields.
struct CoachSSEDecoder {
    private var line: [UInt8] = []
    private var name = "message"
    private var data: [String] = []
    private var eventSize = 0
    private var total = 0
    mutating func feed(_ byte: UInt8) throws -> CoachSSEEvent? {
        total += 1
        guard total <= 1048576 else { throw CoachFailure("回复内容过大，已停止接收") }
        if byte != 10 {
            line.append(byte)
            guard line.count <= 65536 else { throw CoachFailure("回复格式无效") }
            return nil
        }
        if line.last == 13 { line.removeLast() }
        guard let value = String(bytes:line, encoding:.utf8) else { throw CoachFailure("回复编码无效") }
        line.removeAll(keepingCapacity:true)
        if value.isEmpty {
            defer { name = "message"; data = []; eventSize = 0 }
            return data.isEmpty ? nil : CoachSSEEvent(name:name, data:data.joined(separator:"\n"))
        }
        if value.hasPrefix(":") { return nil }
        let split = value.split(separator:":", maxSplits:1, omittingEmptySubsequences:false)
        let field = String(split[0])
        var content = split.count == 2 ? String(split[1]) : ""
        if content.hasPrefix(" ") { content.removeFirst() }
        if field == "event" { name = content }
        if field == "data" {
            eventSize += content.utf8.count + 1
            guard eventSize <= 65536 else { throw CoachFailure("回复格式无效") }
            data.append(content)
        }
        return nil
    }
}

extension CoachClient {
    func stream(context: CoachContext, messages: [CoachWireMessage], references:[CoachReference] = [], onMetadata: (@MainActor ([CoachReference],[CoachContentBlock])->Void)? = nil, onDelta: @escaping @MainActor (String) -> Void) async throws -> CoachReply {
        var request = try makeRequest(context:context, messages:messages, path:"/api/coach/chat/stream",references:references)
        request.setValue("text/event-stream", forHTTPHeaderField:"Accept")
        do {
            let (bytes, response) = try await session.bytes(for:request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw CoachFailure("教练服务响应无效") }
            if http.statusCode == 404 {
                if !references.isEmpty { throw CoachFailure("服务器尚未支持比赛引用，请稍后重试") }
                bytes.task.cancel()
                try Task.checkCancellation()
                // Only an explicit unsupported route can fall back. No retry after model output.
                return try await self.response(context:context, messages:messages)
            }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes { body.append(byte); if body.count > 8192 { break } }
                let object = (try? JSONSerialization.jsonObject(with:body)) as? [String:Any]
                throw Self.failure(status:http.statusCode, code:object?["code"] as? String)
            }
            guard http.value(forHTTPHeaderField:"Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
                throw CoachFailure("服务器未返回流式回复")
            }
            var decoder = CoachSSEDecoder(), text = ""
            var resolved:[CoachReference]=[]; var blocks:[CoachContentBlock]=[]
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let event = try decoder.feed(byte) else { continue }
                guard let object = (try? JSONSerialization.jsonObject(with:Data(event.data.utf8))) as? [String:Any] else {
                    throw CoachFailure("回复格式无效，已收到的内容已保留")
                }
                switch event.name {
                case "references":
                    guard resolved.isEmpty, !references.isEmpty,
                          let rawReferences=object["references"], let rawBlocks=object["blocks"],
                          let decoded=try? JSONDecoder().decode([CoachReference].self,from:JSONSerialization.data(withJSONObject:rawReferences)),
                          decoded.count==1,decoded[0].id==references[0].id,decoded[0].type==references[0].type,
                          let decodedBlocks=try? JSONDecoder().decode([CoachContentBlock].self,from:JSONSerialization.data(withJSONObject:rawBlocks)),
                          decodedBlocks.count<=8 else { throw CoachFailure("比赛引用响应无效") }
                    resolved=decoded;blocks=decodedBlocks
                    await onMetadata?(resolved,blocks)
                case "text_delta":
                    guard let delta = object["text"] as? String else { throw CoachFailure("回复格式无效") }
                    guard text.unicodeScalars.count + delta.unicodeScalars.count <= 8000 else { throw CoachFailure("回复内容过大，已停止接收") }
                    text += delta
                    if !delta.isEmpty { await onDelta(delta) }
                case "done":
                    guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CoachFailure("教练未返回有效回复") }
                    guard references.isEmpty || !resolved.isEmpty else { throw CoachFailure("服务器未确认比赛引用") }
                    return CoachReply(reply:text,blocks:blocks.isEmpty ? nil : [.markdown(id:"answer",text:text)]+blocks,references:resolved.isEmpty ? nil : resolved)
                case "error":
                    throw Self.failure(status:502, code:object["code"] as? String)
                default: break // Forward-compatible metadata/ping events never become visible content.
                }
            }
            throw CoachFailure("回复中断，已收到的内容已保留；可重新发送问题")
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as CoachFailure { throw error }
        catch { throw CoachFailure("连接中断或回复超时，已收到的内容已保留；可稍后重试") }
    }
}

/// Only completed paragraphs outside fenced code are promoted to Markdown during a stream.
/// The tail remains plain text, preserving incomplete syntax and grapheme clusters exactly.
enum CoachStreamingMarkdown {
    static func split(_ text: String) -> (prefix:String, tail:String) {
        var fence: Character?, fenceCount = 0
        var complexTail = false
        var boundary = text.startIndex, cursor = text.startIndex
        while cursor < text.endIndex, let end = text[cursor...].firstIndex(of:"\n") {
            let line = String(text[cursor..<end])
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            // Loose lists, nested code, quotes and tables can continue across blank
            // lines. Keep their tail intact until done rather than guessing an end.
            if trimmed.range(of: #"^(?:[-+*]\s|\d+[.)]\s|>)"#, options:.regularExpression) != nil ||
                trimmed.contains("|") || (indent >= 4 && fence == nil) { complexTail = true }
            if indent <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if fence == nil { fence = first; fenceCount = count }
                    else if fence == first && count >= fenceCount && trimmed.dropFirst(count).trimmingCharacters(in:.whitespaces).isEmpty { fence = nil }
                }
            }
            let next = text.index(after:end)
            if trimmed.isEmpty && fence == nil && !complexTail { boundary = next }
            cursor = next
        }
        return (String(text[..<boundary]),String(text[boundary...]))
    }
}
