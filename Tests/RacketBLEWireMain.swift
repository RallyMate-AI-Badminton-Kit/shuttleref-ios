import Foundation
@main struct BLEWireChecks {
    static func main() throws {
        let path = "docs/contracts/racket-ble-v1/vector.json"
        let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        func bytes(_ text: String) -> Data {
            let values = Array(text); return Data(stride(from: 0, to: values.count, by: 2).map { UInt8(String(values[$0...($0+1)]), radix: 16)! })
        }
        let command = bytes(vector["request_hex"] as! String)
        let frames = try RacketBLEWire.fragments(command, transaction: 1)
        precondition(frames == (vector["request_frames_hex"] as! [String]).map(bytes))
        var assembler = RacketBLEWire.Assembler(transaction: 1)
        var result: Data?
        for frame in (vector["response_frames_hex"] as! [String]).map(bytes) { result = try assembler.append(frame) }
        precondition(result == bytes(vector["response_hex"] as! String))
        var bad = RacketBLEWire.Assembler(transaction: 2)
        do { _ = try bad.append(frames[0]); fatalError("wrong transaction accepted") } catch {}
        var info = Data([1]); info.append(bytes("d40592412074")); info.append(Data(repeating: 9, count: 16)); info.append(contentsOf: [0,0,0,1,1])
        let decoded = try RacketBLEWire.parseInfo(info)
        precondition(decoded.deviceID == "d40592412074" && decoded.revision == 1 && decoded.bound)
        let draft = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "docs/handoff/2026-10-27-racket-ble-v2-proposal-vectors.json"))) as! [String: Any]
        for action in ["bind", "unbind"] {
            let vector = draft[action] as! [String: String]
            let request = bytes(vector["request_hex"]!), response = bytes(vector["response_hex"]!)
            let pieces = try RacketBLEWireV2.fragments(request, transaction: 7)
            precondition(pieces.count == 9 && pieces.last!.count == 7)
            var v2 = RacketBLEWireV2.Assembler(transaction: 7)
            let responsePieces = stride(from: 0, to: response.count, by: 17).enumerated().map { index, start in
                Data([7, UInt8(index), 10]) + response.subdata(in: start..<min(start + 17, response.count))
            }
            var reassembled: Data?
            for piece in responsePieces { reassembled = try v2.append(piece) }
            precondition(reassembled == response)
            var wrong = RacketBLEWireV2.Assembler(transaction: 8)
            do { _ = try wrong.append(responsePieces[0]); fatalError("v2 wrong transaction accepted") } catch {}
        }
        var info2 = Data([2]); info2.append(bytes("d40592412074")); info2.append(Data(repeating: 9, count: 16)); info2.append(contentsOf: [0,0,0,2,0,0,0,0,15,0,0])
        let decoded2 = try RacketBLEWireV2.parseInfo(info2)
        precondition(decoded2.deviceID == "d40592412074" && decoded2.revision == 2 && !decoded2.bound && decoded2.capabilities == 15)
        info2[28] = 1
        do { _ = try RacketBLEWireV2.parseInfo(info2); fatalError("reserved capabilities accepted") } catch {}
        print("PASS: BLE v2 draft info, framing, public vectors and reserved capability rejection")
        print("PASS: BLE published cross-language frames, response assembly, transaction rejection and INFO decoding")
    }
}
