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

struct AgentLoop: Sendable {
    let planner: AgentPlanner
    let executor: AgentExecutor
    let observer: AgentObserver
    let reflector: AgentReflector
    let contextBuilder: ContextBuilder

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
                let runRecord = AgentRunRecord(
                    id: state.runID,
                    conversationID: conversationID,
                    goal: goal,
                    autonomyLevelRawValue: options.autonomyLevel.rawValue,
                    maxSteps: options.maxSteps
                )
                context.insert(runRecord)

                do {
                    try context.safeSave()
                    try await runPhase(.understandIntent, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                        "Intent understood: \(goal)"
                    }

                    let contextPackage = try contextBuilder.build(goal: goal, messages: messages, graphState: state, toolResults: state.toolResults, context: context, budget: provider.capabilities.maxContextTokens)
                    state.retrievedContext = contextPackage.memories + contextPackage.documents
                    try await runPhase(.retrieveContext, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                        "Retrieved \(contextPackage.memories.count) memories and \(contextPackage.documents.count) document snippets."
                    }

                    state.plan = planner.makePlan(goal: goal, contextPackage: contextPackage)
                    let planMessage = state.plan?.steps.joined(separator: " -> ") ?? "No plan."
                    try await runPhase(.plan, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                        planMessage
                    }

                    let tool = executor.selectedTool(for: goal)
                    state.selectedToolName = tool?.name
                    try await runPhase(.selectTool, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                        tool.map { "Selected tool: \($0.name)" } ?? "No tool required."
                    }

                    if let tool {
                        if requiresApproval(tool: tool, autonomyLevel: options.autonomyLevel) {
                            state.status = .waitingForApproval
                            runRecord.statusRawValue = state.status.rawValue
                            runRecord.requiresApproval = true
                            let reason = "\(tool.name) is \(tool.riskLevel.rawValue) risk or current autonomy is \(options.autonomyLevel.label)."
                            context.insert(ApprovalRequestRecord(runID: state.runID, actionName: tool.name, reason: reason))
                            try recordCheckpoint(state: state, nodeID: AgentPhase.askUser.rawValue, context: context)
                            try context.safeSave()
                            continuation.yield(.approvalRequired(runID: state.runID, toolName: tool.name, reason: reason))
                            continuation.finish()
                            return
                        }

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

                    state.reflection = reflector.reflect(goal: goal, plan: state.plan, observations: state.observations)
                    let reflectionMessage = state.reflection
                    try await runPhase(.reflect, state: &state, runRecord: runRecord, context: context, continuation: continuation) {
                        reflectionMessage
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

                    if state.plan?.shouldRemember == true {
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
                    try context.safeSave()
                    continuation.yield(.completed(runID: state.runID, response: state.finalResponse))
                    continuation.finish()
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
                        try? context.safeSave()
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    func resume(run: AgentRunRecord, provider: any LLMProvider, context: ModelContext) -> AsyncThrowingStream<AgentRuntimeEvent, Error> {
        run.statusRawValue = AgentRunStatus.running.rawValue
        run.requiresApproval = false
        run.updatedAt = .now
        try? context.safeSave()
        return self.run(goal: run.goal, conversationID: run.conversationID, messages: [], provider: provider, options: AgentRuntimeOptions(autonomyLevel: AutonomyLevel(rawValue: run.autonomyLevelRawValue) ?? .assisted, maxSteps: run.maxSteps), context: context)
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
        context.insert(AgentTraceRecord(runID: state.runID, stepIndex: state.stepIndex, phase: phase.rawValue, message: text))
        try recordCheckpoint(state: state, nodeID: phase.rawValue, context: context)
        try context.safeSave()
        continuation.yield(.status(runID: state.runID, phase: phase, message: phase.statusText))
        continuation.yield(.trace(runID: state.runID, phase: phase, message: text))
    }

    private func recordCheckpoint(state: AgentLoopState, nodeID: String, context: ModelContext) throws {
        let data = try? JSONEncoder().encode(state)
        context.insert(AgentCheckpointRecord(runID: state.runID, nodeID: nodeID, stateSummary: state.summary, stateData: data))
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
        try? context.safeSave()
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
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    init(planner: AgentPlanner, executor: AgentExecutor, observer: AgentObserver, reflector: AgentReflector, contextBuilder: ContextBuilder) {
        loop = AgentLoop(planner: planner, executor: executor, observer: observer, reflector: reflector, contextBuilder: contextBuilder)
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
        try context.safeSave()
    }

    func approve(_ approval: ApprovalRequestRecord, context: ModelContext) throws {
        approval.approved = true
        approval.resolvedAt = .now
        try context.safeSave()
    }

    func reject(_ approval: ApprovalRequestRecord, context: ModelContext) throws {
        approval.approved = false
        approval.resolvedAt = .now
        try context.safeSave()
    }
}
