import SwiftUI

struct SettingsView: View {
    @Bindable var container: AppContainer

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

            Section("Remote Endpoint") {
                Toggle("Enable network provider", isOn: remoteProviderEnabled)
                TextField("Endpoint", text: remoteEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Remote calls are disabled unless the toggle is on. Mock and Foundation modes make no developer-backend network requests.")
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

    private var autonomyLevel: Binding<AutonomyLevel> {
        Binding {
            container.settingsStore.autonomyLevel
        } set: { value in
            container.settingsStore.autonomyLevel = value
        }
    }
}
