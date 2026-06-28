import SwiftData
import SwiftUI
#if canImport(Contacts)
import Contacts
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(MapKit)
import MapKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

struct SettingsView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @State private var connectionTestStatus: String?
    @State private var nativeToolTestStatus: String?
    @State private var isRunningDeveloperDiagnostics = false
    @State private var developerDiagnosticsResult: DeveloperDiagnosticsResult?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Mode", selection: providerMode) {
                    ForEach(ProviderMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(container.diagnostics.providerStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                let capabilities = container.llmProvider().capabilities
                LabeledContent("Local") {
                    Text(capabilities.isLocal ? "Yes" : "No")
                }
                LabeledContent("Streaming") {
                    Text(capabilities.supportsStreaming ? "Yes" : "No")
                }
                LabeledContent("JSON Mode") {
                    Text(capabilities.supportsJSONMode ? "Yes" : "No")
                }
                LabeledContent("Max Context") {
                    Text("\(capabilities.maxContextTokens) tokens")
                }
            }

            Section("Network") {
                Toggle("Enable network provider and tools", isOn: remoteProviderEnabled)
                LabeledContent("Timeout") {
                    Stepper("\(Int(container.settingsStore.networkTimeoutSeconds))s", value: networkTimeoutSeconds, in: 5...90, step: 5)
                }
                LabeledContent("Retries") {
                    Stepper("\(container.settingsStore.networkMaxRetries)", value: networkMaxRetries, in: 0...5)
                }
                if let connectionTestStatus {
                    Text(connectionTestStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Network is off by default. Remote provider calls, web fetches, weather lookups, Maps search, and in-app web navigation stay disabled unless this toggle is on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Weather") {
                TextField("OpenWeather-compatible endpoint", text: weatherEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Weather API key", text: weatherAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Units", selection: weatherUnits) {
                    Text("Metric").tag("metric")
                    Text("Imperial").tag("imperial")
                    Text("Standard").tag("standard")
                }
                Button("Test Weather") {
                    Task { await testWeather() }
                }
                Text("Weather lookup prefers WeatherKit when available, then falls back to this OpenWeather-compatible endpoint. Keys are stored in Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Web") {
                TextEditor(text: remoteNetworkHeadersText)
                    .frame(minHeight: 88)
                    .font(.footnote.monospaced())
                Button("Test Web Fetch") {
                    Task { await testWebFetch() }
                }
                .disabled(!container.settingsStore.remoteProviderEnabled)
                Text("Optional headers for the generic remote network tool, one per line as Name: Value. Web fetch and WebKit navigation still require network access and approval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Documents/RAG") {
                LabeledContent("Import") {
                    Text("UTF-8 text, Markdown, selectable-text PDF")
                }
                Button("Test PDFKit Availability") {
                    testPDFKitAvailability()
                }
                Text("Imported PDFs are extracted locally with PDFKit and stored as SwiftData chunks for retrieval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Integrations") {
                LabeledContent("Maps") {
                    Text("MapKit search + Apple Maps handoff")
                }
                LabeledContent("Communication") {
                    Text("Messages, Phone, Mail handoff")
                }
                LabeledContent("Data") {
                    Text("EventKit + Contacts permissions")
                }
                Button("Test MapKit") {
                    Task { await testMapKit() }
                }
                .disabled(!container.settingsStore.remoteProviderEnabled)
                Button("Test Contacts Permission") {
                    Task { await testContactsPermission() }
                }
                Button("Test Calendar Permission") {
                    Task { await testCalendarPermission() }
                }
                Button("Test Reminders Permission") {
                    Task { await testRemindersPermission() }
                }
                Text("Native integrations require approval. The app prepares system UI or handoff URLs; it never auto-sends, auto-calls, or dumps contact data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Autonomy") {
                Picker("Level", selection: autonomyLevel) {
                    ForEach(AutonomyLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text("Manual and Assisted modes ask before risky tool use. Network, file deletion, destructive, privacy-sensitive, and external actions remain blocked behind approval gates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Speech") {
                Button("Request Speech Permission") {
                    Task {
                        _ = await container.speechService.requestAuthorization()
                    }
                }
            }

            Section("Developer") {
                Toggle("Allow localhost and private LAN hosts", isOn: developerModeEnabled)
                Button {
                    Task { await runDeveloperDiagnostics() }
                } label: {
                    if isRunningDeveloperDiagnostics {
                        Label("Running Real Tool E2E...", systemImage: "hourglass")
                    } else {
                        Label("Run Real Tool E2E & Export Report", systemImage: "stethoscope")
                    }
                }
                .disabled(isRunningDeveloperDiagnostics)
                Text("Developer Mode permits localhost, .local, and private LAN HTTP targets for local testing. Keep it off for normal privacy-first operation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let developerDiagnosticsResult {
                Section("Developer Report") {
                    Text(developerDiagnosticsResult.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let fileURL = developerDiagnosticsResult.fileURL {
                        ShareLink(item: fileURL) {
                            Label("Export Latest Report", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        ShareLink(item: developerDiagnosticsResult.text) {
                            Label("Export Latest Report", systemImage: "square.and.arrow.up")
                        }
                    }
                    DisclosureGroup("Preview") {
                        Text(developerDiagnosticsResult.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            if container.settingsStore.developerModeEnabled {
                Section("Advanced / Paused Remote LLM") {
                    Text("Remote LLM remains paused unless Remote Endpoint mode and network access are both explicitly enabled. Keep this section for development only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Endpoint", text: remoteEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Model", text: remoteModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Remote API key", text: remoteAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Test Remote Connection") {
                        Task { await testRemoteConnection() }
                    }
                    .disabled(container.settingsStore.providerMode != .remote || !container.settingsStore.remoteProviderEnabled)
                }
            }

            if let nativeToolTestStatus {
                Section("Test Results") {
                    Text(nativeToolTestStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Reset") {
                Button("Reset Network Configuration", role: .destructive) {
                    container.settingsStore.resetNetworkConfiguration()
                    connectionTestStatus = "Network configuration reset. Network access is off."
                }
            }
        }
        .navigationTitle("Settings")
        .task(id: container.settingsStore.providerMode) {
            container.diagnostics.providerStatus = await container.llmProvider().status
        }
    }

    private var providerMode: Binding<ProviderMode> {
        Binding {
            container.settingsStore.providerMode
        } set: { value in
            container.settingsStore.providerMode = value
        }
    }

    private var remoteProviderEnabled: Binding<Bool> {
        Binding {
            container.settingsStore.remoteProviderEnabled
        } set: { value in
            container.settingsStore.remoteProviderEnabled = value
        }
    }

    private var remoteEndpoint: Binding<String> {
        Binding {
            container.settingsStore.remoteEndpoint
        } set: { value in
            container.settingsStore.remoteEndpoint = value
        }
    }

    private var remoteModel: Binding<String> {
        Binding {
            container.settingsStore.remoteModel
        } set: { value in
            container.settingsStore.remoteModel = value
        }
    }

    private var remoteAPIKey: Binding<String> {
        Binding {
            container.settingsStore.remoteAPIKey
        } set: { value in
            container.settingsStore.remoteAPIKey = value
        }
    }

    private var networkTimeoutSeconds: Binding<Double> {
        Binding {
            container.settingsStore.networkTimeoutSeconds
        } set: { value in
            container.settingsStore.networkTimeoutSeconds = value
        }
    }

    private var networkMaxRetries: Binding<Int> {
        Binding {
            container.settingsStore.networkMaxRetries
        } set: { value in
            container.settingsStore.networkMaxRetries = value
        }
    }

    private var weatherEndpoint: Binding<String> {
        Binding {
            container.settingsStore.weatherEndpoint
        } set: { value in
            container.settingsStore.weatherEndpoint = value
        }
    }

    private var weatherAPIKey: Binding<String> {
        Binding {
            container.settingsStore.weatherAPIKey
        } set: { value in
            container.settingsStore.weatherAPIKey = value
        }
    }

    private var weatherUnits: Binding<String> {
        Binding {
            container.settingsStore.weatherUnits
        } set: { value in
            container.settingsStore.weatherUnits = value
        }
    }

    private var remoteNetworkHeadersText: Binding<String> {
        Binding {
            container.settingsStore.remoteNetworkHeadersText
        } set: { value in
            container.settingsStore.remoteNetworkHeadersText = value
        }
    }

    private var autonomyLevel: Binding<AutonomyLevel> {
        Binding {
            container.settingsStore.autonomyLevel
        } set: { value in
            container.settingsStore.autonomyLevel = value
        }
    }

    private var developerModeEnabled: Binding<Bool> {
        Binding {
            container.settingsStore.developerModeEnabled
        } set: { value in
            container.settingsStore.developerModeEnabled = value
        }
    }

    private func testRemoteConnection() async {
        connectionTestStatus = "Testing remote endpoint..."
        do {
            let provider = container.llmProvider()
            let response = try await provider.complete(request: LLMRequest(prompt: "Reply with: ok", conversationContext: [], retrievedContext: []))
            connectionTestStatus = "Remote connection succeeded: \(response.text.prefix(80))"
            container.diagnostics.providerStatus = await provider.status
        } catch {
            connectionTestStatus = "Remote connection failed: \(error.localizedDescription)"
        }
    }

    private func runDeveloperDiagnostics() async {
        isRunningDeveloperDiagnostics = true
        nativeToolTestStatus = "Running developer diagnostics..."
        let result = await DeveloperDiagnosticsRunner.run(container: container, context: modelContext)
        developerDiagnosticsResult = result
        nativeToolTestStatus = result.summary
        isRunningDeveloperDiagnostics = false
    }

    private func testWeather() async {
        nativeToolTestStatus = "Testing weather provider..."
        do {
            let report = try await WeatherServiceFactory.makeConfiguredService().currentWeather(for: "Montreal")
            nativeToolTestStatus = "Weather OK: \(report.provider) for \(report.locationName), target \(report.target)."
        } catch {
            nativeToolTestStatus = "Weather test failed: \(error.localizedDescription)"
        }
    }

    private func testWebFetch() async {
        nativeToolTestStatus = "Testing web fetch..."
        do {
            let response = try await AppNetworkConfiguration.client().send(NetworkRequest(url: URL(string: "https://example.com")!, acceptedContentTypes: ["text/html", "text/plain"]))
            nativeToolTestStatus = "Web fetch OK: \(response.statusCode) from \(response.finalURL.host ?? response.finalURL.absoluteString), \(response.data.count) bytes."
        } catch {
            nativeToolTestStatus = "Web fetch failed: \(error.localizedDescription)"
        }
    }

    private func testMapKit() async {
        nativeToolTestStatus = "Testing MapKit..."
        #if canImport(MapKit)
        do {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = "Apple Park"
            let response = try await MKLocalSearch(request: request).start()
            nativeToolTestStatus = "MapKit OK: \(response.mapItems.first?.name ?? "no named result")."
        } catch {
            nativeToolTestStatus = "MapKit failed: \(error.localizedDescription)"
        }
        #else
        nativeToolTestStatus = "MapKit is unavailable on this platform."
        #endif
    }

    private func testContactsPermission() async {
        nativeToolTestStatus = "Testing Contacts permission..."
        #if canImport(Contacts)
        do {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                CNContactStore().requestAccess(for: .contacts) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            nativeToolTestStatus = granted ? "Contacts permission granted." : "Contacts permission denied."
        } catch {
            nativeToolTestStatus = "Contacts permission failed: \(error.localizedDescription)"
        }
        #else
        nativeToolTestStatus = "Contacts are unavailable on this platform."
        #endif
    }

    private func testCalendarPermission() async {
        nativeToolTestStatus = "Testing Calendar permission..."
        #if canImport(EventKit)
        await testEventKitPermission(kind: .event)
        #else
        nativeToolTestStatus = "Calendar permissions are unavailable on this platform."
        #endif
    }

    private func testRemindersPermission() async {
        nativeToolTestStatus = "Testing Reminders permission..."
        #if canImport(EventKit)
        await testEventKitPermission(kind: .reminder)
        #else
        nativeToolTestStatus = "Reminders permissions are unavailable on this platform."
        #endif
    }

    #if canImport(EventKit)
    private func testEventKitPermission(kind: EKEntityType) async {
        let store = EKEventStore()
        do {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                if kind == .event {
                    if #available(iOS 17.0, *) {
                        store.requestFullAccessToEvents { granted, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                        }
                    } else {
                        store.requestAccess(to: .event) { granted, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                        }
                    }
                } else {
                    if #available(iOS 17.0, *) {
                        store.requestFullAccessToReminders { granted, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                        }
                    } else {
                        store.requestAccess(to: .reminder) { granted, error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
                        }
                    }
                }
            }
            nativeToolTestStatus = granted ? "\(kind == .event ? "Calendar" : "Reminders") permission granted." : "\(kind == .event ? "Calendar" : "Reminders") permission denied."
        } catch {
            nativeToolTestStatus = "\(kind == .event ? "Calendar" : "Reminders") permission failed: \(error.localizedDescription)"
        }
    }
    #endif

    private func testPDFKitAvailability() {
        #if canImport(PDFKit)
        let available = PDFDocument(data: Data("%PDF-1.4\n%EOF".utf8)) != nil
        nativeToolTestStatus = available ? "PDFKit is available." : "PDFKit framework loaded, but the sample PDF could not be opened."
        #else
        nativeToolTestStatus = "PDFKit is unavailable on this platform."
        #endif
    }
}
