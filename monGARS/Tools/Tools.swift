import Foundation
import SwiftData

struct ToolResult: Sendable {
    var toolName: String
    var output: String
    var riskLevel: ToolRiskLevel = .low
    var requiresApproval: Bool = false
    var approved: Bool = true
}

protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var schema: ToolSchema { get }
    var riskLevel: ToolRiskLevel { get }
    var requiresApproval: Bool { get }
    func canHandle(_ input: String) -> Bool
    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult
}

extension Tool {
    var schema: ToolSchema {
        ToolSchema(inputDescription: description, examples: [])
    }

    var riskLevel: ToolRiskLevel { .low }

    var requiresApproval: Bool { riskLevel.requiresApprovalByDefault }

    func run(input: String, context: ModelContext) async throws -> ToolResult {
        try await execute(request: ToolExecutionRequest(runID: UUID(), input: input, autonomyLevel: .assisted, approved: true), context: context)
    }
}

struct ToolRegistry: Sendable {
    let tools: [any Tool]

    static func defaultRegistry(memoryService: MemoryService, documentService: DocumentService) -> ToolRegistry {
        ToolRegistry(tools: [
            DateTimeTool(),
            CalculatorTool(),
            DocumentSummaryTool(documentService: documentService),
            DocumentSearchTool(documentService: documentService),
            MemorySaveTool(memoryService: memoryService),
            MemoryLookupTool(memoryService: memoryService),
            MemoryDeleteTool(memoryService: memoryService),
            ConversationSearchTool(),
            DiagnosticsTool(),
            TaskTool(),
            RemoteNetworkTool()
        ])
    }
}

struct ToolRouter: Sendable {
    let registry: ToolRegistry

    func route(input: String) -> (any Tool)? {
        registry.tools.first { $0.canHandle(input) }
    }

    func execute(input: String, context: ModelContext) async throws -> ToolResult? {
        guard let tool = route(input: input) else { return nil }
        return try await tool.run(input: input, context: context)
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult? {
        guard let tool = route(input: request.input) else { return nil }
        return try await tool.execute(request: request, context: context)
    }
}

struct DateTimeTool: Tool {
    let name = "date_time"
    let description = "Answers current date and time questions."

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("time") || lower.contains("date") || lower.contains("today")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return ToolResult(toolName: name, output: "Local device time: \(formatter.string(from: .now)).")
    }
}

struct CalculatorTool: Tool {
    let name = "calculator"
    let description = "Evaluates basic arithmetic expressions."

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("calculate") || lower.contains("what is") && input.range(of: #"[0-9]+ *[+\-*/] *[0-9]+"#, options: .regularExpression) != nil
    }

    var schema: ToolSchema {
        ToolSchema(inputDescription: "A basic arithmetic expression using +, -, *, /, and parentheses.", examples: ["calculate 12 * (3 + 4)"])
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let expression = request.input.replacingOccurrences(of: "calculate", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "what is", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var evaluator = ArithmeticEvaluator(expression: expression)
        let value = try evaluator.parse()
        return ToolResult(toolName: name, output: "\(expression) = \(String(format: "%.4g", value))")
    }
}

enum CalculatorError: LocalizedError {
    case invalidExpression

    var errorDescription: String? {
        "I can calculate basic +, -, *, / expressions with numbers and parentheses."
    }
}

struct ArithmeticEvaluator {
    private let characters: [Character]
    private var index = 0

    init(expression: String) {
        characters = Array(expression.filter { !$0.isWhitespace })
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        guard index == characters.count else { throw CalculatorError.invalidExpression }
        return value
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while let character = peek(), character == "+" || character == "-" {
            index += 1
            let next = try parseTerm()
            value = character == "+" ? value + next : value - next
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while let character = peek(), character == "*" || character == "/" {
            index += 1
            let next = try parseFactor()
            value = character == "*" ? value * next : value / next
        }
        return value
    }

    private mutating func parseFactor() throws -> Double {
        guard let character = peek() else { throw CalculatorError.invalidExpression }
        if character == "(" {
            index += 1
            let value = try parseExpression()
            guard peek() == ")" else { throw CalculatorError.invalidExpression }
            index += 1
            return value
        }
        if character == "-" {
            index += 1
            return try -parseFactor()
        }
        return try parseNumber()
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        while let character = peek(), character.isNumber || character == "." {
            index += 1
        }
        guard start != index else { throw CalculatorError.invalidExpression }
        let text = String(characters[start..<index])
        guard let value = Double(text) else { throw CalculatorError.invalidExpression }
        return value
    }

    private func peek() -> Character? {
        guard index < characters.count else { return nil }
        return characters[index]
    }
}

struct MemoryLookupTool: Tool {
    let name = "memory_lookup"
    let description = "Searches saved local memories."
    let memoryService: MemoryService

    func canHandle(_ input: String) -> Bool {
        input.lowercased().contains("memory") || input.lowercased().contains("remember")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let records = try memoryService.search(query: request.input, context: context)
        let output = records.isEmpty ? "No local memories matched." : records.map(\.content).joined(separator: "\n")
        return ToolResult(toolName: name, output: output)
    }
}

struct MemorySaveTool: Tool {
    let name = "memory_save"
    let description = "Saves important local memories."
    let memoryService: MemoryService

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("remember that") || lower.contains("save memory") || lower.contains("remember key points")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let content = request.input
            .replacingOccurrences(of: "remember that", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "save memory", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try memoryService.save(content: content.isEmpty ? request.input : content, source: "agent", scope: "longTerm", context: context)
        return ToolResult(toolName: name, output: "Saved a local memory.")
    }
}

struct MemoryDeleteTool: Tool {
    let name = "memory_delete"
    let description = "Deletes or forgets local memories."
    let riskLevel: ToolRiskLevel = .destructive
    let memoryService: MemoryService

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("forget all") || lower.contains("delete memory")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        guard request.approved else {
            throw AgentRuntimeError.approvalRequired(name)
        }
        if request.input.lowercased().contains("forget all") {
            let count = try memoryService.forgetAll(context: context)
            return ToolResult(toolName: name, output: "Deleted \(count) local memories.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        let records = try memoryService.search(query: request.input, context: context)
        for record in records {
            try memoryService.delete(record, context: context)
        }
        return ToolResult(toolName: name, output: "Deleted \(records.count) matching memories.", riskLevel: riskLevel, requiresApproval: true, approved: true)
    }
}

struct DocumentSearchTool: Tool {
    let name = "document_search"
    let description = "Searches imported text and Markdown documents."
    let documentService: DocumentService

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("document") || lower.contains("imported") || lower.contains("notes")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let snippets = try documentService.snippets(matching: request.input, context: context)
        let output = snippets.isEmpty ? "No imported document snippets matched." : snippets.joined(separator: "\n\n")
        return ToolResult(toolName: name, output: output)
    }
}

struct DocumentSummaryTool: Tool {
    let name = "document_summary"
    let description = "Summarizes imported text and Markdown documents."
    let documentService: DocumentService

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("summarize document") || lower.contains("document summary") || lower.contains("summarize my imported document")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let summaries = try documentService.documents(context: context).prefix(3).map { document in
            "\(document.title): \(document.content.prefix(180))"
        }
        let output = summaries.isEmpty ? "No documents have been imported yet." : summaries.joined(separator: "\n\n")
        return ToolResult(toolName: name, output: output)
    }
}

struct ConversationSearchTool: Tool {
    let name = "conversation_search"
    let description = "Searches local conversation history."

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("conversation") || lower.contains("chat history")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let conversations = try context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        let terms = request.input.searchTerms
        let matches = conversations.flatMap { conversation in
            conversation.messages.filter { message in
                terms.contains { message.content.lowercased().contains($0) }
            }.prefix(3).map { "\($0.role.rawValue): \($0.content)" }
        }.prefix(8)
        let output = matches.isEmpty ? "No conversation history matched." : matches.joined(separator: "\n")
        return ToolResult(toolName: name, output: output)
    }
}

struct DiagnosticsTool: Tool {
    let name = "diagnostics"
    let description = "Reports local agent runs, checkpoints, tool calls, and errors."

    func canHandle(_ input: String) -> Bool {
        input.lowercased().contains("diagnostic")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let runs = (try? context.fetchCount(FetchDescriptor<AgentRunRecord>())) ?? 0
        let checkpoints = (try? context.fetchCount(FetchDescriptor<AgentCheckpointRecord>())) ?? 0
        let toolCalls = (try? context.fetchCount(FetchDescriptor<ToolCallRecord>())) ?? 0
        return ToolResult(toolName: name, output: "Diagnostics: \(runs) agent runs, \(checkpoints) checkpoints, \(toolCalls) tool calls.")
    }
}

struct TaskTool: Tool {
    let name = "task_manager"
    let description = "Creates, updates, and completes local tasks."

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("create task") || lower.contains("complete task") || lower.contains("update task")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let lower = request.input.lowercased()
        if lower.contains("complete task") {
            let tasks = try context.fetch(FetchDescriptor<AgentTaskRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            if let task = tasks.first(where: { $0.statusRawValue != "completed" }) {
                task.statusRawValue = "completed"
                task.completedAt = .now
                task.updatedAt = .now
                try context.safeSave()
                return ToolResult(toolName: name, output: "Completed task: \(task.title)")
            }
            return ToolResult(toolName: name, output: "No active tasks to complete.")
        }

        let title = request.input
            .replacingOccurrences(of: "create task", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "update task", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let task = AgentTaskRecord(runID: request.runID, title: title.isEmpty ? request.input : title)
        context.insert(task)
        try context.safeSave()
        return ToolResult(toolName: name, output: "Created task: \(task.title)")
    }
}

struct RemoteNetworkTool: Tool {
    let name = "remote_network"
    let description = "Remote/network action placeholder. Disabled unless remote features are explicitly enabled."
    let riskLevel: ToolRiskLevel = .high

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("web") || lower.contains("network") || lower.contains("remote")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        guard request.approved else {
            throw AgentRuntimeError.approvalRequired(name)
        }
        return ToolResult(toolName: name, output: "Remote/network tools are stubbed and disabled by default.", riskLevel: riskLevel, requiresApproval: true, approved: request.approved)
    }
}
