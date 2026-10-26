import Foundation
import CryptoKit
import Security

// Account + origin scoped; never use the Tuya account ID to authorize business requests.
enum GatheringPersistence {
    static func partition(_ origin: String, _ user: String = "") -> String {
        SHA256.hash(data: Data((origin + "|" + user).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func loadSecret(_ origin: String) -> GatheringCredentials? { loadValue(origin) }
    static func loadValue<T: Decodable>(_ origin: String) -> T? {
        var query = keyQuery(origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func saveSecret(_ value: GatheringCredentials?, origin: String) throws {
        try saveValue(value, origin: origin)
    }
    static func saveValue<T: Encodable>(_ value: T?, origin: String) throws {
        let query = keyQuery(origin)
        guard let value = value else { SecItemDelete(query as CFDictionary); return }
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SocialClientError("无法安全保存身份，请重试") }
        } else if status != errSecSuccess { throw SocialClientError("无法更新安全身份存储") }
    }
    private static func keyQuery(_ origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.yahabib.shuttleref.social", kSecAttrAccount as String: partition(origin)]
    }
    static func file(_ origin: String, _ user: String) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Gatherings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(partition(origin, user) + ".json")
    }
}
struct GatheringJournal: Codable { var context: GatheringContext?; var events: [GatheringEvent] = []; var archived = false; var mvpUserID: String? = nil; var earlyEnded: Bool? = nil }
struct SocialClientError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

protocol GatheringStorage {
    func load(_ origin: String) -> GatheringCredentials?
    func save(_ value: GatheringCredentials?, origin: String) throws
    func journalFile(_ origin: String, user: String) throws -> URL
    func loadAccounts(_ origin: String) -> [GatheringCredentials]
    func saveAccounts(_ values: [GatheringCredentials], origin: String) throws
}
extension GatheringStorage {
    func loadAccounts(_ origin: String) -> [GatheringCredentials] { load(origin).map { [$0] } ?? [] }
    func saveAccounts(_ values: [GatheringCredentials], origin: String) throws {}
}
struct SystemGatheringStorage: GatheringStorage {
    func loadAccounts(_ origin: String) -> [GatheringCredentials] { GatheringPersistence.loadValue(origin + "#accounts") ?? [] }
    func saveAccounts(_ values: [GatheringCredentials], origin: String) throws { try GatheringPersistence.saveValue(values, origin: origin + "#accounts") }
    func load(_ origin: String) -> GatheringCredentials? { GatheringPersistence.loadSecret(origin) }
    func save(_ value: GatheringCredentials?, origin: String) throws { try GatheringPersistence.saveSecret(value, origin: origin) }
    func journalFile(_ origin: String, user: String) throws -> URL { try GatheringPersistence.file(origin, user) }
}
