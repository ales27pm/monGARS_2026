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
    var agentRunID: UUID?
    var statusText: String?
    var conversation: Conversation?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    init(id: UUID = UUID(), role: MessageRole, content: String, createdAt: Date = .now, agentRunID: UUID? = nil, statusText: String? = nil) {
        self.id = id
        self.roleRawValue = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.agentRunID = agentRunID
        self.statusText = statusText
    }
}

@Model
final class MemoryRecord {
    var id: UUID
    var content: String
    var tags: [String]
    var importance: Double
    var source: String
    var scope: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        content: String,
        tags: [String] = [],
        importance: Double = 0.5,
        source: String = "user",
        scope: String = "longTerm",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.content = content
        self.tags = tags
        self.importance = importance
        self.source = source
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
final class DocumentChunkRecord {
    var id: UUID
    var documentID: UUID
    var title: String
    var text: String
    var chunkIndex: Int
    var tokenEstimate: Int
    var lexicalTerms: [String]
    var embeddingData: Data?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        documentID: UUID,
        title: String,
        text: String,
        chunkIndex: Int,
        tokenEstimate: Int,
        lexicalTerms: [String],
        embeddingData: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.text = text
        self.chunkIndex = chunkIndex
        self.tokenEstimate = tokenEstimate
        self.lexicalTerms = lexicalTerms
        self.embeddingData = embeddingData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class AgentCheckpointRecord {
    var id: UUID
    var runID: UUID
    var nodeID: String
    var stateSummary: String
    var stateData: Data?
    var createdAt: Date

    init(id: UUID = UUID(), runID: UUID, nodeID: String, stateSummary: String, stateData: Data? = nil, createdAt: Date = .now) {
        self.id = id
        self.runID = runID
        self.nodeID = nodeID
        self.stateSummary = stateSummary
        self.stateData = stateData
        self.createdAt = createdAt
    }
}

@Model
final class AgentRunRecord {
    var id: UUID
    var conversationID: UUID?
    var goal: String
    var statusRawValue: String
    var autonomyLevelRawValue: String
    var currentPhase: String
    var currentStep: Int
    var maxSteps: Int
    var summary: String
    var lastError: String?
    var requiresApproval: Bool
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        conversationID: UUID? = nil,
        goal: String,
        statusRawValue: String = "running",
        autonomyLevelRawValue: String = "assisted",
        currentPhase: String = "understandIntent",
        currentStep: Int = 0,
        maxSteps: Int = 12,
        summary: String = "",
        lastError: String? = nil,
        requiresApproval: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.goal = goal
        self.statusRawValue = statusRawValue
        self.autonomyLevelRawValue = autonomyLevelRawValue
        self.currentPhase = currentPhase
        self.currentStep = currentStep
        self.maxSteps = maxSteps
        self.summary = summary
        self.lastError = lastError
        self.requiresApproval = requiresApproval
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

@Model
final class AgentTraceRecord {
    var id: UUID
    var runID: UUID
    var stepIndex: Int
    var phase: String
    var message: String
    var toolName: String?
    var latencyMs: Double
    var createdAt: Date

    init(id: UUID = UUID(), runID: UUID, stepIndex: Int, phase: String, message: String, toolName: String? = nil, latencyMs: Double = 0, createdAt: Date = .now) {
        self.id = id
        self.runID = runID
        self.stepIndex = stepIndex
        self.phase = phase
        self.message = message
        self.toolName = toolName
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }
}

@Model
final class ToolCallRecord {
    var id: UUID
    var runID: UUID
    var sessionID: UUID = UUID()
    var toolName: String
    var input: String
    var output: String
    var riskLevel: String
    var requiresApproval: Bool
    var approved: Bool
    var target: String?
    var payloadHash: String = ""
    var statusCode: Int?
    var latencyMs: Double
    var errorCategory: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        runID: UUID,
        sessionID: UUID? = nil,
        toolName: String,
        input: String,
        output: String,
        riskLevel: String,
        requiresApproval: Bool,
        approved: Bool,
        target: String? = nil,
        payloadHash: String = "",
        statusCode: Int? = nil,
        latencyMs: Double = 0,
        errorCategory: String? = nil,
        createdAt: Date = .now
    ) {
        let resolvedSessionID = sessionID ?? runID
        let normalizedRisk = ApprovalPolicy.normalizedRisk(riskLevel)
        self.id = id
        self.runID = runID
        self.sessionID = resolvedSessionID
        self.toolName = toolName
        self.input = input
        self.output = output
        self.riskLevel = normalizedRisk.rawValue
        self.requiresApproval = requiresApproval
        self.approved = approved
        self.target = target
        self.payloadHash = payloadHash.isEmpty
            ? ApprovalTupleHasher.payloadHash(
                toolName: toolName,
                target: target,
                normalizedArgumentsJSON: ApprovalTupleHasher.normalizedArguments(toolName: toolName, input: input, target: target),
                riskLevel: normalizedRisk.rawValue,
                sessionID: resolvedSessionID
            )
            : payloadHash
        self.statusCode = statusCode
        self.latencyMs = latencyMs
        self.errorCategory = errorCategory
        self.createdAt = createdAt
    }
}

@Model
final class ApprovalRequestRecord {
    var id: UUID
    var runID: UUID
    var sessionID: UUID = UUID()
    var actionName: String
    var toolName: String = ""
    var target: String?
    var normalizedArgumentsJSON: String = "{}"
    var payloadHash: String = ""
    var riskLevelRawValue: String = ApprovalPolicy.defaultRiskLevel.rawValue
    var reason: String
    var userVisibleDiff: String = ""
    var expiresAt: Date = ApprovalPolicy.expirationDate()
    var approved: Bool?
    var createdAt: Date
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        runID: UUID,
        actionName: String,
        reason: String,
        approved: Bool? = nil,
        createdAt: Date = .now,
        resolvedAt: Date? = nil,
        sessionID: UUID? = nil,
        toolName: String? = nil,
        target: String? = nil,
        normalizedArgumentsJSON: String = "{}",
        payloadHash: String? = nil,
        riskLevelRawValue: String = ApprovalPolicy.defaultRiskLevel.rawValue,
        userVisibleDiff: String? = nil,
        expiresAt: Date? = nil
    ) {
        let resolvedSessionID = sessionID ?? runID
        let resolvedToolName = toolName ?? actionName
        let normalizedRisk = ApprovalPolicy.normalizedRisk(riskLevelRawValue)
        let resolvedArguments = ApprovalTupleHasher.normalizedJSON(normalizedArgumentsJSON)
        self.id = id
        self.runID = runID
        self.sessionID = resolvedSessionID
        self.actionName = actionName
        self.toolName = resolvedToolName
        self.target = target
        self.normalizedArgumentsJSON = resolvedArguments
        self.riskLevelRawValue = normalizedRisk.rawValue
        self.payloadHash = payloadHash ?? ApprovalTupleHasher.payloadHash(
            toolName: resolvedToolName,
            target: target,
            normalizedArgumentsJSON: resolvedArguments,
            riskLevel: normalizedRisk.rawValue,
            sessionID: resolvedSessionID
        )
        self.reason = reason
        self.userVisibleDiff = userVisibleDiff ?? reason
        self.expiresAt = expiresAt ?? ApprovalPolicy.expirationDate(from: createdAt)
        self.approved = approved
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    var riskLevel: ToolRiskLevel {
        ApprovalPolicy.normalizedRisk(riskLevelRawValue)
    }

    func isExpired(at date: Date = .now) -> Bool {
        date > expiresAt
    }

    func approvalTuple() -> ApprovalTuple {
        ApprovalTuple(
            toolName: toolName,
            target: target,
            normalizedArgumentsJSON: normalizedArgumentsJSON,
            riskLevel: riskLevel,
            expiresAt: expiresAt,
            sessionID: sessionID,
            userVisibleDiff: userVisibleDiff
        )
    }
}

@Model
final class AgentTaskRecord {
    var id: UUID
    var runID: UUID?
    var title: String
    var notes: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(), runID: UUID? = nil, title: String, notes: String = "", statusRawValue: String = "active", createdAt: Date = .now, updatedAt: Date = .now, completedAt: Date? = nil) {
        self.id = id
        self.runID = runID
        self.title = title
        self.notes = notes
        self.statusRawValue = statusRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

enum MonGARSSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Conversation.self,
            ChatMessage.self,
            MemoryRecord.self,
            DocumentRecord.self,
            DocumentChunkRecord.self,
            AgentCheckpointRecord.self,
            AgentRunRecord.self,
            AgentTraceRecord.self,
            ToolCallRecord.self,
            ApprovalRequestRecord.self,
            AgentTaskRecord.self,
            RepoIndexRecord.self,
            RepoSymbolRecord.self
        ]
    }
}

enum MonGARSMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MonGARSSchemaV2.self] }
    static var stages: [MigrationStage] { [] }
}
