import Foundation
import SwiftData

struct AgentPlanner: Sendable {
    func makePlan(goal: String, contextPackage: ContextPackage) -> AgentPlan {
        let lower = goal.lowercased()
        var steps = ["Understand the request", "Retrieve local context"]
        if lower.contains("document") || lower.contains("summarize") {
            steps.append("Search and summarize imported documents")
        }
        if lower.contains("remember") || lower.contains("memory") {
            steps.append("Save important durable facts")
        }
        if lower.contains("calculate") || lower.contains("time") || lower.contains("task") {
            steps.append("Use the appropriate local tool")
        }
        steps.append("Reflect on whether the goal is satisfied")
        steps.append("Respond with a concise answer")

        return AgentPlan(
            summary: "Plan for: \(goal)",
            steps: steps,
            shouldRemember: lower.contains("remember") || lower.contains("key point") || lower.contains("prefer")
        )
    }
}

struct AgentExecutor: Sendable {
    let toolRouter: ToolRouter

    func selectedTool(for goal: String) -> (any Tool)? {
        toolRouter.route(input: goal)
    }

    func execute(goal: String, runID: UUID, autonomyLevel: AutonomyLevel, approved: Bool, context: ModelContext) async throws -> ToolResult? {
        let request = ToolExecutionRequest(runID: runID, input: goal, autonomyLevel: autonomyLevel, approved: approved)
        return try await toolRouter.execute(request: request, context: context)
    }
}

struct AgentObserver: Sendable {
    func observe(toolResult: ToolResult?, retrievedContext: [String]) -> String {
        if let toolResult {
            return "Observed \(toolResult.toolName): \(toolResult.output)"
        }
        if !retrievedContext.isEmpty {
            return "Observed \(retrievedContext.count) relevant local context snippets."
        }
        return "Observed no tool output and no strong local context."
    }
}

struct AgentReflector: Sendable {
    func reflect(goal: String, plan: AgentPlan?, observations: [String]) -> String {
        let planText = plan?.steps.joined(separator: " -> ") ?? "No explicit plan."
        let evidence = observations.isEmpty ? "No observations yet." : observations.joined(separator: " ")
        return "Goal: \(goal). Plan: \(planText). Evidence: \(evidence)"
    }
}

enum ApprovalDecision: Sendable {
    case approved
    case rejected
}

actor AgentApprovalGate {
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var resolvedDecisions: [UUID: ApprovalDecision] = [:]

    func suspend(runID: UUID, approvalID: UUID) async -> ApprovalDecision {
        if let decision = resolvedDecisions.removeValue(forKey: approvalID) {
            return decision
        }

        return await withCheckedContinuation { continuation in
            continuations[approvalID] = continuation
        }
    }

    func resolve(approvalID: UUID, approved: Bool) {
        let decision: ApprovalDecision = approved ? .approved : .rejected
        if let continuation = continuations.removeValue(forKey: approvalID) {
            continuation.resume(returning: decision)
        } else {
            resolvedDecisions[approvalID] = decision
        }
    }
}

private struct AgentTraceSnapshot: Sendable {
    var runID: UUID
    var stepIndex: Int
    var phase: String
    var message: String
    var toolName: String?
    var latencyMs: Double
    var createdAt: Date
}

private struct AgentCheckpointSnapshot: Sendable {
    var runID: UUID
    var nodeID: String
    var stateSummary: String
    var stateData: Data?
    var createdAt: Date
}

final class AgentTelemetryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var traces: [AgentTraceSnapshot] = []
    private var checkpoints: [AgentCheckpointSnapshot] = []

    func appendTrace(runID: UUID, stepIndex: Int, phase: String, message: String, toolName: String? = nil, latencyMs: Double = 0) {
        let snapshot = AgentTraceSnapshot(runID: runID, stepIndex: stepIndex, phase: phase, message: message, toolName: toolName, latencyMs: latencyMs, createdAt: .now)
        lock.withLock {
            traces.append(snapshot)
        }
    }

    func appendCheckpoint(runID: UUID, nodeID: String, stateSummary: String, stateData: Data? = nil) {
        let snapshot = AgentCheckpointSnapshot(runID: runID, nodeID: nodeID, stateSummary: stateSummary, stateData: stateData, createdAt: .now)
        lock.withLock {
            checkpoints.append(snapshot)
        }
    }

    func flush(runID: UUID, to context: ModelContext) throws {
        let payload = lock.withLock {
            let matchingTraces = traces.filter { $0.runID == runID }
            let matchingCheckpoints = checkpoints.filter { $0.runID == runID }
            traces.removeAll { $0.runID == runID }
            checkpoints.removeAll { $0.runID == runID }
            return (matchingTraces, matchingCheckpoints)
        }

        for trace in payload.0 {
            context.insert(AgentTraceRecord(
                runID: trace.runID,
                stepIndex: trace.stepIndex,
                phase: trace.phase,
                message: trace.message,
                toolName: trace.toolName,
                latencyMs: trace.latencyMs,
                createdAt: trace.createdAt
            ))
        }

        for checkpoint in payload.1 {
            context.insert(AgentCheckpointRecord(
                runID: checkpoint.runID,
                nodeID: checkpoint.nodeID,
                stateSummary: checkpoint.stateSummary,
                stateData: checkpoint.stateData,
                createdAt: checkpoint.createdAt
            ))
        }

        try context.safeSave()
    }
}

struct AgentLoop: Sendable {
    let planner: AgentPlanner
    let executor: AgentExecutor
    let observer: AgentObserver
    let reflector: AgentReflector
    let contextBuilder: ContextBuilder
    let approvalGate: AgentApprovalGate
    let telemetryBuffer: AgentTelemetryBuffer

    func run(
        goal: String,
        conversationID: UUID?,
        messages: [String],
        provider: any LLMProvider,
        options: AgentRuntimeOptions,
        context: ModelContext
    ) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let startedAt = Date()
                var state = AgentLoopState(runID: UUID(), goal: goal)
                let runRecord = AgentRunRecord(id: state.runID, conversationID: conversationID, goal: goal, autonomyLevelRawValue: options.autonomyLevel.rawValue, maxSteps: options.maxSteps)

                do {
                    context.insert(runRecord)
                    try context.safeSave()
                    try await continueRun(goal: goal, conversationID: conversationID, messages: messages, provider: provider, options: options, context: context, state: &state, runRecord: runRecord, startedAt: startedAt, continuation: continuation)
                } catch is CancellationError {
                    finishFailure(.cancelled, state: state, runRecord: runRecord, context: context, continuation: continuation)
                } catch AgentRuntimeError.paused {
                    finishFailure(.paused, state: state, runRecord: runRecord, context: context, continuation: continuation)
                } catch AgentRuntimeError.maxStepsReached {
                    finishFailure(.maxStepsReached, state: state, runRecord: runRecord, context: context, continuation: continuation)
                } catch AgentRuntimeError.timedOut {
                    finishFailure(.timedOut, state: state, runRecord: runRecord, context: context, continuation: continuation)
                } catch {
                    if Date().timeIntervalSince(startedAt) > options.timeoutSeconds {
                        finishFailure(.timedOut, state: state, runRecord: runRecord, context: context, continuation: continuation)
                    } else {
                        runRecord.statusRawValue = AgentRunStatus.failed.rawValue
                        runRecord.lastError = error.localizedDescription
                        runRecord.updatedAt = .now
                        try? recordCheckpoint(state: state, nodeID: AgentRunStatus.failed.rawValue, context: context, includeStateData: true)
                        try? telemetryBuffer.flush(runID: state.runID, to: context)
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    func resume(run: AgentRunRecord, provider: any LLMProvider, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let descriptor = FetchDescriptor<AgentCheckpointRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
                    let checkpoint = try context.fetch(descriptor).first { $0.runID == run.id && $0.stateData != nil }
                    guard let data = checkpoint?.stateData else {
                        throw AgentRuntimeError.resumeCheckpointUnavailable
                    }

                    var state = try JSONDecoder().decode(AgentLoopState.self, from: data)
                    run.statusRawValue = AgentRunStatus.running.rawValue
                    run.requiresApproval = false
                    run.updatedAt = .now
                    try context.safeSave()
                    try await continueRun(
                        goal: run.goal,
                        conversationID: run.conversationID,
                        messages: [],
                        provider: provider,
                        options: AgentRuntimeOptions(autonomyLevel: AutonomyLevel(rawValue: run.autonomyLevelRawValue) ?? .assisted, maxSteps: run.maxSteps),
                        context: context,
                        state: &state,
                        runRecord: run,
                        startedAt: .now,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func continueRun(
        goal: String,
        conversationID: UUID?,
        messages: [String],
        provider: any LLMProvider,
        options: AgentRuntimeOptions,
        context: ModelContext,
        state: inout AgentLoopState,
        runRecord: AgentRunRecord,
        startedAt: Date,
        continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation
    ) async throws {
        if needsPhase(.understandIntent, state: state) {
            try await runPhase(.understandIntent, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                "Intent understood: \(goal)"
            }
        }

        var contextPackage = try contextBuilder.build(goal: goal, messages: messages, graphState: state, toolResults: state.toolResults, context: context, phase: .retrieveContext, budget: provider.capabilities.maxContextTokens)
        if needsPhase(.retrieveContext, state: state) {
            state.retrievedContext = contextPackage.memories + contextPackage.documents
            try await runPhase(.retrieveContext, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                "Retrieved \(contextPackage.memories.count) memories and \(contextPackage.documents.count) document snippets."
            }
        }

        if needsPhase(.plan, state: state) {
            state.plan = planner.makePlan(goal: goal, contextPackage: contextPackage)
            let planMessage = state.plan?.steps.joined(separator: " -> ") ?? "No plan."
            try await runPhase(.plan, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                planMessage
            }
        }

        let tool = executor.selectedTool(for: goal)
        if needsPhase(.selectTool, state: state) {
            state.selectedToolName = tool?.name
            try await runPhase(.selectTool, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                tool.map { "Selected tool: \($0.name)" } ?? "No tool required."
            }
        }

        if let tool, needsPhase(.executeTool, state: state) {
            if requiresApproval(tool: tool, autonomyLevel: options.autonomyLevel) {
                let decision = try await requestApprovalIfNeeded(tool: tool, goal: goal, options: options, state: &state, runRecord: runRecord, context: context, continuation: continuation)
                guard decision == .approved else {
                    state.status = .failed
                    state.finalResponse = "I did not run \(tool.name) because approval was rejected."
                    runRecord.statusRawValue = state.status.rawValue
                    runRecord.lastError = AgentRuntimeError.approvalRejected(tool.name).localizedDescription
                    runRecord.summary = state.finalResponse
                    runRecord.completedAt = .now
                    runRecord.updatedAt = .now
                    try recordCheckpoint(state: state, nodeID: AgentPhase.askUser.rawValue, context: context, includeStateData: true)
                    try telemetryBuffer.flush(runID: state.runID, to: context)
                    continuation.yield(.completed(runID: state.runID, response: state.finalResponse))
                    continuation.finish()
                    return
                }
            }

            _ = try contextBuilder.build(goal: goal, messages: messages, graphState: state, toolResults: state.toolResults, context: context, phase: .executeTool, selectedToolName: tool.name, selectedToolSchema: tool.schema, budget: provider.capabilities.maxContextTokens)
            let result = try await executor.execute(goal: goal, runID: state.runID, autonomyLevel: options.autonomyLevel, approved: true, context: context)
            if let result {
                state.toolResults.append(result.output)
                context.insert(ToolCallRecord(runID: state.runID, toolName: result.toolName, input: goal, output: result.output, riskLevel: result.riskLevel.rawValue, requiresApproval: result.requiresApproval, approved: result.approved))
            }
            try await runPhase(.executeTool, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                result?.output ?? "Tool produced no output."
            }

            let observation = observer.observe(toolResult: result, retrievedContext: state.retrievedContext)
            state.observations.append(observation)
            try await runPhase(.observeResult, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                observation
            }
        }

        if needsPhase(.reflect, state: state) {
            state.reflection = reflector.reflect(goal: goal, plan: state.plan, observations: state.observations)
            let reflectionMessage = state.reflection
            try await runPhase(.reflect, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                reflectionMessage
            }
        }

        contextPackage = try contextBuilder.build(goal: goal, messages: messages, graphState: state, toolResults: state.toolResults, context: context, phase: .reflect, budget: provider.capabilities.maxContextTokens)
        if needsPhase(.respond, state: state) {
            if Date().timeIntervalSince(startedAt) > options.timeoutSeconds {
                throw AgentRuntimeError.timedOut
            }
            let response = try await responseText(goal: goal, state: state, provider: provider, contextPackage: contextPackage)
            var accumulated = ""
            for word in response.split(separator: " ") {
                try Task.checkCancellation()
                accumulated += word + " "
                continuation.yield(.partialResponse(runID: state.runID, text: accumulated))
            }
            state.finalResponse = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            let responseMessage = state.finalResponse
            try await runPhase(.respond, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                responseMessage
            }
        }

        if state.plan?.shouldRemember == true, needsPhase(.saveMemory, state: state) {
            let memory = durableMemory(from: goal, state: state)
            try contextBuilder.memoryService.save(content: memory, source: "agentRun:\(state.runID.uuidString)", scope: "longTerm", context: context)
            try await runPhase(.saveMemory, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                "Saved memory: \(memory)"
            }
        }

        state.status = .completed
        runRecord.statusRawValue = state.status.rawValue
        runRecord.summary = state.finalResponse
        runRecord.completedAt = .now
        runRecord.updatedAt = .now
        try recordCheckpoint(state: state, nodeID: AgentRunStatus.completed.rawValue, context: context, includeStateData: false)
        try telemetryBuffer.flush(runID: state.runID, to: context)
        continuation.yield(.completed(runID: state.runID, response: state.finalResponse))
        continuation.finish()
    }

    private func runPhase(
        _ phase: AgentPhase,
        state: inout AgentLoopState,
        runRecord: AgentRunRecord,
        context: ModelContext,
        continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation,
        message: () -> String
    ) async throws {
        try Task.checkCancellation()
        if runRecord.statusRawValue == AgentRunStatus.cancelled.rawValue {
            throw AgentRuntimeError.cancelled
        }
        if runRecord.statusRawValue == AgentRunStatus.paused.rawValue {
            throw AgentRuntimeError.paused
        }
        state.phase = phase
        state.stepIndex += 1
        if state.stepIndex > runRecord.maxSteps {
            state.status = .maxStepsReached
            runRecord.statusRawValue = AgentRunStatus.maxStepsReached.rawValue
            runRecord.lastError = AgentRuntimeError.maxStepsReached.localizedDescription
            try context.safeSave()
            throw AgentRuntimeError.maxStepsReached
        }
        runRecord.currentPhase = phase.rawValue
        runRecord.currentStep = state.stepIndex
        runRecord.updatedAt = .now
        let text = message()
        if !state.completedNodeIDs.contains(phase.rawValue) {
            state.completedNodeIDs.append(phase.rawValue)
        }
        telemetryBuffer.appendTrace(runID: state.runID, stepIndex: state.stepIndex, phase: phase.rawValue, message: text)
        try recordCheckpoint(state: state, nodeID: phase.rawValue, context: context, includeStateData: false)
        continuation.yield(.status(runID: state.runID, phase: phase, message: phase.statusText))
        continuation.yield(.trace(runID: state.runID, phase: phase, message: text))
    }

    private func recordCheckpoint(state: AgentLoopState, nodeID: String, context: ModelContext, includeStateData: Bool) throws {
        let data = includeStateData ? try? JSONEncoder().encode(state) : nil
        telemetryBuffer.appendCheckpoint(runID: state.runID, nodeID: nodeID, stateSummary: state.summary, stateData: data)
    }

    private func needsPhase(_ phase: AgentPhase, state: AgentLoopState) -> Bool {
        !state.completedNodeIDs.contains(phase.rawValue)
    }

    private func requestApprovalIfNeeded(
        tool: any Tool,
        goal: String,
        options: AgentRuntimeOptions,
        state: inout AgentLoopState,
        runRecord: AgentRunRecord,
        context: ModelContext,
        continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation
    ) async throws -> ApprovalDecision {
        if let approval = try approvalRecord(runID: state.runID, toolName: tool.name, context: context) {
            if let approved = approval.approved {
                if approved {
                    state.status = .running
                    runRecord.statusRawValue = state.status.rawValue
                    runRecord.requiresApproval = false
                    runRecord.updatedAt = .now
                    try context.safeSave()
                }
                return approved ? .approved : .rejected
            }

            state.status = .waitingForApproval
            runRecord.statusRawValue = state.status.rawValue
            runRecord.requiresApproval = true
            runRecord.updatedAt = .now
            try context.safeSave()
            continuation.yield(.approvalRequired(runID: state.runID, approvalID: approval.id, toolName: tool.name, reason: approval.reason))

            let decision = await approvalGate.suspend(runID: state.runID, approvalID: approval.id)
            if runRecord.statusRawValue == AgentRunStatus.cancelled.rawValue {
                throw AgentRuntimeError.cancelled
            }
            runRecord.requiresApproval = false
            runRecord.updatedAt = .now
            if decision == .approved {
                state.status = .running
                runRecord.statusRawValue = state.status.rawValue
                try context.safeSave()
            }
            return decision
        }

        let approval = ApprovalRequestRecord(
            runID: state.runID,
            actionName: tool.name,
            reason: "\(tool.name) is \(tool.riskLevel.rawValue) risk or current autonomy is \(options.autonomyLevel.label)."
        )
        context.insert(approval)

        state.status = .waitingForApproval
        runRecord.statusRawValue = state.status.rawValue
        runRecord.requiresApproval = true
        runRecord.updatedAt = .now
        try await runPhase(.askUser, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
            "Approval requested for \(tool.name): \(approval.reason)"
        }
        try recordCheckpoint(state: state, nodeID: AgentPhase.askUser.rawValue, context: context, includeStateData: true)
        try telemetryBuffer.flush(runID: state.runID, to: context)

        continuation.yield(.approvalRequired(runID: state.runID, approvalID: approval.id, toolName: tool.name, reason: approval.reason))
        let decision = await approvalGate.suspend(runID: state.runID, approvalID: approval.id)
        if runRecord.statusRawValue == AgentRunStatus.cancelled.rawValue {
            throw AgentRuntimeError.cancelled
        }
        runRecord.requiresApproval = false
        runRecord.updatedAt = .now
        if decision == .approved {
            state.status = .running
            runRecord.statusRawValue = state.status.rawValue
            try context.safeSave()
        }
        return decision
    }

    private func approvalRecord(runID: UUID, toolName: String, context: ModelContext) throws -> ApprovalRequestRecord? {
        let descriptor = FetchDescriptor<ApprovalRequestRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor).first { $0.runID == runID && $0.actionName == toolName }
    }

    private func responseText(goal: String, state: AgentLoopState, provider: any LLMProvider, contextPackage: ContextPackage) async throws -> String {
        if let toolOutput = state.toolResults.last {
            let reflection = state.reflection.isEmpty ? "" : "\n\nReflection: \(state.reflection)"
            return "\(toolOutput)\(reflection)"
        }
        let request = LLMRequest(prompt: contextPackage.prompt, conversationContext: [goal], retrievedContext: state.retrievedContext)
        let response = try await provider.complete(request: request)
        return response.text
    }

    private func durableMemory(from goal: String, state: AgentLoopState) -> String {
        if let toolOutput = state.toolResults.last, !toolOutput.isEmpty {
            return "From goal '\(goal)': \(toolOutput)"
        }
        return "From goal '\(goal)': \(state.finalResponse)"
    }

    private func requiresApproval(tool: any Tool, autonomyLevel: AutonomyLevel) -> Bool {
        if tool.riskLevel == .destructive || tool.riskLevel == .high {
            return true
        }
        switch autonomyLevel {
        case .manual:
            return tool.requiresApproval
        case .assisted:
            return tool.riskLevel == .medium
        case .semiAuto, .auto:
            return false
        }
    }

    private func finishFailure(
        _ status: AgentRunStatus,
        state: AgentLoopState,
        runRecord: AgentRunRecord,
        context: ModelContext,
        continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation
    ) {
        runRecord.statusRawValue = status.rawValue
        runRecord.lastError = error(for: status).localizedDescription
        runRecord.updatedAt = .now
        try? recordCheckpoint(state: state, nodeID: status.rawValue, context: context, includeStateData: true)
        try? telemetryBuffer.flush(runID: state.runID, to: context)
        continuation.finish(throwing: error(for: status))
    }

    private func error(for status: AgentRunStatus) -> AgentRuntimeError {
        switch status {
        case .paused:
            return .paused
        case .timedOut:
            return .timedOut
        case .maxStepsReached:
            return .maxStepsReached
        default:
            return .cancelled
        }
    }
}

@MainActor
@Observable
final class AgentRuntime {
    private let loop: AgentLoop
    private let approvalGate = AgentApprovalGate()
    private let telemetryBuffer = AgentTelemetryBuffer()
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    init(planner: AgentPlanner, executor: AgentExecutor, observer: AgentObserver, reflector: AgentReflector, contextBuilder: ContextBuilder) {
        loop = AgentLoop(
            planner: planner,
            executor: executor,
            observer: observer,
            reflector: reflector,
            contextBuilder: contextBuilder,
            approvalGate: approvalGate,
            telemetryBuffer: telemetryBuffer
        )
    }

    func run(goal: String, conversationID: UUID?, messages: [String], provider: any LLMProvider, options: AgentRuntimeOptions, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        loop.run(goal: goal, conversationID: conversationID, messages: messages, provider: provider, options: options, context: context)
    }

    func resume(run: AgentRunRecord, provider: any LLMProvider, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        loop.resume(run: run, provider: provider, context: context)
    }

    func pause(run: AgentRunRecord, context: ModelContext) throws {
        run.statusRawValue = AgentRunStatus.paused.rawValue
        run.updatedAt = .now
        try context.safeSave()
    }

    func cancel(run: AgentRunRecord, context: ModelContext) throws {
        runningTasks[run.id]?.cancel()
        runningTasks[run.id] = nil
        run.statusRawValue = AgentRunStatus.cancelled.rawValue
        run.updatedAt = .now
        let pendingApprovals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>()).filter { $0.runID == run.id && $0.approved == nil }
        for approval in pendingApprovals {
            approval.approved = false
            approval.resolvedAt = .now
            Task { await approvalGate.resolve(approvalID: approval.id, approved: false) }
        }
        try context.safeSave()
    }

    func approve(_ approval: ApprovalRequestRecord, context: ModelContext) throws {
        approval.approved = true
        approval.resolvedAt = .now
        try context.safeSave()
        Task { await approvalGate.resolve(approvalID: approval.id, approved: true) }
    }

    func reject(_ approval: ApprovalRequestRecord, context: ModelContext) throws {
        approval.approved = false
        approval.resolvedAt = .now
        try context.safeSave()
        Task { await approvalGate.resolve(approvalID: approval.id, approved: false) }
    }

    func approve(approvalID: UUID, context: ModelContext) throws {
        guard let approval = try context.fetch(FetchDescriptor<ApprovalRequestRecord>()).first(where: { $0.id == approvalID }) else {
            throw AgentRuntimeError.approvalNotFound
        }
        try approve(approval, context: context)
    }

    func reject(approvalID: UUID, context: ModelContext) throws {
        guard let approval = try context.fetch(FetchDescriptor<ApprovalRequestRecord>()).first(where: { $0.id == approvalID }) else {
            throw AgentRuntimeError.approvalNotFound
        }
        try reject(approval, context: context)
    }
}
