import Foundation

enum RacketArchiveWire {
 static func isTerminal(_ status:String?) -> Bool { status.map { ["confirmed","superseded","rejected"].contains($0) } ?? false }
 static let service="7a6e4000-6c7d-4c8a-9b12-01d40a521001"
 static let rx="7a6e4001-6c7d-4c8a-9b12-01d40a521001"
 static let tx="7a6e4002-6c7d-4c8a-9b12-01d40a521001"
 static func frames(_ command:Data,transaction:UInt8) throws -> [Data] {
  guard command.count==196,command.first==1,(1...3).contains(command[1]) else { throw PhoneScoreError.invalidWire }
  return try RacketScoreWire.frames(command,transaction:transaction)
 }
 static func response(_ data:Data,command:Data) throws {
  guard data.count==281,command.count==196,data[0]==1,data[1]==command[1],data[2]<=9,
        data.subdata(in:3..<25)==command.subdata(in:2..<24),data.subdata(in:25..<89)==command.subdata(in:24..<88) else { throw PhoneScoreError.invalidWire }
  // Signature and checkpoint decisions are exclusively made by the business server.
 }
}
