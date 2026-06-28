import SwiftUI

struct SettingsView: View {
    @Bindable var container: AppContainer
    @State private var connectionTestStatus: String?

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
                LabeledContent("Timeout") {
                    Stepper("\(Int(container.settingsStore.networkTimeoutSeconds))s", value: networkTimeoutSeconds, in: 5...90, step: 5)
                }
                LabeledContent("Retries") {
                    Stepper("\(container.settingsStore.networkMaxRetries)", value: networkMaxRetries, in: 0...5)
                }
                Button("Test Remote Connection") {
                    Task { await testRemoteConnection() }
                }
                .disabled(!container.settingsStore.remoteProviderEnabled)
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
                Text("Weather lookup prefers WeatherKit when available, then falls back to this OpenWeather-compatible endpoint. Keys are stored in Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Web") {
                TextEditor(text: remoteNetworkHeadersText)
                    .frame(minHeight: 88)
                    .font(.footnote.monospaced())
                Text("Optional headers for the generic remote network tool, one per line as Name: Value. Web fetch and WebKit navigation still require network access and approval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Documents/RAG") {
                LabeledContent("Import") {
                    Text("UTF-8 text, Markdown, selectable-text PDF")
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
                Text("Developer Mode permits localhost, .local, and private LAN HTTP targets for local testing. Keep it off for normal privacy-first operation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
}
