import SwiftData
import SwiftUI

struct DiagnosticsView: View {
    @Bindable var container: AppContainer
    @Query(sort: \AgentCheckpointRecord.createdAt, order: .reverse) private var checkpointRecords: [AgentCheckpointRecord]
    @Query(sort: \AgentRunRecord.updatedAt, order: .reverse) private var runs: [AgentRunRecord]
    @Query(sort: \AgentTraceRecord.createdAt, order: .reverse) private var traces: [AgentTraceRecord]
    @Query(sort: \ToolCallRecord.createdAt, order: .reverse) private var persistedToolCalls: [ToolCallRecord]
    @State private var visualizationMode: DiagnosticsVisualizationMode = .timeline

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

            Section("Execution Visualization") {
                Picker("View", selection: $visualizationMode) {
                    ForEach(DiagnosticsVisualizationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch visualizationMode {
                case .timeline:
                    timelineView
                case .graph:
                    graphView
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

    private var timelineView: some View {
        let rows = DiagnosticsVisualizationBuilder.timelineRows(runs: Array(runs.prefix(8)), traces: traces)
        return VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("No agent runs recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows.prefix(32)) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(row.stepIndex). \(row.phase)")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(row.goal)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(row.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var graphView: some View {
        let latestRun = runs.sorted { $0.updatedAt > $1.updatedAt }.first
        let nodes = DiagnosticsVisualizationBuilder.graphNodes(for: latestRun, traces: traces)
        return VStack(alignment: .leading, spacing: 10) {
            if let latestRun {
                Text(latestRun.goal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("No agent runs recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(nodes) { node in
                        graphNode(node)
                        if node.phase != nodes.last?.phase {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(DiagnosticsVisualizationBuilder.phaseEdges.prefix(6)) { edge in
                Text("\(edge.from.statusText) -> \(edge.to.statusText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func graphNode(_ node: DiagnosticsGraphNode) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color(for: node.state))
                .frame(width: 12, height: 12)
            Text(node.phase.statusText)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func color(for state: DiagnosticsGraphNodeState) -> Color {
        switch state {
        case .pending:
            return .gray
        case .completed:
            return .green
        case .current:
            return .blue
        case .waiting:
            return .orange
        case .failed:
            return .red
        }
    }
}
