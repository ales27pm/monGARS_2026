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

    private struct LoadedSession {
        var modelID: String
        var session: ChatSession
    }

    private var loadedSession: LoadedSession?

    func hasLoaded(modelID: String) -> Bool {
        loadedSession?.modelID == modelID
    }

    func complete(prompt: String, modelID: String, maxTokens: Int, temperature: Double) async throws -> String {
        let session = try await session(modelID: modelID, maxTokens: maxTokens, temperature: temperature)
        return try await session.respond(to: prompt)
    }

    func stream(prompt: String, modelID: String, maxTokens: Int, temperature: Double, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            let session = try await session(modelID: modelID, maxTokens: maxTokens, temperature: temperature)
            for try await chunk in session.streamResponse(to: prompt) {
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func session(modelID: String, maxTokens: Int, temperature: Double) async throws -> ChatSession {
        if let loadedSession, loadedSession.modelID == modelID {
            loadedSession.session.generateParameters = generationParameters(maxTokens: maxTokens, temperature: temperature)
            return loadedSession.session
        }

        let configuration = LLMRegistry.shared.configuration(id: modelID)
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        let session = ChatSession(
            container,
            instructions: PromptContract.finalAnswer,
            generateParameters: generationParameters(maxTokens: maxTokens, temperature: temperature)
        )
        loadedSession = LoadedSession(modelID: modelID, session: session)
        return session
    }

    private func generationParameters(maxTokens: Int, temperature: Double) -> GenerateParameters {
        GenerateParameters(
            maxTokens: max(1, min(maxTokens, 4096)),
            temperature: Float(max(0, min(temperature, 2.0))),
            topP: 0.9,
            repetitionPenalty: 1.05
        )
    }
}
#endif
