import SwiftData
import SwiftUI

struct GoalsView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AgentRunRecord.updatedAt, order: .reverse) private var runs: [AgentRunRecord]
    @Query(sort: \AgentTaskRecord.updatedAt, order: .reverse) private var tasks: [AgentTaskRecord]
    @Query(sort: \ApprovalRequestRecord.createdAt, order: .reverse) private var approvals: [ApprovalRequestRecord]
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Approvals") {
                ForEach(approvals.filter { $0.approved == nil }) { approval in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(approval.actionName)
                            .font(.headline)
                        Text(approval.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                resolve(approval, approved: true)
                            } label: {
                                Label("Approve", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                resolve(approval, approved: false)
                            } label: {
                                Label("Reject", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section("Agent Runs") {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(run.goal)
                                .font(.headline)
                            Spacer()
                            Text(run.statusRawValue)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Text("\(run.currentPhase) step \(run.currentStep)/\(run.maxSteps)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !run.summary.isEmpty {
                            Text(run.summary)
                                .font(.caption)
                                .lineLimit(3)
                        }
                        HStack {
                            Button {
                                pause(run)
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(run.statusRawValue != AgentRunStatus.running.rawValue)

                            Button {
                                resume(run)
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(run.statusRawValue != AgentRunStatus.paused.rawValue && run.statusRawValue != AgentRunStatus.waitingForApproval.rawValue)

                            Button(role: .destructive) {
                                cancel(run)
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(run.statusRawValue == AgentRunStatus.completed.rawValue || run.statusRawValue == AgentRunStatus.cancelled.rawValue)
                        }
                    }
                }
            }

            Section("Tasks") {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.headline)
                        Text(task.statusRawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !task.notes.isEmpty {
                            Text(task.notes)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Goals")
    }

    private func resolve(_ approval: ApprovalRequestRecord, approved: Bool) {
        do {
            if approved {
                try container.agentRuntime.approve(approval, context: modelContext)
            } else {
                try container.agentRuntime.reject(approval, context: modelContext)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pause(_ run: AgentRunRecord) {
        do {
            try container.agentRuntime.pause(run: run, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resume(_ run: AgentRunRecord) {
        Task {
            do {
                let options = AgentRuntimeOptions(
                    autonomyLevel: container.settingsStore.autonomyLevel,
                    maxSteps: run.maxSteps,
                    timeoutSeconds: 45,
                    networkToolsEnabled: container.settingsStore.remoteProviderEnabled
                )
                for try await _ in container.agentRuntime.resume(run: run, provider: container.llmProvider(), options: options, context: modelContext) {}
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancel(_ run: AgentRunRecord) {
        do {
            try container.agentRuntime.cancel(run: run, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
