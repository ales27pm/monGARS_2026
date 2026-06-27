import SwiftData
import SwiftUI

struct DiagnosticsView: View {
    @Bindable var container: AppContainer
    @Query(sort: \AgentCheckpointRecord.createdAt, order: .reverse) private var checkpointRecords: [AgentCheckpointRecord]

    var body: some View {
        List {
            Section("Provider") {
                Text(container.diagnostics.providerStatus)
                if let lastError = container.diagnostics.lastError {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }

            Section("Graph Steps") {
                ForEach(container.diagnostics.graphSteps.indices, id: \.self) { index in
                    Text(container.diagnostics.graphSteps[index])
                }
            }

            Section("Tool Calls") {
                ForEach(container.diagnostics.toolCalls.indices, id: \.self) { index in
                    Text(container.diagnostics.toolCalls[index])
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

