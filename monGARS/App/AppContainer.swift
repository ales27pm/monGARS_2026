import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let storageState: StorageState
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
    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?

    init(inMemory: Bool = false) {
        let schema = Schema(Self.schemaModels)
        let containerResult = Self.makeModelContainer(schema: schema, inMemory: inMemory)
        modelContainer = containerResult.container
        storageState = containerResult.storageState
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
        let startupContext = ModelContext(modelContainer)
        AuditMetadataBackfillService.run(context: startupContext)
        do {
            _ = try AgentRunRecoveryService.recoverStaleRunningRuns(
                context: startupContext,
                staleAfterSeconds: Self.staleRunRecoveryGraceSeconds(timeoutSeconds: settingsStore.networkTimeoutSeconds)
            )
        } catch {
            diagnostics.lastError = "Could not recover stale agent runs: \(error.localizedDescription)"
        }
        if diagnostics.lastError == nil {
            diagnostics.lastError = persistenceRecoveryMessage
        }
        installMemoryPressureHandlers()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    static var schemaModels: [any PersistentModel.Type] {
        MonGARSSchemaV2.models
    }

    static func staleRunRecoveryGraceSeconds(timeoutSeconds: TimeInterval) -> TimeInterval {
        max(timeoutSeconds * 2, 30)
    }

    func llmProvider() -> any LLMProvider {
        switch settingsStore.providerMode {
        case .foundation:
            return FoundationModelProvider(isEnabled: settingsStore.foundationModelsEnabled)
        case .mlx:
            return MLXLocalProvider(
                modelID: settingsStore.mlxModelID,
                maxTokens: settingsStore.mlxMaxTokens,
                temperature: settingsStore.mlxTemperature,
                allowsModelDownload: settingsStore.remoteProviderEnabled
            )
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

    private func installMemoryPressureHandlers() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await MLXLocalProvider.releaseCachedModel(reason: "iOS memory warning")
            }
            Task { @MainActor [weak self] in
                self?.diagnostics.lastError = "iOS memory warning received; released cached MLX model."
            }
        }
        #endif
    }

    func seedIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<Conversation>()
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        guard existing == 0 else { return }

        let conversation = Conversation(title: "Welcome")
        conversation.messages.append(ChatMessage(role: .assistant, content: "Hi, I am monGARS. Ask me for the time, a calculation, a saved memory, or a document summary."))
        context.insert(conversation)
        try? context.save()
    }

    enum StorageState: Equatable {
        case durable
        case testMemory
        case recoveredDurable
        case unavailableEphemeral(String)

        var allowsUserWorkflows: Bool {
            switch self {
            case .durable, .testMemory, .recoveredDurable:
                true
            case .unavailableEphemeral:
                false
            }
        }

        var message: String? {
            switch self {
            case .durable, .testMemory:
                nil
            case .recoveredDurable:
                "Persistent storage was recovered after a startup error."
            case .unavailableEphemeral(let reason):
                reason
            }
        }
    }

    private static func makeModelContainer(schema: Schema, inMemory: Bool) -> (container: ModelContainer, storageState: StorageState, recoveryMessage: String?) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return (try ModelContainer(for: schema, migrationPlan: MonGARSMigrationPlan.self, configurations: [configuration]), inMemory ? .testMemory : .durable, nil)
        } catch {
            guard !inMemory else {
                return makeVolatileRecoveryContainer(schema: schema, originalError: error)
            }

            let recovery = quarantineDefaultStoreFiles()
            do {
                let container = try ModelContainer(for: schema, migrationPlan: MonGARSMigrationPlan.self, configurations: [configuration])
                let message = "Recovered local storage after SwiftData startup error: \(error.localizedDescription). \(recovery)"
                return (container, .recoveredDurable, message)
            } catch {
                return makeVolatileRecoveryContainer(schema: schema, originalError: error)
            }
        }
    }

    private static func makeVolatileRecoveryContainer(schema: Schema, originalError: Error) -> (container: ModelContainer, storageState: StorageState, recoveryMessage: String?) {
        do {
            let container = try ModelContainer(for: schema, migrationPlan: MonGARSMigrationPlan.self, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            let message = "Persistent storage is unavailable. User workflows are disabled until the store can be repaired or the app is reinstalled: \(originalError.localizedDescription)"
            return (container, .unavailableEphemeral(message), message)
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

enum AgentRunRecoveryService {
    @MainActor
    @discardableResult
    static func recoverStaleRunningRuns(
        context: ModelContext,
        now: Date = .now,
        staleAfterSeconds: TimeInterval = 120
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-staleAfterSeconds)
        let runningStatus = AgentRunStatus.running.rawValue
        let descriptor = FetchDescriptor<AgentRunRecord>(
            predicate: #Predicate { run in
                run.statusRawValue == runningStatus && run.updatedAt < cutoff
            }
        )
        let staleRuns = try context.fetch(descriptor)
        guard !staleRuns.isEmpty else { return 0 }

        for run in staleRuns {
            let message = "Recovered stale running run after app restart; previous execution did not finish before timeout."
            run.statusRawValue = AgentRunStatus.timedOut.rawValue
            run.requiresApproval = false
            run.lastError = AgentRuntimeError.timedOut.localizedDescription
            run.completedAt = now
            run.updatedAt = now
            context.insert(AgentTraceRecord(runID: run.id, stepIndex: run.currentStep, phase: run.currentPhase, message: message, createdAt: now))
            context.insert(AgentCheckpointRecord(runID: run.id, nodeID: AgentRunStatus.timedOut.rawValue, stateSummary: message, createdAt: now))
        }
        try context.safeSave()
        return staleRuns.count
    }
}
