import Foundation
func check(_ ok: Bool, _ label: String) { if !ok { print("FAIL: \(label)"); exit(1) } }
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
@main struct PhoneCoreTests {
    static func main() throws {
        var score = PhoneScore()
        try score.add(.red)
        check(score.red == 1 && score.server == .red, "point updates score")
        try score.undo(); check(score.red == 0, "undo")
        for _ in 0..<20 { try score.add(.red); try score.add(.blue) }
        try score.add(.red); check(score.red == 21 && score.redGames == 0, "deuce requires two point lead")
        try score.add(.red); check(score.red == 0 && score.redGames == 1, "22:20 game rollover")
        try score.undo(); check(score.red == 21 && score.blue == 20 && score.redGames == 0, "undo across game boundary")
        for _ in 21..<29 { try score.add(.blue); try score.add(.red) }
        try score.add(.blue); check(score.red == 29 && score.blue == 29, "29 all")
        try score.add(.blue); check(score.blueGames == 1 && score.red == 0, "30 cap")
        for _ in 0..<21 { try score.add(.blue) }
        check(score.finished && score.blueGames == 2 && score.blue == 21, "match end retains points")
        check(rejects { try score.add(.red) }, "finished rejects add")
        try score.undo(); check(!score.finished && score.blue == 20 && score.blueGames == 1, "undo match point")
        let encoded = try JSONEncoder().encode(score)
        let restored = try JSONDecoder().decode(PhoneScore.self,from:encoded)
        check(restored == score, "score and undo stack restore")
        if CommandLine.arguments.count > 1 {
            // Compare each state to the existing C core, including undo after game/match end.
            let process = Process(); process.executableURL = URL(fileURLWithPath:CommandLine.arguments[1])
            let output = Pipe(); process.standardOutput = output; try process.run()
            let text = String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
            process.waitUntilExit(); check(process.terminationStatus == 0,"C oracle exit")
            var oracle = PhoneScore()
            for line in text.split(separator:"\n") {
                let v = line.split(separator:",").map(String.init)
                switch v[0] { case "r": try oracle.add(.red); case "b": try oracle.add(.blue); default: try oracle.undo() }
                check([oracle.red,oracle.blue,oracle.redGames,oracle.blueGames,oracle.server == .red ? 0:1,oracle.finished ? 1:0] == v.dropFirst().map { Int($0)! },"C parity \(line)")
            }
        }
        print("PASS phone match scoring, persistence encoding and C parity")
    }
}
