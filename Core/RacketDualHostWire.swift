import Foundation

enum RacketDualHostWire {
    static func pendingKey(origin:String,account:String,device:String) -> String {
        "racket.mode."+[origin,account,device].map { "\($0.utf8.count):\($0)" }.joined()
    }
    static let service="7a6e5000-6c7d-4c8a-9b12-01d40a521001"
    static let rx="7a6e5001-6c7d-4c8a-9b12-01d40a521001"
    static let tx="7a6e5002-6c7d-4c8a-9b12-01d40a521001"
    static func frames(_ command:Data,transaction:UInt8) throws -> [Data] {
        guard command.count==277,command[0]==1,command[1]<=1 else { throw PhoneScoreError.invalidWire }
        return try RacketScoreWire.frames(command,transaction:transaction)
    }
    static func response(_ data:Data,command:Data) throws {
        guard data.count==98,command.count==277,data[0]==1,data[1]<=5,data[2]<=1,data[3]<=2,
              data.subdata(in:8..<24)==command.subdata(in:8..<24),
              data.subdata(in:24..<40)==command.subdata(in:229..<245),
              data.subdata(in:40..<46)==command.subdata(in:2..<8) else { throw PhoneScoreError.invalidWire }
        // Backend verifies signature and mutation nonce/generation; UI never infers success.
    }
}
