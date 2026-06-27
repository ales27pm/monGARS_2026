#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

struct FoundationModelProvider: LLMProvider {
    let name = "Apple Foundation Models"
    private let fallback: any LLMProvider

    init(fallback: any LLMProvider) {
        self.fallback = fallback
    }

    var status: String {
        get async {
#if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return "FoundationModels framework available; on-device provider preferred"
            }
#endif
            return "FoundationModels unavailable on this runtime; using local deterministic fallback"
        }
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                let session = LanguageModelSession()
                let context = request.retrievedContext.isEmpty ? "" : "\n\nLocal context:\n\(request.retrievedContext.joined(separator: "\n\n"))"
                let response = try await session.respond(to: request.prompt + context)
                return LLMResponse(text: response.content, providerName: name)
            } catch {
                let fallbackResponse = try await fallback.complete(request: request)
                return LLMResponse(text: "\(fallbackResponse.text)\n\nFoundation Models was unavailable at runtime, so I used the local fallback.", providerName: fallbackResponse.providerName)
            }
        }
#endif
        return try await fallback.complete(request: request)
    }
}

