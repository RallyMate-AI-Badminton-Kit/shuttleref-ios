import Foundation
import Combine

@MainActor final class CoachStore: ObservableObject {
    typealias StreamingReply = (CoachContext, [CoachWireMessage], @escaping @MainActor (String) -> Void) async throws -> CoachReply
    typealias ReferencedStreamingReply = (CoachContext,[CoachWireMessage],[CoachReference],@escaping @MainActor (String)->Void,@escaping @MainActor ([CoachReference],[CoachContentBlock])->Void) async throws -> CoachReply
    @Published private(set) var references:[CoachReference]=[]
    @Published private(set) var pendingReferences:[CoachReference]=[]
    private var pendingBlocks:[CoachContentBlock]=[]
    @Published var draft = "" {
        didSet {
            if draft.unicodeScalars.count > 600 { draft = String(String.UnicodeScalarView(draft.unicodeScalars.prefix(600))) }
            if !restoring { save() }
        }
    }
    @Published private(set) var messages: [CoachMessage] = []
    @Published private(set) var sending = false
    @Published private(set) var pendingQuestion = ""
    @Published private(set) var pendingAnswer = ""
    @Published private(set) var pendingID = UUID()
    @Published private(set) var error = ""
    @Published private(set) var conversations: [CoachConversation] = []
    @Published private(set) var activeConversationID = UUID()
    private let defaults: UserDefaults
    private let stream: ReferencedStreamingReply
    private var context: CoachContext?
    private var epoch = UUID()
    private var request: Task<CoachReply, Error>?
    private var flush: Task<Void, Never>?
    private var received = ""
    private var restoring = false
    var canSend: Bool { context != nil && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(defaults: UserDefaults = .standard, reply: ((CoachContext, [CoachWireMessage]) async throws -> String)? = nil) {
        self.defaults = defaults
        let client = CoachClient()
        if let reply { self.stream = { context, messages, _, onDelta, _ in
            let text = try await reply(context, messages); onDelta(text); return CoachReply(reply:text)
        } }
        else { self.stream = { context,messages,references,onDelta,onMetadata in try await client.stream(context:context,messages:messages,references:references,onMetadata:onMetadata,onDelta:onDelta) } }
    }
    init(defaults: UserDefaults = .standard, streaming: @escaping StreamingReply) {
        self.defaults = defaults; self.stream = { context,messages,_,onDelta,_ in try await streaming(context,messages,onDelta) }
    }

    init(defaults:UserDefaults = .standard,referencedStreaming:@escaping ReferencedStreamingReply) {
        self.defaults=defaults;self.stream=referencedStreaming
    }
    func selectReference(_ reference:CoachReference?) {
        references=reference.map { [$0] } ?? [];save()
    }
    func bind(_ value: CoachContext?) {
        guard value != context else { return }
        cancel()
        context = value
        let stored = value.flatMap { defaults.data(forKey: $0.storageKey + ".conversations") }
            .flatMap { try? JSONDecoder().decode(CoachConversations.self, from: $0) }
        if let stored, !stored.items.isEmpty {
            conversations = stored.items
            activeConversationID = stored.items.contains(where: { $0.id == stored.activeID }) ? stored.activeID : stored.items[0].id
        } else {
            let legacy = value.flatMap { defaults.data(forKey: $0.storageKey) }
                .flatMap { try? JSONDecoder().decode(CoachHistory.self, from: $0) } ?? CoachHistory()
            let initial = CoachConversation(history: legacy)
            conversations = [initial]; activeConversationID = initial.id
        }
        restoreActive()
        save()
    }

    private func restoreActive() {
        let history = conversations.first(where: { $0.id == activeConversationID })?.history ?? CoachHistory()
        restoring = true
        messages = Array(history.messages.suffix(100)); draft = history.draft; references = history.references ?? []
        restoring = false; error = ""
    }

    func newConversation() {
        cancel(); save()
        if messages.isEmpty && draft.isEmpty && references.isEmpty { return }
        let next = CoachConversation()
        conversations.insert(next, at: 0); activeConversationID = next.id
        restoreActive(); save()
    }

    func openConversation(_ id: UUID) {
        guard id != activeConversationID, conversations.contains(where: { $0.id == id }) else { return }
        cancel(); save()
        activeConversationID = id; restoreActive(); save()
    }

    /// Closing the screen or changing identity preserves partial text in its original scope.
    func cancel() {
        preservePartial(status:"stopped")
        cancelWork()
    }
    func stop() {
        let hadText = !received.isEmpty
        preservePartial(status:"stopped")
        cancelWork()
        if hadText { draft = "" }
    }
    private func cancelWork() {
        epoch = UUID(); request?.cancel(); request = nil
        flush?.cancel(); flush = nil
        sending = false; pendingQuestion = ""; pendingAnswer = ""; received = "";pendingReferences=[];pendingBlocks=[]
    }
    private func preservePartial(status:String) {
        guard sending, !received.isEmpty else { return }
        appendAnswer(CoachReply(reply:received), status:status)
        save()
    }
    private func appendAnswer(_ reply:CoachReply, status:String? = nil) {
        let refs=reply.references ?? (pendingReferences.isEmpty ? nil : pendingReferences)
        let blocks=reply.blocks ?? (pendingBlocks.isEmpty ? nil : [.markdown(id:"answer",text:reply.reply)]+pendingBlocks)
        messages.append(contentsOf:[CoachMessage(role:"user", content:pendingQuestion,references:pendingReferences.isEmpty ? nil : pendingReferences),
            CoachMessage(id:pendingID, role:"assistant", content:reply.reply, blocks:blocks,references:refs, completion:status)])
        messages = Array(messages.suffix(100))
    }
    private func receive(_ text:String, run:UUID) {
        guard epoch == run, sending else { return }
        received += text
        if pendingAnswer.isEmpty { pendingAnswer = received; return }
        guard flush == nil else { return }
        flush = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:50_000_000) } catch { return }
            guard let self, self.epoch == run, self.sending else { return }
            self.pendingAnswer = self.received; self.flush = nil
        }
    }

    func send() async {
        guard canSend, let context else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = epoch
        error = ""; sending = true; pendingQuestion = question
        pendingID = UUID(); pendingAnswer = ""; received = "";pendingReferences=references;pendingBlocks=[]
        let input = CoachHistory.context(messages, question: question)
        let transport = stream
        let frozen=references
        let task = Task { [weak self] in try await transport(context,input,frozen,{ [weak self] text in self?.receive(text,run:run) },{ [weak self] refs,blocks in
            guard let self,self.epoch==run,self.sending else { return }
            self.pendingReferences=refs;self.pendingBlocks=blocks
        }) }
        request = task
        do {
            let answer = try await task.value
            guard epoch == run, self.context == context else { return }
            appendAnswer(answer)
            draft = ""; save()
        } catch {
            guard epoch == run, self.context == context else { return }
            preservePartial(status:error is CancellationError ? "stopped" : "interrupted")
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        guard epoch == run else { return }
        flush?.cancel(); flush = nil
        request = nil; sending = false; pendingQuestion = ""; pendingAnswer = ""; received = "";pendingReferences=[];pendingBlocks=[]
    }

    private func save() {
        guard !restoring, let context,
              let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        let history = CoachHistory(messages: messages, draft: draft, references: references.isEmpty ? nil : references)
        conversations[index].history = history
        conversations[index].updatedAt = Date()
        let archive = CoachConversations(activeID: activeConversationID, items: conversations)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: context.storageKey + ".conversations")
    }
}
