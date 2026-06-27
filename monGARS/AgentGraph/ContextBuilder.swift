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

    func build(
        goal: String,
        messages: [String],
        graphState: AgentLoopState,
        toolResults: [String],
        context: ModelContext,
        phase: AgentPhase = .retrieveContext,
        selectedToolName: String? = nil,
        selectedToolSchema: ToolSchema? = nil,
        budget: Int = 4_000
    ) throws -> ContextPackage {
        let memories = try memoryService.search(query: goal, context: context).prefix(8).map { memory in
            "[\(String(format: "%.2f", memory.importance)) \(memory.source)] \(memory.content)"
        }
        let rawDocuments = Array(try documentService.snippets(matching: goal, context: context).prefix(6))
        let documents = phase == .executeTool ? [] : rawDocuments
        let conversationSummary = summarize(messages: messages, budget: max(300, budget / 5))
        let finalInstructions = "Final instructions: Follow the current phase. Act only through approved tools. Keep required output formatting valid. Observe tool output. Reflect on whether the goal is satisfied. Respond clearly and save durable facts only when useful."
        let toolSection: String
        if let selectedToolSchema {
            let examples = selectedToolSchema.examples.isEmpty ? "No examples provided." : selectedToolSchema.examples.joined(separator: "\n")
            toolSection = "Selected tool: \(selectedToolName ?? graphState.selectedToolName ?? "unknown")\nTool schema: \(selectedToolSchema.inputDescription)\nTool examples:\n\(examples)"
        } else if let selectedToolName = selectedToolName ?? graphState.selectedToolName {
            toolSection = "Selected tool: \(selectedToolName)"
        } else {
            toolSection = "Selected tool: none"
        }

        let sections: [String]
        switch phase {
        case .executeTool:
            sections = [
                "Current phase: \(phase.rawValue)",
                toolSection,
                "System rules: privacy-first, local by default, ask before risky or external actions.",
                "User goal: \(goal)",
                "Recent observations:\n\(graphState.observations.suffix(4).joined(separator: "\n"))",
                "Tool results:\n\(toolResults.suffix(4).joined(separator: "\n"))",
                "Graph state: \(graphState.summary)",
                finalInstructions
            ]
        case .reflect:
            sections = [
                "Current phase: \(phase.rawValue)",
                "Recent observations:\n\(graphState.observations.suffix(6).joined(separator: "\n"))",
                "Tool results:\n\(toolResults.suffix(6).joined(separator: "\n"))",
                "System rules: privacy-first, local by default, ask before risky or external actions.",
                "User goal: \(goal)",
                "Conversation summary: \(conversationSummary)",
                "Graph state: \(graphState.summary)",
                finalInstructions
            ]
        default:
            sections = [
                "System rules: privacy-first, local by default, ask before risky or external actions.",
                "Current phase: \(phase.rawValue)",
                "User goal: \(goal)",
                "Conversation summary: \(conversationSummary)",
                "Memories:\n\(memories.joined(separator: "\n"))",
                "Documents:\n\(documents.joined(separator: "\n\n"))",
                "Tool results:\n\(toolResults.joined(separator: "\n"))",
                "Graph state: \(graphState.summary)",
                finalInstructions
            ]
        }
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
        let marker = "\n\nFinal instructions:"
        guard let markerRange = text.range(of: marker, options: .backwards) else {
            let end = text.index(text.startIndex, offsetBy: approximateCharacterBudget - "\n[truncated]".count)
            return String(text[..<end]) + "\n[truncated]"
        }

        let tail = String(text[markerRange.lowerBound...])
        if tail.count >= approximateCharacterBudget {
            let start = tail.index(tail.endIndex, offsetBy: -approximateCharacterBudget)
            return String(tail[start...])
        }

        let prefixBudget = max(0, approximateCharacterBudget - tail.count - "\n[truncated]\n".count)
        let prefixEnd = text.index(text.startIndex, offsetBy: prefixBudget)
        return String(text[..<prefixEnd]) + "\n[truncated]\n" + tail
    }
}
