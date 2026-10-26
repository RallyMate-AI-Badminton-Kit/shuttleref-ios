import Foundation

/// TuyaOpen switch_demo's printed device URL. Never open arbitrary QR URLs.
struct DevicePairingCode: Equatable {
    let uuid: String
    let productID: String

    static func parse(_ text: String) -> Self? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 2048, let url = URLComponents(string: value),
              url.scheme == "https", url.host == "smartapp.tuya.com", url.path == "/s/p",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { return nil }
        let items = url.queryItems ?? []
        func single(_ key: String) -> String? {
            let matches = items.filter { $0.name == key }
            return matches.count == 1 ? matches[0].value : nil
        }
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 128 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        guard single("v") == "2.0", let uuid = single("uuid"), let product = single("p"),
              identifier(uuid), identifier(product) else { return nil }
        return Self(uuid: uuid, productID: product)
    }
}
