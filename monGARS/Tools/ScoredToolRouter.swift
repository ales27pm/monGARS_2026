import Foundation
import SwiftData

struct ToolRouteDecision: Sendable {
    var tool: (any Tool)?
    var toolName: String?
    var confidence: Double
    var anchoredJustification: String
    var riskLevel: ToolRiskLevel?
    var requiresApproval: Bool
    var abstained: Bool
    var abstentionReason: String?
    var competingToolName: String?
    var competingConfidence: Double?

    static func abstain(reason: String, competingToolName: String? = nil, competingConfidence: Double? = nil) -> ToolRouteDecision {
        ToolRouteDecision(
            tool: nil,
            toolName: nil,
            confidence: 0,
            anchoredJustification: reason,
            riskLevel: nil,
            requiresApproval: false,
            abstained: true,
            abstentionReason: reason,
            competingToolName: competingToolName,
            competingConfidence: competingConfidence
        )
    }
}

private struct ToolRouteCandidate {
    var tool: any Tool
    var confidence: Double
    var evidence: [String]
}

extension ToolRouter {
    private var minimumRouteConfidence: Double { 0.35 }
    private var ambiguityMargin: Double { 0.08 }

    func routeDecision(input: String) -> ToolRouteDecision {
        let candidates = registry.tools
            .map { score(tool: $0, input: input) }
            .filter { $0.confidence > 0 }
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return registryIndex(of: lhs.tool.name) < registryIndex(of: rhs.tool.name)
                }
                return lhs.confidence > rhs.confidence
            }

        guard let winner = candidates.first else {
            return .abstain(reason: "No registered tool matched the request with enough lexical or schema evidence.")
        }

        guard winner.confidence >= minimumRouteConfidence else {
            return .abstain(
                reason: "Top route confidence \(Self.format(winner.confidence)) is below the abstention threshold \(Self.format(minimumRouteConfidence)).",
                competingToolName: winner.tool.name,
                competingConfidence: winner.confidence
            )
        }

        if let runnerUp = candidates.dropFirst().first,
           winner.confidence - runnerUp.confidence < ambiguityMargin {
            return .abstain(
                reason: "Ambiguous tool route between \(winner.tool.name) and \(runnerUp.tool.name); confidence gap \(Self.format(winner.confidence - runnerUp.confidence)) is below \(Self.format(ambiguityMargin)).",
                competingToolName: runnerUp.tool.name,
                competingConfidence: runnerUp.confidence
            )
        }

        let metadata = winner.tool.metadata(for: input)
        let riskLevel = winner.tool.riskLevel
        let justificationParts = [
            "confidence=\(Self.format(winner.confidence))",
            "schema=\(winner.tool.schema.inputDescription)",
            metadata.actionPreview.map { "action=\($0)" },
            metadata.targetPreview.map { "target=\($0)" },
            metadata.requiresNetwork ? "requires_network=true" : nil,
            winner.evidence.isEmpty ? nil : "evidence=\(winner.evidence.joined(separator: "; "))"
        ].compactMap { $0 }

        return ToolRouteDecision(
            tool: winner.tool,
            toolName: winner.tool.name,
            confidence: winner.confidence,
            anchoredJustification: justificationParts.joined(separator: " | "),
            riskLevel: riskLevel,
            requiresApproval: winner.tool.requiresApproval || riskLevel.requiresApprovalByDefault,
            abstained: false,
            abstentionReason: nil,
            competingToolName: candidates.dropFirst().first?.tool.name,
            competingConfidence: candidates.dropFirst().first?.confidence
        )
    }

    func execute(decision: ToolRouteDecision, request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult? {
        guard !decision.abstained, let tool = decision.tool else { return nil }
        return try await tool.execute(request: request, context: context)
    }

    private func score(tool: any Tool, input: String) -> ToolRouteCandidate {
        let normalized = ToolRouteScorer.normalized(input)
        var evidence: [String] = []
        var score = 0.0

        if tool.canHandle(input) {
            score += 0.55
            evidence.append("tool.canHandle matched")
        }

        let profile = ToolRouteScorer.profile(for: tool.name)
        let matchedPositive = profile.positiveKeywords.filter { normalized.contains($0) }
        if !matchedPositive.isEmpty {
            let keywordScore = min(0.35, Double(matchedPositive.count) * 0.08)
            score += keywordScore
            evidence.append("keywords: \(matchedPositive.prefix(5).joined(separator: ", "))")
        }

        let matchedNegative = profile.negativeKeywords.filter { normalized.contains($0) }
        if !matchedNegative.isEmpty {
            score -= min(0.35, Double(matchedNegative.count) * 0.10)
            evidence.append("negative keywords: \(matchedNegative.prefix(5).joined(separator: ", "))")
        }

        if profile.requiresURL, ToolRouteScorer.containsHTTPURL(input) {
            score += 0.18
            evidence.append("http_url present")
        } else if profile.requiresURL, normalized.contains("url") || normalized.contains("website") {
            score += 0.08
            evidence.append("url intent present")
        }

        if profile.prefersArithmetic, ToolRouteScorer.containsArithmetic(input) {
            score += 0.28
            evidence.append("arithmetic expression present")
        }

        if profile.requiresPhone, ToolRouteScorer.containsPhoneNumber(input) {
            score += 0.20
            evidence.append("phone number present")
        }

        if profile.requiresEmail, ToolRouteScorer.containsEmail(input) {
            score += 0.20
            evidence.append("email address present")
        }

        if tool.riskLevel.requiresApprovalByDefault {
            evidence.append("risk=\(tool.riskLevel.rawValue)")
        }

        return ToolRouteCandidate(tool: tool, confidence: max(0, min(1, score)), evidence: evidence)
    }

    private func registryIndex(of toolName: String) -> Int {
        registry.tools.firstIndex { $0.name == toolName } ?? Int.max
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private struct ToolRouteProfile {
    var positiveKeywords: [String]
    var negativeKeywords: [String] = []
    var requiresURL: Bool = false
    var requiresPhone: Bool = false
    var requiresEmail: Bool = false
    var prefersArithmetic: Bool = false
}

private enum ToolRouteScorer {
    static func profile(for toolName: String) -> ToolRouteProfile {
        switch toolName {
        case "document_summary":
            ToolRouteProfile(
                positiveKeywords: ["summarize document", "document summary", "summarize imported", "summarize my imported document", "summary"],
                negativeKeywords: ["search document", "find in document"]
            )
        case "document_search":
            ToolRouteProfile(
                positiveKeywords: ["document", "documents", "imported", "notes", "search document", "find in document"],
                negativeKeywords: ["summarize document", "document summary"]
            )
        case "memory_save":
            ToolRouteProfile(
                positiveKeywords: ["remember that", "save memory", "save this memory", "remember key points", "remember the key points", "remember my"],
                negativeKeywords: ["what do you remember", "search memory", "what is my name", "who am i"]
            )
        case "memory_lookup":
            ToolRouteProfile(
                positiveKeywords: ["memory", "memories", "what do you remember", "search memory", "what is my name", "who am i"],
                negativeKeywords: ["remember that", "save memory", "save this memory", "remember key points", "forget all"]
            )
        case "memory_delete":
            ToolRouteProfile(positiveKeywords: ["forget all", "delete memory", "forget memories", "delete memories", "memory reset"])
        case "calculator":
            ToolRouteProfile(positiveKeywords: ["calculate", "what is"], prefersArithmetic: true)
        case "date_time":
            ToolRouteProfile(positiveKeywords: ["time", "date", "today", "current time", "what day"])
        case "task_manager":
            ToolRouteProfile(positiveKeywords: ["create task", "complete task", "update task", "task manager"])
        case "diagnostics":
            ToolRouteProfile(positiveKeywords: ["diagnostic", "diagnostics", "developer report", "tool calls", "checkpoints"])
        case "conversation_search":
            ToolRouteProfile(positiveKeywords: ["conversation", "chat history", "previous chat", "search chat"])
        case "weather_lookup":
            ToolRouteProfile(positiveKeywords: ["weather", "forecast", "temperature", "humidity"])
        case "current_location":
            ToolRouteProfile(positiveKeywords: ["where am i", "current location", "my location", "show me where i am"])
        case "maps_lookup":
            ToolRouteProfile(positiveKeywords: ["map", "maps", "directions", "navigate", "nearby", "show me where"], negativeKeywords: ["where am i"])
        case "integrated_webview":
            ToolRouteProfile(positiveKeywords: ["webview", "web view", "open website", "open url"], requiresURL: true)
        case "web_fetch":
            ToolRouteProfile(positiveKeywords: ["web fetch", "fetch", "download url", "read url", "extract page"], requiresURL: true)
        case "remote_network":
            ToolRouteProfile(positiveKeywords: ["remote network", "remote http", "network request", "get ", "post ", "put ", "patch ", "delete "], requiresURL: true)
        case "local_file":
            ToolRouteProfile(positiveKeywords: ["local file", "list files", "read file", "write file", "delete file", "agent file"])
        case "contacts_lookup":
            ToolRouteProfile(positiveKeywords: ["contact", "contacts", "phone number for", "email address for"])
        case "calendar_manager":
            ToolRouteProfile(positiveKeywords: ["calendar", "create event", "schedule", "meeting", "appointment"])
        case "reminder_manager":
            ToolRouteProfile(positiveKeywords: ["remind me", "create reminder", "add reminder", "reminder"])
        case "email_compose":
            ToolRouteProfile(positiveKeywords: ["email", "send email", "compose email", "mailto"], negativeKeywords: ["read email", "inbox", "latest email"], requiresEmail: true)
        case "email_inbox":
            ToolRouteProfile(positiveKeywords: ["read email", "latest email", "email inbox", "inbox", "my email"], negativeKeywords: ["compose email", "send email"])
        case "text_message":
            ToolRouteProfile(positiveKeywords: ["text", "send text", "sms", "message"], requiresPhone: true)
        case "phone_call":
            ToolRouteProfile(positiveKeywords: ["call", "phone call", "dial"], requiresPhone: true)
        default:
            ToolRouteProfile(positiveKeywords: [toolName.replacingOccurrences(of: "_", with: " ")])
        }
    }

    static func normalized(_ input: String) -> String {
        input.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s:/\.@+\-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsHTTPURL(_ input: String) -> Bool {
        input.range(of: #"https?://[^\s]+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func containsArithmetic(_ input: String) -> Bool {
        input.range(of: #"[0-9]+\s*[+\-*/]\s*[0-9]+"#, options: .regularExpression) != nil
    }

    static func containsPhoneNumber(_ input: String) -> Bool {
        input.range(of: #"\+?[0-9][0-9\s\-\(\)\.]{5,}[0-9]"#, options: .regularExpression) != nil
    }

    static func containsEmail(_ input: String) -> Bool {
        input.range(of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
