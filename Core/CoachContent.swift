import Foundation

/// Display payloads supplied by the business backend. These references are not access grants.
struct CoachContentBlock: Codable, Identifiable {
    let id: String
    let type: String
    var text: String? = nil
    var title: String? = nil
    var metrics: [CoachMetric]? = nil
    var video: CoachVideoReference? = nil
    var source: CoachSourceReference? = nil

    static func markdown(id: String, text: String) -> Self { Self(id: id, type: "markdown", text: text) }
}

extension CoachContentBlock {
    enum CodingKeys: String, CodingKey { case id, type, text, title, metrics, video, source }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type = (try? values.decode(String.self, forKey: .type)) ?? "unsupported"
        text = try? values.decode(String.self, forKey: .text)
        title = try? values.decode(String.self, forKey: .title)
        metrics = try? values.decode([CoachMetric].self, forKey: .metrics)
        video = try? values.decode(CoachVideoReference.self, forKey: .video)
        source = try? values.decode(CoachSourceReference.self, forKey: .source)
    }
}

struct CoachMetric: Codable {
    let label: String
    let value: String
    var unit: String? = nil
}

struct CoachSourceReference: Codable {
    let id: String
    let label: String
    var kind: String? = nil
}

struct CoachVideoReference: Codable {
    let assetID: String
    let startSeconds: Double
    let endSeconds: Double
    var isValid: Bool {
        !assetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && startSeconds.isFinite && endSeconds.isFinite &&
        startSeconds >= 0 && endSeconds > startSeconds && endSeconds <= 86400
    }
    // The asset ID is resolved via an authenticated media service in a later phase.
    // Never accept a model-generated URL as a playable resource or authorization.
}

struct CoachReply: Decodable {
    let reply: String
    var blocks: [CoachContentBlock]? = nil
    var references: [CoachReference]? = nil
}

/// Only IDs are sent back to the server; display metadata is never an authorization grant.
struct CoachReference: Codable, Identifiable, Equatable {
    let type: String
    let id: String
    var match_id: String? = nil
    var label: String? = nil
    var is_demo: Bool? = nil
    var wire: [String:String] {
        var value = ["type":type,"id":id]
        if let match_id { value["match_id"] = match_id }
        return value
    }
}
