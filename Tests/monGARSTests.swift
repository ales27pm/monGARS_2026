import Foundation
import SwiftData
import Testing
@testable import monGARS

#if canImport(UIKit)
import UIKit
#endif

final class TestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.withLock { storage }
    }

    func set(_ value: String) {
        lock.withLock {
            storage = value
        }
    }
}

#if canImport(UIKit)
private func makePDFData(text: String) -> Data {
    let data = NSMutableData()
    UIGraphicsBeginPDFContextToData(data, CGRect(x: 0, y: 0, width: 240, height: 160), nil)
    UIGraphicsBeginPDFPage()
    (text as NSString).draw(
        at: CGPoint(x: 24, y: 48),
        withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
    )
    UIGraphicsEndPDFContext()
    return data as Data
}
#endif

@MainActor
struct MonGARSTests {
    private func makeContext() -> (AppContainer, ModelContext) {
        let container = AppContainer(inMemory: true)
        return (container, ModelContext(container.modelContainer))
    }

    @Test func memorySearchFindsSavedFacts() throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "My preferred city is Montreal.", context: context)
        try container.memoryService.save(content: "My preferred city is Montreal.", context: context)
        let results = try container.memoryService.search(query: "city Montreal", context: context)
        #expect(results.count == 1)
        #expect(results.first?.content.contains("Montreal") == true)
        #expect((results.first?.importance ?? 0) > 0.5)
    }

    @Test func memoryEditExportAndForgetAllWork() throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Remember that my planning window is Friday morning.", context: context)
        let saved = try #require(try context.fetch(FetchDescriptor<MemoryRecord>()).first)

        try container.memoryService.edit(saved, content: "Remember that my planning window is Monday morning.", context: context)
        let export = try container.memoryService.exportText(context: context)
        #expect(export.contains("Monday morning"))
        #expect(saved.tags.contains("remember"))

        let deleted = try container.memoryService.forgetAll(context: context)
        let remaining = try context.fetch(FetchDescriptor<MemoryRecord>())
        #expect(deleted == 1)
        #expect(remaining.isEmpty)
    }

    @Test func toolRouterChoosesCalculator() async throws {
        let (container, context) = makeContext()
        let result = try await container.toolRouter.execute(input: "calculate 2 + 3", context: context)
        #expect(result?.toolName == "calculator")
        #expect(result?.output.contains("5") == true)
    }

    @Test func registryIncludesPrivacyGatedToolSurface() {
        let (container, _) = makeContext()
        let toolNames = Set(container.toolRouter.registry.tools.map(\.name))
        let expected: Set<String> = [
            "text_message",
            "phone_call",
            "email_inbox",
            "email_compose",
            "reminder_manager",
            "calendar_manager",
            "contacts_lookup",
            "weather_lookup",
            "current_location",
            "maps_lookup",
            "integrated_webview",
            "web_fetch",
            "local_file"
        ]

        #expect(expected.isSubset(of: toolNames))
    }

    @Test func networkClientValidatesStatusContentTypeAndLatency() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try #require(response), Data(#"{"ok":true}"#.utf8))
        }

        let client = NetworkClient(configuration: NetworkClientConfiguration(timeoutSeconds: 5, maxRetries: 0), session: session)
        let response = try await client.send(NetworkRequest(url: try #require(URL(string: "https://example.com/status")), acceptedContentTypes: ["application/json"]))

        #expect(response.statusCode == 200)
        #expect(response.text.contains("\"ok\""))
        #expect(response.latencyMs >= 0)

        TestURLProtocol.handler = nil
    }

    @Test func networkClientRejectsHTTPFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try #require(request.url), statusCode: 503, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            return (try #require(response), Data())
        }

        let client = NetworkClient(configuration: NetworkClientConfiguration(timeoutSeconds: 5, maxRetries: 0), session: session)
        do {
            _ = try await client.send(NetworkRequest(url: try #require(URL(string: "https://example.com/down")), acceptedContentTypes: ["application/json"]))
            #expect(Bool(false), "503 should fail")
        } catch NetworkClientError.unacceptableStatus(let status) {
            #expect(status == 503)
        }

        TestURLProtocol.handler = nil
    }

    @Test func networkClientBlocksPrivateLANByDefault() async throws {
        let client = NetworkClient(configuration: NetworkClientConfiguration(timeoutSeconds: 5, maxRetries: 0))
        do {
            _ = try await client.send(NetworkRequest(url: try #require(URL(string: "http://192.168.1.25/status"))))
            #expect(Bool(false), "Private LAN hosts should be blocked unless Developer Mode enables them.")
        } catch NetworkClientError.blockedHost(let host) {
            #expect(host == "192.168.1.25")
        }
    }

    @Test func networkClientStreamsLinesThroughConfiguredSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        TestURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )
            return (try #require(response), Data("data: one\n\ndata: two\n".utf8))
        }

        let client = NetworkClient(configuration: NetworkClientConfiguration(timeoutSeconds: 5, maxRetries: 0), session: session)
        var lines: [String] = []
        for try await event in client.streamLines(NetworkRequest(url: try #require(URL(string: "https://example.com/stream")), acceptedContentTypes: ["text/event-stream"])) {
            lines.append(event.line)
            #expect(event.statusCode == 200)
            #expect(event.finalURL.host == "example.com")
        }

        #expect(lines.contains("data: one"))
        #expect(lines.contains("data: two"))
        TestURLProtocol.handler = nil
    }

    @Test func htmlExtractorReturnsMetadataAndReadableText() {
        let html = """
        <html>
          <head>
            <title>Example &amp; Test</title>
            <meta name="description" content="Useful page summary">
            <link rel="canonical" href="https://example.com/article">
            <style>.hidden { display: none; }</style>
          </head>
          <body><nav>Skip this</nav><main><h1>Hello</h1><p>Readable body&nbsp;text.</p></main><script>bad()</script></body>
        </html>
        """

        let content = WebContentExtractor.extractHTML(html)

        #expect(content.title == "Example & Test")
        #expect(content.metaDescription == "Useful page summary")
        #expect(content.canonicalURL == "https://example.com/article")
        #expect(content.readableText.contains("Hello"))
        #expect(content.readableText.contains("Readable body text."))
        #expect(!content.readableText.contains("bad()"))
        #expect(!content.readableText.contains("Skip this"))
    }

    @Test func openWeatherServiceRequiresConfiguredKey() async throws {
        let service = OpenWeatherCompatibleWeatherService(
            endpoint: "https://example.com/weather",
            apiKey: "",
            units: "metric",
            client: NetworkClient(configuration: NetworkClientConfiguration(timeoutSeconds: 5, maxRetries: 0))
        )

        do {
            _ = try await service.currentWeather(for: "Montreal")
            #expect(Bool(false), "Weather fallback should not fake success without a key.")
        } catch WeatherServiceError.missingAPIKey {
            #expect(true)
        }
    }

    @Test func settingsHeaderParserValidatesNameValueLines() {
        #expect(SettingsStore.parseHeaders("X-Test: one\nAccept: application/json") == ["X-Test": "one", "Accept": "application/json"])
        #expect(SettingsStore.parseHeaders("Authorization") == nil)
        #expect(SettingsStore.parseHeaders("X-Empty:") == nil)
    }

    @Test func compactNavigationSmokeTestBuildsRootSections() {
        let (container, _) = makeContext()
        _ = RootView(container: container)

        #expect(AppSection.allCases.map(\.title) == ["Chat", "Memories", "Documents", "Goals", "Diagnostics", "Settings"])
        #expect(AppSection.allCases.allSatisfy { !$0.icon.isEmpty })
        #expect(AppSection.chat.id == "chat")
    }

    @Test func toolRouterRoutesPrivacyGatedTools() {
        let (container, _) = makeContext()
        let cases: [(String, String)] = [
            ("text 5551234567 hello", "text_message"),
            ("call 5551234567", "phone_call"),
            ("read my latest email", "email_inbox"),
            ("email sam@example.com hello", "email_compose"),
            ("remind me to check the oven", "reminder_manager"),
            ("schedule team sync tomorrow", "calendar_manager"),
            ("find contact Sarah", "contacts_lookup"),
            ("weather in Montreal", "weather_lookup"),
            ("what is the weather forecast for tomorrow", "weather_lookup"),
            ("where am I", "current_location"),
            ("show me where I am on map", "current_location"),
            ("map nearest coffee shop", "maps_lookup"),
            ("open webview https://example.com", "integrated_webview"),
            ("fetch https://example.com", "web_fetch"),
            ("write file note.txt content hello", "local_file")
        ]

        for testCase in cases {
            #expect(container.toolRouter.route(input: testCase.0)?.name == testCase.1)
        }
    }

    @Test func memorySaveIntentsWinOverMemoryLookup() {
        let (container, _) = makeContext()
        let cases = [
            "remember that my passport expires in July",
            "save memory project alpha ships Friday",
            "save this memory: the demo uses local documents",
            "remember key points from this summary",
            "remember the key points from this summary",
            "remember my name is Alexis"
        ]

        for input in cases {
            #expect(container.toolRouter.route(input: input)?.name == "memory_save")
        }
    }

    @Test func memoryLookupStillHandlesReadOnlyMemoryQueries() {
        let (container, _) = makeContext()
        let cases = [
            "search memory for project alpha",
            "what do you remember about the demo",
            "what is my name",
            "who am I"
        ]

        for input in cases {
            #expect(container.toolRouter.route(input: input)?.name == "memory_lookup")
        }
    }

    @Test func explicitNameMemorySaveCanBeLookedUp() async throws {
        let (container, context) = makeContext()
        let saveTool = MemorySaveTool(memoryService: container.memoryService)
        let lookupTool = MemoryLookupTool(memoryService: container.memoryService)

        let saveResult = try await saveTool.execute(
            request: ToolExecutionRequest(runID: UUID(), input: "Remember my name is Alexis", autonomyLevel: .assisted, approved: true),
            context: context
        )
        let lookupResult = try await lookupTool.execute(
            request: ToolExecutionRequest(runID: UUID(), input: "What is my name", autonomyLevel: .assisted, approved: true),
            context: context
        )

        #expect(saveResult.output.contains("User name is Alexis"))
        #expect(lookupResult.output.contains("User name is Alexis"))
    }

    @Test func documentSummaryIntentsWinOverDocumentSearch() {
        let (container, _) = makeContext()
        let cases = [
            "summarize my imported document",
            "summarize my imported document and remember the key points",
            "document summary for the imported notes"
        ]

        for input in cases {
            #expect(container.toolRouter.route(input: input)?.name == "document_summary")
        }
    }

    @Test func privacyGatedToolsRejectUnapprovedExecution() async throws {
        let (_, context) = makeContext()
        let tools: [(any Tool, String)] = [
            (TextMessageTool(), "text 5551234567 hello"),
            (PhoneCallTool(), "call 5551234567"),
            (EmailInboxTool(), "read my latest email"),
            (EmailTool(), "email sam@example.com hello"),
            (ReminderTool(), "remind me to check the oven"),
            (CalendarTool(), "schedule team sync tomorrow"),
            (ContactsTool(), "find contact Sarah"),
            (WeatherTool(), "weather in Montreal"),
            (CurrentLocationTool(), "where am I"),
            (MapsTool(), "map nearest coffee shop"),
            (WebViewTool(), "open webview https://example.com"),
            (WebFetchTool(), "fetch https://example.com"),
            (LocalFileTool(), "write file note.txt content hello")
        ]

        for (tool, input) in tools {
            let request = ToolExecutionRequest(runID: UUID(), input: input, autonomyLevel: .auto, approved: false)
            do {
                _ = try await tool.execute(request: request, context: context)
                #expect(Bool(false), "\(tool.name) should require approval")
            } catch AgentRuntimeError.approvalRequired(let toolName) {
                #expect(toolName == tool.name)
            } catch {
                #expect(Bool(false), "\(tool.name) threw unexpected error: \(error)")
            }
        }
    }

    @Test func approvedNetworkToolsStayDisabledUntilSettingsAllowsNetwork() async throws {
        let (_, context) = makeContext()
        let tools: [(any Tool, String)] = [
            (WeatherTool(), "weather in Montreal"),
            (WebViewTool(), "open webview https://example.com"),
            (WebFetchTool(), "fetch https://example.com"),
            (RemoteNetworkTool(), "remote network check")
        ]

        for (tool, input) in tools {
            let request = ToolExecutionRequest(runID: UUID(), input: input, autonomyLevel: .auto, approved: true, networkAccessAllowed: false)
            let result = try await tool.execute(request: request, context: context)
            #expect(result.output.contains("Network tools are disabled in Settings"))
            #expect(result.requiresApproval)
        }
    }

    @Test func remoteNetworkToolIsRealAndRequiresURLWhenEnabled() async throws {
        let (_, context) = makeContext()
        let request = ToolExecutionRequest(runID: UUID(), input: "remote network check", autonomyLevel: .auto, approved: true, networkAccessAllowed: true)
        let result = try await RemoteNetworkTool().execute(request: request, context: context)
        #expect(result.output.contains("Provide an HTTP or HTTPS URL"))
        #expect(!result.output.localizedCaseInsensitiveContains("stubbed"))
    }

    @Test func textMessageRequiresRecipientPhone() async throws {
        let (_, context) = makeContext()
        let request = ToolExecutionRequest(runID: UUID(), input: "text hello", autonomyLevel: .assisted, approved: true)
        let result = try await TextMessageTool().execute(request: request, context: context)
        #expect(result.output.contains("Provide a phone number"))
    }

    @Test func emailInboxRequestsFailHonestlyOnNativeIOS() async throws {
        let (_, context) = makeContext()
        let request = ToolExecutionRequest(runID: UUID(), input: "read my latest email", autonomyLevel: .assisted, approved: true)
        let result = try await EmailInboxTool().execute(request: request, context: context)

        #expect(result.toolName == "email_inbox")
        #expect(result.errorCategory == "platform_unavailable")
        #expect(result.output.contains("iOS does not expose Mail messages"))
        #expect(!result.output.localizedCaseInsensitiveContains("chatbot created by Apple"))
    }

    @Test func approvedLocalFileToolStaysInAgentWorkspace() async throws {
        let (_, context) = makeContext()
        let tool = LocalFileTool()
        let filename = "monGARS-test-\(UUID().uuidString).txt"
        let runID = UUID()

        _ = try await tool.execute(
            request: ToolExecutionRequest(runID: runID, input: "delete file \(filename)", autonomyLevel: .assisted, approved: true),
            context: context
        )

        let write = try await tool.execute(
            request: ToolExecutionRequest(runID: runID, input: "write file \(filename) content private local note", autonomyLevel: .assisted, approved: true),
            context: context
        )
        let list = try await tool.execute(
            request: ToolExecutionRequest(runID: runID, input: "list files", autonomyLevel: .assisted, approved: true),
            context: context
        )
        let read = try await tool.execute(
            request: ToolExecutionRequest(runID: runID, input: "read file \(filename)", autonomyLevel: .assisted, approved: true),
            context: context
        )
        let delete = try await tool.execute(
            request: ToolExecutionRequest(runID: runID, input: "delete file \(filename)", autonomyLevel: .assisted, approved: true),
            context: context
        )

        #expect(write.output.contains(filename))
        #expect(list.output.contains(filename))
        #expect(read.output == "private local note")
        #expect(delete.output.contains(filename))
    }

    @Test func localFileToolBlocksPathTraversal() async throws {
        let (_, context) = makeContext()
        let result = try await LocalFileTool().execute(
            request: ToolExecutionRequest(runID: UUID(), input: #"write file "../escape.txt" content no"#, autonomyLevel: .assisted, approved: true),
            context: context
        )
        #expect(result.output.contains("Provide a filename"))
    }

    @Test func keychainSaveReadDeleteRoundTrip() {
        let account = "test-\(UUID().uuidString)"
        KeychainStore.delete(account: account)
        KeychainStore.set(" secret-token ", for: account)
        #expect(KeychainStore.string(for: account) == "secret-token")
        KeychainStore.delete(account: account)
        #expect(KeychainStore.string(for: account).isEmpty)
    }

    #if canImport(UIKit)
    @Test func pdfKitExtractorReturnsPageText() throws {
        let data = makePDFData(text: "Hello selectable PDF")
        let extraction = try PDFTextExtractor.extract(data: data)

        #expect(extraction.text.contains("Page 1"))
        #expect(extraction.text.localizedCaseInsensitiveContains("Hello selectable PDF"))
    }
    #endif

    @Test func toolHandoffParserBuildsApprovedActions() {
        let message = """
        Prepared approved SMS handoff: sms:5551234567&body=hello.
        Prepared approved phone handoff: tel://5551234567.
        Prepared approved email handoff: mailto:sam@example.com?body=hello.
        Prepared approved Maps handoff: http://maps.apple.com/?q=coffee.
        Approved in-app webview navigation prepared: https://example.com.
        """

        let actions = ToolHandoffAction.actions(from: message)

        #expect(actions.contains { $0.label == "Open Messages" && $0.destination == .openURL })
        #expect(actions.contains { $0.label == "Call" && $0.destination == .openURL })
        #expect(actions.contains { $0.label == "Compose Email" && $0.destination == .mailCompose })
        #expect(actions.contains { $0.label == "Open Maps" && $0.destination == .openURL })
        #expect(actions.contains { $0.label == "Open Web View" && $0.destination == .integratedWebView && $0.url.absoluteString == "https://example.com" })
    }

    @Test func graphRecordsCheckpoints() async throws {
        let (container, context) = makeContext()
        let execution = AgentExecutionContext(
            llmProvider: MockLLMProvider(),
            toolRouter: container.toolRouter,
            context: context,
            event: { _ in }
        )

        for try await _ in container.agentGraph.run(input: "What time is it?", messages: [], context: execution) {}

        let records = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        #expect(records.contains { $0.nodeID == "route" })
        #expect(records.contains { $0.nodeID == "tool" })
        #expect(records.contains { $0.nodeID == "respond" })
    }

    @Test func checkpointResumeCompletesResponse() async throws {
        let (container, context) = makeContext()
        let execution = AgentExecutionContext(
            llmProvider: MockLLMProvider(),
            toolRouter: container.toolRouter,
            context: context,
            event: { _ in }
        )

        let state = AgentState(userInput: "calculate 4 * 5", selectedToolName: "calculator")
        let checkpoint = AgentCheckpoint(runID: state.runID, nodeID: "route", summary: state.summary, state: state)
        let resumed = try await container.agentGraph.resume(from: checkpoint, context: execution)
        #expect(resumed.finalResponse.contains("20"))
    }

    @Test func persistenceModelsSaveConversation() throws {
        let (_, context) = makeContext()
        let conversation = Conversation(title: "Test")
        conversation.messages.append(ChatMessage(role: .user, content: "Hello"))
        context.insert(conversation)
        try context.save()

        let conversations = try context.fetch(FetchDescriptor<Conversation>())
        #expect(conversations.count == 1)
        #expect(conversations.first?.messages.first?.content == "Hello")
    }

    @Test func documentServiceRanksAndHighlightsChunks() throws {
        let (container, context) = makeContext()
        let first = DocumentRecord(title: "Architecture.md", content: "Privacy first local agent. " + String(repeating: "telemetry buffer ", count: 12))
        let second = DocumentRecord(title: "Notes.md", content: "A short note about weather.")
        context.insert(first)
        context.insert(second)
        try container.documentService.rebuildChunks(for: first, context: context)
        try container.documentService.rebuildChunks(for: second, context: context)
        try context.save()

        let results = try container.documentService.rankedSnippets(matching: "telemetry buffer", context: context)
        #expect(results.first?.title == "Architecture.md")
        #expect(results.first?.highlightedText.contains("**telemetry**") == true)
        #expect(results.first?.highlightedText.contains("**buffer**") == true)
        #expect(results.first?.source == "lexical")
    }

    @Test func documentDeleteRemovesChunks() throws {
        let (container, context) = makeContext()
        let document = DocumentRecord(title: "Delete.md", content: String(repeating: "delete chunk ", count: 80))
        context.insert(document)
        try container.documentService.rebuildChunks(for: document, context: context)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<DocumentChunkRecord>()).isEmpty == false)

        try container.documentService.delete(document, context: context)

        #expect(try context.fetch(FetchDescriptor<DocumentRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DocumentChunkRecord>()).isEmpty)
    }

    @Test func coreMLEmbeddingProviderReportsUnavailableWithoutBundledModel() {
        let provider = CoreMLEmbeddingProvider()
        if case .unavailable(let reason) = provider.status {
            #expect(reason.contains("DocumentEmbedding") || reason.contains("CoreML"))
        } else {
            #expect(Bool(false), "Test environment unexpectedly has a bundled DocumentEmbedding model.")
        }
    }

    @Test func autonomousRuntimeCompletesAndPersistsTrace() async throws {
        let (container, context) = makeContext()
        let document = DocumentRecord(
            title: "Demo Notes.md",
            content: "The demo document says monGARS should summarize imported Markdown and remember the privacy-first key points."
        )
        context.insert(document)
        try container.documentService.rebuildChunks(for: document, context: context)
        try context.save()

        var finalResponse = ""
        for try await event in container.agentRuntime.run(
            goal: "summarize my imported document and remember the key points",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .semiAuto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .completed(_, let response) = event {
                finalResponse = response
            }
        }

        let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
        let traces = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        let memories = try context.fetch(FetchDescriptor<MemoryRecord>())
        let toolCalls = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(runs.first?.statusRawValue == AgentRunStatus.completed.rawValue)
        #expect(traces.contains { $0.phase == AgentPhase.selectTool.rawValue && $0.message.contains("document_summary") })
        #expect(traces.contains { $0.phase == AgentPhase.plan.rawValue })
        #expect(traces.contains { $0.phase == AgentPhase.reflect.rawValue })
        #expect(toolCalls.contains { $0.toolName == "document_summary" && $0.output.contains("Demo Notes.md") })
        #expect(memories.contains { $0.source.contains("agentRun") && $0.content.contains("Demo Notes.md") })
        #expect(!finalResponse.isEmpty)
        #expect(finalResponse.contains("Demo Notes.md"))
    }

    @Test func autonomousRuntimePersistsMaxStepStop() async throws {
        let (container, context) = makeContext()

        do {
            for try await _ in container.agentRuntime.run(
                goal: "summarize my imported document and remember key points",
                conversationID: nil,
                messages: [],
                provider: MockLLMProvider(),
                options: AgentRuntimeOptions(autonomyLevel: .semiAuto, maxSteps: 2, timeoutSeconds: 20),
                context: context
            ) {}
        } catch {
            #expect(error.localizedDescription == AgentRuntimeError.maxStepsReached.localizedDescription)
        }

        let run = try #require(try context.fetch(FetchDescriptor<AgentRunRecord>()).first)
        #expect(run.statusRawValue == AgentRunStatus.maxStepsReached.rawValue)
        #expect(run.lastError == AgentRuntimeError.maxStepsReached.localizedDescription)
        #expect(run.completedAt != nil)
    }

    @Test func pauseAndCancelPersistControlDiagnostics() throws {
        let (container, context) = makeContext()
        let runID = UUID()
        let run = AgentRunRecord(
            id: runID,
            goal: "calculate 2 + 3",
            statusRawValue: AgentRunStatus.running.rawValue,
            currentPhase: AgentPhase.plan.rawValue,
            currentStep: 3,
            requiresApproval: true
        )
        let approval = ApprovalRequestRecord(runID: runID, actionName: "memory_delete", reason: "Needs approval.")
        context.insert(run)
        context.insert(approval)
        try context.save()

        try container.agentRuntime.pause(run: run, context: context)
        var traces = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        var checkpoints = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        #expect(run.statusRawValue == AgentRunStatus.paused.rawValue)
        #expect(run.requiresApproval == false)
        #expect(traces.contains { $0.runID == runID && $0.message == "Run paused by user." })
        #expect(checkpoints.contains { $0.runID == runID && $0.nodeID == AgentRunStatus.paused.rawValue })

        try container.agentRuntime.cancel(run: run, context: context)
        traces = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        checkpoints = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        #expect(run.statusRawValue == AgentRunStatus.cancelled.rawValue)
        #expect(run.lastError == AgentRuntimeError.cancelled.localizedDescription)
        #expect(run.completedAt != nil)
        #expect(approvals.first?.approved == false)
        #expect(traces.contains { $0.runID == runID && $0.message == "Run cancelled by user." })
        #expect(checkpoints.contains { $0.runID == runID && $0.nodeID == AgentRunStatus.cancelled.rawValue })
    }

    @Test func approvalGateBlocksDestructiveMemoryDelete() async throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Keep this important memory.", context: context)

        var approvalToolName: String?
        var approvalRunID: UUID?
        var completedResponse = ""
        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired(let runID, let approvalID, let toolName, _) = event {
                approvalToolName = toolName
                approvalRunID = runID
                let memoriesBeforeApproval = try context.fetch(FetchDescriptor<MemoryRecord>())
                #expect(memoriesBeforeApproval.count == 1)
                try container.agentRuntime.approve(approvalID: approvalID, context: context)
            }
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        let memories = try context.fetch(FetchDescriptor<MemoryRecord>())
        let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
        let traces = try context.fetch(FetchDescriptor<AgentTraceRecord>())
        #expect(approvalToolName == "memory_delete")
        #expect(approvalRunID != nil)
        #expect(approvals.count == 1)
        #expect(approvals.first?.approved == true)
        #expect(memories.isEmpty)
        #expect(runs.count == 1)
        #expect(runs.first?.statusRawValue == AgentRunStatus.completed.rawValue)
        #expect(traces.contains { $0.phase == AgentPhase.askUser.rawValue })
        #expect(traces.contains { $0.phase == AgentPhase.executeTool.rawValue })
        #expect(completedResponse.contains("Deleted"))
    }

    @Test func approvalRejectionDoesNotExecuteDestructiveTool() async throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Keep this important memory.", context: context)

        var completedResponse = ""
        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired(_, let approvalID, _, _) = event {
                try container.agentRuntime.reject(approvalID: approvalID, context: context)
            }
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        let memories = try context.fetch(FetchDescriptor<MemoryRecord>())
        let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
        let toolCalls = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(approvals.first?.approved == false)
        #expect(memories.count == 1)
        #expect(runs.first?.statusRawValue == AgentRunStatus.failed.rawValue)
        #expect(toolCalls.isEmpty)
        #expect(completedResponse.contains("approval was rejected"))
    }

    @Test func resumeWaitingForApprovalDoesNotDuplicateApproval() async throws {
        let (container, context) = makeContext()
        try container.memoryService.save(content: "Temporary memory.", context: context)

        var state = AgentLoopState(runID: UUID(), goal: "forget all memories")
        state.phase = .askUser
        state.stepIndex = 5
        state.completedNodeIDs = [
            AgentPhase.understandIntent.rawValue,
            AgentPhase.retrieveContext.rawValue,
            AgentPhase.plan.rawValue,
            AgentPhase.selectTool.rawValue,
            AgentPhase.askUser.rawValue
        ]
        state.selectedToolName = "memory_delete"
        let stateData = try JSONEncoder().encode(state)

        let run = AgentRunRecord(
            id: state.runID,
            goal: state.goal,
            statusRawValue: AgentRunStatus.waitingForApproval.rawValue,
            autonomyLevelRawValue: AutonomyLevel.auto.rawValue,
            currentPhase: AgentPhase.askUser.rawValue,
            currentStep: state.stepIndex,
            maxSteps: 12,
            requiresApproval: true
        )
        let approval = ApprovalRequestRecord(
            runID: state.runID,
            actionName: "memory_delete",
            reason: "memory_delete is destructive risk or current autonomy is Auto."
        )
        context.insert(run)
        context.insert(approval)
        context.insert(AgentCheckpointRecord(runID: state.runID, nodeID: AgentPhase.askUser.rawValue, stateSummary: state.summary, stateData: stateData))
        try context.save()

        var completedResponse = ""
        for try await event in container.agentRuntime.resume(run: run, provider: MockLLMProvider(), context: context) {
            if case .approvalRequired(_, let approvalID, _, _) = event {
                try container.agentRuntime.approve(approvalID: approvalID, context: context)
            }
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        let toolCalls = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(approvals.count == 1)
        #expect(approvals.first?.approved == true)
        #expect(toolCalls.count == 1)
        #expect(completedResponse.contains("Deleted"))
    }

    @Test func resumePausedRunUsesDurablePhaseCheckpoint() async throws {
        let (container, context) = makeContext()
        var state = AgentLoopState(runID: UUID(), goal: "calculate 4 * 5")
        state.phase = .selectTool
        state.stepIndex = 4
        state.completedNodeIDs = [
            AgentPhase.understandIntent.rawValue,
            AgentPhase.retrieveContext.rawValue,
            AgentPhase.plan.rawValue,
            AgentPhase.selectTool.rawValue
        ]
        state.selectedToolName = "calculator"
        let stateData = try JSONEncoder().encode(state)

        let run = AgentRunRecord(
            id: state.runID,
            goal: state.goal,
            statusRawValue: AgentRunStatus.paused.rawValue,
            currentPhase: AgentPhase.selectTool.rawValue,
            currentStep: state.stepIndex,
            maxSteps: 12
        )
        context.insert(run)
        context.insert(AgentCheckpointRecord(runID: state.runID, nodeID: AgentPhase.selectTool.rawValue, stateSummary: state.summary, stateData: stateData))
        try context.save()

        var completedResponse = ""
        for try await event in container.agentRuntime.resume(run: run, provider: MockLLMProvider(), context: context) {
            if case .completed(_, let response) = event {
                completedResponse = response
            }
        }

        let toolCalls = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(run.statusRawValue == AgentRunStatus.completed.rawValue)
        #expect(toolCalls.count == 1)
        #expect(completedResponse.contains("20"))
    }

    @Test func contextBuilderHonorsBudget() throws {
        let (container, context) = makeContext()
        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        let state = AgentLoopState(runID: UUID(), goal: "privacy")
        let package = try builder.build(goal: "privacy", messages: Array(repeating: "long message", count: 200), graphState: state, toolResults: [], context: context, budget: 80)
        #expect(package.prompt.count <= 340)
        #expect(package.prompt.contains("Final instructions:"))
    }

    @Test func contextBuilderPrioritizesToolSchemaDuringExecute() throws {
        let (container, context) = makeContext()
        context.insert(DocumentRecord(title: "Large.md", content: "RAW_DOCUMENT_CONTENT_SHOULD_BE_DROPPED " + String(repeating: "document ", count: 200)))
        try context.save()

        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        var state = AgentLoopState(runID: UUID(), goal: "calculate")
        state.selectedToolName = "calculator"
        let schema = ToolSchema(inputDescription: "A precise arithmetic expression.", examples: ["calculate 2 + 2"])
        let package = try builder.build(
            goal: "calculate 2 + 2",
            messages: Array(repeating: "chat filler", count: 80),
            graphState: state,
            toolResults: [],
            context: context,
            phase: .executeTool,
            selectedToolName: "calculator",
            selectedToolSchema: schema,
            budget: 100
        )

        #expect(package.documents.isEmpty)
        #expect(!package.prompt.contains("RAW_DOCUMENT_CONTENT_SHOULD_BE_DROPPED"))
        #expect(package.prompt.contains("Tool schema: A precise arithmetic expression."))
        #expect(package.prompt.contains("Final instructions:"))
    }

    @Test func contextBuilderProtectsExecuteContractWhenObservationsAreLarge() throws {
        let (container, context) = makeContext()
        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        var state = AgentLoopState(runID: UUID(), goal: "run remote check")
        state.selectedToolName = "remote_network"
        state.observations = Array(repeating: "OVERSIZED_OBSERVATION_PAYLOAD " + String(repeating: "detail ", count: 80), count: 4)
        let schema = ToolSchema(inputDescription: "Requires explicit user approval before any external network action.", examples: ["remote status check"])

        let package = try builder.build(
            goal: "run remote check",
            messages: [],
            graphState: state,
            toolResults: [],
            context: context,
            phase: .executeTool,
            selectedToolName: "remote_network",
            selectedToolSchema: schema,
            budget: 90
        )

        #expect(package.prompt.contains("Current phase: executeTool"))
        #expect(package.prompt.contains("Selected tool: remote_network"))
        #expect(package.prompt.contains("Tool schema:"))
        #expect(package.prompt.contains("Final instructions:"))
        #expect(!package.prompt.contains("OVERSIZED_OBSERVATION_PAYLOAD detail detail detail detail detail detail detail detail detail detail"))
    }

    @Test func contextBuilderUsesSummaryDuringReflection() throws {
        let (container, context) = makeContext()
        let builder = ContextBuilder(memoryService: container.memoryService, documentService: container.documentService)
        var state = AgentLoopState(runID: UUID(), goal: "reflect")
        state.observations = ["Observation: local tool succeeded."]
        let messages = (0..<80).map { "raw message \($0) SHOULD_NOT_ALL_APPEAR" }
        let package = try builder.build(goal: "reflect", messages: messages, graphState: state, toolResults: ["tool result"], context: context, phase: .reflect, budget: 160)
        #expect(package.prompt.contains("Conversation summary:"))
        #expect(package.prompt.contains("Observation: local tool succeeded."))
        #expect(!package.prompt.contains("raw message 0 SHOULD_NOT_ALL_APPEAR"))
    }

    @Test func checkpointsPersistResumablePayloadsIncludingApprovalPause() async throws {
        let (container, context) = makeContext()
        for try await _ in container.agentRuntime.run(
            goal: "calculate 2 + 3",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .semiAuto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {}

        let lowRiskCheckpoints = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        #expect(!lowRiskCheckpoints.isEmpty)
        #expect(lowRiskCheckpoints.contains { $0.nodeID == AgentPhase.selectTool.rawValue && $0.stateData != nil })

        try container.memoryService.save(content: "Temporary memory.", context: context)
        for try await event in container.agentRuntime.run(
            goal: "forget all memories",
            conversationID: nil,
            messages: [],
            provider: MockLLMProvider(),
            options: AgentRuntimeOptions(autonomyLevel: .auto, maxSteps: 12, timeoutSeconds: 20),
            context: context
        ) {
            if case .approvalRequired(_, let approvalID, _, _) = event {
                try container.agentRuntime.reject(approvalID: approvalID, context: context)
            }
        }

        let allCheckpoints = try context.fetch(FetchDescriptor<AgentCheckpointRecord>())
        #expect(allCheckpoints.contains { $0.nodeID == AgentPhase.askUser.rawValue && $0.stateData != nil })
    }

    @Test func telemetryBufferDefersToolCallPersistenceUntilFlush() throws {
        let (_, context) = makeContext()
        let buffer = AgentTelemetryBuffer()
        let runID = UUID()
        buffer.appendToolCall(
            runID: runID,
            input: "GET https://example.com/status",
            result: ToolResult(toolName: "remote_network", output: "HTTP GET example.com completed", target: "example.com", statusCode: 200, latencyMs: 42)
        )

        let beforeFlush = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(beforeFlush.isEmpty)

        try buffer.flush(runID: runID, to: context)

        let afterFlush = try context.fetch(FetchDescriptor<ToolCallRecord>())
        #expect(afterFlush.count == 1)
        #expect(afterFlush.first?.toolName == "remote_network")
        #expect(afterFlush.first?.output == "HTTP GET example.com completed")
        #expect(afterFlush.first?.target == "example.com")
        #expect(afterFlush.first?.statusCode == 200)
        #expect(afterFlush.first?.latencyMs == 42)
    }

    @Test func approvalGateCancelRunReleasesSuspendedApproval() async throws {
        let gate = AgentApprovalGate()
        let runID = UUID()
        let approvalID = UUID()
        let decisionTask = Task {
            await gate.suspend(runID: runID, approvalID: approvalID)
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        await gate.cancel(runID: runID)

        let decision = await decisionTask.value
        #expect(decision == .rejected)
    }

    @Test func mockSpeechServiceStreamsPartialTranscript() async throws {
        let service = MockSpeechService(transcript: "hello monGARS")
        let partial = LockedString()
        try await service.startTranscription { text in
            partial.set(text)
        }

        let status = await service.status
        #expect(status == "Mock speech ready")
        #expect(partial.value == "hello monGARS")
        #expect(service.stopCount == 0)

        service.stopTranscription()
        #expect(service.stopCount == 1)
    }

    @Test func diagnosticsVisualizationBuildsTimelineAndGraphStates() throws {
        let runID = UUID()
        let run = AgentRunRecord(id: runID, goal: "calculate", statusRawValue: AgentRunStatus.waitingForApproval.rawValue, currentPhase: AgentPhase.askUser.rawValue, currentStep: 5)
        let traces = [
            AgentTraceRecord(runID: runID, stepIndex: 1, phase: AgentPhase.understandIntent.rawValue, message: "understood"),
            AgentTraceRecord(runID: runID, stepIndex: 5, phase: AgentPhase.askUser.rawValue, message: "approval")
        ]

        let rows = DiagnosticsVisualizationBuilder.timelineRows(runs: [run], traces: traces)
        let nodes = DiagnosticsVisualizationBuilder.graphNodes(for: run, traces: traces)

        #expect(rows.map(\.phase) == [AgentPhase.understandIntent.rawValue, AgentPhase.askUser.rawValue])
        #expect(nodes.first(where: { $0.phase == .understandIntent })?.state == .completed)
        #expect(nodes.first(where: { $0.phase == .askUser })?.state == .waiting)
    }

    @Test func providerFallbackReportsLocalCapabilities() async {
        let provider = FoundationModelProvider(fallback: MockLLMProvider())
        #expect(provider.capabilities.isLocal)
        let status = await provider.status
        #expect(status.contains("FoundationModels") || status.contains("fallback"))
    }
}

final class MockSpeechService: SpeechService, @unchecked Sendable {
    private let transcript: String
    private(set) var stopCount = 0

    init(transcript: String) {
        self.transcript = transcript
    }

    var status: String {
        get async { "Mock speech ready" }
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func startTranscription(onPartial: @escaping @Sendable (String) -> Void) async throws {
        onPartial(transcript)
    }

    func stopTranscription() {
        stopCount += 1
    }
}
