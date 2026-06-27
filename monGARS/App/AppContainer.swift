import Foundation
import SwiftData

@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let settingsStore: SettingsStore
    let memoryService: MemoryService
    let documentService: DocumentService
    let toolRegistry: ToolRegistry
    let toolRouter: ToolRouter
    let agentGraph: AgentGraph
    let agentRuntime: AgentRuntime
    let speechService: SpeechService

    var diagnostics = DiagnosticsStore()

    init(inMemory: Bool = false) {
        let schema = Schema(Self.schemaModels)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create SwiftData container: \(error)")
        }

        settingsStore = SettingsStore()
        memoryService = MemoryService()
        documentService = DocumentService()
        toolRegistry = ToolRegistry.defaultRegistry(memoryService: memoryService, documentService: documentService)
        toolRouter = ToolRouter(registry: toolRegistry)
        speechService = AppleSpeechService()
        agentGraph = AgentGraph.makeDefault(toolRouter: toolRouter)
        agentRuntime = AgentRuntime(
            planner: AgentPlanner(),
            executor: AgentExecutor(toolRouter: toolRouter),
            observer: AgentObserver(),
            reflector: AgentReflector(),
            contextBuilder: ContextBuilder(memoryService: memoryService, documentService: documentService)
        )
    }

    static let schemaModels: [any PersistentModel.Type] = [
        Conversation.self,
        ChatMessage.self,
        MemoryRecord.self,
        DocumentRecord.self,
        AgentCheckpointRecord.self,
        AgentRunRecord.self,
        AgentTraceRecord.self,
        ToolCallRecord.self,
        ApprovalRequestRecord.self,
        AgentTaskRecord.self
    ]

    func llmProvider() -> any LLMProvider {
        switch settingsStore.providerMode {
        case .foundation:
            return FoundationModelProvider(fallback: MockLLMProvider())
        case .mock:
            return MockLLMProvider()
        case .remote:
            return RemoteLLMProvider(endpoint: settingsStore.remoteEndpoint, isEnabled: settingsStore.remoteProviderEnabled)
        }
    }

    func seedIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<Conversation>()
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        guard existing == 0 else { return }

        let conversation = Conversation(title: "Welcome")
        conversation.messages.append(ChatMessage(role: .assistant, content: "Hi, I am monGARS. Ask me for the time, a calculation, a saved memory, or a document summary."))
        context.insert(conversation)
        context.insert(MemoryRecord(content: "monGARS keeps chat, memories, and documents local by default.", tags: ["privacy", "local"]))
        context.insert(DocumentRecord(title: "Sample Notes.md", content: "monGARS is a local-first SwiftUI assistant with tool routing, memory search, and document retrieval."))
        context.insert(AgentTaskRecord(title: "Try the autonomous document summary flow", notes: "Import a Markdown file, then ask monGARS to summarize it and remember key points."))
        try? context.save()
    }
}
