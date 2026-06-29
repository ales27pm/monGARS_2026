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

    func execute(goal: String, runID: UUID, autonomyLevel: AutonomyLevel, approved: Bool, networkAccessAllowed: Bool, context: ModelContext) async throws -> ToolResult? {
        let request = ToolExecutionRequest(runID: runID, input: goal, autonomyLevel: autonomyLevel, approved: approved, networkAccessAllowed: networkAccessAllowed)
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

enum ApprovalDecision: Sendable, Equatable {
    case approved
    case rejected
}

actor AgentApprovalGate {
    private struct ApprovalWaiter {
        var runID: UUID
        var continuation: CheckedContinuation<ApprovalDecision, Never>
    }

    private var continuations: [UUID: ApprovalWaiter] = [:]
    private var resolvedDecisions: [UUID: ApprovalDecision] = [:]
    private var cancelledRunIDs: Set<UUID> = []

    func suspend(runID: UUID, approvalID: UUID) async -> ApprovalDecision {
        if cancelledRunIDs.contains(runID) { return .rejected }
        if let decision = resolvedDecisions.removeValue(forKey: approvalID) { return decision }

        return await withCheckedContinuation { continuation in
            if cancelledRunIDs.contains(runID) {
                continuation.resume(returning: .rejected)
                return
            }
            if let decision = resolvedDecisions.removeValue(forKey: approvalID) {
                continuation.resume(returning: decision)
            } else {
                continuations[approvalID] = ApprovalWaiter(runID: runID, continuation: continuation)
            }
        }
    }

    func resolve(approvalID: UUID, approved: Bool) {
        let decision: ApprovalDecision = approved ? .approved : .rejected
        if let waiter = continuations.removeValue(forKey: approvalID) {
            waiter.continuation.resume(returning: decision)
        } else {
            resolvedDecisions[approvalID] = decision
        }
    }

    func cancel(runID: UUID) {
        cancelledRunIDs.insert(runID)
        let approvalIDs = continuations.compactMap { approvalID, waiter in
            waiter.runID == runID ? approvalID : nil
        }
        for approvalID in approvalIDs {
            continuations.removeValue(forKey: approvalID)?.continuation.resume(returning: .rejected)
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

private struct ToolCallSnapshot: Sendable {
    var runID: UUID
    var toolName: String
    var input: String
    var output: String
    var riskLevel: String
    var requiresApproval: Bool
    var approved: Bool
    var target: String?
    var statusCode: Int?
    var latencyMs: Double
    var errorCategory: String?
    var createdAt: Date
}

final class AgentTelemetryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let inMemoryContainer: ModelContainer?
    private let inMemoryContext: ModelContext?
    private var traces: [AgentTraceSnapshot] = []
    private var checkpoints: [AgentCheckpointSnapshot] = []
    private var toolCalls: [ToolCallSnapshot] = []

    init() {
        let schema = Schema([
            AgentTraceRecord.self,
            AgentCheckpointRecord.self,
            ToolCallRecord.self
        ])
        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            inMemoryContainer = container
            inMemoryContext = ModelContext(container)
        } catch {
            inMemoryContainer = nil
            inMemoryContext = nil
        }
    }

    func appendTrace(runID: UUID, stepIndex: Int, phase: String, message: String, toolName: String? = nil, latencyMs: Double = 0) {
        let snapshot = AgentTraceSnapshot(runID: runID, stepIndex: stepIndex, phase: phase, message: DiagnosticsRedactor.redact(message, maxLength: 600), toolName: toolName, latencyMs: latencyMs, createdAt: .now)
        lock.withLock {
            if let inMemoryContext {
                inMemoryContext.insert(AgentTraceRecord(runID: snapshot.runID, stepIndex: snapshot.stepIndex, phase: snapshot.phase, message: snapshot.message, toolName: snapshot.toolName, latencyMs: snapshot.latencyMs, createdAt: snapshot.createdAt))
            } else {
                traces.append(snapshot)
            }
        }
    }

    func appendCheckpoint(runID: UUID, nodeID: String, stateSummary: String, stateData: Data? = nil) {
        let snapshot = AgentCheckpointSnapshot(runID: runID, nodeID: nodeID, stateSummary: DiagnosticsRedactor.redact(stateSummary, maxLength: 360), stateData: stateData, createdAt: .now)
        lock.withLock {
            if let inMemoryContext {
                inMemoryContext.insert(AgentCheckpointRecord(runID: snapshot.runID, nodeID: snapshot.nodeID, stateSummary: snapshot.stateSummary, stateData: snapshot.stateData, createdAt: snapshot.createdAt))
            } else {
                checkpoints.append(snapshot)
            }
        }
    }

    func appendToolCall(runID: UUID, input: String, result: ToolResult) {
        let snapshot = ToolCallSnapshot(
            runID: runID,
            toolName: result.toolName,
            input: DiagnosticsRedactor.redact(input, maxLength: 500),
            output: DiagnosticsRedactor.redact(result.output, maxLength: 700),
            riskLevel: result.riskLevel.rawValue,
            requiresApproval: result.requiresApproval,
            approved: result.approved,
            target: DiagnosticsRedactor.redactOptional(result.target, maxLength: 160),
            statusCode: result.statusCode,
            latencyMs: result.latencyMs ?? 0,
            errorCategory: result.errorCategory,
            createdAt: .now
        )
        lock.withLock {
            if let inMemoryContext {
                inMemoryContext.insert(ToolCallRecord(runID: snapshot.runID, toolName: snapshot.toolName, input: snapshot.input, output: snapshot.output, riskLevel: snapshot.riskLevel, requiresApproval: snapshot.requiresApproval, approved: snapshot.approved, target: snapshot.target, statusCode: snapshot.statusCode, latencyMs: snapshot.latencyMs, errorCategory: snapshot.errorCategory, createdAt: snapshot.createdAt))
            } else {
                toolCalls.append(snapshot)
            }
        }
    }

    func flush(runID: UUID, to context: ModelContext) throws {
        if let inMemoryContext {
            try flushFromInMemoryContext(runID: runID, from: inMemoryContext, to: context)
            return
        }

        let payload = lock.withLock {
            let matchingTraces = traces.filter { $0.runID == runID }
            let matchingCheckpoints = checkpoints.filter { $0.runID == runID }
            let matchingToolCalls = toolCalls.filter { $0.runID == runID }
            traces.removeAll { $0.runID == runID }
            checkpoints.removeAll { $0.runID == runID }
            toolCalls.removeAll { $0.runID == runID }
            return (matchingTraces, matchingCheckpoints, matchingToolCalls)
        }

        for trace in payload.0 {
            context.insert(AgentTraceRecord(runID: trace.runID, stepIndex: trace.stepIndex, phase: trace.phase, message: trace.message, toolName: trace.toolName, latencyMs: trace.latencyMs, createdAt: trace.createdAt))
        }
        for checkpoint in payload.1 {
            context.insert(AgentCheckpointRecord(runID: checkpoint.runID, nodeID: checkpoint.nodeID, stateSummary: checkpoint.stateSummary, stateData: checkpoint.stateData, createdAt: checkpoint.createdAt))
        }
        for toolCall in payload.2 {
            context.insert(ToolCallRecord(runID: toolCall.runID, toolName: toolCall.toolName, input: toolCall.input, output: toolCall.output, riskLevel: toolCall.riskLevel, requiresApproval: toolCall.requiresApproval, approved: toolCall.approved, target: toolCall.target, statusCode: toolCall.statusCode, latencyMs: toolCall.latencyMs, errorCategory: toolCall.errorCategory, createdAt: toolCall.createdAt))
        }
        try context.safeSave()
    }

    private func flushFromInMemoryContext(runID: UUID, from sourceContext: ModelContext, to destinationContext: ModelContext) throws {
        try lock.withLock {
            let traceRecords = try sourceContext.fetch(FetchDescriptor<AgentTraceRecord>()).filter { $0.runID == runID }
            let checkpointRecords = try sourceContext.fetch(FetchDescriptor<AgentCheckpointRecord>()).filter { $0.runID == runID }
            let toolCallRecords = try sourceContext.fetch(FetchDescriptor<ToolCallRecord>()).filter { $0.runID == runID }

            for trace in traceRecords {
                destinationContext.insert(AgentTraceRecord(runID: trace.runID, stepIndex: trace.stepIndex, phase: trace.phase, message: trace.message, toolName: trace.toolName, latencyMs: trace.latencyMs, createdAt: trace.createdAt))
                sourceContext.delete(trace)
            }
            for checkpoint in checkpointRecords {
                destinationContext.insert(AgentCheckpointRecord(runID: checkpoint.runID, nodeID: checkpoint.nodeID, stateSummary: checkpoint.stateSummary, stateData: checkpoint.stateData, createdAt: checkpoint.createdAt))
                sourceContext.delete(checkpoint)
            }
            for toolCall in toolCallRecords {
                destinationContext.insert(ToolCallRecord(runID: toolCall.runID, sessionID: toolCall.sessionID, toolName: toolCall.toolName, input: toolCall.input, output: toolCall.output, riskLevel: toolCall.riskLevel, requiresApproval: toolCall.requiresApproval, approved: toolCall.approved, target: toolCall.target, payloadHash: toolCall.payloadHash, statusCode: toolCall.statusCode, latencyMs: toolCall.latencyMs, errorCategory: toolCall.errorCategory, createdAt: toolCall.createdAt))
                sourceContext.delete(toolCall)
            }
            try sourceContext.safeSave()
            try destinationContext.safeSave()
        }
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

    func run(runID: UUID = UUID(), goal: String, conversationID: UUID?, messages: [String], provider: any LLMProvider, options: AgentRuntimeOptions, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let startedAt = Date()
                var state = AgentLoopState(runID: runID, goal: goal)
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func resume(run: AgentRunRecord, provider: any LLMProvider, options: AgentRuntimeOptions? = nil, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let descriptor = FetchDescriptor<AgentCheckpointRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
                    let checkpoint = try context.fetch(descriptor).first { $0.runID == run.id && $0.stateData != nil }
                    guard let data = checkpoint?.stateData else { throw AgentRuntimeError.resumeCheckpointUnavailable }
                    var state = try JSONDecoder().decode(AgentLoopState.self, from: data)
                    run.statusRawValue = AgentRunStatus.running.rawValue
                    run.requiresApproval = false
                    run.updatedAt = .now
                    try context.safeSave()
                    try await continueRun(goal: run.goal, conversationID: run.conversationID, messages: [], provider: provider, options: options ?? AgentRuntimeOptions(autonomyLevel: AutonomyLevel(rawValue: run.autonomyLevelRawValue) ?? .assisted, maxSteps: run.maxSteps), context: context, state: &state, runRecord: run, startedAt: .now, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func continueRun(goal: String, conversationID: UUID?, messages: [String], provider: any LLMProvider, options: AgentRuntimeOptions, context: ModelContext, state: inout AgentLoopState, runRecord: AgentRunRecord, startedAt: Date, continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation) async throws {
        if needsPhase(.understandIntent, state: state) {
            try await runPhase(.understandIntent, state: &state, runRecord: runRecord, context: context, continuation: continuation) { "Intent understood: \(goal)" }
        }

        var contextPackage = try contextBuilder.build(goal: goal, messages: messages, graphState: state, toolResults: state.toolResults, context: context, phase: .retrieveContext, budget: provider.capabilities.maxContextTokens)
        if needsPhase(.retrieveContext, state: state) {
            state.retrievedContext = contextPackage.memories + contextPackage.documents
            try await runPhase(.retrieveContext, state: &state, runRecord: runRecord, context: context, continuation: continuation) { "Retrieved \(contextPackage.memories.count) memories and \(contextPackage.documents.count) document snippets." }
        }

        if needsPhase(.plan, state: state) {
            state.plan = planner.makePlan(goal: goal, contextPackage: contextPackage)
            let planMessage = state.plan?.steps.joined(separator: " -> ") ?? "No plan."
            try await runPhase(.plan, state: &state, runRecord: runRecord, context: context, continuation: continuation) { planMessage }
        }

        let tool = executor.selectedTool(for: goal)
        if needsPhase(.selectTool, state: state) {
            state.selectedToolName = tool?.name
            try await runPhase(.selectTool, state: &state, runRecord: runRecord, context: context, continuation: continuation) { tool.map { "Selected tool: \($0.name)" } ?? "No tool required." }
        }

        if let tool, needsPhase(.executeTool, state: state) {
            let metadata = tool.metadata(for: goal)
            if metadata.requiresNetwork && !options.networkToolsEnabled {
                let result = ToolResult.networkDisabled(toolName: tool.name, riskLevel: tool.riskLevel, target: metadata.targetPreview)
                state.toolResults.append(result.output)
                telemetryBuffer.appendToolCall(runID: state.runID, input: goal, result: result)
                try await runPhase(.executeTool, state: &state, runRecord: runRecord, context: context, continuation: continuation) { result.output }
                let observation = observer.observe(toolResult: result, retrievedContext: state.retrievedContext)
                state.observations.append(observation)
                try await runPhase(.observeResult, state: &state, runRecord: runRecord, context: context, continuation: continuation) { observation }
            } else {
                if requiresApproval(tool: tool, autonomyLevel: options.autonomyLevel) {
                    let decision = try await requestApprovalIfNeeded(tool: tool, goal: goal, options: options, state: &state, runRecord: runRecord, context: context, continuation: continuation)
                    guard decision == .approved else {
                        state.status = .failed
                        state.finalResponse = "I did not run \(tool.name) because approval was rejected or expired."
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
                let result = try await executor.execute(goal: goal, runID: state.runID, autonomyLevel: options.autonomyLevel, approved: true, networkAccessAllowed: options.networkToolsEnabled, context: context)
                if let result {
                    state.toolResults.append(result.output)
                    telemetryBuffer.appendToolCall(runID: state.runID, input: goal, result: result)
                }
                try await runPhase(.executeTool, state: &state, runRecord: runRecord, context: context, continuation: continuation) { result?.output ?? "Tool produced no output." }
                let observation = observer.observe(toolResult: result, retrievedContext: state.retrievedContext)
                state.observations.append(observation)
                try await runPhase(.observeResult, state: &state, runRecord: runRecord, context: context, continuation: continuation) { observation }
            }
        }

        if needsPhase(.reflect, state: state) {
            state.reflection = reflector.reflect(goal: goal, plan: state.plan, observations: state.observations)
            let reflectionMessage = state.reflection
            try await runPhase(.reflect, state: &state, runRecord: runRecord, context: context, continuation: continuation) { reflectionMessage }
        }

        contextPackage = try contextBuilder.build(goal: goal, messages: messages, graphState: state, toolResults: state.toolResults, context: context, phase: .reflect, budget: provider.capabilities.maxContextTokens)
        if needsPhase(.respond, state: state) {
            if Date().timeIntervalSince(startedAt) > options.timeoutSeconds { throw AgentRuntimeError.timedOut }
            let response = try await responseText(goal: goal, state: state, provider: provider, contextPackage: contextPackage)
            var accumulated = ""
            for word in response.split(separator: " ") {
                try Task.checkCancellation()
                accumulated += word + " "
                continuation.yield(.partialResponse(runID: state.runID, text: accumulated))
            }
            state.finalResponse = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            let responseMessage = state.finalResponse
            try await runPhase(.respond, state: &state, runRecord: runRecord, context: context, continuation: continuation) { responseMessage }
        }

        if state.plan?.shouldRemember == true, state.selectedToolName != "memory_save", needsPhase(.saveMemory, state: state) {
            let memory = durableMemory(from: goal, state: state)
            try contextBuilder.memoryService.save(content: memory, source: "agentRun:\(state.runID.uuidString)", scope: "longTerm", context: context)
            try await runPhase(.saveMemory, state: &state, runRecord: runRecord, context: context, continuation: continuation) { "Saved memory: \(memory)" }
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

    private func runPhase(_ phase: AgentPhase, state: inout AgentLoopState, runRecord: AgentRunRecord, context: ModelContext, continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation, message: () -> String) async throws {
        try Task.checkCancellation()
        if runRecord.statusRawValue == AgentRunStatus.cancelled.rawValue { throw AgentRuntimeError.cancelled }
        if runRecord.statusRawValue == AgentRunStatus.paused.rawValue { throw AgentRuntimeError.paused }
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
        if !state.completedNodeIDs.contains(phase.rawValue) { state.completedNodeIDs.append(phase.rawValue) }
        telemetryBuffer.appendTrace(runID: state.runID, stepIndex: state.stepIndex, phase: phase.rawValue, message: text)
        try recordCheckpoint(state: state, nodeID: phase.rawValue, context: context, includeStateData: true)
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

    private func requestApprovalIfNeeded(tool: any Tool, goal: String, options: AgentRuntimeOptions, state: inout AgentLoopState, runRecord: AgentRunRecord, context: ModelContext, continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation) async throws -> ApprovalDecision {
        if let approval = try approvalRecord(runID: state.runID, toolName: tool.name, context: context) {
            if approval.isExpired() {
                try markApprovalExpired(approval, context: context)
                return .rejected
            }
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
            if runRecord.statusRawValue == AgentRunStatus.cancelled.rawValue { throw AgentRuntimeError.cancelled }
            runRecord.requiresApproval = false
            runRecord.updatedAt = .now
            if decision == .approved {
                state.status = .running
                runRecord.statusRawValue = state.status.rawValue
                try context.safeSave()
            }
            return decision
        }

        let metadata = tool.metadata(for: goal)
        let target = metadata.targetPreview
        let reason = approvalReason(tool: tool, goal: goal, autonomyLevel: options.autonomyLevel, metadata: metadata)
        let approval = ApprovalRequestRecord(
            runID: state.runID,
            actionName: tool.name,
            reason: reason,
            sessionID: state.runID,
            toolName: tool.name,
            target: target,
            normalizedArgumentsJSON: ApprovalTupleHasher.normalizedArguments(toolName: tool.name, input: goal, target: target),
            riskLevelRawValue: tool.riskLevel.rawValue,
            userVisibleDiff: approvalUserVisibleDiff(tool: tool, goal: goal, metadata: metadata)
        )
        context.insert(approval)

        state.status = .waitingForApproval
        runRecord.statusRawValue = state.status.rawValue
        runRecord.requiresApproval = true
        runRecord.updatedAt = .now
        try await runPhase(.askUser, state: &state, runRecord: runRecord, context: context, continuation: continuation) { "Approval requested for \(tool.name): \(approval.reason)" }
        try recordCheckpoint(state: state, nodeID: AgentPhase.askUser.rawValue, context: context, includeStateData: true)
        try telemetryBuffer.flush(runID: state.runID, to: context)

        continuation.yield(.approvalRequired(runID: state.runID, approvalID: approval.id, toolName: tool.name, reason: approval.reason))
        let decision = await approvalGate.suspend(runID: state.runID, approvalID: approval.id)
        if runRecord.statusRawValue == AgentRunStatus.cancelled.rawValue { throw AgentRuntimeError.cancelled }
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
        let descriptor = FetchDescriptor<ApprovalRequestRecord>(
            predicate: #Predicate { record in
                record.runID == runID && record.actionName == toolName
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first
    }

    private func markApprovalExpired(_ approval: ApprovalRequestRecord, context: ModelContext) throws {
        approval.approved = false
        approval.resolvedAt = .now
        try context.safeSave()
        Task { await approvalGate.resolve(approvalID: approval.id, approved: false) }
    }

    private func approvalReason(tool: any Tool, goal: String, autonomyLevel: AutonomyLevel, metadata: ToolExecutionMetadata? = nil) -> String {
        let metadata = metadata ?? tool.metadata(for: goal)
        var details = ["\(tool.name) is \(tool.riskLevel.rawValue) risk or current autonomy is \(autonomyLevel.label)."]
        if let action = metadata.actionPreview, !action.isEmpty { details.append("Action: \(action).") }
        if let target = metadata.targetPreview, !target.isEmpty { details.append("Target: \(target).") }
        if metadata.requiresNetwork { details.append("Requires network access.") }
        return details.joined(separator: " ")
    }

    private func approvalUserVisibleDiff(tool: any Tool, goal: String, metadata: ToolExecutionMetadata) -> String {
        let action = metadata.actionPreview ?? "Run \(tool.name)"
        let target = metadata.targetPreview ?? "local"
        return "\(action). Target: \(target). Input: \(DiagnosticsRedactor.redact(goal, maxLength: 180))"
    }

    private func responseText(goal: String, state: AgentLoopState, provider: any LLMProvider, contextPackage: ContextPackage) async throws -> String {
        if let toolOutput = state.toolResults.last { return UserFacingResponseSanitizer.sanitize(toolOutput) }
        let request = LLMRequest(prompt: contextPackage.prompt, conversationContext: [goal], retrievedContext: state.retrievedContext)
        let response = try await provider.complete(request: request)
        return UserFacingResponseSanitizer.sanitize(response.text)
    }

    private func durableMemory(from goal: String, state: AgentLoopState) -> String {
        if let toolOutput = state.toolResults.last, !toolOutput.isEmpty { return "From goal '\(goal)': \(toolOutput)" }
        return "From goal '\(goal)': \(state.finalResponse)"
    }

    private func requiresApproval(tool: any Tool, autonomyLevel: AutonomyLevel) -> Bool {
        ToolApprovalPolicy.requiresApproval(tool: tool, autonomyLevel: autonomyLevel)
    }

    private func finishFailure(_ status: AgentRunStatus, state: AgentLoopState, runRecord: AgentRunRecord, context: ModelContext, continuation: AsyncThrowingStream<AgentRuntimeEvent, Error>.Continuation) {
        runRecord.statusRawValue = status.rawValue
        runRecord.lastError = error(for: status).localizedDescription
        runRecord.completedAt = status == .paused ? nil : .now
        runRecord.updatedAt = .now
        try? recordCheckpoint(state: state, nodeID: status.rawValue, context: context, includeStateData: true)
        try? telemetryBuffer.flush(runID: state.runID, to: context)
        continuation.finish(throwing: error(for: status))
    }

    private func error(for status: AgentRunStatus) -> AgentRuntimeError {
        switch status {
        case .paused: return .paused
        case .timedOut: return .timedOut
        case .maxStepsReached: return .maxStepsReached
        default: return .cancelled
        }
    }
}

enum UserFacingResponseSanitizer {
    private static let internalHeadings = ["Assistant Reflection", "Final Decision", "Output Formatting", "Local Context", "Action", "Conclusion"]

    static func sanitize(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = extractAssistantResponse(from: cleaned)
        cleaned = removeInternalSections(from: cleaned)
        cleaned = cleaned
            .replacingOccurrences(of: #"(?m)^\s*\*\*Response:\*\*\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*Response:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*Reflection:\s*.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.localizedCaseInsensitiveContains("reflect phase") || cleaned.localizedCaseInsensitiveContains("output formatting valid") {
            return "I could not produce a useful local answer for that request."
        }
        return cleaned.isEmpty ? "I could not produce a useful local answer for that request." : cleaned
    }

    private static func extractAssistantResponse(from text: String) -> String {
        let markers = ["**Assistant Response:**", "Assistant Response:"]
        for marker in markers {
            guard let markerRange = text.range(of: marker, options: [.caseInsensitive]) else { continue }
            return String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func removeInternalSections(from text: String) -> String {
        var cleaned = text
        for heading in internalHeadings {
            let escaped = NSRegularExpression.escapedPattern(for: heading)
            cleaned = cleaned.replacingOccurrences(of: #"(?is)\n?\s*\*\*\#(escaped):\*\*.*?(?=\n\s*\*\*[^*]+:\*\*|\z)"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"(?is)\n?\s*\#(escaped):.*?(?=\n\s*[^:\n]{2,60}:|\z)"#, with: "", options: .regularExpression)
        }
        return cleaned
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
        loop = AgentLoop(planner: planner, executor: executor, observer: observer, reflector: reflector, contextBuilder: contextBuilder, approvalGate: approvalGate, telemetryBuffer: telemetryBuffer)
    }

    func run(goal: String, conversationID: UUID?, messages: [String], provider: any LLMProvider, options: AgentRuntimeOptions, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        let runID = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await event in loop.run(runID: runID, goal: goal, conversationID: conversationID, messages: messages, provider: provider, options: options, context: context) { continuation.yield(event) }
                    runningTasks[runID] = nil
                    continuation.finish()
                } catch {
                    runningTasks[runID] = nil
                    continuation.finish(throwing: error)
                }
            }
            runningTasks[runID] = task
            continuation.onTermination = { @Sendable _ in Task { @MainActor in self.runningTasks[runID]?.cancel(); self.runningTasks[runID] = nil } }
        }
    }

    func resume(run: AgentRunRecord, provider: any LLMProvider, options: AgentRuntimeOptions? = nil, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let runID = run.id
            let task = Task { @MainActor in
                do {
                    for try await event in loop.resume(run: run, provider: provider, options: options, context: context) { continuation.yield(event) }
                    runningTasks[runID] = nil
                    continuation.finish()
                } catch {
                    runningTasks[runID] = nil
                    continuation.finish(throwing: error)
                }
            }
            runningTasks[runID] = task
            continuation.onTermination = { @Sendable _ in Task { @MainActor in self.runningTasks[runID]?.cancel(); self.runningTasks[runID] = nil } }
        }
    }

    func pause(run: AgentRunRecord, context: ModelContext) throws {
        try telemetryBuffer.flush(runID: run.id, to: context)
        run.statusRawValue = AgentRunStatus.paused.rawValue
        run.requiresApproval = false
        run.updatedAt = .now
        context.insert(AgentTraceRecord(runID: run.id, stepIndex: run.currentStep, phase: run.currentPhase, message: "Run paused by user."))
        context.insert(AgentCheckpointRecord(runID: run.id, nodeID: AgentRunStatus.paused.rawValue, stateSummary: "Paused at \(run.currentPhase) step \(run.currentStep)."))
        try context.safeSave()
    }

    func cancel(run: AgentRunRecord, context: ModelContext) throws {
        runningTasks[run.id]?.cancel()
        runningTasks[run.id] = nil
        try telemetryBuffer.flush(runID: run.id, to: context)
        run.statusRawValue = AgentRunStatus.cancelled.rawValue
        run.requiresApproval = false
        run.lastError = AgentRuntimeError.cancelled.localizedDescription
        run.completedAt = .now
        run.updatedAt = .now
        Task { await approvalGate.cancel(runID: run.id) }
        let descriptor = FetchDescriptor<ApprovalRequestRecord>(predicate: #Predicate { approval in
            approval.runID == run.id && approval.approved == nil
        })
        let pendingApprovals = try context.fetch(descriptor)
        for approval in pendingApprovals {
            approval.approved = false
            approval.resolvedAt = .now
            Task { await approvalGate.resolve(approvalID: approval.id, approved: false) }
        }
        context.insert(AgentTraceRecord(runID: run.id, stepIndex: run.currentStep, phase: run.currentPhase, message: "Run cancelled by user."))
        context.insert(AgentCheckpointRecord(runID: run.id, nodeID: AgentRunStatus.cancelled.rawValue, stateSummary: "Cancelled at \(run.currentPhase) step \(run.currentStep)."))
        try context.safeSave()
    }

    func approve(_ approval: ApprovalRequestRecord, context: ModelContext) throws {
        guard !approval.isExpired() else {
            approval.approved = false
            approval.resolvedAt = .now
            try context.safeSave()
            Task { await approvalGate.resolve(approvalID: approval.id, approved: false) }
            throw AgentRuntimeError.approvalExpired(approval.toolName)
        }
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
        let descriptor = FetchDescriptor<ApprovalRequestRecord>(predicate: #Predicate { approval in
            approval.id == approvalID
        })
        guard let approval = try context.fetch(descriptor).first else { throw AgentRuntimeError.approvalNotFound }
        try approve(approval, context: context)
    }

    func reject(approvalID: UUID, context: ModelContext) throws {
        let descriptor = FetchDescriptor<ApprovalRequestRecord>(predicate: #Predicate { approval in
            approval.id == approvalID
        })
        guard let approval = try context.fetch(descriptor).first else { throw AgentRuntimeError.approvalNotFound }
        try reject(approval, context: context)
    }
}
