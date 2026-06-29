import Foundation
import SwiftData

#if canImport(UIKit)
import UIKit
#endif
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
    var outcome: ToolOutcome
    var target: String?
    var statusCode: Int?
    var errorCategory: String?
    var output: String

    var reportLine: String {
        var parts = [
            "- \(passed ? "PASS" : "FAIL") \(label)",
            "tool=\(toolName)",
            "outcome=\(outcome.rawValue)"
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
        builder.add("- No LLM provider is used by this report; tools are invoked directly through their production implementations.")
        builder.add("- Network calls and privacy-sensitive Apple integrations still require Settings enablement and user approval.")
        builder.add("- Secrets, contacts, message bodies, and token-like values are redacted before export.")

        let text = DiagnosticsRedactor.redact(builder.text, maxLength: 24_000)
        let url = writeReportFile ? writeReport(text) : nil
        return DeveloperDiagnosticsResult(text: text, fileURL: url)
    }

    private static func appendAppSection(to builder: inout ReportBuilder) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = appBuildNumber()
        let identifier = Bundle.main.bundleIdentifier ?? "unknown"
        builder.add("App")
        builder.add("- Bundle: \(identifier)")
        builder.add("- Version: \(version)")
        builder.add("- Build: \(build)")
        builder.add("- Runtime: \(runtimePlatformDescription())")
        builder.add("- Physical device runtime: \(isPhysicalIOSDeviceRuntime())")
        builder.add("- Accepted on-device iteration: \(isPhysicalIOSDeviceRuntime())")
        builder.add("- Report acceptance: \(isPhysicalIOSDeviceRuntime() ? "accepted" : "rejected - physical iOS device runtime required")")
        builder.add("")
    }

    @MainActor
    private static func appendRealToolE2E(container: AppContainer, context: ModelContext, to builder: inout ReportBuilder) async {
        builder.add("Real Tool E2E")
        builder.add("- LLM provider usage: false")
        builder.add("- Network toggle honored: \(container.settingsStore.remoteProviderEnabled)")
        let runID = UUID()
        var results: [ToolE2EResult] = []

        func request(_ input: String, approved: Bool = true, network: Bool = false) -> ToolExecutionRequest {
            ToolExecutionRequest(
                runID: runID,
                input: input,
                autonomyLevel: .assisted,
                approved: approved,
                networkAccessAllowed: network && container.settingsStore.remoteProviderEnabled
            )
        }

        func approved(_ input: String, network: Bool = false) -> ToolExecutionRequest {
            request(input, approved: true, network: network)
        }

        func record(_ label: String, _ result: ToolResult, expected: (ToolResult) -> Bool) {
            results.append(ToolE2EResult(
                label: label,
                toolName: result.toolName,
                passed: expected(result),
                outcome: result.outcome,
                target: result.target,
                statusCode: result.statusCode,
                errorCategory: result.errorCategory,
                output: result.output
            ))
        }

        func recordSynthetic(
            _ label: String,
            toolName: String,
            passed: Bool,
            output: String,
            target: String? = nil,
            statusCode: Int? = nil,
            errorCategory: String? = nil
        ) {
            results.append(ToolE2EResult(
                label: label,
                toolName: toolName,
                passed: passed,
                outcome: errorCategory == nil ? .success : .failed,
                target: target,
                statusCode: statusCode,
                errorCategory: errorCategory,
                output: output
            ))
        }

        func recordError(_ label: String, toolName: String, error: Error) {
            results.append(ToolE2EResult(
                label: label,
                toolName: toolName,
                passed: false,
                outcome: .failed,
                target: nil,
                statusCode: nil,
                errorCategory: "thrown_error",
                output: error.localizedDescription
            ))
        }

        let marker = "monGARS E2E \(runID.uuidString.prefix(8))"
        if !isPhysicalIOSDeviceRuntime() {
            recordSynthetic(
                "physical iOS runtime acceptance gate",
                toolName: "runtime_acceptance",
                passed: false,
                output: "Report was not produced on a physical iOS device. This run is useful for debugging only and is not accepted as real on-device evidence.",
                errorCategory: "physical_device_required"
            )
        }

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

            #if canImport(PDFKit)
            let pdfProbeText = "\(marker) selectable PDF import text"
            if let pdfData = DiagnosticPDFFactory.makeSelectablePDFData(text: pdfProbeText) {
                let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(marker)-diagnostic.pdf")
                try pdfData.write(to: pdfURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: pdfURL) }
                try container.documentService.importDocument(url: pdfURL, context: context)
                if let importedPDF = try container.documentService.documents(context: context).first(where: { $0.title == pdfURL.lastPathComponent }) {
                    let pdfSearchQuery = "\(pdfURL.lastPathComponent) \(pdfProbeText)"
                    let rankedPDF = try container.documentService.rankedSnippets(matching: pdfSearchQuery, context: context, limit: 1)
                    let pdfSearch = try await DocumentSearchTool(documentService: container.documentService).execute(request: approved(pdfSearchQuery), context: context)
                    let rawImportMatched = importedPDF.content.contains(pdfProbeText)
                    let indexedChunkMatched = rankedPDF.contains { result in
                        result.documentID == importedPDF.id && result.chunkText.contains(pdfProbeText)
                    }
                    record("PDF document import and search", pdfSearch) {
                        rawImportMatched && indexedChunkMatched && $0.output.contains(importedPDF.title)
                    }
                    try container.documentService.delete(importedPDF, context: context)
                } else {
                    recordSynthetic("PDF document import and search", toolName: "document_search", passed: false, output: "Imported diagnostic PDF was not found in SwiftData.", errorCategory: "document_import_missing")
                }
            } else {
                recordSynthetic("PDF document import and search", toolName: "document_search", passed: false, output: "Could not generate diagnostic PDF data.", errorCategory: "pdf_generation_unavailable")
            }
            #endif
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
        await appendPolicyAndNegativeE2E(
            context: context,
            request: request,
            record: record,
            recordSynthetic: recordSynthetic,
            recordError: recordError
        )
        appendExtractionAndRedactionE2E(recordSynthetic: recordSynthetic)

        let passed = results.filter(\.passed).count
        let registryToolNames = Set(container.toolRouter.registry.tools.map(\.name))
        let coveredToolNames = registryToolNames.intersection(Set(results.map(\.toolName)))
        let missingToolNames = registryToolNames.subtracting(coveredToolNames).sorted()
        builder.add("- Summary: \(passed)/\(results.count) probes passed")
        builder.add("- Tool coverage: \(coveredToolNames.count)/\(registryToolNames.count) registry tools")
        if !missingToolNames.isEmpty {
            builder.add("- Missing registry tool probes: \(missingToolNames.joined(separator: ", "))")
        }
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
                    || $0.errorCategory == "permission_denied"
                    || $0.errorCategory == "platform_unavailable"
                    || $0.errorCategory == "invalid_arguments"
            }
        } catch { recordError("contacts lookup", "contacts_lookup", error) }

        do {
            let result = try await CalendarTool().execute(request: request("create calendar event \(marker) tomorrow", false), context: context)
            record("calendar create", result) {
                $0.output.contains("Created approved calendar event")
                    || $0.errorCategory == "permission_or_platform_unavailable"
            }
        } catch { recordError("calendar create", "calendar_manager", error) }

        do {
            let result = try await ReminderTool().execute(request: request("remind me to \(marker)", false), context: context)
            record("reminder create", result) {
                $0.output.contains("Created approved reminder")
                    || $0.errorCategory == "permission_or_platform_unavailable"
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
                    || $0.errorCategory == "location_unavailable"
                    || $0.errorCategory == "invalid_configuration"
            }
        } catch { recordError("weather lookup", "weather_lookup", error) }

        do {
            let result = try await MapsTool().execute(request: request("map 1 Apple Park Way Cupertino CA", true), context: context)
            record("MapKit search", result) {
                $0.output.contains("Network tools are disabled")
                    || ($0.outcome == .handoffPrepared && $0.statusCode == 200 && $0.output.contains("Apple Maps"))
                    || $0.errorCategory == "platform_unavailable"
                    || ($0.errorCategory == "service_unavailable" && $0.output.contains("Apple Maps"))
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

    @MainActor
    private static func appendPolicyAndNegativeE2E(
        context: ModelContext,
        request: (String, Bool, Bool) -> ToolExecutionRequest,
        record: (String, ToolResult, (ToolResult) -> Bool) -> Void,
        recordSynthetic: (String, String, Bool, String, String?, Int?, String?) -> Void,
        recordError: (String, String, Error) -> Void
    ) async {
        await recordApprovalRejection(
            label: "SMS approval rejection",
            toolName: "text_message",
            recordSynthetic: recordSynthetic
        ) {
            try await TextMessageTool().execute(
                request: request("text +15551234567 should not send", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "phone approval rejection",
            toolName: "phone_call",
            recordSynthetic: recordSynthetic
        ) {
            try await PhoneCallTool().execute(
                request: request("call +15551234567", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "email inbox approval rejection",
            toolName: "email_inbox",
            recordSynthetic: recordSynthetic
        ) {
            try await EmailInboxTool().execute(
                request: request("read my latest email", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "email compose approval rejection",
            toolName: "email_compose",
            recordSynthetic: recordSynthetic
        ) {
            try await EmailTool().execute(
                request: request("email e2e@example.com should not prepare", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "reminder approval rejection",
            toolName: "reminder_manager",
            recordSynthetic: recordSynthetic
        ) {
            try await ReminderTool().execute(
                request: request("remind me to should not create", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "calendar approval rejection",
            toolName: "calendar_manager",
            recordSynthetic: recordSynthetic
        ) {
            try await CalendarTool().execute(
                request: request("create calendar event should not create tomorrow", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "contacts approval rejection",
            toolName: "contacts_lookup",
            recordSynthetic: recordSynthetic
        ) {
            try await ContactsTool().execute(
                request: request("find contact Nobody", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "weather approval rejection",
            toolName: "weather_lookup",
            recordSynthetic: recordSynthetic
        ) {
            try await WeatherTool().execute(
                request: request("weather in Montreal", false, true),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "current location approval rejection",
            toolName: "current_location",
            recordSynthetic: recordSynthetic
        ) {
            try await CurrentLocationTool().execute(
                request: request("where am I", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "MapKit approval rejection",
            toolName: "maps_lookup",
            recordSynthetic: recordSynthetic
        ) {
            try await MapsTool().execute(
                request: request("map Apple Park", false, true),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "WebKit approval rejection",
            toolName: "integrated_webview",
            recordSynthetic: recordSynthetic
        ) {
            try await WebViewTool().execute(
                request: request("open webview https://example.com", false, true),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "web fetch approval rejection",
            toolName: "web_fetch",
            recordSynthetic: recordSynthetic
        ) {
            try await WebFetchTool().execute(
                request: request("fetch https://example.com", false, true),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "local file approval rejection",
            toolName: "local_file",
            recordSynthetic: recordSynthetic
        ) {
            try await LocalFileTool().execute(
                request: request("write file rejected.txt content should not write", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "memory delete approval rejection",
            toolName: "memory_delete",
            recordSynthetic: recordSynthetic
        ) {
            try await MemoryDeleteTool(memoryService: MemoryService()).execute(
                request: request("delete memory should not delete", false, false),
                context: context
            )
        }

        await recordApprovalRejection(
            label: "remote HTTP approval rejection",
            toolName: "remote_network",
            recordSynthetic: recordSynthetic
        ) {
            try await RemoteNetworkTool().execute(
                request: request("POST https://example.com body should-not-send", false, true),
                context: context
            )
        }

        do {
            let result = try await WeatherTool().execute(request: request("weather in Montreal", true, false), context: context)
            record("weather network-off block", result) { $0.errorCategory == "network_disabled" }
        } catch { recordError("weather network-off block", "weather_lookup", error) }

        do {
            let result = try await MapsTool().execute(request: request("map Apple Park", true, false), context: context)
            record("MapKit network-off block", result) { $0.errorCategory == "network_disabled" }
        } catch { recordError("MapKit network-off block", "maps_lookup", error) }

        do {
            let result = try await WebViewTool().execute(request: request("open webview https://example.com", true, false), context: context)
            record("WebKit network-off block", result) { $0.errorCategory == "network_disabled" }
        } catch { recordError("WebKit network-off block", "integrated_webview", error) }

        do {
            let result = try await WebFetchTool().execute(request: request("fetch https://example.com", true, false), context: context)
            record("web fetch network-off block", result) { $0.errorCategory == "network_disabled" }
        } catch { recordError("web fetch network-off block", "web_fetch", error) }

        do {
            let result = try await RemoteNetworkTool().execute(request: request("GET https://example.com", true, false), context: context)
            record("remote HTTP network-off block", result) { $0.errorCategory == "network_disabled" }
        } catch { recordError("remote HTTP network-off block", "remote_network", error) }

        do {
            let result = try await TextMessageTool().execute(request: request("text no-number hello", true, false), context: context)
            record("SMS invalid input", result) { $0.output.contains("Provide a phone number") }
        } catch { recordError("SMS invalid input", "text_message", error) }

        do {
            let result = try await PhoneCallTool().execute(request: request("call nobody", true, false), context: context)
            record("phone invalid input", result) { $0.output.contains("Provide a phone number") }
        } catch { recordError("phone invalid input", "phone_call", error) }

        do {
            let result = try await EmailTool().execute(request: request("email not-an-address hello", true, false), context: context)
            record("email invalid input", result) { $0.output.contains("Provide an email address") }
        } catch { recordError("email invalid input", "email_compose", error) }

        do {
            let result = try await MapsTool().execute(request: request("map", true, true), context: context)
            record("MapKit invalid query", result) { $0.errorCategory == "invalid_arguments" }
        } catch { recordError("MapKit invalid query", "maps_lookup", error) }

        do {
            let result = try await WebViewTool().execute(request: request("open webview file:///etc/passwd", true, true), context: context)
            record("WebKit unsafe scheme block", result) { $0.output.contains("http or https URL") }
        } catch { recordError("WebKit unsafe scheme block", "integrated_webview", error) }

        do {
            let result = try await RemoteNetworkTool().execute(request: request("GET ftp://example.com/file", true, true), context: context)
            record("remote HTTP invalid URL", result) { $0.output.contains("HTTP or HTTPS URL") }
        } catch { recordError("remote HTTP invalid URL", "remote_network", error) }
    }

    @MainActor
    private static func recordApprovalRejection(
        label: String,
        toolName: String,
        recordSynthetic: (String, String, Bool, String, String?, Int?, String?) -> Void,
        operation: () async throws -> ToolResult
    ) async {
        do {
            let result = try await operation()
            recordSynthetic(label, toolName, false, "Tool executed unexpectedly: \(result.output)", result.target, result.statusCode, "approval_not_enforced")
        } catch AgentRuntimeError.approvalRequired(let rejectedToolName) {
            recordSynthetic(
                label,
                toolName,
                rejectedToolName == toolName,
                "Approval was required before \(rejectedToolName) executed.",
                nil,
                nil,
                "approval_required"
            )
        } catch {
            recordSynthetic(label, toolName, false, error.localizedDescription, nil, nil, "unexpected_error")
        }
    }

    private static func appendExtractionAndRedactionE2E(
        recordSynthetic: (String, String, Bool, String, String?, Int?, String?) -> Void
    ) {
        let html = """
        <!doctype html>
        <html>
        <head>
        <title>monGARS HTML Probe</title>
        <meta name="description" content="diagnostic description">
        <link rel="canonical" href="https://example.com/diagnostic">
        <style>.hidden { display: none; }</style>
        <script>window.secret = 'nope';</script>
        </head>
        <body><nav>Navigation should disappear</nav><main><h1>Readable heading</h1><p>Useful readable body.</p></main></body>
        </html>
        """
        let extracted = WebContentExtractor.extractHTML(html)
        recordSynthetic(
            "HTML extraction local",
            "web_content_extractor",
            extracted.title == "monGARS HTML Probe"
                && extracted.metaDescription == "diagnostic description"
                && extracted.canonicalURL == "https://example.com/diagnostic"
                && extracted.readableText.contains("Useful readable body")
                && !extracted.readableText.contains("window.secret"),
            extracted.preview(limit: 240),
            nil,
            nil,
            nil
        )

        let jsonPreview = WebContentExtractor.extractPlainText(#"{"status":"ok","message":"monGARS JSON probe"}"#, limit: 80)
        recordSynthetic(
            "plain text JSON preview local",
            "web_content_extractor",
            jsonPreview.contains("monGARS JSON probe"),
            jsonPreview,
            nil,
            nil,
            nil
        )

        #if canImport(PDFKit)
        if let data = DiagnosticPDFFactory.makeSelectablePDFData(text: "monGARS PDF extraction probe") {
            do {
                let extraction = try PDFTextExtractor.extract(data: data)
                recordSynthetic(
                    "PDFKit extraction local",
                    "pdf_text_extractor",
                    extraction.text.contains("Page 1") && extraction.text.contains("monGARS PDF extraction probe"),
                    extraction.text,
                    nil,
                    nil,
                    nil
                )
            } catch {
                recordSynthetic("PDFKit extraction local", "pdf_text_extractor", false, error.localizedDescription, nil, nil, "pdf_extraction_failed")
            }
        } else {
            recordSynthetic("PDFKit extraction local", "pdf_text_extractor", false, "Could not generate diagnostic PDF data.", nil, nil, "pdf_generation_unavailable")
        }
        #else
        recordSynthetic("PDFKit extraction local", "pdf_text_extractor", false, "PDFKit is unavailable.", nil, nil, "platform_unavailable")
        #endif

        let currentBuild = appBuildNumber()
        let rawSensitive = """
        Build: \(currentBuild)
        Current location: 46.00604, -73.16488
        Prepared approved SMS handoff: sms:15551234567&body=secret body.
        Authorization: Bearer hidden-token
        """
        let redacted = DiagnosticsRedactor.redact(rawSensitive, maxLength: 1_000)
        recordSynthetic(
            "diagnostics redaction self-check",
            "diagnostics_redactor",
            redacted.contains(currentBuild)
                && redacted.contains("46.00604, -73.16488")
                && !redacted.contains("15551234567")
                && !redacted.contains("secret body")
                && !redacted.contains("hidden-token"),
            redacted,
            nil,
            nil,
            nil
        )
    }

    private static func appBuildNumber() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private static func runtimePlatformDescription() -> String {
        #if targetEnvironment(simulator)
        return "iOS Simulator"
        #elseif os(iOS)
        #if canImport(UIKit)
        return "physical iOS device (\(UIDevice.current.model), \(UIDevice.current.systemVersion))"
        #else
        return "physical iOS device"
        #endif
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    private static func isPhysicalIOSDeviceRuntime() -> Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
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
        let pdfStatus: String
        if let data = DiagnosticPDFFactory.makeSelectablePDFData(text: "monGARS PDFKit framework probe"),
           let extraction = try? PDFTextExtractor.extract(data: data),
           extraction.text.contains("monGARS PDFKit framework probe") {
            pdfStatus = "available; text extraction probe passed"
        } else {
            pdfStatus = "available; text extraction probe failed"
        }
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
                builder.add("- Tool \(call.toolName): outcome=\(call.outcomeRawValue), approved=\(call.approved), target=\(DiagnosticsRedactor.redact(call.target ?? "none", maxLength: 80)), status=\(call.statusCode.map(String.init) ?? "none"), error=\(call.errorCategory ?? "none"), latencyMs=\(Int(call.latencyMs))")
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
