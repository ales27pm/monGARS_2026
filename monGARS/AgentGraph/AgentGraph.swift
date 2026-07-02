import Foundation
import SwiftData

struct AgentState: Sendable, Codable {
    var runID: UUID = UUID()
    var userInput: String
    var messages: [String] = []
    var selectedToolName: String?
    var toolOutput: String?
    var retrievedContext: [String] = []
    var finalResponse: String = ""
    var currentNodeID: String = "route"
    var completedNodeIDs: [String] = []

    var summary: String {
        let tool = selectedToolName ?? "none"
        return "input=\(userInput.prefix(40)); tool=\(tool); final=\(finalResponse.prefix(60))"
    }
}

struct AgentCheckpoint: Sendable, Codable, Identifiable {
    var id = UUID()
    var runID: UUID
    var nodeID: String
    var summary: String
    var state: AgentState
    var createdAt = Date()
}

enum AgentEvent: Sendable {
    case step(String)
    case toolCall(tool: String, input: String, output: String)
    case checkpoint(AgentCheckpoint)
    case partialResponse(String)
}

private extension AgentState {
    func checkpointSnapshot() -> AgentState {
        var snapshot = self
        snapshot.userInput = Self.truncated(userInput, limit: 1_200)
        snapshot.messages = Self.boundedStrings(messages, itemLimit: 6, characterLimit: 1_200)
        snapshot.toolOutput = toolOutput.map { Self.truncated($0, limit: 1_200) }
        snapshot.retrievedContext = Self.boundedStrings(retrievedContext, itemLimit: 6, characterLimit: 1_200)
        snapshot.finalResponse = Self.truncated(finalResponse, limit: 1_200)
        return snapshot
    }

    private static func boundedStrings(_ values: [String], itemLimit: Int, characterLimit: Int) -> [String] {
        values.suffix(itemLimit).map { truncated($0, limit: characterLimit) }
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "\n[truncated]"
    }
}

struct AgentNode: Sendable {
    let id: String
    let run: @Sendable (AgentState, AgentExecutionContext) async throws -> AgentState
}

struct AgentEdge: Sendable {
    let from: String
    let to: String
    let condition: @Sendable (AgentState) -> Bool
}

struct AgentExecutionContext {
    let llmProvider: any LLMProvider
    let toolRouter: ToolRouter
    let context: ModelContext
    let event: @Sendable (AgentEvent) async -> Void
}

struct AgentGraph: Sendable {
    private let startNodeID: String
    private let nodes: [String: AgentNode]
    private let edges: [AgentEdge]

    init(startNodeID: String, nodes: [AgentNode], edges: [AgentEdge]) {
        self.startNodeID = startNodeID
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        self.edges = edges
    }

    func run(input: String, messages: [String], context: AgentExecutionContext) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    var state = AgentState(userInput: input, messages: messages, currentNodeID: startNodeID)
                    while let node = nodes[state.currentNodeID] {
                        await context.event(.step(node.id))
                        continuation.yield(.step(node.id))
                        state = try await node.run(state, context)
                        state.completedNodeIDs.append(node.id)

                        let checkpointState = state.checkpointSnapshot()
                        let checkpoint = AgentCheckpoint(runID: checkpointState.runID, nodeID: node.id, summary: checkpointState.summary, state: checkpointState)
                        let stateData = try? JSONEncoder().encode(checkpointState)
                        context.context.insert(AgentCheckpointRecord(runID: checkpoint.runID, nodeID: checkpoint.nodeID, stateSummary: checkpoint.summary, stateData: stateData))
                        try? context.context.save()
                        await context.event(.checkpoint(checkpoint))
                        continuation.yield(.checkpoint(checkpoint))

                        guard let edge = edges.first(where: { $0.from == node.id && $0.condition(state) }) else {
                            break
                        }
                        state.currentNodeID = edge.to
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func resume(from checkpoint: AgentCheckpoint, context: AgentExecutionContext) async throws -> AgentState {
        guard let edge = edges.first(where: { $0.from == checkpoint.nodeID && $0.condition(checkpoint.state) }) else {
            return checkpoint.state
        }
        var state = checkpoint.state
        state.currentNodeID = edge.to
        while let node = nodes[state.currentNodeID] {
            await context.event(.step(node.id))
            state = try await node.run(state, context)
            state.completedNodeIDs.append(node.id)
            guard let next = edges.first(where: { $0.from == node.id && $0.condition(state) }) else {
                return state
            }
            state.currentNodeID = next.to
        }
        return state
    }

    private static func responseSegments(for state: AgentState) -> [LLMPromptSegment] {
        [
            LLMPromptSegment(title: "Current phase", body: "respond", trustLevel: .trustedInstruction),
            LLMPromptSegment(title: "System rules", body: PromptContract.responseSystemRules, trustLevel: .trustedInstruction),
            LLMPromptSegment(title: "USER GOAL", body: state.userInput, trustLevel: .untrustedData),
            LLMPromptSegment(title: "CONVERSATION CONTEXT", body: state.messages.joined(separator: "\n\n"), trustLevel: .untrustedData),
            LLMPromptSegment(title: "RETRIEVED CONTEXT", body: state.retrievedContext.joined(separator: "\n\n"), trustLevel: .untrustedData),
            LLMPromptSegment(title: "Final answer contract", body: PromptContract.finalAnswer, trustLevel: .trustedInstruction)
        ]
    }

    private static func responseRequest(for state: AgentState) -> LLMRequest {
        let segments = responseSegments(for: state)
        return LLMRequest(
            prompt: LLMPromptAssembler.assemble(segments: segments),
            conversationContext: [],
            retrievedContext: [],
            segments: segments,
            isPromptPreassembled: true
        )
    }

    static func makeDefault(toolRouter: ToolRouter) -> AgentGraph {
        let route = AgentNode(id: "route") { state, execution in
            var next = state
            let decision = execution.toolRouter.routeDecision(input: state.userInput)
            next.selectedToolName = decision.toolName
            return next
        }

        let tool = AgentNode(id: "tool") { state, execution in
            var next = state
            let decision = execution.toolRouter.routeDecision(input: state.userInput)
            if decision.requiresApproval {
                next.toolOutput = AgentRuntimeError.approvalRequired(decision.toolName ?? "tool").localizedDescription
            } else if let result = try await execution.toolRouter.execute(input: state.userInput, context: execution.context) {
                next.toolOutput = result.output
                await execution.event(.toolCall(tool: result.toolName, input: state.userInput, output: result.output))
            }
            return next
        }

        let retrieve = AgentNode(id: "retrieve") { state, execution in
            var next = state
            next.retrievedContext = try DocumentService().snippets(matching: state.userInput, context: execution.context)
            return next
        }

        let respond = AgentNode(id: "respond") { state, execution in
            var next = state
            if let toolOutput = state.toolOutput {
                next.finalResponse = UserFacingResponseSanitizer.sanitize(toolOutput)
            } else {
                let request = Self.responseRequest(for: state)
                var accumulated = ""
                for try await chunk in execution.llmProvider.stream(request: request) {
                    accumulated += chunk
                }
                let responseText: String
                if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let response = try await execution.llmProvider.completeDetached(request: request)
                    responseText = response.text
                } else {
                    responseText = accumulated
                }
                next.finalResponse = try UserFacingResponseSanitizer.sanitizeModelResponse(responseText)
                await execution.event(.partialResponse(next.finalResponse))
            }
            return next
        }

        return AgentGraph(
            startNodeID: "route",
            nodes: [route, tool, retrieve, respond],
            edges: [
                AgentEdge(from: "route", to: "tool", condition: { $0.selectedToolName != nil }),
                AgentEdge(from: "route", to: "retrieve", condition: { $0.selectedToolName == nil }),
                AgentEdge(from: "tool", to: "respond", condition: { _ in true }),
                AgentEdge(from: "retrieve", to: "respond", condition: { _ in true })
            ]
        )
    }

    static func makeAutonomous(toolRouter: ToolRouter) -> AgentGraph {
        func simpleNode(_ id: String, transform: @escaping @Sendable (AgentState, AgentExecutionContext) async throws -> AgentState) -> AgentNode {
            AgentNode(id: id, run: transform)
        }

        let understand = simpleNode("UnderstandIntent") { state, _ in state }
        let retrieve = simpleNode("RetrieveContext") { state, execution in
            var next = state
            next.retrievedContext = try DocumentService().snippets(matching: state.userInput, context: execution.context)
            return next
        }
        let plan = simpleNode("Plan") { state, _ in
            var next = state
            next.messages.append("Plan: retrieve context, select tools, observe, reflect, respond, remember if useful.")
            return next
        }
        let selectTool = simpleNode("SelectTool") { state, execution in
            var next = state
            let decision = execution.toolRouter.routeDecision(input: state.userInput)
            next.selectedToolName = decision.toolName
            return next
        }
        let executeTool = simpleNode("ExecuteTool") { state, execution in
            var next = state
            let decision = execution.toolRouter.routeDecision(input: state.userInput)
            if decision.requiresApproval {
                next.toolOutput = AgentRuntimeError.approvalRequired(decision.toolName ?? "tool").localizedDescription
            } else if let result = try await execution.toolRouter.execute(input: state.userInput, context: execution.context) {
                next.toolOutput = result.output
                await execution.event(.toolCall(tool: result.toolName, input: state.userInput, output: result.output))
            }
            return next
        }
        let observe = simpleNode("ObserveResult") { state, _ in
            var next = state
            next.messages.append("Observation: \(state.toolOutput ?? state.retrievedContext.joined(separator: " "))")
            return next
        }
        let reflect = simpleNode("Reflect") { state, _ in
            var next = state
            next.messages.append("Reflection: answer is based on local context/tool output.")
            return next
        }
        let respond = simpleNode("Respond") { state, execution in
            var next = state
            if let toolOutput = state.toolOutput {
                next.finalResponse = UserFacingResponseSanitizer.sanitize(toolOutput)
            } else {
                let request = Self.responseRequest(for: state)
                let response = try await execution.llmProvider.completeDetached(request: request)
                next.finalResponse = try UserFacingResponseSanitizer.sanitizeModelResponse(response.text)
            }
            return next
        }
        let askUser = simpleNode("AskUser") { state, _ in state }
        let saveMemory = simpleNode("SaveMemory") { state, execution in
            var next = state
            if state.userInput.lowercased().contains("remember") {
                try MemoryService().save(content: state.finalResponse.isEmpty ? state.userInput : state.finalResponse, source: "agentGraph", scope: "longTerm", context: execution.context)
                next.messages.append("Saved memory.")
            }
            return next
        }

        return AgentGraph(
            startNodeID: "UnderstandIntent",
            nodes: [understand, retrieve, plan, selectTool, executeTool, observe, reflect, respond, askUser, saveMemory],
            edges: [
                AgentEdge(from: "UnderstandIntent", to: "RetrieveContext", condition: { _ in true }),
                AgentEdge(from: "RetrieveContext", to: "Plan", condition: { _ in true }),
                AgentEdge(from: "Plan", to: "SelectTool", condition: { _ in true }),
                AgentEdge(from: "SelectTool", to: "AskUser", condition: { $0.selectedToolName?.contains("delete") == true || $0.selectedToolName?.contains("remote") == true }),
                AgentEdge(from: "SelectTool", to: "ExecuteTool", condition: { $0.selectedToolName != nil }),
                AgentEdge(from: "SelectTool", to: "Reflect", condition: { $0.selectedToolName == nil }),
                AgentEdge(from: "ExecuteTool", to: "ObserveResult", condition: { $0.toolOutput != nil }),
                AgentEdge(from: "ExecuteTool", to: "AskUser", condition: { $0.toolOutput == nil }),
                AgentEdge(from: "ObserveResult", to: "Reflect", condition: { _ in true }),
                AgentEdge(from: "Reflect", to: "Respond", condition: { _ in true }),
                AgentEdge(from: "Respond", to: "SaveMemory", condition: { $0.userInput.lowercased().contains("remember") }),
                AgentEdge(from: "Respond", to: "SaveMemory", condition: { $0.userInput.lowercased().contains("key point") })
            ]
        )
    }
}
