import Foundation
struct Vectors: Codable {
    let protocolName: String; let info_hex: String; let state_ready_hex: String; let messages: [Vector]
    enum CodingKeys: String,CodingKey { case protocolName = "protocol", info_hex, state_ready_hex, messages }
}
struct Vector: Codable { let type: String; let transaction: UInt8; let json: String; let utf8_hex: String; let frames_hex: [String] }
func data(_ hex: String) -> Data { var bytes: [UInt8] = []; var i = hex.startIndex; while i < hex.endIndex { let end = hex.index(i,offsetBy:2); bytes.append(UInt8(hex[i..<end],radix:16)!); i = end }; return Data(bytes) }
func hex(_ data: Data) -> String { data.map { String(format:"%02x",$0) }.joined() }
@main struct VectorChecks {
    static func main() throws {
        let original = try JSONDecoder().decode(Vectors.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let info = try RacketScoreWire.info(data(original.info_hex)); precondition(info.device == "d40592412074")
        let state = try RacketScoreWire.state(data(original.state_ready_hex)); precondition(state.lease == 1)
        var produced: [Vector] = []
        for v in original.messages {
            let raw = Data(v.json.utf8)
            precondition(hex(raw) == v.utf8_hex)
            let decoded = try RacketScoreWire.decode(raw)
            precondition(decoded.type == v.type)
            let frames = try RacketScoreWire.frames(raw,transaction:v.transaction)
            precondition(frames.map(hex) == v.frames_hex)
            var assembly = RacketScoreAssembler(); var complete: Data?
            for frame in v.frames_hex { complete = try assembly.append(data(frame),now:0) }
            precondition(complete == raw)
            let encoded = try RacketScoreWire.encode(decoded)
            let result = try RacketScoreWire.decode(encoded); precondition(result == decoded)
            produced.append(Vector(type:v.type,transaction:v.transaction,json:String(decoding:encoded,as:UTF8.self),utf8_hex:hex(encoded),frames_hex:try RacketScoreWire.frames(encoded,transaction:v.transaction).map(hex)))
        }
        if CommandLine.arguments.count > 2 {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            try encoder.encode(Vectors(protocolName:original.protocolName,info_hex:original.info_hex,state_ready_hex:original.state_ready_hex,messages:produced)).write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
        }
        print("PASS shared firmware vectors: \(original.messages.count) messages, INFO, STATE, UTF8 and every fragment")
    }
}
