import Foundation
import SwiftData

@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let settingsStore: SettingsStore
    let memoryService: MemoryService
    let documentService: DocumentService
    let repoSelfModelService: RepoSelfModelService
    let toolRegistry: ToolRegistry
    let toolRouter: ToolRouter
    let agentGraph: AgentGraph
    let agentRuntime: AgentRuntime
    let speechService: SpeechService

    var diagnostics = DiagnosticsStore()
    private(set) var persistenceRecoveryMessage: String?

    init(inMemory: Bool = false) {
        let schema = Schema(Self.schemaModels)
        let containerResult = Self.makeModelContainer(schema: schema, inMemory: inMemory)
        modelContainer = containerResult.container
        persistenceRecoveryMessage = containerResult.recoveryMessage

        settingsStore = SettingsStore()
        memoryService = MemoryService()
        documentService = DocumentService()
        repoSelfModelService = RepoSelfModelService()
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
        diagnostics.lastError = persistenceRecoveryMessage
    }

    static let schemaModels: [any PersistentModel.Type] = [
        Conversation.self,
        ChatMessage.self,
        MemoryRecord.self,
        DocumentRecord.self,
        DocumentChunkRecord.self,
        AgentCheckpointRecord.self,
        AgentRunRecord.self,
        AgentTraceRecord.self,
        ToolCallRecord.self,
        ApprovalRequestRecord.self,
        AgentTaskRecord.self,
        RepoIndexRecord.self,
        RepoSymbolRecord.self
    ]

    func llmProvider() -> any LLMProvider {
        switch settingsStore.providerMode {
        case .foundation:
            return FoundationModelProvider(fallback: MockLLMProvider())
        case .mock:
            return MockLLMProvider()
        case .remote:
            return RemoteLLMProvider(
                endpoint: settingsStore.remoteEndpoint,
                isEnabled: settingsStore.remoteProviderEnabled,
                model: settingsStore.remoteModel,
                apiKey: settingsStore.remoteAPIKey,
                client: AppNetworkConfiguration.client()
            )
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
        let sampleDocument = DocumentRecord(title: "Sample Notes.md", content: "monGARS is a local-first SwiftUI assistant with tool routing, memory search, and document retrieval.")
        context.insert(sampleDocument)
        try? documentService.rebuildChunks(for: sampleDocument, context: context)
        context.insert(AgentTaskRecord(title: "Try the autonomous document summary flow", notes: "Import a Markdown file, then ask monGARS to summarize it and remember key points."))
        try? context.save()
    }

    private static func makeModelContainer(schema: Schema, inMemory: Bool) -> (container: ModelContainer, recoveryMessage: String?) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return (try ModelContainer(for: schema, configurations: [configuration]), nil)
        } catch {
            guard !inMemory else {
                return makeInMemoryFallback(schema: schema, originalError: error)
            }

            let recovery = quarantineDefaultStoreFiles()
            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let message = "Recovered local storage after SwiftData startup error: \(error.localizedDescription). \(recovery)"
                return (container, message)
            } catch {
                return makeInMemoryFallback(schema: schema, originalError: error)
            }
        }
    }

    private static func makeInMemoryFallback(schema: Schema, originalError: Error) -> (container: ModelContainer, recoveryMessage: String?) {
        do {
            let fallback = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            return (fallback, "Using temporary in-memory storage because persistent storage could not start: \(originalError.localizedDescription)")
        } catch {
            preconditionFailure("Unable to create any SwiftData container: \(error)")
        }
    }

    static func quarantineDefaultStoreFiles(fileManager: FileManager = .default, now: Date = .now) -> String {
        guard let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return "Application Support was unavailable."
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let folderName = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let quarantineURL = supportURL
            .appendingPathComponent("IncompatibleStores", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: quarantineURL, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(at: supportURL, includingPropertiesForKeys: nil)
            let storeFiles = files.filter { url in
                let name = url.lastPathComponent
                return name == "default.store" || name.hasPrefix("default.store-")
            }

            guard !storeFiles.isEmpty else {
                return "No default SwiftData store files were found to quarantine."
            }

            for file in storeFiles {
                let destination = quarantineURL.appendingPathComponent(file.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: file, to: destination)
            }
            return "Moved \(storeFiles.count) incompatible store file(s) aside."
        } catch {
            return "Could not quarantine the previous SwiftData store: \(error.localizedDescription)"
        }
    }
}
