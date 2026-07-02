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

    @Test func scoredRouterTreatsExplicitWebSearchAsWebFetchIntent() {
        let (container, _) = makeContext()

        let decision = container.toolRouter.routeDecision(input: "Search web")

        #expect(decision.toolName == "web_fetch")
        #expect(decision.confidence >= 0.55)
        #expect(decision.requiresApproval)
        #expect(decision.anchoredJustification.contains("search web"))
    }

    @Test func scoredRouterTreatsURLSearchAsWebFetchIntent() {
        let (container, _) = makeContext()

        let decision = container.toolRouter.routeDecision(input: "Search https://lapresse.ca for \"luc Bordeleau\"")

        #expect(decision.toolName == "web_fetch")
        #expect(decision.confidence >= 0.70)
        #expect(decision.requiresApproval)
        #expect(decision.anchoredJustification.contains("http_url"))
        #expect(decision.anchoredJustification.contains("target=lapresse.ca"))
    }

    @Test func scoredRouterUsesWholeKeywordMatches() {
        let (container, _) = makeContext()

        let decision = container.toolRouter.routeDecision(input: "contextual mapmaking notes")

        #expect(decision.abstained)
        #expect(decision.toolName == nil)
    }

    @Test func scoredRouterAbstainsWhenIntentIsUnsupported() {
        let (container, _) = makeContext()

        let decision = container.toolRouter.routeDecision(input: "make the vibes better but do not use a tool")

        #expect(decision.abstained)
        #expect(decision.tool == nil)
        #expect(decision.abstentionReason?.contains("No registered tool") == true)
    }

    @Test func runtimeFallsBackToLLMWhenToolRouteConfidenceIsLow() async throws {
        let (container, context) = makeContext()
        var completedResponse: String?

        for try await event in container.agentRuntime.run(
            goal: "What is Quebec net debt",
            conversationID: nil,
            messages: [],
            provider: FixedLLMProvider(response: "Quebec net debt should be answered by the model or an approved web lookup, not by a routing error."),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let response = try #require(completedResponse)
        let traces = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        #expect(response.contains("Quebec net debt should be answered"))
        #expect(!response.contains("No safe tool selected"))
        #expect(traces.contains { $0.phase == AgentPhase.selectTool.rawValue && $0.message.contains("below the abstention threshold") })
        #expect(try context.fetch(FetchDescriptor<ToolCallRecord>()).isEmpty)
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

    @Test func legacyRouterExecuteDoesNotBypassApprovalForHighRiskTool() async throws {
        let (_, context) = makeContext()
        let probe = ToolExecutionProbe()
        let router = ToolRouter(registry: ToolRegistry(tools: [ProbeHighRiskTool(probe: probe)]))

        var blockedToolName: String?
        do {
            _ = try await router.execute(input: "probe high risk action", context: context)
        } catch AgentRuntimeError.approvalRequired(let toolName) {
            blockedToolName = toolName
        }

        #expect(blockedToolName == "probe_high_risk")
        #expect(!probe.didExecute)
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
        let nilTarget = ApprovalTuple(
            toolName: "web_fetch",
            target: nil,
            normalizedArgumentsJSON: #"{"url":"https://example.com/a"}"#,
            riskLevel: .high,
            expiresAt: first.expiresAt,
            sessionID: sessionID,
            userVisibleDiff: "Fetch example.com/a"
        )
        let emptyTarget = ApprovalTuple(
            toolName: "web_fetch",
            target: "",
            normalizedArgumentsJSON: #"{"url":"https://example.com/a"}"#,
            riskLevel: .high,
            expiresAt: first.expiresAt,
            sessionID: sessionID,
            userVisibleDiff: "Fetch example.com/a"
        )

        #expect(first.payloadHash == sameButReordered.payloadHash)
        #expect(first.payloadHash != changed.payloadHash)
        #expect(nilTarget.payloadHash != emptyTarget.payloadHash)
        #expect(!first.isExpired())
        #expect(first.matches(toolName: "web_fetch", target: "example.com", normalizedArgumentsJSON: #"{"method":"GET","url":"https://example.com/a"}"#, riskLevel: .high, sessionID: sessionID))
    }

    @Test func approvalRecordPersistsExpandedTupleMetadata() {
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

    @Test func approvalRecordLegacyInitializerDerivesTupleDefaults() {
        let runID = UUID()
        let record = ApprovalRequestRecord(
            runID: runID,
            actionName: "memory_delete",
            reason: "Needs approval."
        )

        #expect(record.sessionID == runID)
        #expect(record.toolName == "memory_delete")
        #expect(record.target == nil)
        #expect(record.normalizedArgumentsJSON == "{}")
        #expect(record.riskLevel == ApprovalPolicy.defaultRiskLevel)
        #expect(record.userVisibleDiff == "Needs approval.")
        #expect(record.payloadHash == record.approvalTuple().payloadHash)
    }

    @Test func auditMetadataBackfillRepairsLegacyRows() throws {
        let (_, context) = makeContext()
        let runID = UUID()
        let approval = ApprovalRequestRecord(runID: runID, actionName: "web_fetch", reason: "Legacy approval.")
        approval.toolName = ""
        approval.normalizedArgumentsJSON = "{}"
        approval.payloadHash = ""
        approval.userVisibleDiff = ""
        approval.expiresAt = Date(timeIntervalSince1970: 0)
        let toolCall = ToolCallRecord(
            runID: runID,
            toolName: "web_fetch",
            input: "fetch [REDACTED]",
            output: "ok",
            riskLevel: ToolRiskLevel.high.rawValue,
            outcomeRawValue: ToolOutcome.success.rawValue,
            requiresApproval: true,
            approved: true,
            target: "example.com"
        )
        toolCall.normalizedArgumentsJSON = "{}"
        toolCall.payloadHash = ""
        context.insert(approval)
        context.insert(toolCall)
        try context.save()

        AuditMetadataBackfillService.run(context: context)

        #expect(approval.toolName == "web_fetch")
        #expect(approval.sessionID == runID)
        #expect(approval.normalizedArgumentsJSON != "{}")
        #expect(!approval.payloadHash.isEmpty)
        #expect(approval.userVisibleDiff == "Legacy approval.")
        #expect(toolCall.sessionID == runID)
        #expect(toolCall.normalizedArgumentsJSON != "{}")
        #expect(!toolCall.payloadHash.isEmpty)
        #expect(toolCall.errorCategory == "legacy_audit_hash_best_effort")
    }

    @Test func toolCallPayloadHashUsesExplicitSessionID() {
        let runID = UUID()
        let sessionID = UUID()
        let input = "fetch https://example.com/status"
        let record = ToolCallRecord(
            runID: runID,
            sessionID: sessionID,
            toolName: "web_fetch",
            input: input,
            output: "ok",
            riskLevel: ToolRiskLevel.high.rawValue,
            outcomeRawValue: ToolOutcome.success.rawValue,
            requiresApproval: true,
            approved: true,
            target: "example.com"
        )
        let expected = ApprovalTupleHasher.payloadHash(
            toolName: "web_fetch",
            target: "example.com",
            normalizedArgumentsJSON: ApprovalTupleHasher.normalizedArguments(toolName: "web_fetch", input: input, target: "example.com"),
            riskLevel: ToolRiskLevel.high.rawValue,
            sessionID: sessionID
        )

        #expect(record.sessionID == sessionID)
        #expect(record.payloadHash == expected)
        #expect(record.normalizedArgumentsJSON == ApprovalTupleHasher.normalizedArguments(toolName: "web_fetch", input: input, target: "example.com"))
    }

    @Test func runtimeRejectsExpiredApprovalCentrally() throws {
        let (container, context) = makeContext()
        let approval = ApprovalRequestRecord(
            runID: UUID(),
            actionName: "web_fetch",
            reason: "Expired approval.",
            toolName: "web_fetch",
            expiresAt: Date().addingTimeInterval(-1)
        )
        context.insert(approval)
        try context.save()

        do {
            try container.agentRuntime.approve(approval, context: context)
            #expect(Bool(false), "Expired approval should not be approved.")
        } catch AgentRuntimeError.approvalExpired(let toolName) {
            #expect(toolName == "web_fetch")
        }

        #expect(approval.approved == false)
        #expect(approval.resolvedAt != nil)
    }

    @Test func runtimeCreatesDestructiveApprovalTupleForDestructiveTool() async throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Keep this memory until explicitly deleted.", context: context)

        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: ScriptedLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired = event {
                break
            }
        }

        let approval = try #require(try context.fetch(FetchDescriptor<ApprovalRequestRecord>()).first)
        #expect(approval.toolName == "memory_delete")
        #expect(approval.riskLevel == .destructive)
        #expect(approval.riskLevelRawValue == ToolRiskLevel.destructive.rawValue)
        #expect(approval.normalizedArgumentsJSON.contains("forget all memories"))
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
        let route = try #require(matches.first { $0.name == "route" && $0.kind == .function })

        #expect(index.symbolCount >= 3)
        #expect(matches.contains { $0.name == "ToolRouter" && $0.kind == .struct })
        #expect(route.parentName == "ToolRouter")
        #expect(route.path == "monGARS/Tools/Tools.swift")
        #expect(route.lineStart == 6)
        #expect(route.lineEnd == 8)
        #expect(route.provenance == "test-sha:monGARS/Tools/Tools.swift:L6-L8")
        #expect(snapshot.repositoryName == "ales27pm/monGARS_2026")
        #expect(snapshot.modules.contains("Tools"))
    }

    @Test func repoSelfModelSearchUsesOnlyActiveIndex() throws {
        let (container, context) = makeContext()
        try container.repoSelfModelService.rebuildIndex(
            files: [RepoSourceFile(path: "Old.swift", content: "struct DeletedType {}")],
            repositoryName: "repo/app",
            commitHash: "old-sha",
            context: context
        )
        try container.repoSelfModelService.rebuildIndex(
            files: [RepoSourceFile(path: "New.swift", content: "struct CurrentType {}")],
            repositoryName: "repo/app",
            commitHash: "new-sha",
            context: context
        )

        #expect(try container.repoSelfModelService.symbols(matching: "DeletedType", context: context).isEmpty)
        #expect(try container.repoSelfModelService.symbols(matching: "CurrentType", context: context).contains { $0.commitHash == "new-sha" })
    }

    @Test func repoSelfModelSkipsLocalDeclarationsAndReadsCompoundModifiers() throws {
        let (container, context) = makeContext()
        let source = RepoSourceFile(
            path: "monGARS/Sample.swift",
            content: """
            public final class PublicBox {
                public static let shared = PublicBox()
                private static func hidden() {
                    let localValue = 1
                    func localHelper() {}
                }
            }
            """
        )

        try container.repoSelfModelService.rebuildIndex(files: [source], repositoryName: "repo/app", commitHash: "compound-sha", context: context)
        let publicMatches = try container.repoSelfModelService.symbols(matching: "PublicBox shared hidden", context: context)
        let localMatches = try container.repoSelfModelService.symbols(matching: "localValue localHelper", context: context)

        #expect(publicMatches.contains { $0.name == "PublicBox" && $0.privacyLevel == .publicAPI })
        #expect(publicMatches.contains { $0.name == "shared" && $0.privacyLevel == .publicAPI })
        #expect(publicMatches.contains { $0.name == "hidden" && $0.privacyLevel == .private })
        #expect(localMatches.isEmpty)
    }

    @Test func appSchemaIncludesRepoSelfModelRecords() {
        let modelNames = AppContainer.schemaModels.map { String(describing: $0) }

        #expect(modelNames.contains("RepoIndexRecord"))
        #expect(modelNames.contains("RepoSymbolRecord"))
    }
}

private struct FixedLLMProvider: LLMProvider {
    let name = "Fixed Test Provider"
    let capabilities = LLMProviderCapabilities.foundationLocal
    var response: String

    var status: String {
        get async { "Fixed test provider ready" }
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: response, providerName: name)
    }
}

private final class ToolExecutionProbe: @unchecked Sendable {
    var didExecute = false
}

private struct ProbeHighRiskTool: Tool {
    let probe: ToolExecutionProbe
    let name = "probe_high_risk"
    let description = "Probe high-risk execution for approval tests."
    let riskLevel: ToolRiskLevel = .high

    func canHandle(_ input: String) -> Bool {
        input.localizedCaseInsensitiveContains("probe high risk")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        probe.didExecute = true
        return ToolResult(toolName: name, output: "executed", riskLevel: riskLevel, requiresApproval: true, approved: request.approved)
    }
}
