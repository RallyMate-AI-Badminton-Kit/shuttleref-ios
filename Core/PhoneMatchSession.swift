import Foundation

/// Main-actor command arbiter; SQLite writer token also fences stale sessions/other
/// controllers. This core never publishes DP110 and never interprets ATT success as scoring.
@MainActor final class PhoneMatchSession {
    private let storage: PhoneMatchPersistence; let scope: PhoneMatchScope
    private let writer = UUID().uuidString
    private var isForeground = true
    private var activeContext: String?; private var connection: UUID?
    private var contextConnections: [String:UUID] = [:]
    private var configuredOK = false; private var readyLease: UInt32 = 0; private var validUntil: UInt64 = 0
    private var capabilities: UInt8 = 0
    private(set) var needsReview = false
    private var uncertain: Pending?
    var storageUncertain: Bool { uncertain != nil }
    var readyForScoring: Bool { configuredOK && validUntil > 0 && !needsReview && !storageUncertain && isForeground }
    private struct Pending {
        let matchID: String; let id: String; let payload: Data
        let context: String?; let seq: UInt32?
    }
    init(storage: PhoneMatchPersistence, scope: PhoneMatchScope) throws {
        guard storage.namespace == scope.key, !scope.origin.isEmpty, !scope.account.isEmpty, !scope.installation.isEmpty else { throw PhoneScoreError.invalidState }
        self.storage = storage; self.scope = scope
        try storage.transaction { db in
            db.writer = writer
            for m in db.matches.indices { for c in db.matches[m].contexts.indices { db.matches[m].contexts[c].retired = true } }
            needsReview = db.matches.last.map { $0.phase != .ended } ?? false
        }
    }
    private func owned(_ db: PhoneMatchDatabase) throws { guard db.writer == writer else { throw PhoneScoreError.staleWriter } }
    func current() throws -> PhoneLocalMatch? { let db = try storage.read(); try owned(db); return db.matches.last }
    private func writable() throws {
        guard isForeground, uncertain == nil else { throw PhoneScoreError.invalidState }
    }
    private func queue(_ match: PhoneLocalMatch, db: inout PhoneMatchDatabase) {
        let envelope = PhoneSyncEnvelope(match:match,installation:scope.installation)
        db.outbox.append(PhoneSyncItem(id:match.id+":"+String(match.revision),envelope:envelope))
    }
    func start(participants: [PhoneParticipant], doubles: Bool) throws {
        try writable()
        let count = doubles ? 2:1
        guard participants.count == 2*count, Set(participants.map(\.id)).count == participants.count,
              participants.allSatisfy({ RacketScoreWire.identityUUID($0.id) != nil && !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }),
              participants.filter({ $0.side == .red }).count == count else { throw PhoneScoreError.invalidState }
        let id = UUID().uuidString.lowercased(), payload = try JSONEncoder().encode(participants)
        let pending = Pending(matchID:id,id:"start:"+id,payload:payload,context:nil,seq:nil)
        do {
            try storage.transaction { db in
                try owned(db); guard db.matches.last?.phase == .ended || db.matches.isEmpty else { throw PhoneScoreError.invalidState }
                var match = PhoneLocalMatch(id:id,participants:participants,doubles:doubles)
                match.journal.append(PhoneJournalEntry(id:pending.id,payload:payload,action:.start,ack:nil,revision:1))
                db.matches.append(match); queue(match,db:&db)
            }
            needsReview = false
        } catch PhoneScoreError.storageUncertain { uncertain = pending; suspend(); throw PhoneScoreError.storageUncertain }
    }
    func manual(_ action: PhoneAction, id: String = UUID().uuidString.lowercased()) throws {
        try writable(); guard action != .start, RacketScoreWire.uuid(id), let current = try current() else { throw PhoneScoreError.invalidState }
        let payload = Data(action.rawValue.utf8), eventID = "manual:"+id
        let pending = Pending(matchID:current.id,id:eventID,payload:payload,context:nil,seq:nil)
        do {
            try storage.transaction { db in
                try owned(db); guard let i = db.matches.indices.last else { throw PhoneScoreError.invalidState }
                var m = db.matches[i]
                if let receipt = m.journal.first(where: { $0.id == eventID }) {
                    guard receipt.payload == payload else { throw PhoneScoreError.protocolConflict }
                    guard receipt.action != nil else { throw PhoneScoreError.storageFailed }; return
                }
                guard m.phase != .ended, m.revision < UInt32.max else { throw PhoneScoreError.invalidState }
                switch action {
                case .red, .blue, .undo:
                    guard m.phase == .active else { throw PhoneScoreError.invalidState }
                    if action == .undo { try m.score.undo() } else { try m.score.add(action == .red ? .red:.blue) }
                case .pause: guard m.phase == .active else { throw PhoneScoreError.invalidState }; m.phase = .paused
                case .resume: guard m.phase == .paused else { throw PhoneScoreError.invalidState }; m.phase = .active
                case .end: m.phase = .ended
                case .start: throw PhoneScoreError.invalidState
                }
                m.revision += 1; bumpLease(&m)
                m.journal.append(PhoneJournalEntry(id:eventID,payload:payload,action:action,ack:nil,revision:m.revision))
                db.matches[i] = m; queue(m,db:&db)
            }
            if [.pause,.resume,.end].contains(action) { stop() }
        } catch PhoneScoreError.storageUncertain { uncertain = pending; suspend(); throw PhoneScoreError.storageUncertain }
    }
    private func bumpLease(_ m: inout PhoneLocalMatch) {
        for i in m.contexts.indices where !m.contexts[i].retired {
            if m.contexts[i].lease == UInt32.max { m.contexts[i].retired = true }
            else { m.contexts[i].lease += 1 }
        }
    }
    /// Caller supplies the identity/revision established by the current v2 authentication,
    /// never from advertisements. A future signed control grant is still required for Release.
    func prepare(info: RacketScoreInfo, authenticatedDevice: String, owner: String, associationRevision: UInt32,
                 side: PhoneSide, connection: UUID, subscribed: Bool, controlOwner: String? = nil) throws -> RacketScoreMessage {
        try writable()
        guard !needsReview, activeContext == nil, subscribed, info.device == authenticatedDevice,
              info.capabilities & 1 != 0, let match = try current(), match.phase == .active, !match.score.finished,
              match.participants.contains(where: { $0.id == owner && $0.side == side }) else { throw PhoneScoreError.invalidState }
        var c = PhoneScoreContext(id:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),matchID:match.id,
                                 device:info.device,boot:info.boot,owner:owner,associationRevision:associationRevision,side:side)
        c.controlOwner = controlOwner
        let message = try c.configure()
        try storage.transaction { db in
            try owned(db); guard db.matches.last?.id == match.id else { throw PhoneScoreError.invalidState }
            db.matches[db.matches.count-1].contexts.append(c)
        }
        self.connection = connection; contextConnections[c.id] = connection; activeContext = c.id
        configuredOK = false; validUntil = 0; readyLease = 0; capabilities = info.capabilities
        return message
    }
    func configured(_ message: RacketScoreMessage, connection: UUID) throws {
        guard message.type == "configured", self.connection == connection, message.text("context") == activeContext,
              !needsReview else { suspend(); throw PhoneScoreError.invalidState }
        guard message.text("status") == "ok" else { suspend(); throw PhoneScoreError.configurationRejected }
        configuredOK = true
    }
    private func liveContext() throws -> PhoneScoreContext {
        guard let id = activeContext, let m = try current(), m.phase == .active,
              let c = m.contexts.first(where: { $0.id == id }), !c.retired else { throw PhoneScoreError.invalidState }
        return c
    }
    func ready(now: UInt64) throws -> RacketScoreMessage {
        try writable(); guard configuredOK, !needsReview else { throw PhoneScoreError.invalidState }
        if validUntil > 0 && now >= validUntil { suspend(); throw PhoneScoreError.invalidState }
        let c = try liveContext()
        return try RacketScoreWire.message("ready",text:["context":c.id],numbers:["lease":c.lease])
    }
    func readyDelivered(lease: UInt32, now: UInt64) throws {
        guard configuredOK, isForeground, !needsReview, !storageUncertain, now <= UInt64.max-2500,
              validUntil == 0 || now < validUntil,
              try liveContext().lease == lease else { suspend(); throw PhoneScoreError.invalidState }
        readyLease = lease; validUntil = now + 2500
    }
    func observe(_ state: RacketScoreState, connection: UUID, now: UInt64) throws {
        guard self.connection == connection else { return }
        let c = try liveContext()
        if state.boot != c.boot || state.phase == 4 || state.phase == 0 || (validUntil > 0 && now >= validUntil) { suspend() }
        // A STATE read can never establish configuredOK or readiness.
    }
    func requireReview() { suspend() }
    func mayContinue(_ message: RacketScoreMessage) -> Bool {
        if message.type == "stop" { return true }
        guard message.text("context") == activeContext else { return false }
        if message.type == "ack" { return true }
        return isForeground && !needsReview && !storageUncertain
    }
    func maySend(_ message: RacketScoreMessage) -> Bool {
        if message.type == "stop" { return true }
        guard message.text("context") == activeContext else { return false }
        if message.type == "ack" { return true }
        guard isForeground, !needsReview, !storageUncertain else { return false }
        if message.type == "ready" { return configuredOK && (try? liveContext().lease) == message.number("lease") }
        return message.type == "configure"
    }
    func syncState() throws -> String {
        let db = try storage.read(); try owned(db)
        guard let match = db.matches.last else { return "empty" }
        let items = db.outbox.filter { $0.envelope.match_id == match.id }
        if items.contains(where: { $0.state == "conflict" }) { return "conflict" }
        return items.contains(where: { $0.state == "pending" }) ? "pending" : "synced"
    }
    /// Durable outbox retries retain the exact original operation ID and envelope.
    func synchronize(using service: MatchSyncService) async throws {
        guard !storageUncertain else { throw PhoneScoreError.storageUncertain }
        let initial = try storage.read(); try owned(initial)
        var blocked = Set(initial.outbox.filter { $0.state == "conflict" }.map { $0.envelope.match_id })
        for item in initial.outbox where item.state == "pending" && !blocked.contains(item.envelope.match_id) {
            guard !storageUncertain else { throw PhoneScoreError.storageUncertain }
            let response = try await service.upload(item.envelope,operationID:item.id,scope:scope)
            guard !storageUncertain else { throw PhoneScoreError.storageUncertain }
            var state: String
            switch response {
            case .unavailable: return
            case .conflict: state = "conflict"; blocked.insert(item.envelope.match_id)
            case .accepted(let id,let revision,let installation):
                guard id == item.envelope.match_id, revision == item.envelope.revision,
                      installation == scope.installation else { throw PhoneScoreError.protocolConflict }
                state = "synced"
            }
            try storage.transaction { db in
                try owned(db) // A late response from an old login/controller cannot mark new data synced.
                guard let i = db.outbox.firstIndex(where: { $0.id == item.id }),
                      db.outbox[i].envelope == item.envelope else { throw PhoneScoreError.protocolConflict }
                db.outbox[i].state = state
            }
        }
    }
    private func suspend() { needsReview = true; configuredOK = false; validUntil = 0; readyLease = 0 }
    /// Returns the old context's stop message even if the connection has already gone away.
    @discardableResult func stop() -> RacketScoreMessage? {
        let old = activeContext; activeContext = nil; configuredOK = false; validUntil = 0; readyLease = 0
        return old.flatMap { try? RacketScoreWire.message("stop",text:["context":$0]) }
    }
    func background() { isForeground = false; suspend(); stop() }
    func foreground() { isForeground = true } // Explicit review, authentication and new context are required.
    func disconnected() { suspend(); stop(); connection = nil; contextConnections = [:] }
    func confirmReview() throws {
        try writable(); guard activeContext == nil else { throw PhoneScoreError.invalidState }
        let db = try storage.read(); try owned(db); needsReview = false
    }
    func canSend(_ ack: PhoneScoreACK, connection: UUID) -> Bool {
        self.connection == connection && activeContext == ack.context
    }
    func receive(_ event: RacketScoreMessage, connection: UUID, now: UInt64) throws -> PhoneScoreACK {
        guard event.type == "event", contextConnections[event.text("context")] == connection else { throw PhoneScoreError.invalidState }
        let db = try storage.read(); try owned(db)
        guard let m = db.matches.first(where: { $0.contexts.contains(where: { $0.id == event.text("context") }) }),
              let ctx = m.contexts.first(where: { $0.id == event.text("context") }) else { throw PhoneScoreError.invalidState }
        let payload = try RacketScoreWire.encode(event)
        let id = [ctx.device,ctx.boot,ctx.id,String(event.number("seq"))].joined(separator:":")
        let pending = Pending(matchID:m.id,id:id,payload:payload,context:ctx.id,seq:event.number("seq"))
        if storageUncertain { return ack(pending,revision:m.revision,status:"unknown",reason:"storage_uncertain") }
        var result: PhoneScoreACK?
        do {
            try storage.transaction { db in
                try owned(db)
                guard let mi = db.matches.firstIndex(where: { $0.id == m.id }),
                      let ci = db.matches[mi].contexts.firstIndex(where: { $0.id == ctx.id }) else { throw PhoneScoreError.invalidState }
                var match = db.matches[mi]; let c = match.contexts[ci]
                if let record = match.journal.first(where: { $0.id == id }) {
                    guard record.payload == payload, let saved = record.ack else { throw PhoneScoreError.protocolConflict }
                    result = saved; return // Dedup BEFORE current lease, phase or readiness.
                }
                var reason: String?
                if match.phase == .ended || (match.score.finished && event.text("action") == "add") { reason = "match_closed" }
                else if event.number("seq") <= c.highestSeq { reason = "invalid_event" }
                else if !match.participants.contains(where: { $0.id == c.owner && $0.side == c.side }) { reason = "identity_changed" }
                else if event.number("lease") != c.lease { reason = "stale_lease" }
                else if !isForeground || needsReview || activeContext != c.id || !configuredOK || c.retired || match.phase != .active || now >= validUntil || readyLease != c.lease { reason = "not_ready" }
                else if event.text("action") == "undo" && capabilities & 2 == 0 { reason = "invalid_event" }
                else if event.text("action") == "undo" && match.score.points.isEmpty { reason = "no_undo" }
                else if match.revision == UInt32.max || (event.text("action") == "add" && match.score.points.count >= 256) { reason = "invalid_event" }
                let action: PhoneAction = event.text("action") == "undo" ? .undo : (c.side == .red ? .red:.blue)
                if reason == nil {
                    if action == .undo { try match.score.undo() } else { try match.score.add(c.side) }
                    match.revision += 1; bumpLease(&match)
                }
                match.contexts[ci].highestSeq = max(c.highestSeq,event.number("seq"))
                let receipt = ack(pending,revision:match.revision,status:reason == nil ? "committed":"rejected",reason:reason ?? "ok")
                match.journal.append(PhoneJournalEntry(id:id,payload:payload,action:reason == nil ? action:nil,ack:receipt,revision:match.revision))
                db.matches[mi] = match; if reason == nil { queue(match,db:&db) }; result = receipt
            }
            return result!
        } catch PhoneScoreError.protocolConflict { suspend(); throw PhoneScoreError.protocolConflict }
        catch PhoneScoreError.storageUncertain {
            uncertain = pending; suspend(); return ack(pending,revision:m.revision,status:"unknown",reason:"storage_uncertain")
        } catch PhoneScoreError.storageFailed {
            suspend()
            // A known rollback can produce a rejection only when its terminal receipt is durable.
            do { return try persistFailure(pending)! }
            catch { uncertain = pending; return ack(pending,revision:m.revision,status:"unknown",reason:"storage_uncertain") }
        }
    }
    private func ack(_ p: Pending, revision: UInt32, status: String, reason: String) -> PhoneScoreACK {
        PhoneScoreACK(context:p.context!,seq:p.seq!,status:status,revision:revision,reason:reason)
    }
    private func persistFailure(_ p: Pending) throws -> PhoneScoreACK? {
        var result: PhoneScoreACK?
        try storage.transaction { db in
            try owned(db)
            guard let i = db.matches.firstIndex(where: { $0.id == p.matchID }) else {
                // Failed start: no match/event exists. Nothing to execute again implicitly.
                if p.context == nil { return }; throw PhoneScoreError.storageFailed
            }
            if let record = db.matches[i].journal.first(where: { $0.id == p.id }) {
                guard record.payload == p.payload else { throw PhoneScoreError.protocolConflict }
                result = record.ack; return
            }
            result = p.context.map { _ in ack(p,revision:db.matches[i].revision,status:"rejected",reason:"storage_failed") }
            db.matches[i].journal.append(PhoneJournalEntry(id:p.id,payload:p.payload,action:nil,ack:result,revision:db.matches[i].revision))
        }
        return result
    }
    /// Reopen and query by original operation identity. NEVER retry the original action.
    func recoverStorage() throws -> PhoneScoreACK? {
        guard let pending = uncertain else { throw PhoneScoreError.invalidState }
        try storage.reopen()
        let result = try persistFailure(pending)
        uncertain = nil; suspend(); return result
    }
}
