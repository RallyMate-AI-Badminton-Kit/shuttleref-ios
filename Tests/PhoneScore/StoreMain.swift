import Foundation
@main struct StoreChecks {
    static func main() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("phone-store-\(UUID()).sqlite")
        defer { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:path.path+suffix) } }
        let store = try PhoneMatchStore(url:path,scope:"test")
        try store.transaction { $0.writer = "persisted" }
        let reopened = try PhoneMatchStore(url:path,scope:"test")
        if try reopened.read().writer != "persisted" { print("FAIL atomic transaction survives reopen"); exit(1) }
        do { try store.transaction { $0.writer = "rolled-back"; throw PhoneScoreError.invalidState } } catch {}
        if try reopened.read().writer != "persisted" { print("FAIL rollback"); exit(1) }
        let other = try PhoneMatchStore(url:path,scope:"other-account")
        if try other.read().writer != "" { print("FAIL account isolation"); exit(1) }
        print("PASS SQLite reopen, rollback, namespace isolation")
    }
}
