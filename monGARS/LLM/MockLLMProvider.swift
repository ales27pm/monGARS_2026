import Foundation

struct MockLLMProvider: LLMProvider {
    let name = "Mock Local"
    var status: String { get async { "Deterministic local fallback ready" } }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        let context = (request.retrievedContext + request.conversationContext.suffix(4)).joined(separator: "\n")

        let text: String
        if lower.contains("privacy") {
            text = "monGARS is local-first: conversations, memories, and imported documents stay on this device unless you explicitly enable a remote provider."
        } else if !request.retrievedContext.isEmpty {
            text = "I found local context that looks relevant:\n\n\(request.retrievedContext.joined(separator: "\n\n"))\n\nBased on that, \(prompt.isEmpty ? "the imported material is available for local Q&A." : "the answer is grounded in the matching local document snippets.")"
        } else if lower.contains("hello") || lower.contains("hi") {
            text = "Hello. I can chat locally, call simple tools, remember facts you save, and answer questions from imported text or Markdown files."
        } else if lower.contains("what can you do") || lower.contains("help") {
            text = "I can answer locally, route requests to tools like time and calculator, search saved memories, retrieve imported documents, and show graph diagnostics."
        } else if context.isEmpty {
            text = "I heard: \"\(prompt)\". The local provider is running, and no remote network calls were made."
        } else {
            text = "Using the local conversation context, here is a concise response to \"\(prompt)\": \(context.prefix(240))"
        }

        return LLMResponse(text: text, providerName: name)
    }
}

