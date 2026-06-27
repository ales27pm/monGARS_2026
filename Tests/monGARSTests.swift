import Foundation
import SwiftData
import Testing
@testable import monGARS

@MainActor
struct MonGARSTests {
    private func makeContext() -> (AppContainer, ModelContext) {
        let container = AppContainer(inMemory: true)
        return (container, ModelContext(container.modelContainer))
    }

    @Test func memorySearchFindsSavedFacts() throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "My preferred city is Montreal.", context: context)
        try container.memoryService.save(content: "My preferred city is Montreal.", context: context)
        let results = try container.memoryService.search(query: "city Montreal", context: context)
        #expect(results.count == 1)
        #expect(results.first?.content.contains("Montreal") == true)
        #expect((results.first?.importance ?? 0) > 0.5)
    }

    @Test func memoryEditExportAndForgetAllWork() throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Remember that my planning window is Friday morning.", context: context)
        let saved = try #require(try context.fetch(FetchDescriptor<MemoryRecord>()).first)

        try container.memoryService.edit(saved, content: "Remember that my planning window is Monday morning.", context: context)
        let export = try container.memoryService.exportText(context: context)
        #expect(export.contains("Monday morning"))
        #expect(saved.tags.contains("remember"))

        let deleted = try container.memoryService.forgetAll(context: context)
        let remaining = try context.fetch(FetchDescriptor<MemoryRecord>())
        #expect(deleted == 1)
        #expect(remaining.isEmpty)
    }

    @Test func toolRouterChoosesCalculator() async throws {
        let (container, context) = makeContext()
        let result = try await container.toolRouter.execute(input: "calculate 2 + 3", context: context)
        #expect(result?.toolName == "calculator")
        #expect(result?.output.contains("5") == true)
    }

    @Test func graphRecordsCheckpoints() async throws {
        let (container, context) = makeContext()
        let execution = AgentExecutionContext(
            llmProvider: MockLLMProvider(),
            toolRouter: container.toolRouter,
            context: context,
            event: { _ in }
        )

        for try await _ in container.agentGraph.run(input: "What time is it?", messages: [], context: execution) {}

        let records = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        #expect(records.contains { $0.nodeID == "route" })
        #expect(records.contains { $0.nodeID == "tool" })
        #expect(records.contains { $0.nodeID == "respond" })
    }

    @Test func checkpointResumeCompletesResponse() async throws {
        let (container, context) = makeContext()
        let execution = AgentExecutionContext(
            llmProvider: MockLLMProvider(),
            toolRouter: container.toolRouter,
            context: context,
            event: { _ in }
        )

        let state = AgentState(userInput: "calculate 4 * 5", selectedToolName: "calculator")
        let checkpoint = AgentCheckpoint(runID: state.runID, nodeID: "route", summary: state.summary, state: state)
        let resumed = try await container.agentGraph.resume(from: checkpoint, context: execution)
        #expect(resumed.finalResponse.contains("20"))
    }

    @Test func persistenceModelsSaveConversation() throws {
        let (_, context) = makeContext()
        let conversation = Conversation(title: "Test")
        conversation.messages.append(ChatMessage(role: .user, content: "Hello"))
        context.insert(conversation)
        try context.save()

        let conversations = try context.fetch(FetchDescriptor<Conversation>())
        #expect(conversations.count == 1)
        #expect(conversations.first?.messages.first?.content == "Hello")
    }

    @Test func autonomousRuntimeCompletesAndPersistsTrace() async throws {
        let (container, context) = makeContext()
        var finalResponse = ""
        for try await event in container.agentRuntime.run(
            goal: "summarize my imported document and remember key points",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .semiAuto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .completed(_, let response) = event {
                finalResponse = response
            }
        }

        let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
        let traces = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        let memories = try context.fetch(FetchDescriptor<MemoryRecord>())
        #expect(runs.first?.statusRawValue == AgentRunStatus.completed.rawValue)
        #expect(traces.contains { $0.phase == AgentPhase.plan.rawValue })
        #expect(traces.contains { $0.phase == AgentPhase.reflect.rawValue })
        #expect(memories.contains { $0.source.contains("agentRun") })
        #expect(!finalResponse.isEmpty)
    }

    @Test func autonomousRuntimePersistsMaxStepStop() async throws {
        let (container, context) = makeContext()

        do {
            for try await _ in container.agentRuntime.run(
                goal: "summarize my imported document and remember key points",
                conversationID: nil,
                messages: [],
                provider: MockLLMProvider(),
                options: AgentRuntimeOptions(autonomyLevel: .semiAuto, maxSteps: 2, timeoutSeconds: 20),
                context: context
            ) {}
        } catch {
            #expect(error.localizedDescription == AgentRuntimeError.maxStepsReached.localizedDescription)
        }

        let run = try #require(try context.fetch(FetchDescriptor<AgentRunRecord>()).first)
        #expect(run.statusRawValue == AgentRunStatus.maxStepsReached.rawValue)
        #expect(run.lastError == AgentRuntimeError.maxStepsReached.localizedDescription)
    }

    @Test func approvalGateBlocksDestructiveMemoryDelete() async throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Keep this important memory.", context: context)

        var approvalToolName: String?
        var approvalRunID: UUID?
        var completedResponse = ""
        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired(let runID, let approvalID, let toolName, _) = event {
                approvalToolName = toolName
                approvalRunID = runID
                let memoriesBeforeApproval = try context.fetch(FetchDescriptor<MemoryRecord>())
                #expect(memoriesBeforeApproval.count == 1)
                try container.agentRuntime.approve(approvalID: approvalID, context: context)
            }
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        let memories = try context.fetch(FetchDescriptor<MemoryRecord>())
        let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
        let traces = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        #expect(approvalToolName == "memory_delete")
        #expect(approvalRunID != nil)
        #expect(approvals.count == 1)
        #expect(approvals.first?.approved == true)
        #expect(memories.isEmpty)
        #expect(runs.count == 1)
        #expect(runs.first?.statusRawValue == AgentRunStatus.completed.rawValue)
        #expect(traces.contains { $0.phase == AgentPhase.askUser.rawValue })
        #expect(traces.contains { $0.phase == AgentPhase.executeTool.rawValue })
        #expect(completedResponse.contains("Deleted"))
    }

    @Test func approvalRejectionDoesNotExecuteDestructiveTool() async throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Keep this important memory.", context: context)

        var completedResponse = ""
        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired(_, let approvalID, _, _) = event {
                try container.agentRuntime.reject(approvalID: approvalID, context: context)
            }
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        let memories = try context.fetch(FetchDescriptor<MemoryRecord>())
        let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
        let toolCalls = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(approvals.first?.approved == false)
        #expect(memories.count == 1)
        #expect(runs.first?.statusRawValue == AgentRunStatus.failed.rawValue)
        #expect(toolCalls.isEmpty)
        #expect(completedResponse.contains("approval was rejected"))
    }

    @Test func resumeWaitingForApprovalDoesNotDuplicateApproval() async throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Temporary memory.", context: context)

        var state = AgentLoopState(runID: UUID(), goal: "forget all memories")
        state.phase = .askUser
        state.stepIndex = 5
        state.completedNodeIDs = [
            AgentPhase.understandIntent.rawValue,
            AgentPhase.retrieveContext.rawValue,
            AgentPhase.plan.rawValue,
            AgentPhase.selectTool.rawValue,
            AgentPhase.askUser.rawValue
        ]
        state.selectedToolName = "memory_delete"
        let stateData = try JSONEncoder().encode(state)

        let run = AgentRunRecord(
            id: state.runID,
            goal: state.goal,
            statusRawValue: AgentRunStatus.waitingForApproval.rawValue,
            autonomyLevelRawValue: AutonomyLevel.auto.rawValue,
            currentPhase: AgentPhase.askUser.rawValue,
            currentStep: state.stepIndex,
            maxSteps: 12,
            requiresApproval: true
        )
        let approval = ApprovalRequestRecord(
            runID: state.runID,
            actionName: "memory_delete",
            reason: "memory_delete is destructive risk or current autonomy is Auto."
        )
        context.insert(run)
        context.insert(approval)
        context.insert(AgentCheckpointRecord(runID: state.runID, nodeID: AgentPhase.askUser.rawValue, stateSummary: state.summary, stateData: stateData))
        try context.save()

        var completedResponse = ""
        for try await event in container.agentRuntime.resume(run: run, provider: MockLLMProvider(), context: context) {
            if case .approvalRequired(_, let approvalID, _, _) = event {
                try container.agentRuntime.approve(approvalID: approvalID, context: context)
            }
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        let toolCalls = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(approvals.count == 1)
        #expect(approvals.first?.approved == true)
        #expect(toolCalls.count == 1)
        #expect(completedResponse.contains("Deleted"))
    }

    @Test func contextBuilderHonorsBudget() throws {
        let (container, context) = makeContext()
        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        let state = AgentLoopState(runID: UUID(), goal: "privacy")
        let package = try builder.build(goal: "privacy", messages: Array(repeating: "long message", count: 200), graphState: state, toolResults: [], context: context, budget: 80)
        #expect(package.prompt.count <= 340)
        #expect(package.prompt.contains("Final instructions:"))
    }

    @Test func contextBuilderPrioritizesToolSchemaDuringExecute() throws {
        let (container, context) = makeContext()
        context.insert(DocumentRecord(title: "Large.md", content: "RAW_DOCUMENT_CONTENT_SHOULD_BE_DROPPED " + String(repeating: "document ", count: 200)))
        try context.save()

        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        var state = AgentLoopState(runID: UUID(), goal: "calculate")
        state.selectedToolName = "calculator"
        let schema = ToolSchema(inputDescription: "A precise arithmetic expression.", examples: ["calculate 2 + 2"])
        let package = try builder.build(
            goal: "calculate 2 + 2",
            messages: Array(repeating: "chat filler", count: 80),
            graphState: state,
            toolResults: [],
            context: context,
            phase: .executeTool,
            selectedToolName: "calculator",
            selectedToolSchema: schema,
            budget: 100
        )

        #expect(package.documents.isEmpty)
        #expect(!package.prompt.contains("RAW_DOCUMENT_CONTENT_SHOULD_BE_DROPPED"))
        #expect(package.prompt.contains("Tool schema: A precise arithmetic expression."))
        #expect(package.prompt.contains("Final instructions:"))
    }

    @Test func contextBuilderUsesSummaryDuringReflection() throws {
        let (container, context) = makeContext()
        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        var state = AgentLoopState(runID: UUID(), goal: "reflect")
        state.observations = ["Observation: local tool succeeded."]
        let messages = (0..<80).map { "raw message \($0) SHOULD_NOT_ALL_APPEAR" }
        let package = try builder.build(goal: "reflect", messages: messages, graphState: state, toolResults: ["tool result"], context: context, phase: .reflect, budget: 160)
        #expect(package.prompt.contains("Conversation summary:"))
        #expect(package.prompt.contains("Observation: local tool succeeded."))
        #expect(!package.prompt.contains("raw message 0 SHOULD_NOT_ALL_APPEAR"))
    }

    @Test func checkpointsReducePayloadExceptApprovalPause() async throws {
        let (container, context) = makeContext()
        for try await _ in container.agentRuntime.run(
            goal: "calculate 2 + 3",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .semiAuto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {}

        let lowRiskCheckpoints = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        #expect(!lowRiskCheckpoints.isEmpty)
        #expect(lowRiskCheckpoints.allSatisfy { $0.stateData == nil })

        try container.memoryService.save(content: "Temporary memory.", context: context)
        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired(_, let approvalID, _, _) = event {
                try container.agentRuntime.reject(approvalID: approvalID, context: context)
            }
        }

        let allCheckpoints = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        #expect(allCheckpoints.contains { $0.nodeID == AgentPhase.askUser.rawValue && $0.stateData != nil })
    }

    @Test func providerFallbackReportsLocalCapabilities() async {
        let provider = FoundationModelProvider(fallback: MockLLMProvider())
        #expect(provider.capabilities.isLocal)
        let status = await provider.status
        #expect(status.contains("FoundationModels") || status.contains("fallback"))
    }
}
