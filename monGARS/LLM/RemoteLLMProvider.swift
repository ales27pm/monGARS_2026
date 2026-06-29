import Foundation

struct RemoteLLMProvider: LLMProvider {
    let name = "Remote Endpoint"
    let capabilities = LLMProviderCapabilities(supportsStreaming: true, supportsTools: false, supportsVision: false, supportsJSONMode: true, maxContextTokens: 8_000, isLocal: false)
    var endpoint: String
    var isEnabled: Bool
    var model: String = AppNetworkConfiguration.remoteModel
    var apiKey: String = AppNetworkConfiguration.remoteAPIKey
    var client: NetworkClient = AppNetworkConfiguration.client()

    var status: String {
        get async {
            isEnabled ? "Remote provider enabled for \(endpoint)" : "Remote provider disabled; no network calls allowed"
        }
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        guard isEnabled else { throw LLMProviderError.remoteDisabled }
        guard let url = URL(string: endpoint) else { throw LLMProviderError.invalidEndpoint }

        let payload = try JSONEncoder().encode(payload(for: request, stream: false, endpoint: url))
        let response = try await client.send(NetworkRequest(
            url: url,
            method: .post,
            headers: headers(),
            body: payload,
            acceptedContentTypes: ["application/json"]
        ))
        let text = try decodeCompletion(response)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.unavailable("Remote provider returned an empty response.")
        }
        return LLMResponse(text: text, providerName: name)
    }

    func stream(request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard isEnabled else { throw LLMProviderError.remoteDisabled }
                    guard let url = URL(string: endpoint) else { throw LLMProviderError.invalidEndpoint }
                    let body = try JSONEncoder().encode(payload(for: request, stream: true, endpoint: url))
                    let stream = client.streamLines(NetworkRequest(
                        url: url,
                        method: .post,
                        headers: headers(),
                        body: body,
                        acceptedContentTypes: ["application/json", "text/event-stream"]
                    ))

                    for try await event in stream {
                        if let token = try streamToken(from: event.line, endpoint: url) {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func headers() -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    private func payload(for request: LLMRequest, stream: Bool, endpoint: URL) -> LLMRequestPayload {
        let prompt = LLMPromptAssembler.assemble(request: request)
        let path = endpoint.path.lowercased()
        if path.contains("/chat/completions") {
            return .openAI(OpenAIChatRequest(
                model: model,
                messages: [OpenAIMessage(role: "user", content: prompt)],
                stream: stream
            ))
        }
        if path.contains("/api/chat") {
            return .ollamaChat(OllamaChatRequest(
                model: model,
                messages: [OpenAIMessage(role: "user", content: prompt)],
                stream: stream
            ))
        }
        return .ollamaGenerate(OllamaGenerateRequest(model: model, prompt: prompt, stream: stream))
    }

    private func decodeCompletion(_ response: NetworkResponse) throws -> String {
        if let openAI = try? response.decodedJSON(OpenAIChatResponse.self),
           let content = openAI.choices.first?.message.content {
            return content
        }
        if let ollamaChat = try? response.decodedJSON(OllamaChatResponse.self),
           let content = ollamaChat.message?.content {
            return content
        }
        if let ollama = try? response.decodedJSON(OllamaGenerateResponse.self) {
            return ollama.response
        }
        throw LLMProviderError.unavailable("Remote provider returned JSON that does not match OpenAI-compatible or Ollama response formats.")
    }

    private func streamToken(from line: String, endpoint: URL) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let payload = trimmed.hasPrefix("data:") ? String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }

        if endpoint.path.lowercased().contains("/chat/completions"),
           let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) {
            return chunk.choices.first?.delta.content
        }
        if let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data),
           let content = chunk.message?.content {
            return content
        }
        if let chunk = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data) {
            return chunk.response
        }
        return nil
    }
}

private enum LLMRequestPayload: Encodable {
    case openAI(OpenAIChatRequest)
    case ollamaChat(OllamaChatRequest)
    case ollamaGenerate(OllamaGenerateRequest)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .openAI(let payload):
            try payload.encode(to: encoder)
        case .ollamaChat(let payload):
            try payload.encode(to: encoder)
        case .ollamaGenerate(let payload):
            try payload.encode(to: encoder)
        }
    }
}

private struct OpenAIMessage: Codable {
    var role: String
    var content: String
}

private struct OpenAIChatRequest: Encodable {
    var model: String
    var messages: [OpenAIMessage]
    var stream: Bool
}

private struct OllamaChatRequest: Encodable {
    var model: String
    var messages: [OpenAIMessage]
    var stream: Bool
}

private struct OllamaGenerateRequest: Encodable {
    var model: String
    var prompt: String
    var stream: Bool
}

private struct OpenAIChatResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: OpenAIMessage
    }
}

private struct OpenAIStreamChunk: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var delta: Delta
    }

    struct Delta: Decodable {
        var content: String?
    }
}

private struct OllamaChatResponse: Decodable {
    var message: OpenAIMessage?
}

private struct OllamaGenerateResponse: Decodable {
    var response: String
}
