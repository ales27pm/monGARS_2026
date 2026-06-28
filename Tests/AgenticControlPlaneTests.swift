import Foundation
import SwiftData
import Testing
@testable import monGARS

@MainActor
struct AgenticControlPlaneTests {
    private func makeContext() -> (AppContainer, ModelContext) {
        let container = AppContainer(inMemory: true)
        return (container, ModelContext(container.modelContainer))
    }

    @Test func scoredRouterReturnsAnchoredDecisionForNetworkFetch() {
        let (container, _) = makeContext()

        let decision = container.toolRouter.routeDecision(input: "fetch https://example.com/status")

        #expect(decision.toolName == "web_fetch")
        #expect(decision.confidence >= 0.75)
        #expect(decision.requiresApproval)
        #expect(decision.riskLevel == .high)
        #expect(decision.anchoredJustification.contains("http_url"))
        #expect(decision.anchoredJustification.contains("requires_network=true"))
    }

    @Test func scoredRouterAbstainsWhenIntentIsUnsupported() {
        let (container, _) = makeContext()

        let decision = container.toolRouter.routeDecision(input: "make the vibes better but do not use a tool")

        #expect(decision.abstained)
        #expect(decision.tool == nil)
        #expect(decision.abstentionReason?.contains("No registered tool") == true)
    }

    @Test func scoredRouterKeepsMemorySaveDistinctFromLookup() {
        let (container, _) = makeContext()

        let save = container.toolRouter.routeDecision(input: "remember that my passport expires in July")
        let lookup = container.toolRouter.routeDecision(input: "what do you remember about my passport")

        #expect(save.toolName == "memory_save")
        #expect(!save.abstained)
        #expect(lookup.toolName == "memory_lookup")
        #expect(!lookup.abstained)
    }

    @Test func immutableApprovalTupleHashChangesWhenArgumentsChange() {
        let sessionID = UUID()
        let first = ApprovalTuple(
            toolName: "web_fetch",
            target: "example.com",
            normalizedArgumentsJSON: #"{"url":"https://example.com/a","method":"GET"}"#,
            riskLevel: .high,
            expiresAt: Date().addingTimeInterval(60),
            sessionID: sessionID,
            userVisibleDiff: "Fetch example.com/a"
        )
        let sameButReordered = ApprovalTuple(
            toolName: "web_fetch",
            target: "example.com",
            normalizedArgumentsJSON: #"{"method":"GET","url":"https://example.com/a"}"#,
            riskLevel: .high,
            expiresAt: first.expiresAt,
            sessionID: sessionID,
            userVisibleDiff: "Fetch example.com/a"
        )
        let changed = ApprovalTuple(
            toolName: "web_fetch",
            target: "example.com",
            normalizedArgumentsJSON: #"{"url":"https://example.com/b","method":"GET"}"#,
            riskLevel: .high,
            expiresAt: first.expiresAt,
            sessionID: sessionID,
            userVisibleDiff: "Fetch example.com/b"
        )

        #expect(first.payloadHash == sameButReordered.payloadHash)
        #expect(first.payloadHash != changed.payloadHash)
        #expect(!first.isExpired())
        #expect(first.matches(toolName: "web_fetch", target: "example.com", normalizedArgumentsJSON: #"{"method":"GET","url":"https://example.com/a"}"#, riskLevel: .high, sessionID: sessionID))
    }

    @Test func approvalRecordPersistsTupleMetadataWithBackwardsCompatibleInit() {
        let runID = UUID()
        let sessionID = UUID()
        let record = ApprovalRequestRecord(
            runID: runID,
            actionName: "web_fetch",
            reason: "Fetch and extract a short web preview. Target: example.com.",
            sessionID: sessionID,
            toolName: "web_fetch",
            target: "example.com",
            normalizedArgumentsJSON: #"{"url":"https://example.com/status"}"#,
            riskLevelRawValue: ToolRiskLevel.high.rawValue,
            userVisibleDiff: "Fetch https://example.com/status"
        )

        #expect(record.runID == runID)
        #expect(record.sessionID == sessionID)
        #expect(record.toolName == "web_fetch")
        #expect(record.actionName == "web_fetch")
        #expect(record.target == "example.com")
        #expect(record.riskLevel == .high)
        #expect(record.payloadHash == record.approvalTuple().payloadHash)
        #expect(!record.isExpired())
    }

    @Test func repoSelfModelIndexesSymbolsWithLineProvenance() throws {
        let (container, context) = makeContext()
        let source = RepoSourceFile(
            path: "monGARS/Tools/Tools.swift",
            content: """
            import Foundation

            struct ToolRouter: Sendable {
                let registry: ToolRegistry

                func route(input: String) -> (any Tool)? {
                    registry.tools.first { $0.canHandle(input) }
                }
            }
            """
        )

        let index = try container.repoSelfModelService.rebuildIndex(
            files: [source],
            repositoryName: "ales27pm/monGARS_2026",
            commitHash: "test-sha",
            context: context
        )
        let matches = try container.repoSelfModelService.symbols(matching: "ToolRouter route", context: context)
        let snapshot = try #require(try container.repoSelfModelService.latestSnapshot(context: context))

        #expect(index.symbolCount >= 3)
        #expect(matches.contains { $0.name == "ToolRouter" && $0.kind == .struct })
        #expect(matches.contains { $0.name == "route" && $0.kind == .function && $0.parentName == "ToolRouter" })
        #expect(matches.allSatisfy { $0.provenance.contains("test-sha") })
        #expect(snapshot.repositoryName == "ales27pm/monGARS_2026")
        #expect(snapshot.modules.contains("Tools"))
    }

    @Test func appSchemaIncludesRepoSelfModelRecords() {
        let modelNames = AppContainer.schemaModels.map { String(describing: $0) }

        #expect(modelNames.contains("RepoIndexRecord"))
        #expect(modelNames.contains("RepoSymbolRecord"))
    }
}
