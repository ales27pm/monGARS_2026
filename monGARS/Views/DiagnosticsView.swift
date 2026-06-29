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
                        Text(DiagnosticsRedactor.redact(run.goal, maxLength: 180))
                            .font(.headline)
                        Text("\(run.statusRawValue) | \(run.currentPhase) | step \(run.currentStep)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Persisted Tool Calls") {
                if !persistedToolCalls.isEmpty {
                    ShareLink("Export Diagnostics", item: diagnosticsExportText)
                }
                ForEach(persistedToolCalls.prefix(20)) { call in
                    toolCallRow(call)
                }
            }

            Section("Live Tool Calls") {
                ForEach(container.diagnostics.toolCalls) { call in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(call.toolName)
                            .font(.headline)
                        Text("Input: \(call.input)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Output: \(call.output)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Trace Events") {
                ForEach(traces.prefix(24)) { trace in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("\(trace.stepIndex). \(trace.phase)")
                                .font(.headline)
                            if let toolName = trace.toolName {
                                Text(toolName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                            if trace.latencyMs > 0 {
                                Text("\(Int(trace.latencyMs)) ms")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(DiagnosticsRedactor.redact(trace.message, maxLength: 360))
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
                        Text(DiagnosticsRedactor.redact(record.stateSummary, maxLength: 260))
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
                        Text(DiagnosticsRedactor.redact(row.goal, maxLength: 160))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(DiagnosticsRedactor.redact(row.message, maxLength: 220))
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
                Text(DiagnosticsRedactor.redact(latestRun.goal, maxLength: 180))
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

    private func toolCallRow(_ call: ToolCallRecord) -> some View {
        let summary = ToolCallDiagnosticsSummary(call: call)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(call.toolName)
                    .font(.headline)
                Text(summary.status)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(summary.statusColor.opacity(0.15))
                    .foregroundStyle(summary.statusColor)
                    .clipShape(Capsule())
                Spacer()
                if let latency = summary.latencyText {
                    Text(latency)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Label(call.riskLevel, systemImage: "exclamationmark.shield")
                Label(call.outcomeRawValue, systemImage: "target")
                Label(call.approved ? "approved" : "not approved", systemImage: call.approved ? "checkmark.circle" : "xmark.circle")
                if let target = summary.target {
                    Label(target, systemImage: "network")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text(DiagnosticsRedactor.redact(call.input, maxLength: 260))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(DiagnosticsRedactor.redact(call.output, maxLength: 360))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }

    private var diagnosticsExportText: String {
        var lines: [String] = ["monGARS Diagnostics Export", ""]
        for run in runs.prefix(12) {
            lines.append("Run: \(run.id.uuidString)")
            lines.append("Goal: \(DiagnosticsRedactor.redact(run.goal, maxLength: 260))")
            lines.append("Status: \(run.statusRawValue)")
            lines.append("Phase: \(run.currentPhase)")
            lines.append("")
        }
        for call in persistedToolCalls.prefix(50) {
            lines.append("Tool: \(call.toolName)")
            lines.append("Target: \(DiagnosticsRedactor.redact(call.target ?? "none", maxLength: 160))")
            lines.append("Approved: \(call.approved)")
            lines.append("Risk: \(call.riskLevel)")
            lines.append("Outcome: \(call.outcomeRawValue)")
            lines.append("Status code: \(call.statusCode.map(String.init) ?? "none")")
            lines.append("Latency ms: \(Int(call.latencyMs))")
            lines.append("Error category: \(call.errorCategory ?? "none")")
            lines.append("Input: \(DiagnosticsRedactor.redact(call.input, maxLength: 360))")
            lines.append("Output: \(DiagnosticsRedactor.redact(call.output, maxLength: 500))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

private struct ToolCallDiagnosticsSummary {
    var status: String
    var statusColor: Color
    var target: String?
    var latencyText: String?

    init(call: ToolCallRecord) {
        let output = call.output
        let lower = output.lowercased()
        if call.outcomeRawValue != ToolOutcome.success.rawValue {
            status = call.outcomeRawValue
            statusColor = Self.color(for: call.outcomeRawValue)
        } else if let statusCode = call.statusCode {
            status = "HTTP \(statusCode)"
            statusColor = (200..<300).contains(statusCode) ? .green : .orange
        } else if call.errorCategory != nil || lower.contains("network tools are disabled") || lower.contains("api key is missing") || lower.contains("permission was not granted") || lower.contains("was not created") {
            status = "blocked"
            statusColor = .orange
        } else if lower.contains("failed") || lower.contains("invalid") || lower.contains("provide ") {
            status = "error"
            statusColor = .red
        } else {
            status = "ok"
            statusColor = .green
        }

        target = call.target ?? Self.extractTarget(from: output) ?? Self.extractTarget(from: call.input)
        latencyText = call.latencyMs > 0 ? "\(Int(call.latencyMs)) ms" : Self.extractLatency(from: output)
    }

    private static func color(for outcomeRawValue: String) -> Color {
        switch ToolOutcome(rawValue: outcomeRawValue) {
        case .success:
            return .green
        case .handoffPrepared, .noResults, .needsInput:
            return .orange
        case .blocked, .permissionDenied, .unavailable, .failed:
            return .red
        case nil:
            return .secondary
        }
    }

    private static func extractTarget(from text: String) -> String? {
        if let url = firstURL(in: text), let host = url.host {
            return host
        }

        let httpPattern = #"HTTP\s+[A-Z]+\s+([^\s]+)\s+completed"#
        if let value = firstCapture(in: text, pattern: httpPattern) {
            return value
        }

        return nil
    }

    private static func extractLatency(from text: String) -> String? {
        if let value = firstCapture(in: text, pattern: #"(\d+)\s*ms"#) {
            return "\(value) ms"
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        let pattern = #"https?://[^\s]+"#
        guard let raw = firstCapture(in: text, pattern: pattern, wholeMatch: true) else { return nil }
        return URL(string: raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)))
    }

    private static func firstCapture(in text: String, pattern: String, wholeMatch: Bool = false) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let captureIndex = wholeMatch ? 0 : min(1, match.numberOfRanges - 1)
        guard let swiftRange = Range(match.range(at: captureIndex), in: text) else { return nil }
        return String(text[swiftRange])
    }
}
