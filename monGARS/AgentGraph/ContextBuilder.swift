import Foundation
import SwiftData

struct ContextPackage: Sendable {
    var prompt: String
    var segments: [LLMPromptSegment]
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
        let shouldFetchReferenceContext = Self.shouldFetchReferenceContext(phase: phase, toolResults: toolResults)
        let memories = shouldFetchReferenceContext
            ? try memoryService.search(query: goal, context: context).prefix(8).map { memory in
                "[\(String(format: "%.2f", memory.importance)) \(memory.source)] \(memory.content)"
            }
            : []
        let documents = shouldFetchReferenceContext && phase != .executeTool
            ? Array(try documentService.snippets(matching: goal, context: context).prefix(6))
            : []
        let conversationSummary = Self.shouldSummarizeConversation(phase: phase, toolResults: toolResults)
            ? summarize(messages: messages, budget: max(300, budget / 5))
            : ""
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

        let segments: [LLMPromptSegment]
        switch phase {
        case .executeTool:
            segments = [
                trusted("Current phase", phase.rawValue),
                trusted("Tool selection", toolSection),
                trusted("System rules", "privacy-first, local by default, ask before risky or external actions."),
                untrusted("USER GOAL", [goal]),
                untrusted("RECENT OBSERVATIONS", Array(graphState.observations.suffix(4))),
                untrusted("TOOL RESULTS", Array(toolResults.suffix(4))),
                trusted("Graph state", graphState.summary),
                trusted("Final instructions", finalInstructions.replacingOccurrences(of: "Final instructions: ", with: ""))
            ]
        case .reflect:
            segments = [
                trusted("Current phase", phase.rawValue),
                untrusted("RECENT OBSERVATIONS", Array(graphState.observations.suffix(6))),
                untrusted("TOOL RESULTS", Array(toolResults.suffix(6))),
                trusted("System rules", "privacy-first, local by default, ask before risky or external actions."),
                untrusted("USER GOAL", [goal]),
                untrusted("CONVERSATION SUMMARY", [conversationSummary]),
                trusted("Graph state", graphState.summary),
                trusted("Final instructions", finalInstructions.replacingOccurrences(of: "Final instructions: ", with: ""))
            ]
        case .respond:
            segments = [
                trusted("Current phase", "respond"),
                trusted("System rules", PromptContract.responseSystemRules),
                untrusted("USER GOAL", [goal]),
                toolResults.last.map { untrusted("LATEST TOOL RESULT", [$0]) } ?? trusted("Latest tool result", "none"),
                toolResults.isEmpty && !conversationSummary.isEmpty ? untrusted("CONVERSATION SUMMARY", [conversationSummary]) : nil,
                (memories + documents).isEmpty
                    ? trusted("Relevant local context", "none")
                    : untrusted("RELEVANT LOCAL CONTEXT", Array((memories + documents).prefix(6))),
                trusted("Final answer contract", PromptContract.finalAnswer)
            ].compactMap { $0 }
        default:
            segments = [
                trusted("System rules", "privacy-first, local by default, ask before risky or external actions."),
                trusted("Current phase", phase.rawValue),
                untrusted("USER GOAL", [goal]),
                untrusted("CONVERSATION SUMMARY", [conversationSummary]),
                untrusted("MEMORIES", Array(memories)),
                untrusted("DOCUMENTS", documents),
                untrusted("TOOL RESULTS", toolResults),
                trusted("Graph state", graphState.summary),
                trusted("Final instructions", finalInstructions.replacingOccurrences(of: "Final instructions: ", with: ""))
            ]
        }
        let fullPrompt = LLMPromptAssembler.assemble(segments: segments)
        let prompt = truncate(fullPrompt, budget: budget, protectedPrefixes: protectedPrefixes(for: phase))
        let packageSegments = prompt == fullPrompt ? segments : renderedSegments(from: prompt)
        return ContextPackage(prompt: prompt, segments: packageSegments, conversationSummary: conversationSummary, memories: Array(memories), documents: Array(documents), budget: budget)
    }

    func summarize(messages: [String], budget: Int) -> String {
        truncate(PromptContextMarkup.untrustedBlock(title: "RECENT MESSAGES", items: Array(messages.suffix(12))), budget: budget)
    }

    func truncate(_ text: String, budget: Int, protectedPrefixes: [String] = []) -> String {
        let approximateCharacterBudget = max(200, budget * 4)
        if text.count <= approximateCharacterBudget {
            return text
        }
        guard let markerRange = finalInstructionMarkerRange(in: text) else {
            let end = text.index(text.startIndex, offsetBy: approximateCharacterBudget - "\n[truncated]".count)
            return String(text[..<end]) + "\n[truncated]"
        }

        let tail = String(text[markerRange.lowerBound...])
        if tail.count >= approximateCharacterBudget {
            return trim(tail, characterLimit: approximateCharacterBudget)
        }

        let protectedBlocks = protectedPrefixes.compactMap { protectedBlock(startingWith: $0, in: text) }
        if !protectedBlocks.isEmpty {
            let separator = "\n[truncated]\n"
            let available = approximateCharacterBudget - tail.count - separator.count
            if available > 0 {
                var remaining = available
                var protectedPieces: [String] = []
                for block in protectedBlocks where remaining > 0 {
                    let separatorCost = protectedPieces.isEmpty ? 0 : 2
                    let limit = max(0, remaining - separatorCost)
                    let piece = trim(block, characterLimit: limit)
                    guard !piece.isEmpty else { continue }
                    protectedPieces.append(piece)
                    remaining -= piece.count + separatorCost
                }
                let protectedText = protectedPieces.joined(separator: "\n\n")
                if !protectedText.isEmpty {
                    return fit(protectedText + separator + tail, characterLimit: approximateCharacterBudget)
                }
            }
        }

        let prefixBudget = max(0, approximateCharacterBudget - tail.count - "\n[truncated]\n".count)
        let prefixEnd = text.index(text.startIndex, offsetBy: prefixBudget)
        return String(text[..<prefixEnd]) + "\n[truncated]\n" + tail
    }

    private func protectedPrefixes(for phase: AgentPhase) -> [String] {
        switch phase {
        case .executeTool:
            ["Current phase:", "Selected tool:"]
        case .reflect:
            ["Current phase:", "BEGIN UNTRUSTED USER GOAL", "BEGIN UNTRUSTED RECENT OBSERVATIONS", "BEGIN UNTRUSTED CONVERSATION SUMMARY"]
        case .respond:
            ["Current phase:", "BEGIN UNTRUSTED USER GOAL", "BEGIN UNTRUSTED LATEST TOOL RESULT", "BEGIN UNTRUSTED CONVERSATION SUMMARY", "BEGIN UNTRUSTED RELEVANT LOCAL CONTEXT", "Final answer contract:"]
        default:
            ["System rules:", "Current phase:", "BEGIN UNTRUSTED USER GOAL"]
        }
    }

    private func protectedBlock(startingWith prefix: String, in text: String) -> String? {
        guard let start = text.range(of: prefix)?.lowerBound else { return nil }
        let remainder = text[start...]
        if prefix.hasPrefix("BEGIN UNTRUSTED") {
            let title = prefix.replacingOccurrences(of: "BEGIN UNTRUSTED ", with: "")
            if let endRange = remainder.range(of: "\nEND UNTRUSTED \(title)") {
                return String(text[start..<endRange.upperBound])
            }
        }
        let end = remainder.range(of: "\n\n")?.lowerBound ?? text.endIndex
        return String(text[start..<end])
    }

    private func trim(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else { return text }
        let suffix = " [truncated]"
        let limit = max(0, characterLimit - suffix.count)
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + suffix
    }

    private func fit(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else { return text }
        guard let markerRange = finalInstructionMarkerRange(in: text) else {
            let end = text.index(text.startIndex, offsetBy: max(0, characterLimit - "\n[truncated]".count))
            return String(text[..<end]) + "\n[truncated]"
        }

        let tail = String(text[markerRange.lowerBound...])
        if tail.count >= characterLimit {
            return trim(tail, characterLimit: characterLimit)
        }

        let separator = "\n[truncated]\n"
        let prefixBudget = max(0, characterLimit - tail.count - separator.count)
        let prefixEnd = text.index(text.startIndex, offsetBy: prefixBudget)
        return String(text[..<prefixEnd]) + separator + tail
    }

    private func finalInstructionMarkerRange(in text: String) -> Range<String.Index>? {
        ["\n\nFinal instructions:", "\n\nFinal answer contract:"]
            .compactMap { text.range(of: $0, options: .backwards) }
            .max { $0.lowerBound < $1.lowerBound }
    }

    private func trusted(_ title: String, _ body: String) -> LLMPromptSegment {
        LLMPromptSegment(title: title, body: body, trustLevel: .trustedInstruction)
    }

    private func untrusted(_ title: String, _ items: [String]) -> LLMPromptSegment {
        LLMPromptSegment(title: title, body: items.joined(separator: "\n\n"), trustLevel: .untrustedData)
    }

    private func renderedSegments(from prompt: String) -> [LLMPromptSegment] {
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [LLMPromptSegment] = []
        var trustedLines: [String] = []
        var index = 0

        func flushTrusted() {
            let body = trustedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                segments.append(LLMPromptSegment(title: "Rendered trusted prompt", body: body, trustLevel: .trustedInstruction))
            }
            trustedLines.removeAll()
        }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("BEGIN UNTRUSTED ") else {
                trustedLines.append(lines[index])
                index += 1
                continue
            }

            flushTrusted()
            let title = String(line.dropFirst("BEGIN UNTRUSTED ".count))
            index += 1
            var untrustedLines: [String] = []
            while index < lines.count {
                let current = lines[index]
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "END UNTRUSTED \(title)" {
                    index += 1
                    break
                }
                if current.hasPrefix("> ") {
                    untrustedLines.append(String(current.dropFirst(2)))
                } else if current == ">" {
                    untrustedLines.append("")
                } else {
                    untrustedLines.append(current)
                }
                index += 1
            }
            segments.append(LLMPromptSegment(title: title, body: untrustedLines.joined(separator: "\n"), trustLevel: .untrustedData))
        }

        flushTrusted()
        return segments.isEmpty ? [trusted("Rendered trusted prompt", prompt)] : segments
    }

    private static func shouldFetchReferenceContext(phase: AgentPhase, toolResults: [String]) -> Bool {
        switch phase {
        case .executeTool:
            false
        case .respond:
            toolResults.isEmpty
        default:
            true
        }
    }

    private static func shouldSummarizeConversation(phase: AgentPhase, toolResults: [String]) -> Bool {
        !(phase == .respond && !toolResults.isEmpty)
    }
}
