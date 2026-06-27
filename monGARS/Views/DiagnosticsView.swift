import SwiftData
import SwiftUI

struct DiagnosticsView: View {
    @Bindable var container: AppContainer
    @Query(sort: \AgentCheckpointRecord.createdAt, order: .reverse) private var checkpointRecords: [AgentCheckpointRecord]
    @Query(sort: \AgentRunRecord.updatedAt, order: .reverse) private var runs: [AgentRunRecord]
    @Query(sort: \AgentTraceRecord.createdAt, order: .reverse) private var traces: [AgentTraceRecord]
    @Query(sort: \ToolCallRecord.createdAt, order: .reverse) private var persistedToolCalls: [ToolCallRecord]

    var body: some View {
        List {
            Section("Provider") {
                Text(container.diagnostics.providerStatus)
                let capabilities = container.llmProvider().capabilities
                Text("Capabilities: local=\(capabilities.isLocal.description), streaming=\(capabilities.supportsStreaming.description), json=\(capabilities.supportsJSONMode.description), context=\(capabilities.maxContextTokens)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastError = container.diagnostics.lastError {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }

            Section("Live Graph Steps") {
                ForEach(container.diagnostics.graphSteps.indices, id: \.self) { index in
                    Text(container.diagnostics.graphSteps[index])
                }
            }

            Section("Persisted Runs") {
                ForEach(runs.prefix(12)) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.goal)
                            .font(.headline)
                        Text("\(run.statusRawValue) | \(run.currentPhase) | step \(run.currentStep)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Persisted Tool Calls") {
                ForEach(persistedToolCalls.prefix(20)) { call in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(call.toolName)
                            .font(.headline)
                        Text(call.output)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Live Tool Calls") {
                ForEach(container.diagnostics.toolCalls.indices, id: \.self) { index in
                    Text(container.diagnostics.toolCalls[index])
                }
            }

            Section("Trace Events") {
                ForEach(traces.prefix(24)) { trace in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(trace.stepIndex). \(trace.phase)")
                            .font(.headline)
                        Text(trace.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Checkpoints") {
                ForEach(checkpointRecords) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.nodeID)
                            .font(.headline)
                        Text(record.stateSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
