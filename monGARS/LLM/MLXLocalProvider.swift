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

    func complete(request: LLMRequest) async throws -> LLMResponse {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        let prompt = LLMPromptAssembler.assemble(request: request)
        let modelID = Self.normalizedModelID(modelID)
        let modelAlreadyLoaded = await MLXLocalModelStore.shared.hasLoaded(modelID: modelID)
        if !allowsModelDownload && !modelAlreadyLoaded {
            throw LLMProviderError.unavailable("MLX model loading is blocked because network access is off. Enable network access in Settings to prepare the configured model, then run MLX locally.")
        }
        let text = try await MLXLocalModelStore.shared.complete(
            prompt: prompt,
            modelID: modelID,
            maxTokens: maxTokens,
            temperature: temperature
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
            Task {
                let modelAlreadyLoaded = await MLXLocalModelStore.shared.hasLoaded(modelID: modelID)
                if !allowsModelDownload && !modelAlreadyLoaded {
                    continuation.finish(throwing: LLMProviderError.unavailable("MLX model loading is blocked because network access is off. Enable network access in Settings to prepare the configured model, then run MLX locally."))
                    return
                }
                await MLXLocalModelStore.shared.stream(
                    prompt: prompt,
                    modelID: modelID,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    continuation: continuation
                )
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
        return trimmed.isEmpty ? "mlx-community/Qwen3-0.6B-4bit" : trimmed
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

    func hasLoaded(modelID: String) -> Bool {
        loadedModel?.modelID == modelID
    }

    func complete(prompt: String, modelID: String, maxTokens: Int, temperature: Double) async throws -> String {
        var output = ""
        let stream = try await generationStream(prompt: prompt, modelID: modelID, maxTokens: maxTokens, temperature: temperature)
        for await item in stream {
            if let chunk = item.chunk {
                output += chunk
            }
        }
        return output
    }

    func stream(prompt: String, modelID: String, maxTokens: Int, temperature: Double, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            let stream = try await generationStream(prompt: prompt, modelID: modelID, maxTokens: maxTokens, temperature: temperature)
            for await item in stream {
                if let chunk = item.chunk {
                    continuation.yield(chunk)
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func generationStream(prompt: String, modelID: String, maxTokens: Int, temperature: Double) async throws -> AsyncStream<Generation> {
        let container = try await container(modelID: modelID)
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

    private func container(modelID: String) async throws -> ModelContainer {
        if let loadedModel, loadedModel.modelID == modelID {
            return loadedModel.container
        }
        let configuration = LLMRegistry.shared.configuration(id: modelID)
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        loadedModel = LoadedModel(modelID: modelID, container: container)
        return container
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
