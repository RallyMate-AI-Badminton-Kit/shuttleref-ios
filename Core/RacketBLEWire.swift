import Foundation

enum RacketBLEWire {
    static let service = "7a6e1000-6c7d-4c8a-9b12-01d40a521001"
    static let info = "7a6e1001-6c7d-4c8a-9b12-01d40a521001"
    static let rx = "7a6e1002-6c7d-4c8a-9b12-01d40a521001"
    static let tx = "7a6e1003-6c7d-4c8a-9b12-01d40a521001"
    struct Info {
        let deviceID: String
        let session: String
        let revision: Int
        let bound: Bool
    }
    static func parseInfo(_ data: Data) throws -> Info {
        let b = [UInt8](data)
        guard b.count == 28, b[0] == 1, b[27] <= 1 else { throw RacketDiagnostic(stage: "读取 INFO", detail: "设备信息格式不符，收到 \(b.count) 字节，预期 28 字节。") }
        func hex(_ range: Range<Int>) -> String { b[range].map { String(format: "%02x", $0) }.joined() }
        let version = b[23..<27].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Info(deviceID: hex(1..<7), session: hex(7..<23), revision: Int(version), bound: b[27] == 1)
    }
    static func fragments(_ data: Data, transaction: UInt8) throws -> [Data] {
        guard data.count == 124 else { throw RacketFailure.verificationFailed }
        let b = [UInt8](data), count = (data.count + 16) / 17
        return (0..<count).map { i in Data([transaction, UInt8(i), UInt8(count)] + Array(b[(i * 17)..<min((i + 1) * 17, b.count)])) }
    }
    struct Assembler {
        let transaction: UInt8
        private(set) var data = Data()
        private var index = 0
        mutating func append(_ frame: Data) throws -> Data? {
            if frame == Data([0]) { return nil }
            let b = [UInt8](frame)
            guard (4...20).contains(b.count), b[0] == transaction, b[1] == index, b[2] == 9,
                  (index == 8 ? b.count == 9 : b.count == 20) else { throw RacketFailure.verificationFailed }
            data.append(contentsOf: b.dropFirst(3)); index += 1
            if index == 9 { guard data.count == 142 else { throw RacketFailure.verificationFailed }; return data }
            return nil
        }
    }
}

/// Draft protocol framing only; never selects v2 or enables device writes.
enum RacketBLEWireV2 {
    static let service = "7a6e2000-6c7d-4c8a-9b12-01d40a521001"
    static let info = "7a6e2001-6c7d-4c8a-9b12-01d40a521001"
    static let rx = "7a6e2002-6c7d-4c8a-9b12-01d40a521001"
    static let tx = "7a6e2003-6c7d-4c8a-9b12-01d40a521001"
    struct Info {
        let deviceID: String
        let session: String
        let revision: Int
        let bound: Bool
        let capabilities: UInt16
        let storageStatus: UInt8
    }
    static func parseInfo(_ data: Data) throws -> Info {
        let b = [UInt8](data)
        guard b.count == 34, b[0] == 2, b[27] <= 1, b[28] == 0, b[29] == 0, b[30] == 0,
              b[31] & 0xf0 == 0, b[33] == 0 else { throw RacketFailure.verificationFailed }
        func hex(_ range: Range<Int>) -> String { b[range].map { String(format: "%02x", $0) }.joined() }
        let revision = b[23..<27].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Info(deviceID: hex(1..<7), session: hex(7..<23), revision: Int(revision), bound: b[27] == 1,
                    capabilities: UInt16(b[31]), storageStatus: b[32])
    }
    static func fragments(_ data: Data, transaction: UInt8) throws -> [Data] {
        guard data.count == 140 else { throw RacketFailure.verificationFailed }
        let bytes = [UInt8](data)
        return (0..<9).map { index in
            Data([transaction, UInt8(index), 9] + Array(bytes[(index * 17)..<min((index + 1) * 17, bytes.count)]))
        }
    }
    struct Assembler {
        let transaction: UInt8
        private(set) var data = Data()
        private var index = 0
        mutating func append(_ frame: Data) throws -> Data? {
            if frame == Data([0]) { return nil }
            let b = [UInt8](frame)
            guard index < 10, b.count == (index == 9 ? 14 : 20), b[0] == transaction,
                  b[1] == index, b[2] == 10 else { throw RacketFailure.verificationFailed }
            data.append(contentsOf: b.dropFirst(3)); index += 1
            if index == 10 { guard data.count == 164 else { throw RacketFailure.verificationFailed }; return data }
            return nil
        }
    }
}
