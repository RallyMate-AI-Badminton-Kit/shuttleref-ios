import Foundation

@main struct RecordsAnalyticsChecks {
    static func main() throws {
        let calendar = RecordPeriod.calendar
        let boundary = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        precondition(!RecordPeriod.month.contains(boundary, anchor: boundary.addingTimeInterval(-1)))
        precondition(RecordPeriod.month.contains(boundary, anchor: boundary))
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        precondition(RecordPeriod.week.contains(monday, anchor: monday.addingTimeInterval(6*86400)))
        precondition(!RecordPeriod.week.contains(monday.addingTimeInterval(7*86400), anchor: monday))
        let mid = String(repeating: "a", count: 32)
        let snapshot = MatchSnapshot("@1:\(mid):00000001:a:21,10,2,0,0:0")!
        let result = LocalMatchResult(id: mid, snapshot: snapshot, names: ["同名", "unused", "同名", "unused"], doubles: false, mvpSlot: 2, date: Date())
        let row = RecordEntry(personal: PersonalRecord(deviceID: "board", result: result), source: "test")
        precondition(row.red == ["同名"] && row.blue == ["同名"] && row.observations.isEmpty)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(LocalMatchResult.self, from: data)
        precondition(decoded.observations == nil)
        precondition(GatheringFormat.family_doubles.fixedTeams && GatheringFormat.four_rotation.requiredCount == 4)
        let suite = "records-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = MatchSession(accountID: "u", deviceID: "d", online: true, cache: nil, defaults: defaults) { _, done in done(nil) }
        session.send("Q"); session.receive("@1:" + String(repeating: "0", count: 32) + ":00000001:i:0,0,0,0,0:0")
        session.send("B", matchID: mid); session.receive("@1:\(mid):00000002:a:0,0,0,0,0:0")
        session.send("r"); session.receive("@1:\(mid):00000003:a:1,0,0,0,0:0")
        session.receive("@1:\(mid):00000004:a:1,0,0,0,0:0")
        session.send("P"); session.receive("@1:\(mid):00000005:p:1,0,0,0,0:0")
        session.disconnect()
        let relaunched = MatchSession(accountID: "u", deviceID: "d", online: true, cache: nil, defaults: defaults) { _, done in done(nil) }
        relaunched.send("Q"); relaunched.receive("@1:\(mid):00000006:p:1,0,0,0,0:0")
        try relaunched.settle(names: result.names, doubles: false, mvpSlot: nil, early: true)
        precondition(relaunched.completedResults.first?.observations?.count == 3, "Observed scores persist across relaunch; repeated snapshots are not new scoring events")
        print("PASS: week/month boundaries, old result decoding, singles lineup and format constraints")
    }
}
