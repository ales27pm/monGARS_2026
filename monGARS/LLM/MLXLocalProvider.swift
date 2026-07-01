import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
#endif

struct MLXLocalProvider: LLMProvider {
    let name = "MLX Local"
    let capabilities = LLMProviderCapabilities.mlxLocal
    var modelID: String
    var maxTokens: Int
    var temperature: Double
    var allowsModelDownload: Bool = false

    static var isLinked: Bool {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        true
#else
        false
#endif
    }

    static var buildStatus: String {
        isLinked ? "linked" : "not linked"
    }

    var status: String {
        get async {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
            let model = Self.normalizedModelID(modelID)
            let networkStatus = allowsModelDownload ? "model loading network allowed" : "model loading network blocked"
            return "MLX Swift LM linked. Model: \(model). \(networkStatus). First run may download model files from Hugging Face."
#else
            return "MLX Swift LM is not linked in this build. Add mlx-swift-lm, swift-huggingface, and swift-transformers packages to enable local MLX inference."
#endif
        }
    }

    static func prepareModel(id modelID: String, allowsModelDownload: Bool) async throws {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        try await MLXLocalModelStore.shared.prepare(
            modelID: normalizedModelID(modelID),
            allowsModelDownload: allowsModelDownload
        )
#else
        throw LLMProviderError.unavailable("MLX local inference is unavailable because MLX Swift LM is not linked in this app build.")
#endif
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        let prompt = LLMPromptAssembler.assemble(request: request)
        let modelID = Self.normalizedModelID(modelID)
        let text = try await MLXLocalModelStore.shared.complete(
            prompt: prompt,
            modelID: modelID,
            maxTokens: maxTokens,
            temperature: temperature,
            allowsModelDownload: allowsModelDownload
        )
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw LLMProviderError.unavailable("MLX generated an empty response.")
        }
        return LLMResponse(text: cleaned, providerName: name)
#else
        throw LLMProviderError.unavailable("MLX local inference is unavailable because MLX Swift LM is not linked in this app build.")
#endif
    }

    func stream(request: LLMRequest) -> AsyncThrowingStream<String, Error> {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        let prompt = LLMPromptAssembler.assemble(request: request)
        let modelID = Self.normalizedModelID(modelID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await MLXLocalModelStore.shared.stream(
                    prompt: prompt,
                    modelID: modelID,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    allowsModelDownload: allowsModelDownload,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
#else
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMProviderError.unavailable("MLX local inference is unavailable because MLX Swift LM is not linked in this app build."))
        }
#endif
    }

    private static func normalizedModelID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? MLXModelPreset.default.id : trimmed
    }
}

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
private actor MLXLocalModelStore {
    static let shared = MLXLocalModelStore()

    private struct LoadedModel {
        var modelID: String
        var container: ModelContainer
    }

    private var loadedModel: LoadedModel?

    func prepare(modelID: String, allowsModelDownload: Bool) async throws {
        _ = try await container(modelID: modelID, allowsModelDownload: allowsModelDownload)
    }

    func complete(prompt: String, modelID: String, maxTokens: Int, temperature: Double, allowsModelDownload: Bool) async throws -> String {
        var output = ""
        let stream = try await generationStream(prompt: prompt, modelID: modelID, maxTokens: maxTokens, temperature: temperature, allowsModelDownload: allowsModelDownload)
        for await item in stream {
            try Task.checkCancellation()
            if let chunk = item.chunk {
                output += chunk
            }
        }
        return output
    }

    func stream(prompt: String, modelID: String, maxTokens: Int, temperature: Double, allowsModelDownload: Bool, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            let stream = try await generationStream(prompt: prompt, modelID: modelID, maxTokens: maxTokens, temperature: temperature, allowsModelDownload: allowsModelDownload)
            for await item in stream {
                try Task.checkCancellation()
                if let chunk = item.chunk {
                    continuation.yield(chunk)
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func generationStream(prompt: String, modelID: String, maxTokens: Int, temperature: Double, allowsModelDownload: Bool) async throws -> AsyncStream<Generation> {
        let container = try await container(modelID: modelID, allowsModelDownload: allowsModelDownload)
        let input = UserInput(
            chat: [
                .system(systemPrompt),
                .user(prompt)
            ],
            additionalContext: chatTemplateContext
        )
        let prepared = try await container.prepare(input: input)
        return try await container.generate(
            input: prepared,
            parameters: generationParameters(maxTokens: maxTokens, temperature: temperature)
        )
    }

    private func container(modelID: String, allowsModelDownload: Bool) async throws -> ModelContainer {
        if let loadedModel, loadedModel.modelID == modelID {
            return loadedModel.container
        }
        let configuration = try Self.configurationForLoad(modelID: modelID, allowsModelDownload: allowsModelDownload)
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        loadedModel = LoadedModel(modelID: modelID, container: container)
        return container
    }

    private static func configurationForLoad(modelID: String, allowsModelDownload: Bool) throws -> ModelConfiguration {
        let remoteConfiguration = LLMRegistry.shared.configuration(id: modelID)
        if allowsModelDownload {
            return remoteConfiguration
        }
        guard let cachedConfiguration = cachedConfiguration(for: remoteConfiguration) else {
            throw LLMProviderError.unavailable("MLX model loading is blocked because network access is off and the configured model is not available in the local Hugging Face cache. Enable network access in Settings once to prepare the model, then run MLX locally.")
        }
        return cachedConfiguration
    }

    private static func cachedConfiguration(for configuration: ModelConfiguration) -> ModelConfiguration? {
        guard case .id(let modelID, let revision) = configuration.id,
              let modelDirectory = cachedSnapshotDirectory(repoID: modelID, revision: revision) else {
            return nil
        }

        let tokenizerSource: TokenizerSource?
        switch configuration.tokenizerSource {
        case .directory(let directory):
            tokenizerSource = .directory(directory)
        case .id(let tokenizerID, let tokenizerRevision):
            guard let tokenizerDirectory = cachedSnapshotDirectory(repoID: tokenizerID, revision: tokenizerRevision ?? "main") else {
                return nil
            }
            tokenizerSource = .directory(tokenizerDirectory)
        case nil:
            tokenizerSource = nil
        }

        return ModelConfiguration(
            directory: modelDirectory,
            tokenizerSource: tokenizerSource,
            defaultPrompt: configuration.defaultPrompt,
            extraEOSTokens: configuration.extraEOSTokens,
            eosTokenIds: configuration.eosTokenIds,
            toolCallFormat: configuration.toolCallFormat
        )
    }

    private static func cachedSnapshotDirectory(repoID: String, revision: String) -> URL? {
        let parts = repoID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let repo = Repo.ID(namespace: parts[0], name: parts[1])
        let cache = HubCache.default
        let fileManager = FileManager.default
        var commitCandidates: [String] = []
        if let resolved = cache.resolveRevision(repo: repo, kind: .model, ref: revision) {
            commitCandidates.append(resolved)
        }
        commitCandidates.append(revision)

        for commit in commitCandidates {
            guard let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit),
                  usableSnapshotDirectory(snapshot, fileManager: fileManager) else { continue }
            return snapshot
        }

        let snapshotsRoot = cache.snapshotsDirectory(repo: repo, kind: .model)
        guard let snapshots = try? fileManager.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return snapshots
            .filter { usableSnapshotDirectory($0, fileManager: fileManager) }
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private static func usableSnapshotDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return false
        }
        return !contents.isEmpty
    }

    private func generationParameters(maxTokens: Int, temperature: Double) -> GenerateParameters {
        GenerateParameters(
            maxTokens: max(1, min(maxTokens, 4096)),
            temperature: Float(max(0, min(temperature, 2.0))),
            topP: 0.9,
            repetitionPenalty: 1.05
        )
    }

    private var systemPrompt: String {
        """
        You are monGARS. \(PromptContract.responseSystemRules) \(PromptContract.finalAnswer) Do not reveal chain-of-thought, hidden reasoning, chat-template tokens, role labels, or prompt delimiters. Answer directly in natural user-facing text.
        """
    }

    private var chatTemplateContext: [String: any Sendable] {
        [
            "enable_thinking": false
        ]
    }
}
#endif
