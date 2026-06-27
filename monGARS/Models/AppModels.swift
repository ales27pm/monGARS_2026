import Foundation
import SwiftData

enum MessageRole: String, Codable, CaseIterable {
    case user
    case assistant
    case system
    case tool
}

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation) var messages: [ChatMessage]

    init(id: UUID = UUID(), title: String = "New Chat", createdAt: Date = .now, updatedAt: Date = .now, messages: [ChatMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var roleRawValue: String
    var content: String
    var createdAt: Date
    var conversation: Conversation?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    init(id: UUID = UUID(), role: MessageRole, content: String, createdAt: Date = .now) {
        self.id = id
        self.roleRawValue = role.rawValue
        self.content = content
        self.createdAt = createdAt
    }
}

@Model
final class MemoryRecord {
    var id: UUID
    var content: String
    var tags: [String]
    var createdAt: Date

    init(id: UUID = UUID(), content: String, tags: [String] = [], createdAt: Date = .now) {
        self.id = id
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }
}

@Model
final class DocumentRecord {
    var id: UUID
    var title: String
    var content: String
    var importedAt: Date

    init(id: UUID = UUID(), title: String, content: String, importedAt: Date = .now) {
        self.id = id
        self.title = title
        self.content = content
        self.importedAt = importedAt
    }
}

@Model
final class AgentCheckpointRecord {
    var id: UUID
    var runID: UUID
    var nodeID: String
    var stateSummary: String
    var createdAt: Date

    init(id: UUID = UUID(), runID: UUID, nodeID: String, stateSummary: String, createdAt: Date = .now) {
        self.id = id
        self.runID = runID
        self.nodeID = nodeID
        self.stateSummary = stateSummary
        self.createdAt = createdAt
    }
}

