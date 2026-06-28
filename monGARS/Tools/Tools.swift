import Foundation
import SwiftData
#if canImport(Contacts)
import Contacts
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(MapKit)
import MapKit
#endif

struct ToolResult: Sendable {
    var toolName: String
    var output: String
    var riskLevel: ToolRiskLevel = .low
    var requiresApproval: Bool = false
    var approved: Bool = true
    var target: String?
    var statusCode: Int?
    var latencyMs: Double?
    var errorCategory: String?
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
            TextMessageTool(),
            PhoneCallTool(),
            EmailTool(),
            ReminderTool(),
            CalendarTool(),
            ContactsTool(),
            WeatherTool(),
            MapsTool(),
            WebViewTool(),
            WebFetchTool(),
            LocalFileTool(),
            DateTimeTool(),
            CalculatorTool(),
            DocumentSummaryTool(documentService: documentService),
            MemorySaveTool(memoryService: memoryService),
            DocumentSearchTool(documentService: documentService),
            MemoryLookupTool(memoryService: memoryService),
            MemoryDeleteTool(memoryService: memoryService),
            ConversationSearchTool(),
            DiagnosticsTool(),
            TaskTool(),
            RemoteNetworkTool()
        ])
    }
}

private func requirePrivacyApproval(_ request: ToolExecutionRequest, toolName: String) throws {
    guard request.approved else {
        throw AgentRuntimeError.approvalRequired(toolName)
    }
}

private func networkDisabledResult(toolName: String, riskLevel: ToolRiskLevel) -> ToolResult {
    ToolResult(
        toolName: toolName,
        output: "Network tools are disabled in Settings. Enable network access before running this tool.",
        riskLevel: riskLevel,
        requiresApproval: true,
        approved: true,
        errorCategory: "network_disabled"
    )
}

private func cleanedInput(_ input: String, removing phrases: [String]) -> String {
    var cleaned = input
    for phrase in phrases.sorted(by: { $0.count > $1.count }) where !phrase.isEmpty {
        cleaned = cleaned.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive, .diacriticInsensitive])
    }
    return cleaned
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

private func firstPhoneNumber(in input: String) -> String? {
    let pattern = #"\+?[0-9][0-9\s\-\(\)\.]{5,}[0-9]"#
    guard let match = input.range(of: pattern, options: .regularExpression) else { return nil }
    let raw = String(input[match])
    let allowed = Set("+0123456789")
    let digits = String(raw.filter { allowed.contains($0) })
    return digits.isEmpty ? nil : digits
}

private func firstEmail(in input: String) -> String? {
    let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
    guard let match = input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
    return String(input[match])
}

private func firstHTTPURL(in input: String) -> URL? {
    let pattern = #"https?://[^\s]+"#
    guard let match = input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
    let raw = String(input[match]).trimmingCharacters(in: .punctuationCharacters)
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        return nil
    }
    return url
}

private struct WebFetchSummary: Sendable {
    var text: String
    var target: String
    var statusCode: Int
    var latencyMs: Double
}

private func fetchText(url: URL, limit: Int) async throws -> WebFetchSummary {
    let response = try await AppNetworkConfiguration.client().send(NetworkRequest(
        url: url,
        acceptedContentTypes: ["text/html", "text/plain", "application/json", "application/pdf"]
    ))
    let target = response.finalURL.host ?? response.finalURL.absoluteString
    if response.contentType?.contains("application/pdf") == true {
        return WebFetchSummary(
            text: "Fetched PDF from \(target) in \(Int(response.latencyMs)) ms. PDF text extraction is not available in this build.",
            target: target,
            statusCode: response.statusCode,
            latencyMs: response.latencyMs
        )
    }
    let text = response.text
    let cleaned = response.contentType?.contains("text/html") == true ? strippedHTML(text) : text
    return WebFetchSummary(
        text: String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines),
        target: target,
        statusCode: response.statusCode,
        latencyMs: response.latencyMs
    )
}

private func strippedHTML(_ input: String) -> String {
    input
        .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

private func localFileWorkspace() throws -> URL {
    let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let workspace = base.appendingPathComponent("AgentFiles", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    return workspace
}

private func filename(in input: String) -> String? {
    if let quoted = input.range(of: #""[^"]+""#, options: .regularExpression) {
        return sanitizedFilename(String(input[quoted].dropFirst().dropLast()))
    }

    let pattern = #"(read|write|delete)\s+file\s+([^\s]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    guard let match = regex.firstMatch(in: input, range: range), match.numberOfRanges >= 3,
          let swiftRange = Range(match.range(at: 2), in: input) else {
        return nil
    }
    return sanitizedFilename(String(input[swiftRange]))
}

private func sanitizedFilename(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    let filename = URL(fileURLWithPath: trimmed).lastPathComponent
    guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
    return filename
}

private func contentAfterKeyword(_ keyword: String, in input: String) -> String? {
    guard let range = input.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
    return String(input[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
}

#if canImport(EventKit)
private func requestCalendarWriteAccess(_ store: EKEventStore) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
        if #available(iOS 17.0, *) {
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

private func requestReminderWriteAccess(_ store: EKEventStore) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
        if #available(iOS 17.0, *) {
            store.requestFullAccessToReminders { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        } else {
            store.requestAccess(to: .reminder) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

private func eventStartDate(from input: String, now: Date = .now) -> Date {
    let lower = input.lowercased()
    let calendar = Calendar.current
    if lower.contains("tomorrow"), let date = calendar.date(byAdding: .day, value: 1, to: now) {
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }
    if lower.contains("today") {
        return calendar.date(byAdding: .hour, value: 1, to: now) ?? now
    }
    return calendar.date(byAdding: .hour, value: 1, to: now) ?? now
}

private func reminderDueDateComponents(from input: String, now: Date = .now) -> DateComponents? {
    let lower = input.lowercased()
    let calendar = Calendar.current
    if lower.contains("tomorrow"), let date = calendar.date(byAdding: .day, value: 1, to: now) {
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
    if lower.contains("today") {
        return calendar.dateComponents([.year, .month, .day], from: now)
    }
    return nil
}
#endif

struct ReminderTool: Tool {
    let name = "reminder_manager"
    let description = "Creates native Reminders entries after user approval."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Reminder text and optional date/time phrase.", examples: ["remind me to call Sam tomorrow"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("remind me") || lower.contains("create reminder") || lower.contains("add reminder")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        let title = cleanedInput(request.input, removing: ["remind me to", "remind me", "create reminder", "add reminder"])
        let resolvedTitle = title.isEmpty ? request.input : title

        #if canImport(EventKit)
        let store = EKEventStore()
        if try await requestReminderWriteAccess(store), let calendar = store.defaultCalendarForNewReminders() {
            let reminder = EKReminder(eventStore: store)
            reminder.title = resolvedTitle
            reminder.calendar = calendar
            reminder.notes = "Created by monGARS after explicit approval."
            reminder.dueDateComponents = reminderDueDateComponents(from: request.input)
            try store.save(reminder, commit: true)
            let localRecord = AgentTaskRecord(runID: request.runID, title: resolvedTitle, notes: "Native reminder created after approval.")
            context.insert(localRecord)
            try context.safeSave()
            return ToolResult(toolName: name, output: "Created approved reminder: \(resolvedTitle)", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        #endif

        return ToolResult(toolName: name, output: "Reminder was not created because native Reminders access is unavailable or permission was denied.", riskLevel: riskLevel, requiresApproval: true, approved: true)
    }
}

struct CalendarTool: Tool {
    let name = "calendar_manager"
    let description = "Creates native Calendar events after user approval."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Calendar event title and optional date/time phrase.", examples: ["create calendar event Team sync tomorrow at 10"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("calendar") || lower.contains("create event") || lower.contains("schedule")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        let title = cleanedInput(request.input, removing: ["create calendar event", "calendar event", "create event", "schedule"])
        let resolvedTitle = title.isEmpty ? request.input : title

        #if canImport(EventKit)
        let store = EKEventStore()
        if try await requestCalendarWriteAccess(store), let calendar = store.defaultCalendarForNewEvents {
            let startDate = eventStartDate(from: request.input)
            let event = EKEvent(eventStore: store)
            event.title = resolvedTitle
            event.calendar = calendar
            event.startDate = startDate
            event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate
            event.notes = "Created by monGARS after explicit approval."
            try store.save(event, span: .thisEvent, commit: true)
            let localRecord = AgentTaskRecord(runID: request.runID, title: resolvedTitle, notes: "Native calendar event created after approval.")
            context.insert(localRecord)
            try context.safeSave()
            return ToolResult(toolName: name, output: "Created approved calendar event: \(resolvedTitle)", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        #endif

        return ToolResult(toolName: name, output: "Calendar event was not created because native Calendar access is unavailable or permission was denied.", riskLevel: riskLevel, requiresApproval: true, approved: true)
    }
}

struct ContactsTool: Tool {
    let name = "contacts_lookup"
    let description = "Searches device contacts after user approval when Contacts access is available."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Contact name or organization to search.", examples: ["find contact Sarah"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("contact") || lower.contains("phone number for") || lower.contains("email address for")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        #if canImport(Contacts)
        let granted = try await requestContactsAccess()
        guard granted else {
            return ToolResult(toolName: name, output: "Contacts permission was not granted.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        let query = cleanedInput(request.input, removing: ["find contact", "contact", "phone number for", "email address for"]).lowercased()
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var matches: [String] = []
        try store.enumerateContacts(with: request) { contact, stop in
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let haystack = "\(name) \(contact.organizationName)".lowercased()
            if query.isEmpty || haystack.contains(query) {
                let phones = contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
                let emails = contact.emailAddresses.map { String($0.value) }.joined(separator: ", ")
                matches.append("\(name.isEmpty ? contact.organizationName : name) | phones: \(phones.isEmpty ? "none" : phones) | emails: \(emails.isEmpty ? "none" : emails)")
                if matches.count >= 5 {
                    stop.pointee = true
                }
            }
        }
        let output = matches.isEmpty ? "No approved contact matches found." : matches.joined(separator: "\n")
        return ToolResult(toolName: name, output: output, riskLevel: riskLevel, requiresApproval: true, approved: true)
        #else
        return ToolResult(toolName: name, output: "Contacts are unavailable on this platform.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        #endif
    }

    #if canImport(Contacts)
    private func requestContactsAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
    #endif
}

struct WeatherTool: Tool {
    let name = "weather_lookup"
    let description = "Fetches a concise weather summary from the network after user approval."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Location name for a weather lookup.", examples: ["weather in Montreal"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("weather") || lower.contains("forecast")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        let location = cleanedInput(request.input, removing: ["weather in", "weather for", "weather", "forecast in", "forecast for", "forecast"])
        guard !location.isEmpty else {
            return ToolResult(toolName: name, output: "Provide a location for weather lookup.", riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_arguments")
        }
        guard !AppNetworkConfiguration.weatherAPIKey.isEmpty else {
            return ToolResult(toolName: name, output: "Weather API key is missing. Add an OpenWeather-compatible key in Settings before weather lookup.", riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "missing_api_key")
        }
        guard var components = URLComponents(string: AppNetworkConfiguration.weatherEndpoint) else {
            return ToolResult(toolName: name, output: "Weather endpoint in Settings is not a valid URL.", riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_configuration")
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "q", value: location))
        queryItems.append(URLQueryItem(name: "appid", value: AppNetworkConfiguration.weatherAPIKey))
        queryItems.append(URLQueryItem(name: "units", value: AppNetworkConfiguration.weatherUnits))
        components.queryItems = queryItems
        guard let url = components.url else {
            return ToolResult(toolName: name, output: "Weather request could not be built from the configured endpoint.", riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_configuration")
        }
        let response = try await AppNetworkConfiguration.client().send(NetworkRequest(url: url, acceptedContentTypes: ["application/json"]))
        let weather = try response.decodedJSON(OpenWeatherResponse.self)
        let description = weather.weather.first?.description ?? "conditions unavailable"
        let output = "Weather for \(weather.name.isEmpty ? location : weather.name): \(description), \(Int(weather.main.temp.rounded())) degrees, humidity \(weather.main.humidity)%, wind \(String(format: "%.1f", weather.wind?.speed ?? 0)) m/s. Status \(response.statusCode), \(Int(response.latencyMs)) ms."
        return ToolResult(
            toolName: name,
            output: output,
            riskLevel: riskLevel,
            requiresApproval: true,
            approved: true,
            target: response.finalURL.host ?? response.finalURL.absoluteString,
            statusCode: response.statusCode,
            latencyMs: response.latencyMs
        )
    }
}

struct TextMessageTool: Tool {
    let name = "text_message"
    let description = "Prepares an SMS URL after user approval; it does not send automatically."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Recipient phone number and optional message body.", examples: ["text 5551234567 hello"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.hasPrefix("text ") || lower.contains("send text") || lower.contains("sms ")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard let phone = firstPhoneNumber(in: request.input), !phone.isEmpty else {
            return ToolResult(toolName: name, output: "Provide a phone number to prepare an SMS.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        let body = cleanedInput(request.input, removing: ["send text", "text", "sms", phone])
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = "sms:\(phone)\(encodedBody.isEmpty ? "" : "&body=\(encodedBody)")"
        return ToolResult(toolName: name, output: "Prepared approved SMS handoff: \(url). The user must confirm in Messages.", riskLevel: riskLevel, requiresApproval: true, approved: true)
    }
}

struct PhoneCallTool: Tool {
    let name = "phone_call"
    let description = "Prepares a tel URL after user approval; it does not call automatically."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Phone number to call.", examples: ["call 5551234567"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.hasPrefix("call ") || lower.contains("phone call") || lower.contains("dial ")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard let phone = firstPhoneNumber(in: request.input), !phone.isEmpty else {
            return ToolResult(toolName: name, output: "Provide a phone number to prepare a call.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        return ToolResult(toolName: name, output: "Prepared approved phone handoff: tel://\(phone). The user must confirm the call.", riskLevel: riskLevel, requiresApproval: true, approved: true)
    }
}

struct EmailTool: Tool {
    let name = "email_compose"
    let description = "Prepares a native Mail compose handoff after user approval; it does not send automatically."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Recipient email plus optional subject/body.", examples: ["email sam@example.com Project update"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.hasPrefix("email ") || lower.contains("send email") || lower.contains("mail ")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard let email = firstEmail(in: request.input) else {
            return ToolResult(toolName: name, output: "Provide an email address to prepare mail.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        let body = cleanedInput(request.input, removing: ["send email", "email", "mail", email])
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        if !body.isEmpty {
            components.queryItems = [URLQueryItem(name: "body", value: body)]
        }
        let url = components.url?.absoluteString ?? "mailto:\(email)"
        let nativeStatus = "The app will present native Mail compose when iOS reports Mail is configured; otherwise it will offer the system Mail URL handoff."
        return ToolResult(
            toolName: name,
            output: "\(nativeStatus) Prepared approved email handoff: \(url). The user must review and send in Mail.",
            riskLevel: riskLevel,
            requiresApproval: true,
            approved: true,
            target: email
        )
    }
}

struct MapsTool: Tool {
    let name = "maps_lookup"
    let description = "Prepares an Apple Maps search/directions URL after user approval."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Place, address, or directions request.", examples: ["map nearest coffee shop"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("map ") || lower.contains("directions") || lower.contains("navigate") || lower.contains("nearby")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        let query = cleanedInput(request.input, removing: ["open map", "map", "directions to", "directions", "navigate to", "navigate", "nearby"])
        guard !query.isEmpty else {
            return ToolResult(toolName: name, output: "Provide a place, address, or directions destination for Maps.", riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_arguments")
        }

        #if canImport(MapKit)
        let started = ContinuousClock.now
        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = query
        do {
            let response = try await MKLocalSearch(request: searchRequest).start()
            let latencyMs = Self.latencyMilliseconds(started.duration(to: ContinuousClock.now))
            if let item = response.mapItems.first {
                let coordinate = item.placemark.coordinate
                let mapsURL = Self.appleMapsURL(query: item.name ?? query, coordinate: coordinate)
                let target = item.placemark.title ?? item.name ?? query
                return ToolResult(
                    toolName: name,
                    output: "Prepared approved Apple Maps handoff for \(target): \(mapsURL.absoluteString)",
                    riskLevel: riskLevel,
                    requiresApproval: true,
                    approved: true,
                    target: "maps.apple.com",
                    statusCode: 200,
                    latencyMs: latencyMs
                )
            }

            let mapsURL = Self.appleMapsURL(query: query, coordinate: nil)
            return ToolResult(
                toolName: name,
                output: "MapKit returned no local search result. Prepared approved Apple Maps search handoff: \(mapsURL.absoluteString)",
                riskLevel: riskLevel,
                requiresApproval: true,
                approved: true,
                target: "maps.apple.com",
                statusCode: 204,
                latencyMs: latencyMs,
                errorCategory: "no_results"
            )
        } catch {
            let mapsURL = Self.appleMapsURL(query: query, coordinate: nil)
            return ToolResult(
                toolName: name,
                output: "MapKit search failed: \(error.localizedDescription). Prepared approved Apple Maps search handoff: \(mapsURL.absoluteString)",
                riskLevel: riskLevel,
                requiresApproval: true,
                approved: true,
                target: "maps.apple.com",
                errorCategory: "service_unavailable"
            )
        }
        #else
        let mapsURL = Self.appleMapsURL(query: query, coordinate: nil)
        return ToolResult(toolName: name, output: "MapKit is unavailable on this platform. Prepared approved Apple Maps search handoff: \(mapsURL.absoluteString)", riskLevel: riskLevel, requiresApproval: true, approved: true, target: "maps.apple.com", errorCategory: "platform_unavailable")
        #endif
    }

    private static func appleMapsURL(query: String, coordinate: CLLocationCoordinate2D?) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        if let coordinate {
            components.queryItems = [
                URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
                URLQueryItem(name: "q", value: query)
            ]
        } else {
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url ?? URL(string: "https://maps.apple.com")!
    }

    private static func latencyMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds * 1_000) + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

struct WebViewTool: Tool {
    let name = "integrated_webview"
    let description = "Prepares an in-app webview navigation request after user approval."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "HTTP or HTTPS URL to open in the integrated web view.", examples: ["open webview https://example.com"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("webview") || lower.contains("web view") || lower.contains("open website")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        guard let url = firstHTTPURL(in: request.input) else {
            return ToolResult(toolName: name, output: "Provide an http or https URL for the integrated web view.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        return ToolResult(toolName: name, output: "Approved in-app webview navigation prepared: \(url.absoluteString)", riskLevel: riskLevel, requiresApproval: true, approved: true)
    }
}

struct WebFetchTool: Tool {
    let name = "web_fetch"
    let description = "Fetches a web page after user approval and returns a short text preview."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "HTTP or HTTPS URL to fetch.", examples: ["fetch https://example.com"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("web fetch") || lower.hasPrefix("fetch ") || lower.contains("download url")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        guard let url = firstHTTPURL(in: request.input) else {
            return ToolResult(toolName: name, output: "Provide an http or https URL to fetch.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        let summary = try await fetchText(url: url, limit: 2_000)
        return ToolResult(
            toolName: name,
            output: summary.text.isEmpty ? "Fetched URL but no text content was returned." : summary.text,
            riskLevel: riskLevel,
            requiresApproval: true,
            approved: true,
            target: summary.target,
            statusCode: summary.statusCode,
            latencyMs: summary.latencyMs
        )
    }
}

struct LocalFileTool: Tool {
    let name = "local_file"
    let description = "Lists, reads, writes, and deletes files in the app-local agent workspace after user approval."
    let riskLevel: ToolRiskLevel = .destructive

    var schema: ToolSchema {
        ToolSchema(inputDescription: "File action: list files, read file <name>, write file <name> content <text>, delete file <name>.", examples: ["write file note.txt content hello"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("local file") || lower.contains("list files") || lower.contains("read file") || lower.contains("write file") || lower.contains("delete file")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        let workspace = try localFileWorkspace()
        let lower = request.input.lowercased()
        if lower.contains("list files") {
            let files = try FileManager.default.contentsOfDirectory(atPath: workspace.path).sorted()
            return ToolResult(toolName: name, output: files.isEmpty ? "No local agent files." : files.joined(separator: "\n"), riskLevel: riskLevel, requiresApproval: true, approved: true)
        }

        guard let filename = filename(in: request.input) else {
            return ToolResult(toolName: name, output: "Provide a filename for local file action.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        let url = workspace.appendingPathComponent(filename)

        if lower.contains("read file") {
            let text = try String(contentsOf: url, encoding: .utf8)
            return ToolResult(toolName: name, output: String(text.prefix(2_000)), riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        if lower.contains("delete file") {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return ToolResult(toolName: name, output: "Deleted local agent file: \(filename)", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        if lower.contains("write file") {
            let content = contentAfterKeyword("content", in: request.input) ?? ""
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(toolName: name, output: "Wrote local agent file: \(filename)", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }

        return ToolResult(toolName: name, output: "Supported local file actions: list, read, write, delete.", riskLevel: riskLevel, requiresApproval: true, approved: true)
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
        return lower.contains("remember that")
            || lower.contains("save memory")
            || lower.contains("save this memory")
            || lower.contains("remember key points")
            || lower.contains("remember the key points")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let content = request.input
            .replacingOccurrences(of: "remember that", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "save memory", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "save this memory", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "remember the key points", with: "key points", options: .caseInsensitive)
            .replacingOccurrences(of: "remember key points", with: "key points", options: .caseInsensitive)
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
    let description = "Runs an approved generic HTTP request using the configured network client."
    let riskLevel: ToolRiskLevel = .high

    func canHandle(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("network") || lower.contains("remote http") || lower.range(of: #"^(get|post|put|patch|delete)\s+https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        guard request.approved else {
            throw AgentRuntimeError.approvalRequired(name)
        }
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        guard let url = firstHTTPURL(in: request.input) else {
            return ToolResult(toolName: name, output: "Provide an HTTP or HTTPS URL for the remote network request.", riskLevel: riskLevel, requiresApproval: true, approved: true)
        }
        let method = Self.method(from: request.input)
        let bodyText = contentAfterKeyword("body", in: request.input)
        let response = try await AppNetworkConfiguration.client().send(NetworkRequest(
            url: url,
            method: method,
            headers: AppNetworkConfiguration.remoteNetworkHeaders,
            body: bodyText?.data(using: .utf8),
            acceptedContentTypes: ["application/json", "text/plain", "text/html"]
        ))
        let preview = String((response.contentType?.contains("text/html") == true ? strippedHTML(response.text) : response.text).prefix(1_000))
        let host = response.finalURL.host ?? url.host ?? url.absoluteString
        return ToolResult(
            toolName: name,
            output: "HTTP \(method.rawValue) \(host) completed with status \(response.statusCode) in \(Int(response.latencyMs)) ms.\n\(preview)",
            riskLevel: riskLevel,
            requiresApproval: true,
            approved: request.approved,
            target: host,
            statusCode: response.statusCode,
            latencyMs: response.latencyMs
        )
    }

    private static func method(from input: String) -> HTTPMethod {
        let first = input.split(separator: " ").first.map { String($0).uppercased() }
        return HTTPMethod.allCases.first { $0.rawValue == first } ?? .get
    }
}

private struct OpenWeatherResponse: Decodable {
    var name: String
    var weather: [Condition]
    var main: Main
    var wind: Wind?

    struct Condition: Decodable {
        var description: String
    }

    struct Main: Decodable {
        var temp: Double
        var humidity: Int
    }

    struct Wind: Decodable {
        var speed: Double
    }
}
