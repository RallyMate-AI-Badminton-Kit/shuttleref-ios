import Foundation
import SQLite3

protocol PhoneMatchPersistence: AnyObject {
    var namespace: String { get }
    func read() throws -> PhoneMatchDatabase
    func transaction(_ body: (inout PhoneMatchDatabase) throws -> Void) throws
    func reopen() throws
}

/// One SQLite transaction contains the aggregate, terminal receipts and immutable outbox
/// envelopes. FULL WAL durability; never reset corrupt/unreadable data to an empty match.
final class PhoneMatchStore: PhoneMatchPersistence {
    private let url: URL; private let scope: String
    var namespace: String { scope }
    private var db: OpaquePointer?; private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, scope: String) throws {
        self.url = url; self.scope = scope
        guard !scope.isEmpty else { throw PhoneScoreError.invalidState }
        try open()
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    private func open() throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {
            if let db { sqlite3_close_v2(db) }; db = nil; throw PhoneScoreError.storageFailed
        }
        do {
            sqlite3_busy_timeout(db,3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS phone_match_state (scope TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        } catch { sqlite3_close_v2(db); db = nil; throw error }
    }
    func reopen() throws {
        lock.lock(); defer { lock.unlock() }
        if let db { guard sqlite3_close(db) == SQLITE_OK else { throw PhoneScoreError.storageUncertain } }
        db = nil; try open()
    }
    private func execute(_ sql: String) throws {
        guard let db, sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw PhoneScoreError.storageFailed }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw PhoneScoreError.storageFailed }
        return statement
    }
    func read() throws -> PhoneMatchDatabase {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM phone_match_state WHERE scope=?")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement,1,scope,-1,transient) == SQLITE_OK else { throw PhoneScoreError.storageFailed }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return PhoneMatchDatabase() }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement,0) else { throw PhoneScoreError.storageFailed }
        do {
            let state = try JSONDecoder().decode(PhoneMatchDatabase.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(statement,0))))
            guard state.schema == 1 else { throw PhoneScoreError.storageFailed }; return state
        } catch { throw PhoneScoreError.storageFailed }
    }
    func transaction(_ body: (inout PhoneMatchDatabase) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        var committed = false; defer { if !committed { try? execute("ROLLBACK") } }
        var state = try read(); try body(&state)
        let data = try JSONEncoder().encode(state)
        let statement = try prepare("INSERT INTO phone_match_state(scope,payload) VALUES(?,?) ON CONFLICT(scope) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement,1,scope,-1,transient) == SQLITE_OK else { throw PhoneScoreError.storageFailed }
        let bind = data.withUnsafeBytes { sqlite3_bind_blob(statement,2,$0.baseAddress,Int32($0.count),transient) }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw PhoneScoreError.storageFailed }
        do { try execute("COMMIT"); committed = true }
        catch { throw PhoneScoreError.storageUncertain }
    }
}
