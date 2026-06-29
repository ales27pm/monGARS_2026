#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

struct FoundationModelProvider: LLMProvider {
    let name = "Apple Foundation Models"
    let capabilities = LLMProviderCapabilities.foundationLocal

    var status: String {
        get async {
#if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return "FoundationModels framework available; on-device provider required"
            }
#endif
            return "FoundationModels unavailable on this runtime; no alternate local provider is configured"
        }
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession()
            let response = try await session.respond(to: Self.assembledPrompt(for: request))
            return LLMResponse(text: response.content, providerName: name)
        }
#endif
        throw LLMProviderError.unavailable("FoundationModels is unavailable on this runtime. Use a supported on-device runtime or configure an approved remote provider.")
    }

    static func assembledPrompt(for request: LLMRequest) -> String {
        LLMPromptAssembler.assemble(request: request)
    }
}
