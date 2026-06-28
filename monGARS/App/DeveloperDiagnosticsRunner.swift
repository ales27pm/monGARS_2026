import Foundation
import SwiftData

#if canImport(Contacts)
import Contacts
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

struct DeveloperDiagnosticsResult: Equatable {
    var text: String
    var fileURL: URL?

    var summary: String {
        fileURL.map { "Developer diagnostics completed. Report: \($0.lastPathComponent)" }
            ?? "Developer diagnostics completed. Report is ready to export."
    }
}

private struct ToolE2EResult {
    var label: String
    var toolName: String
    var passed: Bool
    var target: String?
    var statusCode: Int?
    var errorCategory: String?
    var output: String

    var reportLine: String {
        var parts = [
            "- \(passed ? "PASS" : "FAIL") \(label)",
            "tool=\(toolName)"
        ]
        if let target {
            parts.append("target=\(DiagnosticsRedactor.redact(target, maxLength: 80))")
        }
        if let statusCode {
            parts.append("status=\(statusCode)")
        }
        if let errorCategory {
            parts.append("error=\(errorCategory)")
        }
        parts.append("output=\(DiagnosticsRedactor.redact(output, maxLength: 220))")
        return parts.joined(separator: " | ")
    }
}

enum DeveloperDiagnosticsRunner {
    @MainActor
    static func run(container: AppContainer, context: ModelContext, writeReportFile: Bool = true) async -> DeveloperDiagnosticsResult {
        var builder = ReportBuilder()
        let settings = container.settingsStore

        builder.add("monGARS Developer Diagnostics Report")
        builder.add("Generated: \(Self.isoDate(Date()))")
        builder.add("")
        appendAppSection(to: &builder)
        appendConfigurationSection(settings: settings, to: &builder)
        appendSecurityChecks(settings: settings, to: &builder)
        appendFrameworkSection(documentService: container.documentService, to: &builder)
        appendPermissionSection(to: &builder)
        appendSwiftDataCounts(context: context, to: &builder)
        await appendRealToolE2E(container: container, context: context, to: &builder)
        appendRecentDiagnostics(context: context, to: &builder)
        builder.add("Notes")
        builder.add("- These are in-app runtime self-checks and direct real-tool E2E probes, not XCTest execution.")
        builder.add("- No MockLLMProvider is used by this report; tools are invoked directly through their production implementations.")
        builder.add("- Network calls and privacy-sensitive Apple integrations still require Settings enablement and user approval.")
        builder.add("- Secrets, contacts, message bodies, and token-like values are redacted before export.")

        let text = DiagnosticsRedactor.redact(builder.text, maxLength: 24_000)
        let url = writeReportFile ? writeReport(text) : nil
        return DeveloperDiagnosticsResult(text: text, fileURL: url)
    }

    private static func appendAppSection(to builder: inout ReportBuilder) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let identifier = Bundle.main.bundleIdentifier ?? "unknown"
        builder.add("App")
        builder.add("- Bundle: \(identifier)")
        builder.add("- Version: \(version)")
        builder.add("- Build: \(build)")
        builder.add("")
    }

    @MainActor
    private static func appendRealToolE2E(container: AppContainer, context: ModelContext, to builder: inout ReportBuilder) async {
        builder.add("Real Tool E2E")
        builder.add("- Provider mock usage: false")
        builder.add("- Network toggle honored: \(container.settingsStore.remoteProviderEnabled)")
        let runID = UUID()
        var results: [ToolE2EResult] = []

        func approved(_ input: String, network: Bool = false) -> ToolExecutionRequest {
            ToolExecutionRequest(
                runID: runID,
                input: input,
                autonomyLevel: .assisted,
                approved: true,
                networkAccessAllowed: network && container.settingsStore.remoteProviderEnabled
            )
        }

        func record(_ label: String, _ result: ToolResult, expected: (ToolResult) -> Bool) {
            results.append(ToolE2EResult(
                label: label,
                toolName: result.toolName,
                passed: expected(result),
                target: result.target,
                statusCode: result.statusCode,
                errorCategory: result.errorCategory,
                output: result.output
            ))
        }

        func recordError(_ label: String, toolName: String, error: Error) {
            results.append(ToolE2EResult(
                label: label,
                toolName: toolName,
                passed: false,
                target: nil,
                statusCode: nil,
                errorCategory: "thrown_error",
                output: error.localizedDescription
            ))
        }

        let marker = "monGARS E2E \(runID.uuidString.prefix(8))"
        do {
            let result = try await CalculatorTool().execute(request: approved("calculate 12 * (3 + 4)"), context: context)
            record("calculator arithmetic", result) { $0.output.contains("84") }
        } catch { recordError("calculator arithmetic", toolName: "calculator", error: error) }

        do {
            let result = try await DateTimeTool().execute(request: approved("what time is it"), context: context)
            record("device date/time", result) { $0.output.contains("Local device time") }
        } catch { recordError("device date/time", toolName: "date_time", error: error) }

        do {
            let save = try await MemorySaveTool(memoryService: container.memoryService).execute(request: approved("remember that \(marker) memory works"), context: context)
            record("memory save", save) { $0.output.contains(marker) }
            let lookup = try await MemoryLookupTool(memoryService: container.memoryService).execute(request: approved(marker), context: context)
            record("memory lookup", lookup) { $0.output.contains(marker) }
            let delete = try await MemoryDeleteTool(memoryService: container.memoryService).execute(request: approved("delete memory \(marker)"), context: context)
            record("memory delete scoped", delete) { $0.output.contains("Deleted") }
        } catch { recordError("memory save/lookup/delete", toolName: "memory", error: error) }

        do {
            let documentQuery = "\(marker) document retrieval text"
            let document = DocumentRecord(title: "\(marker).md", content: "\(documentQuery) for real tool E2E.")
            context.insert(document)
            try container.documentService.rebuildChunks(for: document, context: context)
            let search = try await DocumentSearchTool(documentService: container.documentService).execute(request: approved(marker), context: context)
            record("document search", search) { $0.output.contains(document.title) && $0.output.contains(marker) }
            let summary = try await DocumentSummaryTool(documentService: container.documentService).execute(request: approved("summarize my imported document"), context: context)
            record("document summary", summary) { !$0.output.contains("No documents") }
            try container.documentService.delete(document, context: context)
        } catch { recordError("document search/summary", toolName: "documents", error: error) }

        do {
            let conversation = Conversation(title: marker)
            conversation.messages.append(ChatMessage(role: .user, content: "\(marker) conversation search text"))
            context.insert(conversation)
            try context.safeSave()
            let result = try await ConversationSearchTool().execute(request: approved("conversation \(marker)"), context: context)
            record("conversation search", result) { $0.output.contains(marker) }
            context.delete(conversation)
            try context.safeSave()
        } catch { recordError("conversation search", toolName: "conversation_search", error: error) }

        do {
            let create = try await TaskTool().execute(request: approved("create task \(marker)"), context: context)
            record("task create", create) { $0.output.contains(marker) }
            let complete = try await TaskTool().execute(request: approved("complete task"), context: context)
            record("task complete", complete) { $0.output.contains("Completed task") || $0.output.contains("No active tasks") }
        } catch { recordError("task manager", toolName: "task_manager", error: error) }

        do {
            let filename = "monGARS-e2e-\(runID.uuidString.prefix(8)).txt"
            let fileTool = LocalFileTool()
            let write = try await fileTool.execute(request: approved("write file \(filename) content \(marker) file text"), context: context)
            record("local file write", write) { $0.output.contains(filename) }
            let read = try await fileTool.execute(request: approved("read file \(filename)"), context: context)
            record("local file read", read) { $0.output.contains(marker) }
            let traversal = try await fileTool.execute(request: approved(#"write file "../escape.txt" content no"#), context: context)
            record("local file traversal block", traversal) { $0.output.contains("Provide a filename") }
            let delete = try await fileTool.execute(request: approved("delete file \(filename)"), context: context)
            record("local file delete", delete) { $0.output.contains(filename) }
        } catch { recordError("local file", toolName: "local_file", error: error) }

        do {
            let diagnostics = try await DiagnosticsTool().execute(request: approved("diagnostics"), context: context)
            record("diagnostics tool", diagnostics) { $0.output.contains("Diagnostics:") }
        } catch { recordError("diagnostics tool", toolName: "diagnostics", error: error) }

        await appendHandoffE2E(context: context, request: approved, record: record, recordError: recordError)
        await appendAppleDataE2E(context: context, request: approved, record: record, recordError: recordError, marker: marker)
        await appendNetworkE2E(
            context: context,
            developerModeEnabled: container.settingsStore.developerModeEnabled,
            request: approved,
            record: record,
            recordError: recordError
        )

        let passed = results.filter(\.passed).count
        builder.add("- Summary: \(passed)/\(results.count) probes passed")
        for result in results {
            builder.add(result.reportLine)
        }
        builder.add("")
    }

    @MainActor
    private static func appendHandoffE2E(
        context: ModelContext,
        request: (String, Bool) -> ToolExecutionRequest,
        record: (String, ToolResult, (ToolResult) -> Bool) -> Void,
        recordError: (String, String, Error) -> Void
    ) async {
        do {
            let result = try await TextMessageTool().execute(request: request("text +15551234567 hello from monGARS E2E", false), context: context)
            record("SMS handoff", result) { $0.output.contains("sms:") && $0.output.contains("must confirm") }
        } catch { recordError("SMS handoff", "text_message", error) }

        do {
            let result = try await PhoneCallTool().execute(request: request("call +15551234567", false), context: context)
            record("phone handoff", result) { $0.output.contains("tel://") && $0.output.contains("must confirm") }
        } catch { recordError("phone handoff", "phone_call", error) }

        do {
            let result = try await EmailTool().execute(request: request("email e2e@example.com monGARS E2E body", false), context: context)
            record("email compose handoff", result) { $0.output.contains("Prepared approved email handoff") && $0.output.contains("must review") }
        } catch { recordError("email compose handoff", "email_compose", error) }

        do {
            let result = try await EmailInboxTool().execute(request: request("read my latest email", false), context: context)
            record("email inbox honest limitation", result) { $0.errorCategory == "platform_unavailable" && $0.output.contains("iOS does not expose Mail") }
        } catch { recordError("email inbox honest limitation", "email_inbox", error) }
    }

    @MainActor
    private static func appendAppleDataE2E(
        context: ModelContext,
        request: (String, Bool) -> ToolExecutionRequest,
        record: (String, ToolResult, (ToolResult) -> Bool) -> Void,
        recordError: (String, String, Error) -> Void,
        marker: String
    ) async {
        do {
            let result = try await ContactsTool().execute(request: request("find contact monGARS-no-real-contact-\(marker)", false), context: context)
            record("contacts lookup", result) {
                $0.output.contains("No approved contact matches")
                    || $0.output.contains("permission was not granted")
                    || $0.output.contains("unavailable")
                    || $0.errorCategory == "invalid_arguments"
            }
        } catch { recordError("contacts lookup", "contacts_lookup", error) }

        do {
            let result = try await CalendarTool().execute(request: request("create calendar event \(marker) tomorrow", false), context: context)
            record("calendar create", result) {
                $0.output.contains("Created approved calendar event")
                    || $0.output.contains("not created because native Calendar access is unavailable or permission was denied")
            }
        } catch { recordError("calendar create", "calendar_manager", error) }

        do {
            let result = try await ReminderTool().execute(request: request("remind me to \(marker)", false), context: context)
            record("reminder create", result) {
                $0.output.contains("Created approved reminder")
                    || $0.output.contains("not created because native Reminders access is unavailable or permission was denied")
            }
        } catch { recordError("reminder create", "reminder_manager", error) }

        do {
            let result = try await CurrentLocationTool().execute(request: request("where am I", false), context: context)
            record("current location", result) {
                $0.output.contains("Current location:")
                    || $0.errorCategory == "permission_or_location_unavailable"
                    || $0.errorCategory == "platform_unavailable"
            }
        } catch { recordError("current location", "current_location", error) }
    }

    @MainActor
    private static func appendNetworkE2E(
        context: ModelContext,
        developerModeEnabled: Bool,
        request: (String, Bool) -> ToolExecutionRequest,
        record: (String, ToolResult, (ToolResult) -> Bool) -> Void,
        recordError: (String, String, Error) -> Void
    ) async {
        do {
            let result = try await WeatherTool().execute(request: request("weather in Montreal", true), context: context)
            record("weather lookup", result) {
                $0.output.contains("Network tools are disabled")
                    || $0.output.contains("Weather for")
                    || $0.errorCategory == "missing_api_key"
                    || $0.errorCategory == "service_unavailable"
                    || $0.errorCategory == "geocoding_failed"
                    || $0.errorCategory == "invalid_configuration"
            }
        } catch { recordError("weather lookup", "weather_lookup", error) }

        do {
            let result = try await MapsTool().execute(request: request("map Apple Park", true), context: context)
            record("MapKit search", result) {
                $0.output.contains("Network tools are disabled")
                    || $0.output.contains("Apple Maps")
                    || $0.errorCategory == "service_unavailable"
                    || $0.errorCategory == "platform_unavailable"
            }
        } catch { recordError("MapKit search", "maps_lookup", error) }

        do {
            let result = try await WebViewTool().execute(request: request("open webview https://example.com", true), context: context)
            record("WebKit handoff", result) {
                $0.output.contains("Network tools are disabled")
                    || $0.output.contains("Approved in-app webview navigation prepared")
            }
        } catch { recordError("WebKit handoff", "integrated_webview", error) }

        do {
            let result = try await WebFetchTool().execute(request: request("fetch https://example.com", true), context: context)
            record("web fetch", result) {
                $0.output.contains("Network tools are disabled")
                    || ($0.statusCode == 200 && !$0.output.isEmpty)
            }
        } catch { recordError("web fetch", "web_fetch", error) }

        do {
            let result = try await RemoteNetworkTool().execute(request: request("GET https://example.com", true), context: context)
            record("generic remote HTTP", result) {
                $0.output.contains("Network tools are disabled")
                    || ($0.statusCode == 200 && $0.output.contains("HTTP GET"))
            }
        } catch { recordError("generic remote HTTP", "remote_network", error) }

        do {
            try NetworkPolicy(allowsLocalNetworkHosts: false).validate(URL(string: "http://127.0.0.1:9")!)
            record("default private host policy", ToolResult(toolName: "network_policy", output: "Default policy allowed localhost unexpectedly.", riskLevel: .high, requiresApproval: false, approved: true, errorCategory: "policy_failed")) {
                $0.errorCategory == "blocked_host"
            }
        } catch NetworkClientError.blockedHost(let host) {
            record("default private host policy", ToolResult(toolName: "network_policy", output: "Default policy blocked private host: \(host)", riskLevel: .high, requiresApproval: false, approved: true, target: host, errorCategory: "blocked_host")) {
                $0.errorCategory == "blocked_host"
            }
        } catch { recordError("default private host policy", "network_policy", error) }

        let privateHostLabel = developerModeEnabled ? "private host developer-mode path" : "private host block"
        do {
            let result = try await WebFetchTool().execute(request: request("fetch http://127.0.0.1:9", true), context: context)
            record(privateHostLabel, result) {
                if developerModeEnabled {
                    return $0.errorCategory != "blocked_host"
                }
                return $0.output.contains("Network tools are disabled") || $0.errorCategory == "blocked_host"
            }
        } catch NetworkClientError.blockedHost {
            record(privateHostLabel, ToolResult(toolName: "web_fetch", output: "Blocked private host", riskLevel: .high, requiresApproval: true, approved: true, errorCategory: "blocked_host")) {
                !developerModeEnabled && $0.errorCategory == "blocked_host"
            }
        } catch {
            if developerModeEnabled {
                let nsError = error as NSError
                record(privateHostLabel, ToolResult(
                    toolName: "web_fetch",
                    output: "Developer Mode allowed the private-host request; connection failed because no local service was listening: \(error.localizedDescription)",
                    riskLevel: .high,
                    requiresApproval: true,
                    approved: true,
                    target: "127.0.0.1",
                    errorCategory: nsError.domain == NSURLErrorDomain ? "connection_unavailable" : "thrown_error"
                )) {
                    $0.errorCategory != "blocked_host"
                }
            } else {
                recordError(privateHostLabel, "web_fetch", error)
            }
        }
    }

    private static func appendConfigurationSection(settings: SettingsStore, to builder: inout ReportBuilder) {
        let remoteEndpointURL = URL(string: settings.remoteEndpoint)
        let weatherEndpointURL = URL(string: settings.weatherEndpoint)
        let parsedHeaders = SettingsStore.parseHeaders(settings.remoteNetworkHeadersText)

        builder.add("Configuration")
        builder.add("- Provider mode: \(settings.providerMode.label)")
        builder.add("- Network enabled: \(settings.remoteProviderEnabled)")
        builder.add("- Developer Mode local-network override: \(settings.developerModeEnabled)")
        builder.add("- Autonomy: \(settings.autonomyLevel.label)")
        builder.add("- Timeout seconds: \(Int(settings.networkTimeoutSeconds))")
        builder.add("- Retries: \(settings.networkMaxRetries)")
        builder.add("- Remote endpoint valid URL: \(remoteEndpointURL != nil)")
        builder.add("- Remote API key configured: \(!settings.remoteAPIKey.isEmpty)")
        builder.add("- Weather endpoint valid URL: \(weatherEndpointURL != nil)")
        builder.add("- Weather API key configured: \(!settings.weatherAPIKey.isEmpty)")
        builder.add("- Weather units: \(settings.weatherUnits)")
        builder.add("- Generic network headers valid/count: \(parsedHeaders != nil)/\(parsedHeaders?.count ?? 0)")
        builder.add("")
    }

    private static func appendSecurityChecks(settings: SettingsStore, to builder: inout ReportBuilder) {
        let policy = NetworkPolicy(allowsLocalNetworkHosts: settings.developerModeEnabled)
        builder.add("Security Checks")
        builder.add("- Public HTTPS allowed: \(policyStatus(for: "https://example.com/status", policy: policy))")
        builder.add("- Localhost policy: \(policyStatus(for: "http://127.0.0.1/status", policy: policy))")
        builder.add("- Private LAN policy: \(policyStatus(for: "http://192.168.1.10/status", policy: policy))")
        builder.add("- Keychain round trip: \(keychainRoundTripStatus())")
        builder.add("- Remote LLM expansion: paused")
        builder.add("")
    }

    private static func appendFrameworkSection(documentService: DocumentService, to builder: inout ReportBuilder) {
        builder.add("Framework Availability")
        #if canImport(WeatherKit)
        builder.add("- WeatherKit: compiled in; entitlement/provisioning still required at runtime")
        #else
        builder.add("- WeatherKit: not compiled in")
        #endif
        #if canImport(MapKit)
        builder.add("- MapKit: available")
        #else
        builder.add("- MapKit: unavailable")
        #endif
        #if canImport(WebKit)
        builder.add("- WebKit: available")
        #else
        builder.add("- WebKit: unavailable")
        #endif
        #if canImport(PDFKit)
        let pdfStatus = PDFDocument(data: Data("%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF".utf8)) == nil
            ? "available; sample probe did not open"
            : "available"
        builder.add("- PDFKit: \(pdfStatus)")
        #else
        builder.add("- PDFKit: unavailable")
        #endif
        builder.add("- Document embeddings: \(documentService.embeddingStatusDescription)")
        builder.add("")
    }

    private static func appendPermissionSection(to builder: inout ReportBuilder) {
        builder.add("Permission State")
        #if canImport(Contacts)
        builder.add("- Contacts: raw=\(CNContactStore.authorizationStatus(for: .contacts).rawValue)")
        #else
        builder.add("- Contacts: unavailable")
        #endif
        #if canImport(EventKit)
        builder.add("- Calendar: raw=\(EKEventStore.authorizationStatus(for: .event).rawValue)")
        builder.add("- Reminders: raw=\(EKEventStore.authorizationStatus(for: .reminder).rawValue)")
        #else
        builder.add("- Calendar: unavailable")
        builder.add("- Reminders: unavailable")
        #endif
        #if canImport(CoreLocation)
        let locationStatus: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            locationStatus = CLLocationManager().authorizationStatus
        } else {
            locationStatus = CLLocationManager.authorizationStatus()
        }
        builder.add("- Location: raw=\(locationStatus.rawValue)")
        #else
        builder.add("- Location: unavailable")
        #endif
        builder.add("")
    }

    @MainActor
    private static func appendSwiftDataCounts(context: ModelContext, to builder: inout ReportBuilder) {
        builder.add("SwiftData Counts")
        builder.add("- Conversations: \(count(Conversation.self, context: context))")
        builder.add("- Messages: \(count(ChatMessage.self, context: context))")
        builder.add("- Memories: \(count(MemoryRecord.self, context: context))")
        builder.add("- Documents: \(count(DocumentRecord.self, context: context))")
        builder.add("- Document chunks: \(count(DocumentChunkRecord.self, context: context))")
        builder.add("- Agent runs: \(count(AgentRunRecord.self, context: context))")
        builder.add("- Trace records: \(count(AgentTraceRecord.self, context: context))")
        builder.add("- Tool calls: \(count(ToolCallRecord.self, context: context))")
        builder.add("- Approval requests: \(count(ApprovalRequestRecord.self, context: context))")
        builder.add("- Tasks: \(count(AgentTaskRecord.self, context: context))")
        builder.add("")
    }

    @MainActor
    private static func appendRecentDiagnostics(context: ModelContext, to builder: inout ReportBuilder) {
        builder.add("Recent Diagnostics")
        var runDescriptor = FetchDescriptor<AgentRunRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        runDescriptor.fetchLimit = 5
        let runs = (try? context.fetch(runDescriptor)) ?? []
        if runs.isEmpty {
            builder.add("- Runs: none")
        } else {
            for run in runs {
                builder.add("- Run \(run.id.uuidString): \(run.statusRawValue), phase \(run.currentPhase), goal \(DiagnosticsRedactor.redact(run.goal, maxLength: 120))")
            }
        }

        var toolDescriptor = FetchDescriptor<ToolCallRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        toolDescriptor.fetchLimit = 8
        let toolCalls = (try? context.fetch(toolDescriptor)) ?? []
        if toolCalls.isEmpty {
            builder.add("- Tool calls: none")
        } else {
            for call in toolCalls {
                builder.add("- Tool \(call.toolName): approved=\(call.approved), target=\(DiagnosticsRedactor.redact(call.target ?? "none", maxLength: 80)), status=\(call.statusCode.map(String.init) ?? "none"), error=\(call.errorCategory ?? "none"), latencyMs=\(Int(call.latencyMs))")
            }
        }
        builder.add("")
    }

    @MainActor
    private static func count<T: PersistentModel>(_ model: T.Type, context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    private static func policyStatus(for rawURL: String, policy: NetworkPolicy) -> String {
        guard let url = URL(string: rawURL) else { return "invalid probe URL" }
        do {
            try policy.validate(url)
            return "allowed"
        } catch {
            return "blocked (\(error.localizedDescription))"
        }
    }

    private static func keychainRoundTripStatus() -> String {
        let account = "developer-diagnostics-\(UUID().uuidString)"
        KeychainStore.delete(account: account)
        KeychainStore.set("temporary-diagnostic-secret", for: account)
        let saved = KeychainStore.string(for: account) == "temporary-diagnostic-secret"
        KeychainStore.delete(account: account)
        let deleted = KeychainStore.string(for: account).isEmpty
        return saved && deleted ? "pass" : "fail"
    }

    private static func writeReport(_ text: String) -> URL? {
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let reportsDirectory = root
            .appendingPathComponent("AgentFiles", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
            let filename = "monGARS-developer-diagnostics-\(fileSafeTimestamp(Date())).txt"
            let url = reportsDirectory.appendingPathComponent(filename)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func fileSafeTimestamp(_ date: Date) -> String {
        isoDate(date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}

private struct ReportBuilder {
    private var lines: [String] = []

    var text: String {
        lines.joined(separator: "\n")
    }

    mutating func add(_ line: String) {
        lines.append(line)
    }
}
