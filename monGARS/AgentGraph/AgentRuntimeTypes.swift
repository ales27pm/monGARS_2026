import Foundation

enum AutonomyLevel: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case manual
    case assisted
    case semiAuto
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: "Manual"
        case .assisted: "Assisted"
        case .semiAuto: "Semi-Auto"
        case .auto: "Auto"
        }
    }
}

enum AgentRunStatus: String, Codable, Sendable, Equatable {
    case running
    case paused
    case waitingForApproval
    case completed
    case failed
    case cancelled
    case maxStepsReached
    case timedOut
}

enum AgentPhase: String, Codable, CaseIterable, Sendable, Equatable {
    case understandIntent
    case retrieveContext
    case plan
    case selectTool
    case executeTool
    case observeResult
    case reflect
    case respond
    case askUser
    case saveMemory

    var statusText: String {
        switch self {
        case .understandIntent: "Understanding"
        case .retrieveContext: "Retrieving context"
        case .plan: "Planning"
        case .selectTool: "Selecting tool"
        case .executeTool: "Using tool"
        case .observeResult: "Observing"
        case .reflect: "Reflecting"
        case .respond: "Responding"
        case .askUser: "Waiting for approval"
        case .saveMemory: "Remembering"
        }
    }
}

enum ToolRiskLevel: String, Codable, CaseIterable, Sendable, Equatable {
    case low
    case medium
    case high
    case destructive

    var requiresApprovalByDefault: Bool {
        self == .high || self == .destructive
    }
}

struct ToolSchema: Codable, Sendable, Equatable {
    var inputDescription: String
    var examples: [String]
}

struct ToolExecutionMetadata: Sendable, Equatable {
    var requiresNetwork: Bool = false
    var targetPreview: String?
    var actionPreview: String?
}

struct ToolExecutionRequest: Sendable {
    var runID: UUID
    var input: String
    var autonomyLevel: AutonomyLevel
    var approved: Bool
    var networkAccessAllowed: Bool = false
}

extension ToolResult {
    static func needsInput(toolName: String, output: String, riskLevel: ToolRiskLevel = .low, requiresApproval: Bool = false) -> ToolResult {
        ToolResult(
            toolName: toolName,
            output: output,
            outcome: .needsInput,
            riskLevel: riskLevel,
            requiresApproval: requiresApproval,
            approved: true,
            errorCategory: "invalid_arguments"
        )
    }

    static func unavailable(toolName: String, output: String, riskLevel: ToolRiskLevel = .low, requiresApproval: Bool = false, target: String? = nil, errorCategory: String = "platform_unavailable") -> ToolResult {
        ToolResult(
            toolName: toolName,
            output: output,
            outcome: .unavailable,
            riskLevel: riskLevel,
            requiresApproval: requiresApproval,
            approved: true,
            target: target,
            errorCategory: errorCategory
        )
    }

    static func handoff(toolName: String, output: String, riskLevel: ToolRiskLevel, target: String? = nil) -> ToolResult {
        ToolResult(
            toolName: toolName,
            output: output,
            outcome: .handoffPrepared,
            riskLevel: riskLevel,
            requiresApproval: true,
            approved: true,
            target: target
        )
    }

    static func networkDisabled(toolName: String, riskLevel: ToolRiskLevel, target: String? = nil) -> ToolResult {
        ToolResult(
            toolName: toolName,
            output: "Network tools are disabled in Settings. Enable network access before running this tool.",
            outcome: .blocked,
            riskLevel: riskLevel,
            requiresApproval: false,
            approved: true,
            target: target,
            errorCategory: "network_disabled"
        )
    }
}

struct AgentRuntimeOptions: Sendable, Equatable {
    var autonomyLevel: AutonomyLevel = .assisted
    var maxSteps: Int = 12
    var timeoutSeconds: TimeInterval = 45
    var networkToolsEnabled: Bool = false
}

struct AgentPlan: Sendable, Codable, Equatable {
    var summary: String
    var steps: [String]
    var shouldRemember: Bool
}

struct AgentLoopState: Sendable, Codable, Equatable {
    var runID: UUID
    var goal: String
    var phase: AgentPhase = .understandIntent
    var stepIndex: Int = 0
    var completedNodeIDs: [String] = []
    var plan: AgentPlan?
    var selectedToolName: String?
    var retrievedContext: [String] = []
    var toolResults: [String] = []
    var observations: [String] = []
    var reflection: String = ""
    var finalResponse: String = ""
    var status: AgentRunStatus = .running

    var summary: String {
        "phase=\(phase.rawValue); tool=\(selectedToolName ?? "none"); response=\(finalResponse.prefix(80))"
    }
}

struct ApprovalPresentation: Sendable, Equatable, Identifiable {
    var id: UUID { approvalID }
    var approvalID: UUID
    var runID: UUID
    var toolName: String
    var target: String?
    var riskLevel: ToolRiskLevel
    var payloadHash: String
    var sessionID: UUID
    var expiresAt: Date
    var reason: String
    var userVisibleDiff: String

    var payloadHashPreview: String {
        guard !payloadHash.isEmpty else { return "missing" }
        return String(payloadHash.prefix(12))
    }

    var sessionPreview: String {
        String(sessionID.uuidString.prefix(8))
    }
}

enum AgentRuntimeEvent: Sendable {
    case status(runID: UUID, phase: AgentPhase, message: String)
    case trace(runID: UUID, phase: AgentPhase, message: String)
    case partialResponse(runID: UUID, text: String)
    case approvalRequired(ApprovalPresentation)
    case completed(runID: UUID, response: String)
}

enum AgentRuntimeError: LocalizedError, Equatable {
    case cancelled
    case paused
    case timedOut
    case maxStepsReached
    case approvalRequired(String)
    case approvalRejected(String)
    case approvalExpired(String)
    case approvalNotFound
    case resumeCheckpointUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: "The agent run was cancelled."
        case .paused: "The agent run is paused."
        case .timedOut: "The agent run timed out."
        case .maxStepsReached: "The agent reached its maximum step limit."
        case .approvalRequired(let action): "Approval is required before running \(action)."
        case .approvalRejected(let action): "Approval was rejected for \(action)."
        case .approvalExpired(let action): "Approval expired before running \(action). Restart the run to approve a fresh request."
        case .approvalNotFound: "The approval request could not be found."
        case .resumeCheckpointUnavailable: "No durable checkpoint was available for this run."
        }
    }
}
