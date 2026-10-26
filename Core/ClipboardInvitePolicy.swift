import Foundation
import CryptoKit

/// Persists fingerprints only, never clipboard contents or invitation secrets.
struct ClipboardInvitePolicy {
    private(set) var seen: [String]
    init(seen: [String] = []) { self.seen = seen }
    func candidate(_ text: String) -> String? {
        guard let code = try? InvitationText.code(from: text), !seen.contains(Self.fingerprint(code)) else { return nil }
        return code
    }
    mutating func markPresented(_ code: String) {
        let fingerprint = Self.fingerprint(code)
        seen.removeAll { $0 == fingerprint }; seen.append(fingerprint)
        seen = Array(seen.suffix(100))
    }
    private static func fingerprint(_ code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
