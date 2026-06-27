import Foundation
import SwiftData

struct ContextPackage: Sendable {
    var prompt: String
    var conversationSummary: String
    var memories: [String]
    var documents: [String]
    var budget: Int
}

struct ContextBuilder: Sendable {
    let memoryService: MemoryService
    let documentService: DocumentService

    func build(goal: String, messages: [String], graphState: AgentLoopState, toolResults: [String], context: ModelContext, budget: Int = 4_000) throws -> ContextPackage {
        let memories = try memoryService.search(query: goal, context: context).prefix(8).map { memory in
            "[\(String(format: "%.2f", memory.importance)) \(memory.source)] \(memory.content)"
        }
        let documents = Array(try documentService.snippets(matching: goal, context: context).prefix(6))
        let conversationSummary = summarize(messages: messages, budget: max(300, budget / 5))
        let sections = [
            "System rules: privacy-first, local by default, ask before risky or external actions.",
            "User goal: \(goal)",
            "Conversation summary: \(conversationSummary)",
            "Memories:\n\(memories.joined(separator: "\n"))",
            "Documents:\n\(documents.joined(separator: "\n\n"))",
            "Tool results:\n\(toolResults.joined(separator: "\n"))",
            "Graph state: \(graphState.summary)",
            "Templates: Plan with concise steps. Act only through approved tools. Observe tool output. Reflect on whether the goal is satisfied. Respond clearly and save durable facts."
        ]
        let prompt = truncate(sections.joined(separator: "\n\n"), budget: budget)
        return ContextPackage(prompt: prompt, conversationSummary: conversationSummary, memories: Array(memories), documents: Array(documents), budget: budget)
    }

    func summarize(messages: [String], budget: Int) -> String {
        truncate(messages.suffix(12).joined(separator: "\n"), budget: budget)
    }

    func truncate(_ text: String, budget: Int) -> String {
        let approximateCharacterBudget = max(200, budget * 4)
        if text.count <= approximateCharacterBudget {
            return text
        }
        let end = text.index(text.startIndex, offsetBy: approximateCharacterBudget)
        return String(text[..<end]) + "\n[truncated]"
    }
}
