import Foundation

@Observable
final class DiagnosticsStore {
    var providerStatus = "Local mock provider ready"
    var graphSteps: [String] = []
    var toolCalls: [String] = []
    var checkpoints: [String] = []
    var lastError: String?

    func record(event: AgentEvent) {
        switch event {
        case .step(let name):
            graphSteps.append(name)
        case .toolCall(let tool, let input, let output):
            toolCalls.append("\(tool): \(input) -> \(output)")
        case .checkpoint(let checkpoint):
            checkpoints.append("\(checkpoint.nodeID): \(checkpoint.summary)")
        case .partialResponse:
            break
        }
    }
}

