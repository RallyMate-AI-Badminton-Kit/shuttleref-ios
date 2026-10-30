import Foundation

struct SharedParticipant: Codable, Equatable, Identifiable {
    let id: String; let kind: String; let name: String; let side: String; let scope: String
}
struct SharedMatch: Codable, Equatable, Identifiable {
    let match_id: String; let authority_type: String; let authority_id: String
    let origin: String; let rules_version: String; let participants: [SharedParticipant]
    let doubles: Bool; let revision: String; let snapshot: PhoneScore
    let lifecycle: String; let received_at: Int64; let role: String; let can_score: Bool
    let archived: Bool; let sync_state: String; let tuya_device_id: String?
    var id: String { match_id }
    var names: [String] {
        let r=participants.filter { $0.side == "r" }.map(\.name)
        let b=participants.filter { $0.side == "b" }.map(\.name)
        return [r.first ?? "名单同步中",r.dropFirst().first ?? "",b.first ?? "名单同步中",b.dropFirst().first ?? ""]
    }
}
struct SharedMatchList: Decodable { let matches: [SharedMatch] }
enum MatchReplicaError: Error { case conflict, malformed }
struct MatchReplica {
    private(set) var match: SharedMatch?
    private var generation=UUID()
    mutating func reset(scope: String) -> UUID { generation=UUID();match=nil;return generation }
    mutating func accept(_ next: SharedMatch, epoch: UUID) throws -> Bool {
        guard epoch == generation else { return false }
        guard let revision=UInt64(next.revision), revision>0 else { throw MatchReplicaError.malformed }
        if let old=match {
            guard old.id == next.id, old.authority_type == next.authority_type, old.authority_id == next.authority_id else { throw MatchReplicaError.conflict }
            guard revision >= (UInt64(old.revision) ?? 0) else { return false }
            if revision == UInt64(old.revision) {
                guard old.snapshot == next.snapshot, old.lifecycle == next.lifecycle, old.participants == next.participants else { throw MatchReplicaError.conflict }
            }
        }
        match=next;return true
    }
}
struct MatchEventParser {
    struct Event { let event: String; let data: Data }
    private var event="message"; private var chunks=[String](); private var size=0
    mutating func line(_ line: String) throws -> Event? {
        if line.isEmpty {
            defer { event="message";chunks=[];size=0 }
            guard !chunks.isEmpty else { return nil }
            return Event(event:event,data:Data(chunks.joined(separator:"\n").utf8))
        }
        size+=line.utf8.count;guard size<=131072 else { throw MatchReplicaError.malformed }
        if line.hasPrefix("event: ") { event=String(line.dropFirst(7)) }
        if line.hasPrefix("data: ") { chunks.append(String(line.dropFirst(6))) }
        return nil
    }
}
