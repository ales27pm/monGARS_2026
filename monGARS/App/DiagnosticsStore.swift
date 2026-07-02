import Foundation

struct LiveToolCallDiagnostic: Identifiable, Equatable {
    var id = UUID()
    var toolName: String
    var input: String
    var output: String
}

@Observable
final class DiagnosticsStore {
    static let graphStepLimit = 200
    static let liveToolCallLimit = 100
    static let checkpointLimit = 100

    var providerStatus = "Provider status pending"
    var graphSteps: [String] = []
    var toolCalls: [LiveToolCallDiagnostic] = []
    var checkpoints: [String] = []
    var lastError: String?

    func record(event: AgentEvent) {
        switch event {
        case .step(let name):
            appendBounded(DiagnosticsRedactor.redact(name, maxLength: 240), to: &graphSteps, limit: Self.graphStepLimit)
        case .toolCall(let tool, let input, let output):
            appendBounded(LiveToolCallDiagnostic(
                toolName: DiagnosticsRedactor.redact(tool, maxLength: 120),
                input: DiagnosticsRedactor.redact(input, maxLength: 240),
                output: DiagnosticsRedactor.redact(output, maxLength: 320)
            ), to: &toolCalls, limit: Self.liveToolCallLimit)
        case .checkpoint(let checkpoint):
            appendBounded("\(checkpoint.nodeID): \(DiagnosticsRedactor.redact(checkpoint.summary, maxLength: 240))", to: &checkpoints, limit: Self.checkpointLimit)
        case .partialResponse:
            break
        }
    }

    private func appendBounded<T>(_ value: T, to values: inout [T], limit: Int) {
        values.append(value)
        let overflow = values.count - limit
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }
}

enum DiagnosticsVisualizationMode: String, CaseIterable, Identifiable {
    case timeline = "Timeline"
    case graph = "Graph"

    var id: String { rawValue }
}

enum DiagnosticsGraphNodeState: String, Equatable {
    case pending
    case completed
    case current
    case waiting
    case failed
}

struct DiagnosticsTimelineRow: Identifiable, Equatable {
    var id: String
    var runID: UUID
    var goal: String
    var stepIndex: Int
    var phase: String
    var message: String
    var status: String
}

struct DiagnosticsGraphNode: Identifiable, Equatable {
    var id: String { phase.rawValue }
    var phase: AgentPhase
    var state: DiagnosticsGraphNodeState
}

struct DiagnosticsGraphEdge: Identifiable, Equatable {
    var id: String { "\(from.rawValue)-\(to.rawValue)" }
    var from: AgentPhase
    var to: AgentPhase
}

enum DiagnosticsVisualizationBuilder {
    static let phaseOrder: [AgentPhase] = [
        .understandIntent,
        .retrieveContext,
        .plan,
        .selectTool,
        .askUser,
        .executeTool,
        .observeResult,
        .reflect,
        .respond,
        .saveMemory
    ]

    static let phaseEdges: [DiagnosticsGraphEdge] = zip(phaseOrder, phaseOrder.dropFirst()).map {
        DiagnosticsGraphEdge(from: $0.0, to: $0.1)
    }

    static func timelineRows(runs: [AgentRunRecord], traces: [AgentTraceRecord]) -> [DiagnosticsTimelineRow] {
        let sortedRuns = runs.sorted { $0.updatedAt > $1.updatedAt }
        return sortedRuns.flatMap { run in
            let runTraces = traces
                .filter { $0.runID == run.id }
                .sorted { $0.stepIndex < $1.stepIndex }
            if runTraces.isEmpty {
                return [
                    DiagnosticsTimelineRow(
                        id: "\(run.id.uuidString)-\(run.currentPhase)-empty",
                        runID: run.id,
                        goal: run.goal,
                        stepIndex: run.currentStep,
                        phase: run.currentPhase,
                        message: run.summary.isEmpty ? run.statusRawValue : run.summary,
                        status: run.statusRawValue
                    )
                ]
            }
            return runTraces.map { trace in
                DiagnosticsTimelineRow(
                    id: "\(run.id.uuidString)-\(trace.stepIndex)-\(trace.phase)",
                    runID: run.id,
                    goal: run.goal,
                    stepIndex: trace.stepIndex,
                    phase: trace.phase,
                    message: trace.message,
                    status: run.statusRawValue
                )
            }
        }
    }

    static func graphNodes(for run: AgentRunRecord?, traces: [AgentTraceRecord]) -> [DiagnosticsGraphNode] {
        guard let run else {
            return phaseOrder.map { DiagnosticsGraphNode(phase: $0, state: .pending) }
        }

        let completed = Set(traces.filter { $0.runID == run.id }.map(\.phase))
        return phaseOrder.map { phase in
            let phaseName = phase.rawValue
            let state: DiagnosticsGraphNodeState
            if run.currentPhase == phaseName && run.statusRawValue == AgentRunStatus.failed.rawValue {
                state = .failed
            } else if run.currentPhase == phaseName && run.statusRawValue == AgentRunStatus.waitingForApproval.rawValue {
                state = .waiting
            } else if run.currentPhase == phaseName && run.statusRawValue == AgentRunStatus.running.rawValue {
                state = .current
            } else if completed.contains(phaseName) || run.statusRawValue == AgentRunStatus.completed.rawValue && completed.contains(phaseName) {
                state = .completed
            } else {
                state = .pending
            }
            return DiagnosticsGraphNode(phase: phase, state: state)
        }
    }
}
