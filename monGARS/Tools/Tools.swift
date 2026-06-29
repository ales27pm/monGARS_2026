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
#if canImport(MapKit)
import MapKit
#endif

enum ToolOutcome: String, Codable, Sendable {
    case success
    case handoffPrepared
    case needsInput
    case blocked
    case permissionDenied
    case unavailable
    case noResults
    case failed
}

struct ToolResult: Sendable {
    var toolName: String
    var output: String
    var outcome: ToolOutcome = .success
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
    func metadata(for input: String) -> ToolExecutionMetadata
    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult
}

extension Tool {
    var schema: ToolSchema {
        ToolSchema(inputDescription: description, examples: [])
    }

    var riskLevel: ToolRiskLevel { .low }

    var requiresApproval: Bool { riskLevel.requiresApprovalByDefault }

    func metadata(for input: String) -> ToolExecutionMetadata {
        ToolExecutionMetadata()
    }

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
            EmailInboxTool(),
            EmailTool(),
            ReminderTool(),
            CalendarTool(),
            ContactsTool(),
            WeatherTool(),
            CurrentLocationTool(),
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
    ToolResult.networkDisabled(toolName: toolName, riskLevel: riskLevel)
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

private func networkTargetPreview(from input: String) -> String? {
    guard let url = firstHTTPURL(in: input) else { return nil }
    return url.host ?? url.absoluteString
}

private func normalizedIntent(_ input: String) -> String {
    input.lowercased()
        .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func userVisibleToolError(_ error: Error, defaultMessage: String) -> String {
    let nsError = error as NSError
    switch nsError.domain {
    case kCLErrorDomain:
        return "Location services could not complete that request. Check Location Services, network connectivity, or provide a named place."
    case "MKErrorDomain":
        return "Apple Maps search is unavailable right now. Try a more specific place or address."
    case NSURLErrorDomain:
        return "The network request failed. Check connectivity and try again."
    default:
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !description.localizedCaseInsensitiveContains("kCLErrorDomain"), !description.localizedCaseInsensitiveContains("MKErrorDomain") else {
            return defaultMessage
        }
        return description
    }
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
        let extraction = try PDFTextExtractor.extract(data: response.data)
        return WebFetchSummary(
            text: String(extraction.text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines),
            target: target,
            statusCode: response.statusCode,
            latencyMs: response.latencyMs
        )
    }
    let text = response.text
    let cleaned = response.contentType?.contains("text/html") == true
        ? WebContentExtractor.extractHTML(text).preview(limit: limit)
        : WebContentExtractor.extractPlainText(text, limit: limit)
    return WebFetchSummary(
        text: cleaned,
        target: target,
        statusCode: response.statusCode,
        latencyMs: response.latencyMs
    )
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
    let pathTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathTrimmed.contains("/"), !pathTrimmed.contains("\\") else { return nil }
    let trimmed = pathTrimmed.trimmingCharacters(in: .punctuationCharacters)
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

#if canImport(CoreLocation)
private enum CurrentLocationError: LocalizedError {
    case servicesDisabled
    case permissionDenied
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .servicesDisabled:
            "Location Services are disabled. Enable Location Services in iOS Settings to use current-location tools."
        case .permissionDenied:
            "Location permission was denied. Allow monGARS location access in iOS Settings to use this tool."
        case .unavailable:
            "Current location is unavailable on this device right now."
        case .timedOut:
            "Current location timed out. Check Location Services and try again."
        }
    }
}

@MainActor
private final class CurrentLocationProbe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation(timeoutSeconds: Double = 12) async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw CurrentLocationError.servicesDisabled
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    self?.finish(.failure(CurrentLocationError.timedOut))
                }
            }

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                finish(.failure(CurrentLocationError.permissionDenied))
            @unknown default:
                finish(.failure(CurrentLocationError.unavailable))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(CurrentLocationError.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(CurrentLocationError.unavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(CurrentLocationError.unavailable))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(Self.normalizedLocationError(error)))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        switch result {
        case .success(let location):
            continuation.resume(returning: location)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static func normalizedLocationError(_ error: Error) -> Error {
        guard let locationError = error as? CLError else {
            return error
        }
        switch locationError.code {
        case .denied:
            return CurrentLocationError.permissionDenied
        case .locationUnknown, .network, .headingFailure, .rangingUnavailable, .rangingFailure:
            return CurrentLocationError.unavailable
        default:
            return CurrentLocationError.unavailable
        }
    }
}

private func currentDeviceLocation() async throws -> CLLocation {
    let probe = await MainActor.run { CurrentLocationProbe() }
    return try await probe.requestLocation()
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

        return ToolResult(toolName: name, output: "Reminder was not created because native Reminders access is unavailable or permission was denied.", outcome: .permissionDenied, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "permission_or_platform_unavailable")
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

        return ToolResult(toolName: name, output: "Calendar event was not created because native Calendar access is unavailable or permission was denied.", outcome: .permissionDenied, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "permission_or_platform_unavailable")
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
        let query = Self.searchQuery(from: request.input)
        guard !query.isEmpty else {
            return .needsInput(toolName: name, output: "Provide a non-empty contact name, organization, phone-number owner, or email owner to search.", riskLevel: riskLevel, requiresApproval: true)
        }
        #if canImport(Contacts)
        let granted = try await requestContactsAccess()
        guard granted else {
            return ToolResult(toolName: name, output: "Contacts permission was not granted.", outcome: .permissionDenied, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "permission_denied")
        }
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
        return ToolResult(toolName: name, output: output, outcome: matches.isEmpty ? .noResults : .success, riskLevel: riskLevel, requiresApproval: true, approved: true)
        #else
        return .unavailable(toolName: name, output: "Contacts are unavailable on this platform.", riskLevel: riskLevel, requiresApproval: true)
        #endif
    }

    private static func searchQuery(from input: String) -> String {
        cleanedInput(input, removing: ["find contact", "search contacts", "contact", "contacts", "phone number for", "email address for"]).lowercased()
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

    func metadata(for input: String) -> ToolExecutionMetadata {
        let location = Self.weatherLocation(from: input)
        return ToolExecutionMetadata(
            requiresNetwork: true,
            targetPreview: location.isEmpty ? "Weather provider and current location" : "Weather provider for \(location)",
            actionPreview: "Fetch weather conditions"
        )
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        let location = Self.weatherLocation(from: request.input)
        guard !location.isEmpty else {
            #if canImport(CoreLocation)
            do {
                let deviceLocation = try await currentDeviceLocation()
                let locationName = await Self.reverseGeocodedName(for: deviceLocation)
                let report = try await Self.weatherReport(
                    service: WeatherServiceFactory.makeConfiguredService(),
                    requestInput: request.input,
                    location: deviceLocation,
                    locationName: locationName
                )
                return Self.result(for: report)
            } catch WeatherServiceError.missingAPIKey {
                return ToolResult(toolName: name, output: WeatherServiceError.missingAPIKey.localizedDescription, outcome: .needsInput, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "missing_api_key")
            } catch WeatherServiceError.invalidEndpoint {
                return ToolResult(toolName: name, output: WeatherServiceError.invalidEndpoint.localizedDescription, outcome: .needsInput, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_configuration")
            } catch WeatherServiceError.forecastUnavailable(let reason) {
                return ToolResult(toolName: name, output: "Weather forecast is unavailable: \(reason) Try current weather, or configure a forecast-capable provider.", outcome: .unavailable, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "forecast_unavailable")
            } catch WeatherServiceError.weatherKitUnavailable(let reason) {
                return ToolResult(toolName: name, output: "Weather lookup needs a configured provider. WeatherKit failed: \(reason). Add an OpenWeather-compatible key in Settings or try a named location.", outcome: .unavailable, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "service_unavailable")
            } catch {
                return ToolResult(toolName: name, output: "Weather needs either a location, like 'weather in Montreal', or current-location permission. \(userVisibleToolError(error, defaultMessage: "Current-location lookup failed."))", outcome: .permissionDenied, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "location_unavailable")
            }
            #else
            return ToolResult(toolName: name, output: "Provide a location for weather lookup, such as 'weather in Montreal'.", outcome: .needsInput, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_arguments")
            #endif
        }
        let report: WeatherReport
        do {
            report = try await Self.weatherReport(service: WeatherServiceFactory.makeConfiguredService(), requestInput: request.input, locationName: location)
        } catch WeatherServiceError.missingAPIKey {
            return ToolResult(toolName: name, output: WeatherServiceError.missingAPIKey.localizedDescription, outcome: .needsInput, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "missing_api_key")
        } catch WeatherServiceError.invalidEndpoint {
            return ToolResult(toolName: name, output: WeatherServiceError.invalidEndpoint.localizedDescription, outcome: .needsInput, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_configuration")
        } catch WeatherServiceError.geocodingFailed(let failedLocation) {
            return ToolResult(toolName: name, output: WeatherServiceError.geocodingFailed(failedLocation).localizedDescription, outcome: .noResults, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "geocoding_failed")
        } catch WeatherServiceError.forecastUnavailable(let reason) {
            return ToolResult(toolName: name, output: "Weather forecast is unavailable: \(reason) Try current weather, or configure a forecast-capable provider.", outcome: .unavailable, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "forecast_unavailable")
        } catch {
            return ToolResult(toolName: name, output: "Weather lookup failed: \(userVisibleToolError(error, defaultMessage: "The weather provider could not complete the request."))", outcome: .failed, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "service_unavailable")
        }
        return Self.result(for: report)
    }

    private static func weatherLocation(from input: String) -> String {
        var cleaned = normalizedIntent(input)
        for phrase in [
            "what is the weather forecast for tomorrow",
            "what is the weather forecast tomorrow",
            "what is the weather tomorrow",
            "weather forecast for tomorrow",
            "weather forecast tomorrow",
            "forecast for tomorrow",
            "weather tomorrow",
            "what is the weather",
            "what s the weather",
            "weather forecast",
            "weather in",
            "weather for",
            "forecast in",
            "forecast for",
            "weather",
            "forecast",
            "right now",
            "currently",
            "tomorrow",
            "today",
            "current",
            "now"
        ].sorted(by: { $0.count > $1.count }) {
            let pattern = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![\p{L}\p{N}])"#
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .diacriticInsensitive])
        }
        return cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func requestsForecast(_ input: String) -> Bool {
        let lower = normalizedIntent(input)
        return lower.contains("forecast") || lower.contains("tomorrow")
    }

    private static func weatherReport(service: any WeatherService, requestInput: String, locationName: String) async throws -> WeatherReport {
        if requestsForecast(requestInput) {
            return try await service.forecastWeather(for: locationName, dayOffset: 1)
        }
        return try await service.currentWeather(for: locationName)
    }

    #if canImport(CoreLocation)
    private static func weatherReport(service: any WeatherService, requestInput: String, location: CLLocation, locationName: String) async throws -> WeatherReport {
        if requestsForecast(requestInput) {
            return try await service.forecastWeather(at: location, locationName: locationName, dayOffset: 1)
        }
        return try await service.currentWeather(at: location, locationName: locationName)
    }
    #endif

    private static func result(for report: WeatherReport) -> ToolResult {
        let current = "Current conditions: \(report.condition), \(Int(report.temperature.rounded()))°\(report.temperatureUnit), humidity \(report.humidityPercent)%, wind \(String(format: "%.1f", report.windSpeed)) \(report.windUnit)."
        let output: String
        if let forecastSummary = report.forecastSummary {
            output = "Weather for \(report.locationName): \(forecastSummary). \(current) Provider \(report.provider), \(Int(report.latencyMs)) ms."
        } else {
            output = "Weather for \(report.locationName): \(current) Provider \(report.provider), \(Int(report.latencyMs)) ms."
        }
        return ToolResult(
            toolName: "weather_lookup",
            output: output,
            riskLevel: .high,
            requiresApproval: true,
            approved: true,
            target: report.target,
            statusCode: report.statusCode,
            latencyMs: report.latencyMs
        )
    }

    #if canImport(CoreLocation)
    private static func reverseGeocodedName(for location: CLLocation) async -> String {
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                return placemark.locality ?? placemark.name ?? "Current Location"
            }
        } catch {
            return "\(String(format: "%.4f", location.coordinate.latitude)), \(String(format: "%.4f", location.coordinate.longitude))"
        }
        return "Current Location"
    }
    #endif
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
            return .needsInput(toolName: name, output: "Provide a phone number to prepare an SMS.", riskLevel: riskLevel, requiresApproval: true)
        }
        let body = cleanedInput(request.input, removing: ["send text", "text", "sms", phone])
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = "sms:\(phone)\(encodedBody.isEmpty ? "" : "&body=\(encodedBody)")"
        return .handoff(toolName: name, output: "Prepared approved SMS handoff: \(url). The user must confirm in Messages.", riskLevel: riskLevel, target: phone)
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
            return .needsInput(toolName: name, output: "Provide a phone number to prepare a call.", riskLevel: riskLevel, requiresApproval: true)
        }
        return .handoff(toolName: name, output: "Prepared approved phone handoff: tel://\(phone). The user must confirm the call.", riskLevel: riskLevel, target: phone)
    }
}

struct EmailInboxTool: Tool {
    let name = "email_inbox"
    let description = "Handles requests to read email inbox content with an honest native iOS limitation."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Inbox-read request such as latest email or unread email.", examples: ["read my latest email"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = normalizedIntent(input)
        let asksForEmail = lower.contains("email") || lower.contains("mail") || lower.contains("inbox")
        let asksToRead = lower.contains("read")
            || lower.contains("latest")
            || lower.contains("last")
            || lower.contains("newest")
            || lower.contains("unread")
            || lower.contains("show")
        return asksForEmail && asksToRead
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        return ToolResult(
            toolName: name,
            output: "I cannot read your Apple Mail inbox because iOS does not expose Mail messages to third-party apps. Share or import the email text/document and I can summarize it locally.",
            outcome: .unavailable,
            riskLevel: riskLevel,
            requiresApproval: true,
            approved: true,
            target: "mail",
            errorCategory: "platform_unavailable"
        )
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
            return .needsInput(toolName: name, output: "Provide an email address to prepare mail.", riskLevel: riskLevel, requiresApproval: true)
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
        return .handoff(toolName: name, output: "\(nativeStatus) Prepared approved email handoff: \(url). The user must review and send in Mail.", riskLevel: riskLevel, target: email)
    }
}

struct CurrentLocationTool: Tool {
    let name = "current_location"
    let description = "Requests the device current location after user approval and can prepare an Apple Maps handoff."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Current location request.", examples: ["where am I", "show me where I am on map"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = normalizedIntent(input)
        return lower == "where am i"
            || lower == "where i am"
            || lower.contains("where am i")
            || lower.contains("where i am")
            || lower.contains("my current location")
            || lower.contains("current location")
            || lower.contains("locate me")
            || lower.contains("show me where i am")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        #if canImport(CoreLocation)
        let started = ContinuousClock.now
        do {
            let location = try await currentDeviceLocation()
            let latencyMs = Self.latencyMilliseconds(started.duration(to: ContinuousClock.now))
            let coordinate = location.coordinate
            let accuracy = max(0, Int(location.horizontalAccuracy.rounded()))
            var output = "Current location: \(String(format: "%.5f", coordinate.latitude)), \(String(format: "%.5f", coordinate.longitude))"
            if accuracy > 0 {
                output += " (accuracy about \(accuracy) m)"
            }
            if Self.requestsMap(request.input) {
                output += ". Prepared approved Apple Maps handoff: \(Self.appleMapsURL(for: coordinate).absoluteString)"
            }
            return ToolResult(
                toolName: name,
                output: output,
                outcome: Self.requestsMap(request.input) ? .handoffPrepared : .success,
                riskLevel: riskLevel,
                requiresApproval: true,
                approved: true,
                target: Self.requestsMap(request.input) ? "maps.apple.com" : "CoreLocation",
                latencyMs: latencyMs
            )
        } catch {
            let message = userVisibleToolError(error, defaultMessage: "Current location failed.")
            return ToolResult(
                toolName: name,
                output: "Current location failed: \(message)",
                outcome: .permissionDenied,
                riskLevel: riskLevel,
                requiresApproval: true,
                approved: true,
                target: "CoreLocation",
                errorCategory: "permission_or_location_unavailable"
            )
        }
        #else
        return ToolResult(
            toolName: name,
            output: "Current location is unavailable on this platform.",
            outcome: .unavailable,
            riskLevel: riskLevel,
            requiresApproval: true,
            approved: true,
            target: "CoreLocation",
            errorCategory: "platform_unavailable"
        )
        #endif
    }

    private static func requestsMap(_ input: String) -> Bool {
        let lower = normalizedIntent(input)
        return lower.contains("map") || lower.contains("maps")
    }

    #if canImport(CoreLocation)
    private static func appleMapsURL(for coordinate: CLLocationCoordinate2D) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: "Current Location")
        ]
        return components.url ?? URL(string: "https://maps.apple.com")!
    }

    private static func latencyMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds * 1_000) + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
    #endif
}

struct MapsTool: Tool {
    let name = "maps_lookup"
    let description = "Prepares an Apple Maps search/directions URL after user approval."
    let riskLevel: ToolRiskLevel = .high

    var schema: ToolSchema {
        ToolSchema(inputDescription: "Place, address, or directions request.", examples: ["map nearest coffee shop"])
    }

    func canHandle(_ input: String) -> Bool {
        let lower = normalizedIntent(input)
        return lower.contains("map ")
            || lower.hasPrefix("map ")
            || lower.contains("maps")
            || lower.contains("directions")
            || lower.contains("navigate")
            || lower.contains("nearby")
            || lower.contains("show me where")
    }

    func metadata(for input: String) -> ToolExecutionMetadata {
        let query = cleanedInput(input, removing: ["open map", "map", "directions to", "directions", "navigate to", "navigate", "nearby"])
        return ToolExecutionMetadata(
            requiresNetwork: true,
            targetPreview: query.isEmpty ? "MapKit search" : "MapKit search for \(query)",
            actionPreview: "Search Maps and prepare Apple Maps handoff"
        )
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        let query = cleanedInput(request.input, removing: ["open map", "map", "directions to", "directions", "navigate to", "navigate", "nearby"])
        guard !query.isEmpty else {
            return .needsInput(toolName: name, output: "Provide a place, address, or directions destination for Maps.", riskLevel: riskLevel, requiresApproval: true)
        }

        if Self.isCurrentLocationMapRequest(query) {
            #if canImport(CoreLocation)
            do {
                let location = try await currentDeviceLocation()
                let coordinate = location.coordinate
                let mapsURL = Self.appleMapsURL(query: "Current Location", coordinate: coordinate)
                return ToolResult(
                    toolName: name,
                    output: "Prepared approved Apple Maps handoff for current location: \(mapsURL.absoluteString)",
                    outcome: .handoffPrepared,
                    riskLevel: riskLevel,
                    requiresApproval: true,
                    approved: true,
                    target: "maps.apple.com",
                    statusCode: 200
                )
            } catch {
                let message = userVisibleToolError(error, defaultMessage: "Current location failed.")
                return ToolResult(
                    toolName: name,
                    output: "Current-location Maps handoff failed: \(message)",
                    outcome: .permissionDenied,
                    riskLevel: riskLevel,
                    requiresApproval: true,
                    approved: true,
                    target: "CoreLocation",
                    errorCategory: "permission_or_location_unavailable"
                )
            }
            #endif
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
                    outcome: .handoffPrepared,
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
                outcome: .noResults,
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
            let message = userVisibleToolError(error, defaultMessage: "Apple Maps search could not complete that request.")
            return ToolResult(
                toolName: name,
                output: "MapKit search failed: \(message). Prepared approved Apple Maps search handoff: \(mapsURL.absoluteString)",
                outcome: .failed,
                riskLevel: riskLevel,
                requiresApproval: true,
                approved: true,
                target: "maps.apple.com",
                errorCategory: "service_unavailable"
            )
        }
        #else
        let mapsURL = Self.appleMapsURL(query: query, coordinate: nil)
        return ToolResult(toolName: name, output: "MapKit is unavailable on this platform. Prepared approved Apple Maps search handoff: \(mapsURL.absoluteString)", outcome: .unavailable, riskLevel: riskLevel, requiresApproval: true, approved: true, target: "maps.apple.com", errorCategory: "platform_unavailable")
        #endif
    }

    static func isCurrentLocationMapRequest(_ input: String) -> Bool {
        let intent = normalizedIntent(input)
        return intent == "where am i"
            || intent == "where i am"
            || intent == "current location"
            || intent == "my location"
            || intent == "locate me"
            || intent == "show me where i am"
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

    func metadata(for input: String) -> ToolExecutionMetadata {
        ToolExecutionMetadata(
            requiresNetwork: true,
            targetPreview: networkTargetPreview(from: input),
            actionPreview: "Open URL in the integrated web view"
        )
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        guard let url = firstHTTPURL(in: request.input) else {
            return .needsInput(toolName: name, output: "Provide an http or https URL for the integrated web view.", riskLevel: riskLevel, requiresApproval: true)
        }
        do {
            try AppNetworkConfiguration.networkPolicy().validate(url)
        } catch NetworkClientError.blockedHost(let host) {
            return ToolResult(toolName: name, output: "Web view navigation to \(host) is blocked unless Developer Mode allows local and private LAN hosts.", outcome: .blocked, riskLevel: riskLevel, requiresApproval: true, approved: true, target: host, errorCategory: "blocked_host")
        }
        return ToolResult(toolName: name, output: "Approved in-app webview navigation prepared: \(url.absoluteString)", outcome: .handoffPrepared, riskLevel: riskLevel, requiresApproval: true, approved: true, target: url.host)
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

    func metadata(for input: String) -> ToolExecutionMetadata {
        ToolExecutionMetadata(
            requiresNetwork: true,
            targetPreview: networkTargetPreview(from: input),
            actionPreview: "Fetch and extract a short web preview"
        )
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        try requirePrivacyApproval(request, toolName: name)
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        guard let url = firstHTTPURL(in: request.input) else {
            return .needsInput(toolName: name, output: "Provide an http or https URL to fetch.", riskLevel: riskLevel, requiresApproval: true)
        }
        let summary = try await fetchText(url: url, limit: 2_000)
        return ToolResult(
            toolName: name,
            output: summary.text.isEmpty ? "Fetched URL but no text content was returned." : summary.text,
            outcome: summary.text.isEmpty ? .noResults : .success,
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
            return ToolResult(toolName: name, output: files.isEmpty ? "No local agent files." : files.joined(separator: "\n"), outcome: files.isEmpty ? .noResults : .success, riskLevel: riskLevel, requiresApproval: true, approved: true)
        }

        guard let filename = filename(in: request.input) else {
            return .needsInput(toolName: name, output: "Provide a filename for local file action.", riskLevel: riskLevel, requiresApproval: true)
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

        return ToolResult(toolName: name, output: "Supported local file actions: list, read, write, delete.", outcome: .needsInput, riskLevel: riskLevel, requiresApproval: true, approved: true, errorCategory: "invalid_arguments")
    }
}

struct ToolRouter: Sendable {
    let registry: ToolRegistry

    func route(input: String) -> (any Tool)? {
        let intent = normalizedIntent(input)
        if isCurrentLocationIntent(intent),
           let tool = registry.tools.first(where: { $0.name == "current_location" }) {
            return tool
        }
        if isUserMemoryLookupIntent(intent),
           let tool = registry.tools.first(where: { $0.name == "memory_lookup" }) {
            return tool
        }
        return registry.tools.first { $0.canHandle(input) }
    }

    private func isCurrentLocationIntent(_ intent: String) -> Bool {
        intent == "where am i"
            || intent == "where am i?"
            || intent == "where i am"
            || intent.contains("where am i")
            || intent.contains("where i am")
            || intent.contains("show me where i am")
            || intent.contains("show where i am")
            || intent.contains("show my current location")
            || intent.contains("show me my current location")
            || intent.contains("my current location")
            || intent.contains("current location")
            || intent.contains("locate me")
    }

    private func isUserMemoryLookupIntent(_ intent: String) -> Bool {
        intent == "what is my name"
            || intent == "what s my name"
            || intent == "whats my name"
            || intent == "who am i"
            || intent.contains("what is my name")
            || intent.contains("what s my name")
            || intent.contains("whats my name")
            || intent.contains("do you know my name")
    }

    func execute(input: String, context: ModelContext) async throws -> ToolResult? {
        let decision = routeDecision(input: input, autonomyLevel: .assisted)
        guard let tool = decision.tool else { return nil }
        if decision.requiresApproval {
            throw AgentRuntimeError.approvalRequired(decision.toolName ?? tool.name)
        }
        let request = ToolExecutionRequest(runID: UUID(), input: input, autonomyLevel: .assisted, approved: false)
        return try await tool.execute(request: request, context: context)
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult? {
        let decision = routeDecision(input: request.input, autonomyLevel: request.autonomyLevel)
        return try await execute(decision: decision, request: request, context: context)
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
        let lower = normalizedIntent(input)
        return lower.contains("memory")
            || lower.contains("what do you remember")
            || lower.contains("what is my name")
            || lower.contains("what s my name")
            || lower.contains("who am i")
            || lower.contains("do you know my name")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let records: [MemoryRecord]
        if Self.isNameQuery(request.input) {
            let nameRecords = try memoryService.search(query: "name", context: context)
            let userNameRecords = nameRecords.filter { record in
                let content = normalizedIntent(record.content)
                return content.hasPrefix("user name is") || content.hasPrefix("my name is")
            }
            records = userNameRecords.isEmpty ? try memoryService.search(query: request.input, context: context) : userNameRecords
        } else {
            records = try memoryService.search(query: request.input, context: context)
        }
        let output = records.isEmpty ? "No local memories matched." : records.map(\.content).joined(separator: "\n")
        return ToolResult(toolName: name, output: output, outcome: records.isEmpty ? .noResults : .success)
    }

    private static func isNameQuery(_ input: String) -> Bool {
        let lower = normalizedIntent(input)
        return lower.contains("my name") || lower.contains("who am i")
    }
}

struct MemorySaveTool: Tool {
    let name = "memory_save"
    let description = "Saves important local memories."
    let memoryService: MemoryService

    func canHandle(_ input: String) -> Bool {
        let lower = normalizedIntent(input)
        return lower.contains("remember that")
            || lower.contains("save memory")
            || lower.contains("save this memory")
            || lower.contains("remember key points")
            || lower.contains("remember the key points")
            || lower.hasPrefix("remember my ")
            || lower.contains("remember my name is")
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        let content = Self.canonicalMemory(from: request.input)
        try memoryService.save(content: content.isEmpty ? request.input : content, source: "agent", scope: "longTerm", context: context)
        return ToolResult(toolName: name, output: "Saved local memory: \(content.isEmpty ? request.input : content)")
    }

    private static func canonicalMemory(from input: String) -> String {
        if let name = capturedValue(in: input, pattern: #"(?i)\bremember\s+my\s+name\s+is\s+(.+)$"#) {
            return "User name is \(name)"
        }
        return input
            .replacingOccurrences(of: "remember that", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "save memory", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "save this memory", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "remember the key points", with: "key points", options: .caseInsensitive)
            .replacingOccurrences(of: "remember key points", with: "key points", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capturedValue(in input: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: range), match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: input) else {
            return nil
        }
        let value = String(input[captureRange]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return value.isEmpty ? nil : value
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
        return ToolResult(toolName: name, output: output, outcome: snippets.isEmpty ? .noResults : .success)
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
        return ToolResult(toolName: name, output: output, outcome: summaries.isEmpty ? .noResults : .success)
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
        return ToolResult(toolName: name, output: output, outcome: matches.isEmpty ? .noResults : .success)
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
            return ToolResult(toolName: name, output: "No active tasks to complete.", outcome: .noResults)
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

    func metadata(for input: String) -> ToolExecutionMetadata {
        let method = Self.method(from: input)
        return ToolExecutionMetadata(
            requiresNetwork: true,
            targetPreview: networkTargetPreview(from: input),
            actionPreview: "Run approved HTTP \(method.rawValue) request"
        )
    }

    func execute(request: ToolExecutionRequest, context: ModelContext) async throws -> ToolResult {
        guard request.approved else {
            throw AgentRuntimeError.approvalRequired(name)
        }
        guard request.networkAccessAllowed else {
            return networkDisabledResult(toolName: name, riskLevel: riskLevel)
        }
        guard let url = firstHTTPURL(in: request.input) else {
            return .needsInput(toolName: name, output: "Provide an HTTP or HTTPS URL for the remote network request.", riskLevel: riskLevel, requiresApproval: true)
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
        let preview = response.contentType?.contains("text/html") == true
            ? WebContentExtractor.extractHTML(response.text).preview(limit: 1_000)
            : WebContentExtractor.extractPlainText(response.text, limit: 1_000)
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
