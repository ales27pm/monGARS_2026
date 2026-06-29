import Foundation

struct LLMRequest: Sendable {
    private(set) var prompt: String
    var conversationContext: [String]
    var retrievedContext: [String]
    var segments: [LLMPromptSegment]
    var isPromptPreassembled: Bool

    init(prompt: String, conversationContext: [String], retrievedContext: [String], segments: [LLMPromptSegment]? = nil, isPromptPreassembled: Bool = false) {
        self.conversationContext = conversationContext
        self.retrievedContext = retrievedContext
        self.segments = segments ?? LLMPromptAssembler.segments(
            trustedPrompt: prompt,
            conversationContext: conversationContext,
            retrievedContext: retrievedContext
        )
        self.isPromptPreassembled = isPromptPreassembled
        self.prompt = isPromptPreassembled ? prompt : LLMPromptAssembler.assemble(segments: self.segments)
    }
}

struct LLMResponse: Sendable {
    var text: String
    var providerName: String
}

enum LLMPromptTrustLevel: Sendable, Equatable {
    case trustedInstruction
    case untrustedData
}

struct LLMPromptSegment: Sendable, Equatable {
    var title: String
    var body: String
    var trustLevel: LLMPromptTrustLevel
}

enum PromptContextMarkup {
    static func render(_ segment: LLMPromptSegment) -> String {
        switch segment.trustLevel {
        case .trustedInstruction:
            let body = segment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.contains("\n") else {
                return "\(segment.title): \(body)".trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "\(segment.title):\n\(body)".trimmingCharacters(in: .whitespacesAndNewlines)
        case .untrustedData:
            return untrustedBlock(title: segment.title, body: segment.body)
        }
    }

    static func untrustedBlock(title: String, items: [String]) -> String {
        untrustedBlock(title: title, body: items.map(quoteUntrusted).filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    private static func untrustedBlock(title: String, body: String) -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "\(title): none" }
        return """
        BEGIN UNTRUSTED \(title)
        \(body)
        END UNTRUSTED \(title)
        """
    }

    static func quoteUntrusted(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}

enum LLMPromptAssembler {
    static func assemble(request: LLMRequest) -> String {
        if request.isPromptPreassembled {
            return request.prompt
        }
        return assemble(segments: request.segments)
    }

    static func assemble(segments: [LLMPromptSegment]) -> String {
        segments
            .map(PromptContextMarkup.render)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func segments(trustedPrompt: String, conversationContext: [String], retrievedContext: [String]) -> [LLMPromptSegment] {
        [
            retrievedContext.isEmpty ? nil : LLMPromptSegment(title: "REFERENCE CONTEXT", body: retrievedContext.joined(separator: "\n\n"), trustLevel: .untrustedData),
            conversationContext.isEmpty ? nil : LLMPromptSegment(title: "CONVERSATION CONTEXT", body: conversationContext.joined(separator: "\n\n"), trustLevel: .untrustedData),
            LLMPromptSegment(title: "APP INSTRUCTIONS", body: trustedPrompt, trustLevel: .trustedInstruction)
        ]
            .compactMap { $0 }
    }
}

struct LLMProviderCapabilities: Sendable, Codable {
    var supportsStreaming: Bool
    var supportsTools: Bool
    var supportsVision: Bool
    var supportsJSONMode: Bool
    var maxContextTokens: Int
    var isLocal: Bool

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
