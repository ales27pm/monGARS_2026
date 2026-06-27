import Foundation
import SwiftData

struct ToolResult: Sendable {
    var toolName: String
    var output: String
}

protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    func canHandle(_ input: String) -> Bool
    func run(input: String, context: ModelContext) async throws -> ToolResult
}

struct ToolRegistry: Sendable {
    let tools: [any Tool]

    static func defaultRegistry(memoryService: MemoryService, documentService: DocumentService) -> ToolRegistry {
        ToolRegistry(tools: [
            DateTimeTool(),
            CalculatorTool(),
            MemoryLookupTool(memoryService: memoryService),
            DocumentSummaryTool(documentService: documentService)
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
}

struct DateTimeTool: Tool {
    let name = "date_time"
    let description = "Answers current date and time questions."

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("time") || lower.contains("date") || lower.contains("today")
    }

    func run(input: String, context: ModelContext) async throws -> ToolResult {
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

    func run(input: String, context: ModelContext) async throws -> ToolResult {
        let expression = input.replacingOccurrences(of: "calculate", with: "", options: .caseInsensitive)
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

    func run(input: String, context: ModelContext) async throws -> ToolResult {
        let records = try memoryService.search(query: input, context: context)
        let output = records.isEmpty ? "No local memories matched." : records.map(\.content).joined(separator: "\n")
        return ToolResult(toolName: name, output: output)
    }
}

struct DocumentSummaryTool: Tool {
    let name = "document_summary"
    let description = "Summarizes imported text and Markdown documents."
    let documentService: DocumentService

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("summarize document") || lower.contains("document summary")
    }

    func run(input: String, context: ModelContext) async throws -> ToolResult {
        let summaries = try documentService.documents(context: context).prefix(3).map { document in
            "\(document.title): \(document.content.prefix(180))"
        }
        let output = summaries.isEmpty ? "No documents have been imported yet." : summaries.joined(separator: "\n\n")
        return ToolResult(toolName: name, output: output)
    }
}
