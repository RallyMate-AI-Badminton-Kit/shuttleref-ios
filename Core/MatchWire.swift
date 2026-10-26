import Foundation

struct MatchSnapshot: Codable {
    let id: String
    let token: UInt32
    let state: String
    let scores: [UInt8]
    let code: Int
    var hasID: Bool { id != String(repeating: "0", count: 32) }
    var finished: Bool { scores[2] >= 2 || scores[3] >= 2 }
    init?(_ raw: String) {
        let p = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 6, p[0] == "@1", p[1].count == 32,
              p[1].allSatisfy({ $0.isHexDigit }), p[2].count == 8,
              let token = UInt32(p[2], radix: 16), ["i","a","p"].contains(p[3]),
              let code = Int(p[5]), (0...4).contains(code) else { return nil }
        let parts = p[4].split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { UInt8($0) }
        guard parts.count == 5, values.count == 5, values[0] <= 30, values[1] <= 30,
              values[2] <= 2, values[3] <= 2, values[4] <= 1 else { return nil }
        self.id = p[1].lowercased(); self.token = token; self.state = p[3]
        self.scores = values; self.code = code
    }
}

enum MatchWire {
    static func encode(_ op: String, id: String, sequence: UInt32, scores: [UInt8]) -> String? {
        guard op.utf8.count == 1, ["B","P","R","A","Q","U","r","b"].contains(op),
              id.count == 32, scores.count == 5 else { return nil }
        var bytes = [op.utf8.first!]
        for offset in stride(from: 0, to: 32, by: 2) {
            let start = id.index(id.startIndex, offsetBy: offset)
            guard let byte = UInt8(id[start..<id.index(start, offsetBy: 2)], radix: 16) else { return nil }
            bytes.append(byte)
        }
        bytes += [UInt8(truncatingIfNeeded: sequence >> 24), UInt8(truncatingIfNeeded: sequence >> 16), UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
        if op == "R" {
            guard scores[0] <= 29, scores[1] <= 29, scores[2] <= 1, scores[3] <= 1, scores[4] <= 1 else { return nil }
            bytes += [scores[0], scores[1], scores[2] | (scores[3] << 1) | (scores[4] << 2)]
        } else { bytes += [0,0,0] }
        return Data(bytes).base64EncodedString()
    }
}

// Shared home presentation and navigation policy. An idle snapshot may retain the old ID.
enum CourtHomeState {
    case ready, resume, ended
    init(snapshot: MatchSnapshot?, saved: MatchSnapshot?, settled: Bool) {
        let active = snapshot.map { ["a", "p"].contains($0.state) && $0.hasID } ?? false
        self = active && settled ? .ended : active || saved != nil ? .resume : .ready
    }
    var buttonTitle: String {
        switch self { case .ready: return "准备开赛"; case .resume: return "回到当前球局"; case .ended: return "查看已结束球局" }
    }
}
enum CourtRoster {
    static func defaultName(account: String?, deviceAccount: String) -> String {
        for name in [account ?? "", deviceAccount] {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return String(clean.prefix(12)) }
        }
        return "我方球员"
    }
}
