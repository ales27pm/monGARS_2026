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
            Task {
                do {
                    var state = AgentState(userInput: input, messages: messages, currentNodeID: startNodeID)
                    while let node = nodes[state.currentNodeID] {
                        await context.event(.step(node.id))
                        continuation.yield(.step(node.id))
                        state = try await node.run(state, context)
                        state.completedNodeIDs.append(node.id)

                        let checkpoint = AgentCheckpoint(runID: state.runID, nodeID: node.id, summary: state.summary, state: state)
                        context.context.insert(AgentCheckpointRecord(runID: checkpoint.runID, nodeID: checkpoint.nodeID, stateSummary: checkpoint.summary))
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

    static func makeDefault(toolRouter: ToolRouter) -> AgentGraph {
        let route = AgentNode(id: "route") { state, execution in
            var next = state
            next.selectedToolName = execution.toolRouter.route(input: state.userInput)?.name
            return next
        }

        let tool = AgentNode(id: "tool") { state, execution in
            var next = state
            if let result = try await execution.toolRouter.execute(input: state.userInput, context: execution.context) {
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
                next.finalResponse = toolOutput
            } else {
                let request = LLMRequest(prompt: state.userInput, conversationContext: state.messages, retrievedContext: state.retrievedContext)
                var accumulated = ""
                for try await chunk in execution.llmProvider.stream(request: request) {
                    accumulated += chunk
                    await execution.event(.partialResponse(accumulated))
                }
                next.finalResponse = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if next.finalResponse.isEmpty {
                    let response = try await execution.llmProvider.complete(request: request)
                    next.finalResponse = response.text
                }
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
}
