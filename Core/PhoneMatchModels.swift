import Foundation

enum PhoneSide: String, Codable { case red = "r", blue = "b" }
/// Same 21-point, 30-cap, best-of-three rules and 256-point undo limit as score_engine.c.
struct PhoneScore: Codable, Equatable {
    private(set) var red = 0; private(set) var blue = 0
    private(set) var redGames = 0; private(set) var blueGames = 0
    private(set) var server: PhoneSide = .red
    private(set) var points: [PhoneSide] = []
    var finished: Bool { redGames == 2 || blueGames == 2 }
    mutating func add(_ side: PhoneSide) throws {
        guard !finished, points.count < 256 else { throw PhoneScoreError.invalidState }
        points.append(side); apply(side)
    }
    private mutating func apply(_ side: PhoneSide) {
        if side == .red { red += 1 } else { blue += 1 }; server = side
        let a = side == .red ? red : blue, b = side == .red ? blue : red
        if (a >= 21 && a-b >= 2) || a == 30 {
            if side == .red { redGames += 1 } else { blueGames += 1 }
            if !finished { red = 0; blue = 0 }
        }
    }
    mutating func undo() throws {
        guard !points.isEmpty else { throw PhoneScoreError.invalidState }
        let kept = Array(points.dropLast()); self = PhoneScore()
        points = kept; for side in kept { apply(side) }
    }
}
struct PhoneParticipant: Codable, Equatable { let id: String; let name: String; let side: PhoneSide }
enum PhoneMatchPhase: String, Codable { case active, paused, ended }
enum PhoneAction: String, Codable { case start, red, blue, undo, pause, resume, end }
struct PhoneScoreACK: Codable, Equatable {
    let context: String; let seq: UInt32; let status: String; let revision: UInt32; let reason: String
    func wire() throws -> RacketScoreMessage {
        try RacketScoreWire.message("ack",text:["context":context,"status":status,"reason":reason],numbers:["seq":seq,"revision":revision])
    }
}
struct PhoneJournalEntry: Codable, Equatable {
    let id: String; let payload: Data; let action: PhoneAction?
    let ack: PhoneScoreACK?; let revision: UInt32
}
struct PhoneScoreContext: Codable, Equatable {
    let id: String; let matchID: String; let device: String; let boot: String
    var controlOwner: String? = nil
    let owner: String; let associationRevision: UInt32; let side: PhoneSide
    var lease: UInt32 = 1; var highestSeq: UInt32 = 0; var retired = false
    func configure() throws -> RacketScoreMessage {
        try RacketScoreWire.message("configure",text:["context":id,"match_id":matchID,"device":device,"boot":boot,"owner":RacketScoreWire.identityUUID(controlOwner ?? owner) ?? "","side":side.rawValue],numbers:["association_revision":associationRevision])
    }
}
struct PhoneLocalMatch: Codable, Equatable {
    let id: String; let participants: [PhoneParticipant]; let doubles: Bool
    var phase: PhoneMatchPhase = .active; var score = PhoneScore(); var revision: UInt32 = 1
    var journal: [PhoneJournalEntry] = []; var contexts: [PhoneScoreContext] = []
}
struct PhoneSyncEnvelope: Codable, Equatable {
    let schema_version: Int; let match_id: String; let authority: String; let installation_id: String
    let rules_version: String; let participants: [PhoneParticipant]; let doubles: Bool
    let revision: UInt32; let journal: [PhoneJournalEntry]; let final_snapshot: PhoneScore; let phase: PhoneMatchPhase
    init(match: PhoneLocalMatch, installation: String) {
        schema_version = 1; match_id = match.id; authority = "phone"; installation_id = installation
        rules_version = "badminton-21-cap30-best3-v1"; participants = match.participants; doubles = match.doubles
        revision = match.revision; journal = match.journal; final_snapshot = match.score; phase = match.phase
    }
}
struct PhoneSyncItem: Codable, Equatable {
    let id: String; let envelope: PhoneSyncEnvelope
    var state = "pending" // pending/synced/conflict; network failure keeps the same ID and bytes.
}
struct PhoneMatchDatabase: Codable {
    var schema = 1; var writer = ""; var matches: [PhoneLocalMatch] = []; var outbox: [PhoneSyncItem] = []
}
struct PhoneMatchScope: Codable, Equatable {
    let origin: String; let account: String; let installation: String
    var key: String {
        // Length-prefixed, not delimiter-concatenated: accounts/origins cannot alias.
        [origin,account,installation].map { "\($0.utf8.count):\($0)" }.joined()
    }
}
