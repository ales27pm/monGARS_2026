import Foundation

struct LLMRequest: Sendable {
    var prompt: String
    var conversationContext: [String]
    var retrievedContext: [String]
}

struct LLMResponse: Sendable {
    var text: String
    var providerName: String
}

struct LLMProviderCapabilities: Sendable, Codable {
    var supportsStreaming: Bool
    var supportsTools: Bool
    var supportsVision: Bool
    var supportsJSONMode: Bool
    var maxContextTokens: Int
    var isLocal: Bool

    static let mockLocal = LLMProviderCapabilities(supportsStreaming: true, supportsTools: false, supportsVision: false, supportsJSONMode: true, maxContextTokens: 4_000, isLocal: true)
    static let foundationLocal = LLMProviderCapabilities(supportsStreaming: false, supportsTools: false, supportsVision: false, supportsJSONMode: false, maxContextTokens: 4_000, isLocal: true)
    static let remote = LLMProviderCapabilities(supportsStreaming: false, supportsTools: false, supportsVision: false, supportsJSONMode: true, maxContextTokens: 8_000, isLocal: false)
}

protocol LLMProvider: Sendable {
    var name: String { get }
    var capabilities: LLMProviderCapabilities { get }
    var status: String { get async }
    func complete(request: LLMRequest) async throws -> LLMResponse
    func stream(request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    func stream(request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await complete(request: request)
                    let words = response.text.split(separator: " ").map(String.init)
                    for word in words {
                        try await Task.sleep(nanoseconds: 20_000_000)
                        continuation.yield(word + " ")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum LLMProviderError: LocalizedError {
    case remoteDisabled
    case invalidEndpoint
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .remoteDisabled:
            "Remote providers are disabled. Enable them in Settings before network requests are allowed."
        case .invalidEndpoint:
            "The remote endpoint is not a valid URL."
        case .unavailable(let reason):
            reason
        }
    }
}
