import Foundation

func check(_ value: Bool, _ name: String) {
    if !value { print("FAIL: \(name)"); exit(1) }
}
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
@main struct WireChecks {
    static func main() throws {
        let event = Data(#"{"v":1,"type":"event","context":"11111111111111111111111111111111","seq":1,"lease":1,"action":"add","detected_ms":123}"#.utf8)
        check((try? RacketScoreWire.decode(event)) != nil, "accept documented event")
        let message = try RacketScoreWire.decode(event)
        check(try RacketScoreWire.decode(RacketScoreWire.encode(message)) == message, "canonical event roundtrip")
        for bad in [
            #"{"v":1,"v":1,"type":"stop","context":"11111111111111111111111111111111"}"#,
            #"{"v":1,"\u0076":1,"type":"stop","context":"11111111111111111111111111111111"}"#,
            #"{"v":true,"type":"stop","context":"11111111111111111111111111111111"}"#,
            #"{"v":1,"type":"stop","context":"11111111111111111111111111111111","extra":0}"#,
            #"{"v":1,"type":"ready","context":"11111111111111111111111111111111","lease":0}"#,
            #"{"v":1,"type":"ready","context":"11111111111111111111111111111111","lease":4294967296}"#,
            #"{"v":1.0,"type":"stop","context":"11111111111111111111111111111111"}"#,
            #"{"v":1,"type":"ack","context":"11111111111111111111111111111111","seq":1,"status":"committed","revision":1,"reason":"storage_uncertain"}"#,
            #"{"v":1,"type":"stop","context":"11111111111111111111111111111111",}"#
        ] { check(rejects { _ = try RacketScoreWire.decode(Data(bad.utf8)) }, "reject malformed/ambiguous JSON") }
        check(rejects { _ = try RacketScoreWire.decode(Data([0xff])) }, "illegal UTF8")
        check(rejects { _ = try RacketScoreWire.decode(Data([0xef,0xbb,0xbf]) + event) }, "BOM")
        let info = Data([1,3,0xd4,5,0x92,0x41,0x20,0x74,1,2,3,4,5,6,7,8,2,0,20,0])
        let identity = try RacketScoreWire.info(info)
        check(identity.device == "d40592412074" && identity.boot == "0102030405060708", "INFO binary endian")
        var badInfo = info; badInfo[19] = 1
        check(rejects { _ = try RacketScoreWire.info(badInfo) }, "reserved INFO")
        let state = try RacketScoreWire.state(Data([1,4,0,0,0,7,0,0,0,9,1,2,3,4,5,6,7,8,0,0]))
        check(state.phase == 4 && state.seq == 7 && state.lease == 9, "STATE endian")
        for size in [1,17,18,510,512] {
            let raw = Data(repeating: 0x61, count: size)
            let frames = try RacketScoreWire.frames(raw, transaction: 255)
            var assembly = RacketScoreAssembler(); var result: Data?
            for frame in frames { result = try assembly.append(frame, now: 0) }
            check(result == raw, "MTU23 length \(size)")
        }
        let unicode = Data(String(repeating:"羽", count:10).utf8)
        var unicodeAssembly = RacketScoreAssembler(); var unicodeResult: Data?
        for f in try RacketScoreWire.frames(unicode, transaction: 0) { unicodeResult = try unicodeAssembly.append(f, now: 0) }
        check(unicodeResult == unicode, "UTF8 split in middle of scalar")
        check(rejects { _ = try RacketScoreWire.frames(Data(repeating:1,count:513), transaction:0) }, "513 limit")
        let frames = try RacketScoreWire.frames(event, transaction: 255)
        var assembly = RacketScoreAssembler()
        _ = try assembly.append(frames[0], now:0)
        check(rejects { _ = try assembly.append(frames[2], now:1) }, "out of order resets")
        _ = try assembly.append(frames[0], now:10)
        check(rejects { _ = try assembly.append(frames[1], now:2010) }, "2 second assembly expiry")
        _ = try assembly.append(frames[0], now:3000)
        var wrapped: Data?
        for f in try RacketScoreWire.frames(event, transaction:0) { wrapped = try assembly.append(f, now:3001) }
        check(wrapped == event, "new index zero replaces and transaction wraps")
        print("PASS phone score wire and fragmentation")
    }
}
