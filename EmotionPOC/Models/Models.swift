import Foundation

struct DummyDataset: Codable {
    let family: Family
    let parent: ParentMember
    let child: ChildMember
    let emotionLogs: [EmotionLog]
    let parentContext: ParentContext

    enum CodingKeys: String, CodingKey {
        case family
        case parent
        case child
        case emotionLogs = "emotion_logs"
        case parentContext = "parent_context"
    }
}

struct Family: Codable {
    let id: String
    let name: String
    let timezone: String
}

struct ParentMember: Codable {
    let id: String
    let role: String
    let name: String
    let age: Int
    let email: String
}

struct ChildMember: Codable {
    let id: String
    let role: String
    let name: String
    let age: Int
    let relationship: String
    let healthkitEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, role, name, age, relationship
        case healthkitEnabled = "healthkit_enabled"
    }
}

struct EmotionLog: Codable {
    let id: String
    let childId: String
    let timestamp: String
    let source: String
    let healthkit: HealthKitState
    let journal: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, healthkit, journal
        case childId = "child_id"
    }
}

struct HealthKitState: Codable {
    let kind: String
    let valence: Double
    let labels: [String]
    let associations: [String]
}

struct ParentContext: Codable {
    let parentId: String
    let recentInteractions: [RecentInteraction]
    let parentLogs: [ParentLog]

    enum CodingKeys: String, CodingKey {
        case parentId = "parent_id"
        case recentInteractions = "recent_interactions"
        case parentLogs = "parent_logs"
    }
}

struct RecentInteraction: Codable {
    let timestamp: String
    let topic: String
    let interaction: String
    let parentEmotion: String

    enum CodingKeys: String, CodingKey {
        case timestamp, topic, interaction
        case parentEmotion = "parent_emotion"
    }
}

struct ParentLog: Codable {
    let timestamp: String
    let emotion: String
    let note: String
}

enum DummyData {
    static func load() throws -> DummyDataset {
        let decoder = JSONDecoder()
        return try decoder.decode(DummyDataset.self, from: Data(EmbeddedDataset.json.utf8))
    }
}