import Foundation
import Combine

// Owns the verified DP contract independently of any screen or SDK transport.
final class MatchSession: ObservableObject {
    typealias Sender = (String, @escaping (Error?) -> Void) -> Void
    @Published private(set) var current: MatchSnapshot?
    @Published private(set) var saved: MatchSnapshot?
    @Published private(set) var fresh = false
    @Published private(set) var pending: Pending?
    @Published private(set) var message = "等待同步设备状态"
    @Published private(set) var online: Bool
    @Published private(set) var lastConfirmed: String?
    struct Pending { let op: String; let id: String; let token: UInt32 }
    var completedResults: [LocalMatchResult] {
        guard let data = defaults.data(forKey: key + ".results") else { return [] }
        return (try? JSONDecoder().decode([LocalMatchResult].self, from: data)) ?? []
    }
    func settle(names: [String], doubles: Bool, mvpSlot: Int?, early: Bool = false) throws {
        guard fresh, pending == nil, let snapshot = current, (early ? snapshot.state == "p" && !snapshot.finished : snapshot.state == "a" && snapshot.finished), snapshot.hasID, snapshot.scores[2] + snapshot.scores[3] <= 3, snapshot.code == 0,
              names.count == 4, (mvpSlot.map { (doubles ? [0,1,2,3] : [0,2]).contains($0) } ?? early) else {
            throw NSError(domain: "MatchSettlement", code: 1, userInfo: [NSLocalizedDescriptionKey: "请同步已结束的球局，并选择本场 MVP"])
        }
        guard !completedResults.contains(where: { $0.id == snapshot.id }) else { return }
        let result = LocalMatchResult(id: snapshot.id, snapshot: snapshot, names: names, doubles: doubles, mvpSlot: mvpSlot, date: Date(), earlyEnded: early, observations: observations.filter { $0.snapshot.id == snapshot.id })
        let data = try JSONEncoder().encode([result] + completedResults)
        defaults.set(data, forKey: key + ".results")
        objectWillChange.send()
    }
    private var observations: [MatchObservation] {
        get {
            guard let data = defaults.data(forKey: key + ".observations") else { return [] }
            return (try? JSONDecoder().decode([MatchObservation].self, from: data)) ?? []
        }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key + ".observations") } }
    }
    private func observe(_ snapshot: MatchSnapshot) {
        guard snapshot.code == 0, snapshot.hasID, ["a", "p"].contains(snapshot.state) else { return }
        var values = observations.filter { $0.snapshot.id == snapshot.id }
        if let last = values.last, last.snapshot.scores == snapshot.scores, last.snapshot.state == snapshot.state { return }
        values.append(MatchObservation(date: Date(), snapshot: snapshot))
        observations = Array(values.suffix(600))
    }
    private let key: String
    private let defaults: UserDefaults
    private let sender: Sender
    private var timer: Timer?
    private var valid = true

    init(accountID: String, deviceID: String, online: Bool, cache: String?, defaults: UserDefaults = .standard, sender: @escaping Sender) {
        self.key = "shuttleref.spike.match.\(accountID).\(deviceID)" // Keep v3 saved matches.
        self.defaults = defaults; self.online = online; self.sender = sender
        if let cache = cache { current = MatchSnapshot(cache) }
        if let data = defaults.data(forKey: key) { saved = try? JSONDecoder().decode(MatchSnapshot.self, from: data) }
    }
    var phase: String { current?.finished == true ? "已结束" : current?.state == "p" ? "已暂存" : current?.state == "a" ? "比赛中" : "待机" }
    var hasOldScore: Bool { current?.scores.prefix(4).contains(where: { $0 != 0 }) == true }
    func can(_ op: String) -> Bool {
        guard valid, online, pending == nil else { return false }
        if op == "Q" { return true }
        guard fresh, let s = current else { return false }
        switch op {
        case "r", "b", "U", "P": return s.state == "a" && s.hasID && !s.finished
        case "B": return s.state == "i" && !hasOldScore && saved == nil
        case "R": return saved != nil && s.state != "a"
        case "A": return s.hasID || hasOldScore || saved != nil
        default: return false
        }
    }
    func send(_ op: String, matchID: String? = nil) {
        guard can(op) else { return }
        let s = op == "R" ? saved : current
        let generatedID = (op == "B" || s?.hasID != true) ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : s!.id
        let id = op == "B" ? (matchID ?? generatedID) : generatedID
        let stored = defaults.double(forKey: key + ".seq")
        let safeStored = stored.isFinite && stored >= 0 && stored <= Double(UInt32.max) ? UInt32(stored) : 0
        let previous = max(current?.token ?? 0, safeStored)
        guard previous < UInt32.max else { message = "指令序号已耗尽，请联系开发者"; return }
        let sequence = previous + 1
        guard let wire = MatchWire.encode(op, id: id, sequence: sequence, scores: s?.scores ?? [0,0,0,0,0]) else { message = "此暂存比分无法恢复"; return }
        defaults.set(Double(sequence), forKey: key + ".seq")
        lastConfirmed = nil; pending = Pending(op: op, id: id, token: sequence)
        message = "正在等待设备确认…"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.expire() }
        sender(wire) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self, self.valid, self.pending?.token == sequence else { return }
                if let error = error { self.invalidate("发送异常（\((error as NSError).code)），请同步确认实际结果") }
                else { self.message = "已发送，等待设备确认…" }
            }
        }
    }
    func receive(_ raw: String) {
        guard valid, let s = MatchSnapshot(raw) else { return }
        if let old = current, s.token < old.token { return }
        current = s
        observe(s)
        if s.state == "p", s.hasID, s.code == 0 { save(s) }
        guard let p = pending, s.token == p.token || s.code == 3 && s.token > p.token else { return }
        timer?.invalidate(); pending = nil
        let identityOK = p.op == "Q" || s.id == p.id
        let stateOK = p.op == "B" || p.op == "R" ? s.state == "a" : p.op == "P" ? s.state == "p" : p.op == "A" ? s.state == "i" : true
        fresh = identityOK && s.code == 0 && stateOK
        if fresh {
            if p.op == "A" || p.op == "R" { save(nil) }
            lastConfirmed = p.op
            message = p.op == "Q" ? "比分已同步" : p.op == "P" ? "已暂存到本机" : p.op == "R" ? "已恢复球局" : "设备已确认"
        } else {
            let errors = [1:"当前状态不允许此操作", 2:"设备已有其他球局或旧比分", 3:"序号已更新，请再次同步", 4:"设备存储失败，请检查设备"]
            message = errors[s.code] ?? "回执不匹配，请同步后检查"
        }
    }
    func setOnline(_ value: Bool) {
        online = value
        if !value { invalidate("设备已离线，重连后请同步比分") }
    }
    func discardLocalSave() {
        save(nil)
        message = "本机暂存已删除；设备比分未修改。"
        objectWillChange.send()
    }
    func expire() { invalidate("未收到设备确认，结果未知。请同步后检查，不要重复加分。") }
    func invalidate(_ text: String = "请重新同步设备状态") { timer?.invalidate(); pending = nil; fresh = false; message = text }
    func disconnect() { valid = false; online = false; invalidate("设备已断开") }
    private func save(_ value: MatchSnapshot?) {
        saved = value
        if let value = value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
    deinit { timer?.invalidate() }
}

struct LocalMatchResult: Codable, Identifiable {
    let id: String; let snapshot: MatchSnapshot; let names: [String]; let doubles: Bool; let mvpSlot: Int?; let date: Date; var earlyEnded: Bool? = nil
    var observations: [MatchObservation]? = nil
    var mvpName: String { guard let slot = mvpSlot, names.indices.contains(slot) else { return "未评选" }; return names[slot] }
}


struct MatchObservation: Codable {
    let date: Date
    let snapshot: MatchSnapshot
}
