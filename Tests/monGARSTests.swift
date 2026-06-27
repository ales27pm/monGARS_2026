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
        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired(_, let toolName, _) = event {
                approvalToolName = toolName
            }
        }

        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        let memories = try context.fetch(FetchDescriptor<MemoryRecord>())
        #expect(approvalToolName == "memory_delete")
        #expect(approvals.count == 1)
        #expect(memories.count == 1)
    }

    @Test func contextBuilderHonorsBudget() throws {
        let (container, context) = makeContext()
        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        let state = AgentLoopState(runID: UUID(), goal: "privacy")
        let package = try builder.build(goal: "privacy", messages: Array(repeating: "long message", count: 200), graphState: state, toolResults: [], context: context, budget: 80)
        #expect(package.prompt.count <= 340)
    }

    @Test func providerFallbackReportsLocalCapabilities() async {
        let provider = FoundationModelProvider(fallback: MockLLMProvider())
        #expect(provider.capabilities.isLocal)
        let status = await provider.status
        #expect(status.contains("FoundationModels") || status.contains("fallback"))
    }
}
