import Foundation
import Combine
import Network

@MainActor final class GatheringStore: ObservableObject {
    @Published private(set) var savedAccounts: [GatheringCredentials] = []
    @Published private(set) var credentials: GatheringCredentials?
    @Published private(set) var gatherings: [Gathering] = []
    @Published private(set) var results: [GatheringResult] = []
    @Published private(set) var detail: Gathering?
    @Published private(set) var journal = GatheringJournal()
    @Published private(set) var recordsJournal = RecordsJournal()
    @Published var recordsMessage = ""
    private var uploadingRecords = false
    private var recordsReadable = true
    @Published var message = ""
    @Published var busy = false
    @Published var oauthBusy = false
    @Published private(set) var origin: String
    private let connectivity: NWPathMonitor?
    private let storage: GatheringStorage
    private let http: URLSession
    private var subscription: AnyCancellable?
    private var flushing = false
    private var lastSnapshot = ""
    private(set) var boundSession: MatchSession?
    var userID: String { credentials?.user.id ?? "" }
    var context: GatheringContext? { journal.context }
    var installationID: String {
        let key = "social.installation"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: key); return value
    }
    init(origin override: String? = nil, storage: GatheringStorage = SystemGatheringStorage(), http: URLSession = .shared, connectivity: NWPathMonitor? = NWPathMonitor()) {
        self.storage = storage; self.http = http; self.connectivity = connectivity
        #if DEBUG
        let value = UserDefaults.standard.string(forKey: "social.origin") ?? "http://127.0.0.1:18100"
        #else
        let value = Bundle.main.object(forInfoDictionaryKey: "SocialAPIOrigin") as? String ?? ""
        #endif
        origin = override ?? value
        credentials = storage.load(origin)
        loadAccounts()
        loadJournal()
        connectivity?.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in await self?.flush(); await self?.uploadRecords() }
        }
        connectivity?.start(queue: DispatchQueue(label: "shuttleref.social.connectivity"))
    }
    deinit { connectivity?.cancel() }
    func configure(_ value: String) throws {
        guard !oauthBusy else { throw SocialClientError("请先完成或取消授权") }
        guard journal.context == nil && journal.events.isEmpty else { throw SocialClientError("请先完成当前组局球局并上传，再切换服务器") }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: clean), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else { throw SocialClientError("请输入服务器根地址，例如 http://192.168.1.10:18100") }
        #if DEBUG
        guard ["http", "https"].contains(url.scheme ?? "") else { throw SocialClientError("地址必须使用 HTTP 或 HTTPS") }
        #else
        guard url.scheme == "https" else { throw SocialClientError("正式版本需要 HTTPS") }
        #endif
        origin = clean; UserDefaults.standard.set(clean, forKey: "social.origin")
        credentials = storage.load(clean); loadAccounts(); gatherings = []; results = []; detail = nil; loadJournal()
    }
    func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = ""
        Task { defer { busy = false }; do { try await work() } catch { message = error.localizedDescription } }
    }
    func request<T: Decodable>(_ path: String, body: [String: Any]? = nil, mayRecover: Bool = true, useCredentials: Bool = true) async throws -> T {
        #if UI_PREVIEW
        guard ProcessInfo.processInfo.arguments.contains("--social-live-test") else { throw SocialClientError("界面预览不连接组局服务，请运行 ShuttleRef 目标进行联调。") }
        #endif
        let startOrigin = origin, startToken = credentials?.token
        guard let url = URL(string: startOrigin + "/api/social" + path), url.host != nil else { throw SocialClientError("请先配置组局服务器") }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if useCredentials, let token = startToken { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body = body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await http.data(for: request)
        guard origin == startOrigin, credentials?.token == startToken else { throw SocialClientError("身份或服务器已切换，请刷新") }
        if let response = response as? HTTPURLResponse, response.statusCode == 401, mayRecover,
           !["/session/create", "/session/restore"].contains(path), let previous = credentials, let recovery = previous.recovery {
            var restored: GatheringCredentials = try await self.request("/session/restore", body: ["recovery": recovery], mayRecover: false)
            guard restored.user.id == previous.user.id else { throw SocialClientError("恢复身份与本机球局不匹配，已保留本机记录") }
            restored.recovery = recovery
            try remember(restored); credentials = restored
            return try await self.request(path, body: body, mayRecover: false)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if (response as? HTTPURLResponse)?.statusCode == 401, credentials?.auth_provider == "tuya" {
                throw SocialClientError("登录已失效，请到「账号与安全」重新授权登录")
            }
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw SocialClientError(error?["error"] as? String ?? "服务器请求失败")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func loadAccounts() {
        savedAccounts = storage.loadAccounts(origin)
        if let active = credentials, !savedAccounts.contains(where: { $0.user.id == active.user.id }) { savedAccounts.append(active) }
    }
    private func remember(_ value: GatheringCredentials) throws {
        var accounts = savedAccounts.filter { $0.user.id != value.user.id }
        accounts.append(value)
        try storage.saveAccounts(accounts, origin: origin)
        try storage.save(value, origin: origin)
        savedAccounts = accounts
    }
    func switchAccount(_ id: String) async throws {
        guard let account = savedAccounts.first(where: { $0.user.id == id }), let recovery = account.recovery else { throw SocialClientError("请使用恢复凭据重新登录") }
        try await login(name: "", recovery: recovery, expectedUser: id)
    }
    func login(name: String, recovery: String? = nil, expectedUser: String? = nil) async throws {
        guard !oauthBusy else { throw SocialClientError("请先完成或取消授权") }
        guard context == nil && journal.events.isEmpty else { throw SocialClientError("请先处理当前关联球局") }
        let result: GatheringCredentials = try await request(recovery == nil ? "/session/create" : "/session/restore", body: recovery.map { ["recovery": $0] } ?? ["name": name])
        var saved = result; if saved.recovery == nil { saved.recovery = recovery }
        if let expectedUser = expectedUser, saved.user.id != expectedUser { throw SocialClientError("恢复身份不匹配") }
        try remember(saved)
        credentials = saved; gatherings = []; results = []; detail = nil; loadJournal(); try await refresh()
    }
    func finishOAuth(grant: String, verifier: String, link: Bool, name: String, stillCurrent: () -> Bool = { true }) async throws {
        guard context == nil, journal.events.isEmpty, recordsJournal.pending.isEmpty else { throw SocialClientError("请先处理当前球局和待上传记录") }
        let oldUser = credentials?.user.id
        guard link ? oldUser != nil : (oldUser == nil || credentials?.auth_provider == "tuya") else { throw SocialClientError("请关联当前旧账号，或先退出后登录") }
        let result: GatheringCredentials = try await request("/session/tuya", body: ["grant": grant, "verifier": verifier, "mode": link ? "link" : "login", "name": String((name.isEmpty ? "羽小裁球友" : name).prefix(24))], mayRecover: false, useCredentials: link)
        guard stillCurrent() else { throw SocialClientError("设备账号已变化，请重新授权；不会安装本次返回的会话") }
        guard result.auth_provider == "tuya", oldUser == nil || result.user.id == oldUser else { throw SocialClientError("授权返回的业务账号不匹配，请先退出当前账号") }
        try remember(result); credentials = result
        gatherings = []; results = []; detail = nil; loadJournal()
        do { try await refresh() } catch { message = "已登录，列表暂未刷新，请稍后重试" }
    }
    func logout() async throws {
        guard !oauthBusy else { throw SocialClientError("请先完成或取消授权") }
        guard context == nil && journal.events.isEmpty else { throw SocialClientError("当前还有组局球局或待上传事件，请先处理") }
        if (credentials?.expires_at ?? 0) > Date().timeIntervalSince1970 { let _: SocialOK = try await request("/session/logout", body: [:]) }
        let remaining = savedAccounts.filter { $0.user.id != userID }
        try storage.saveAccounts(remaining, origin: origin)
        try storage.save(nil, origin: origin)
        savedAccounts = remaining
        credentials = nil; gatherings = []; results = []; detail = nil; journal = GatheringJournal(); recordsJournal = RecordsJournal(); recordsMessage = ""
    }
    func refresh() async throws {
        guard credentials != nil else { return }
        if let old = credentials, old.expires_at > Date().timeIntervalSince1970 && old.expires_at - Date().timeIntervalSince1970 < 7 * 86400 {
            var renewed: GatheringCredentials = try await request("/session/renew", body: [:]); renewed.recovery = old.recovery
            try remember(renewed); credentials = renewed
        }
        let value: GatheringList = try await request("/gatherings")
        gatherings = value.gatherings.sorted { $0.starts_at > $1.starts_at }
        if let id = detail?.id { detail = gatherings.first { $0.id == id } }
        let completed: GatheringResults = try await request("/results"); results = completed.results
        await flush()
        try await refreshRecords()
    }
    func closeDetail() { detail = nil }
    func open(_ id: String) async throws { detail = try await request("/gatherings/" + id) }
    func create(_ body: [String: Any]) async throws {
        var body = body; body["operation_id"] = UUID().uuidString
        let _: Gathering = try await request("/gatherings", body: body)
        try await refresh()
    }
    func action(_ action: String, gathering: Gathering, body: [String: Any] = [:]) async throws {
        var body = body; body["operation_id"] = UUID().uuidString
        if action == "leave" { let _: SocialOK = try await request("/gatherings/\(gathering.id)/leave", body: body); detail = nil }
        else { let _: Gathering = try await request("/gatherings/\(gathering.id)/\(action)", body: body) }
        try await refresh()
    }
    func invite(_ gathering: Gathering) async throws -> String {
        let invite: GatheringInvite = try await request("/gatherings/\(gathering.id)/invite", body: [:])
        let configured = Bundle.main.object(forInfoDictionaryKey: "SocialInviteOrigin") as? String
        let base = (configured?.isEmpty == false ? configured! : origin).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let text = "🏸 一起打球｜\(gathering.title)\n地点：\(gathering.location)\n时间：\(Date(timeIntervalSince1970: gathering.starts_at).formatted())\n\(base)/invite/\(invite.code)\n邀请码：\(invite.code)\n复制整段，打开羽小裁 → 约朋友打球 → 粘贴并识别。查看邀请后，自行选择加入或暂不加入。邀请 7 天有效，新邀请会替换旧邀请。"
        return text
    }
    func join(_ code: String) async throws {
        let g: Gathering = try await request("/invites/\(code)/join", body: ["operation_id": UUID().uuidString])
        try await refresh(); detail = g
    }
    func fixture(_ gathering: Gathering, red: [String], blue: [String], referee: String, court: String = "", existing: GatheringFixture? = nil) async throws {
        let _: GatheringFixture = try await request("/gatherings/\(gathering.id)/fixtures" + (existing.map { "/" + $0.id + "/edit" } ?? ""), body: ["red": red, "blue": blue, "referee_id": referee, "court": court, "operation_id": UUID().uuidString])
        try await open(gathering.id)
    }
    func deleteFixture(_ fixture: GatheringFixture, gathering: Gathering) async throws {
        let _: SocialOK = try await request("/gatherings/\(gathering.id)/fixtures/\(fixture.id)/delete", body: ["operation_id": UUID().uuidString])
        try await open(gathering.id)
    }
    func reserve(_ fixture: GatheringFixture, gathering: Gathering, session: MatchSession?, deviceID: String?) async throws {
        guard let session = session, let deviceID = deviceID, session.can("B") else { throw SocialClientError("请先选择在线设备并同步，处理已有比分后再开赛") }
        guard journal.context == nil && journal.events.isEmpty else { throw SocialClientError("请先处理当前关联球局") }
        let context = GatheringContext(gatheringID: gathering.id, fixtureID: fixture.id, deviceID: deviceID,
            matchID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), installationID: installationID,
            red: fixture.red.map { fixture.names[$0] ?? "球友" }, blue: fixture.blue.map { fixture.names[$0] ?? "球友" }, redIDs: fixture.red, blueIDs: fixture.blue)
        // Persist intent BEFORE network reserve: a lost response must never allocate a second match.
        journal.context = context; journal.archived = false; journal.mvpUserID = nil; journal.earlyEnded = nil; try persist()
        var body = binding(context); body["operation_id"] = context.matchID
        do {
            let _: GatheringFixture = try await request(context.path + "/reserve", body: body)
            guard session.can("B") else { throw SocialClientError("设备状态已改变，请同步核对，勿重新开赛") }
            session.send("B", matchID: context.matchID)
        } catch { message = "开赛未确认，已保留关联；请刷新活动并同步核对。"; throw error }
    }
    func reconcileUnstarted(_ fixture: GatheringFixture, session: MatchSession?, deviceID: String?) async throws {
        guard let context = context, context.fixtureID == fixture.id, context.deviceID == deviceID,
              let session = session, session.fresh, session.pending == nil, session.lastConfirmed == "Q",
              let snapshot = session.current, snapshot.state == "i", snapshot.scores == [0,0,0,0,0] else {
            throw SocialClientError("请先同步原设备，确认待机且无比分")
        }
        if fixture.status == "starting" {
            var body = binding(context); body["op"] = "not_started"; body["operation_id"] = UUID().uuidString
            body["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
            let _: GatheringFixture = try await request(context.path + "/confirm", body: body)
        } else if fixture.status != "scheduled" { throw SocialClientError("对阵已经开始，不能解除关联") }
        journal.context = nil; try persist(); try await open(context.gatheringID)
    }
    func bind(_ session: MatchSession?, deviceID: String?) {
        subscription?.cancel(); boundSession = session
        guard let session = session else { return }
        subscription = session.objectWillChange.sink { [weak self, weak session] _ in
            DispatchQueue.main.async { guard let self = self, let session = session else { return }; self.consume(session, deviceID: deviceID) }
        }
    }
    private func consume(_ session: MatchSession, deviceID: String?) {
        guard let context = context, context.deviceID == deviceID, session.fresh, session.pending == nil,
              let snapshot = session.current, snapshot.id == context.matchID, snapshot.code == 0 else { return }
        let marker = "\(snapshot.id):\(snapshot.token):\(snapshot.state):\(snapshot.scores)"
        guard marker != lastSnapshot else { return }
        lastSnapshot = marker
        if journal.events.contains(where: { $0.context.fixtureID == context.fixtureID && ["complete", "early_end", "A"].contains($0.op) }) { return }
        let op = snapshot.state == "i" ? "A" : snapshot.state == "p" ? "P" : "score"
        if journal.archived { if op == "A" { journal.context = nil; try? persist() }; return }
        do { try enqueue(op, snapshot: snapshot); Task { await flush() } } catch { message = error.localizedDescription }
    }
    func settlementPlayers() async throws -> [(id: String, name: String)] {
        guard var context = context else { return [] }
        if context.redIDs == nil || context.blueIDs == nil {
            let gathering: Gathering = try await request("/gatherings/" + context.gatheringID)
            guard let fixture = gathering.fixtures.first(where: { $0.id == context.fixtureID }), self.context?.matchID == context.matchID else { throw SocialClientError("球局关联已改变，请重新打开结算") }
            context.redIDs = fixture.red; context.blueIDs = fixture.blue
            journal.context = context; try persist()
        }
        return Array(zip((context.redIDs ?? []) + (context.blueIDs ?? []), context.red + context.blue)).map { (id: $0.0, name: $0.1) }
    }
    func complete(_ session: MatchSession?, mvpUserID: String?, early: Bool = false) throws {
        guard let session = session, session.fresh, session.pending == nil, let snapshot = session.current,
              (early ? snapshot.state == "p" && !snapshot.finished : snapshot.finished), snapshot.id == context?.matchID else { throw SocialClientError("请先同步并完成当前设备球局") }
        guard !journal.archived, !journal.events.contains(where: { ["complete", "early_end"].contains($0.op) }),
              (mvpUserID.map { ((context?.redIDs ?? []) + (context?.blueIDs ?? [])).contains($0) } ?? early) else { throw SocialClientError("请选择本场参赛球员；已提交的结算不能重复修改") }
        let previous = journal
        do {
            journal.mvpUserID = mvpUserID; journal.earlyEnded = early
            try enqueue(early ? "early_end" : "complete", snapshot: snapshot, mvpUserID: mvpUserID)
        } catch { journal = previous; throw error }
        Task { await flush() }
    }
    private func enqueue(_ op: String, snapshot: MatchSnapshot, mvpUserID: String? = nil) throws {
        guard let context = context else { return }
        journal.events.append(GatheringEvent(id: UUID().uuidString, context: context, op: op, snapshot: snapshot, mvpUserID: mvpUserID))
        try persist(); message = "已保存到本机，等待上传"
    }
    func flush() async {
        guard !flushing, credentials != nil else { return }; flushing = true; defer { flushing = false }
        while let event = journal.events.first {
            do {
                var body = binding(event.context)
                body["operation_id"] = event.id; body["op"] = event.op
                if let mvp = event.mvpUserID { body["mvp_user_id"] = mvp }
                body["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event.snapshot))
                let _: GatheringFixture = try await request(event.context.path + "/confirm", body: body)
                guard journal.events.first?.id == event.id else { return }
                journal.events.removeFirst()
                if ["complete", "early_end"].contains(event.op) {
                    journal.archived = true
                    journal.events.removeAll { $0.context.fixtureID == event.context.fixtureID }
                }
                if event.op == "A" { journal.context = nil }
                try persist(); message = journal.events.isEmpty ? "组局记录已同步" : "正在上传…"
            } catch { message = "本机记录待上传：" + error.localizedDescription; return }
        }
    }
    private func binding(_ c: GatheringContext) -> [String: Any] { ["device_id": c.deviceID, "match_id": c.matchID, "installation_id": c.installationID] }
    private func persist() throws {
        guard !userID.isEmpty else { return }
        try JSONEncoder().encode(journal).write(to: storage.journalFile(origin, user: userID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func loadJournal() {
        loadRecords()
        journal = GatheringJournal(); lastSnapshot = ""
        guard !userID.isEmpty else { return }
        do {
            let path = try storage.journalFile(origin, user: userID)
            if FileManager.default.fileExists(atPath: path.path) { journal = try JSONDecoder().decode(GatheringJournal.self, from: Data(contentsOf: path)) }
        } catch { message = "本机球局记录无法读取，请保留 App 数据并联系开发者" }
    }
}

extension GatheringStore {
    private func recordsFile() throws -> URL {
        try storage.journalFile(origin, user: userID).appendingPathExtension("records")
    }
    private func saveRecords(_ value: RecordsJournal) throws {
        guard recordsReadable, !userID.isEmpty else { throw SocialClientError("战绩缓存不可写，请保留本机数据") }
        try JSONEncoder().encode(value).write(to: recordsFile(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        recordsJournal = value
    }
    private func loadRecords() {
        recordsJournal = RecordsJournal(); recordsMessage = ""; recordsReadable = true
        guard !userID.isEmpty else { return }
        do {
            let file = try recordsFile()
            if FileManager.default.fileExists(atPath: file.path) {
                recordsJournal = try JSONDecoder().decode(RecordsJournal.self, from: Data(contentsOf: file))
                results = recordsJournal.groups
            }
        } catch { recordsReadable = false; recordsMessage = "战绩缓存读取失败，已保留原文件，请联系开发者" }
    }
    /// Explicit owner selection for legacy imports; called at settlement for new matches.
    func queueRecord(_ result: LocalMatchResult, deviceID: String) throws {
        guard !userID.isEmpty else { throw SocialClientError("请先在账号管理登录战绩账号") }
        let record = PersonalRecord(deviceID: deviceID, result: result)
        if recordsJournal.uploaded.contains(where: { $0.id == record.id }) || recordsJournal.pending.contains(where: { $0.id == record.id }) { return }
        var next = recordsJournal; next.pending.append(record)
        try saveRecords(next)
    }
    func uploadRecords() async {
        guard !uploadingRecords, !userID.isEmpty, recordsReadable else { return }
        uploadingRecords = true; defer { uploadingRecords = false }
        let owner = userID, server = origin
        do {
            while let record = recordsJournal.pending.first {
                let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
                let _: SocialOK = try await request("/records", body: body)
                guard owner == userID, server == origin else { return }
                var next = recordsJournal
                next.pending.removeAll { $0.id == record.id }
                next.uploaded.removeAll { $0.id == record.id }; next.uploaded.append(record)
                try saveRecords(next)
            }
            recordsMessage = ""
        } catch {
            if owner == userID && server == origin { recordsMessage = "成绩已保留，上传未完成：" + error.localizedDescription }
        }
    }
    func refreshRecords() async throws {
        guard !userID.isEmpty else { return }
        let owner = userID, server = origin
        await uploadRecords()
        let personal: PersonalRecords = try await request("/records")
        let groups: GatheringResults = try await request("/results")
        guard owner == userID, server == origin else { return }
        var next = recordsJournal; next.uploaded = personal.records; next.groups = groups.results
        try saveRecords(next); results = groups.results
    }
}
