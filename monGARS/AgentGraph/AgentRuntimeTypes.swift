import Foundation

enum AutonomyLevel: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum AgentRunStatus: String, Codable, Sendable {
    case running
    case paused
    case waitingForApproval
    case completed
    case failed
    case cancelled
    case maxStepsReached
    case timedOut
}

enum AgentPhase: String, Codable, CaseIterable, Sendable {
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

enum ToolRiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case destructive

    var requiresApprovalByDefault: Bool {
        self == .high || self == .destructive
    }
}

struct ToolSchema: Codable, Sendable {
    var inputDescription: String
    var examples: [String]
}

struct ToolExecutionRequest: Sendable {
    var runID: UUID
    var input: String
    var autonomyLevel: AutonomyLevel
    var approved: Bool
}

struct AgentRuntimeOptions: Sendable {
    var autonomyLevel: AutonomyLevel = .assisted
    var maxSteps: Int = 12
    var timeoutSeconds: TimeInterval = 45
}

struct AgentPlan: Sendable, Codable {
    var summary: String
    var steps: [String]
    var shouldRemember: Bool
}

struct AgentLoopState: Sendable, Codable {
    var runID: UUID
    var goal: String
    var phase: AgentPhase = .understandIntent
    var stepIndex: Int = 0
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

enum AgentRuntimeEvent: Sendable {
    case status(runID: UUID, phase: AgentPhase, message: String)
    case trace(runID: UUID, phase: AgentPhase, message: String)
    case partialResponse(runID: UUID, text: String)
    case approvalRequired(runID: UUID, toolName: String, reason: String)
    case completed(runID: UUID, response: String)
}

enum AgentRuntimeError: LocalizedError {
    case cancelled
    case paused
    case timedOut
    case maxStepsReached
    case approvalRequired(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "The agent run was cancelled."
        case .paused: "The agent run is paused."
        case .timedOut: "The agent run timed out."
        case .maxStepsReached: "The agent reached its maximum step limit."
        case .approvalRequired(let action): "Approval is required before running \(action)."
        }
    }
}
