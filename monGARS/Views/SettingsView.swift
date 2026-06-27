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
}
