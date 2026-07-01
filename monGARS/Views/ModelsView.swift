import Foundation
import SwiftUI

struct ModelsView: View {
    @Bindable var container: AppContainer
    @State private var modelName: String = ""
    @State private var selectedPresetID: String = RemoteModelPreset.default.id
    @State private var installedModels: [InstalledRemoteModel] = []
    @State private var modelStatus: String?
    @State private var isRefreshing = false
    @State private var isDownloading = false
    @State private var isPreparingMLXModel = false

    var body: some View {
        Form {
            Section("Active Provider") {
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

            Section("On-Device MLX Model") {
                Picker("Model", selection: mlxModelSelection) {
                    ForEach(MLXModelPreset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    Text("Custom").tag(MLXModelPreset.customID)
                }

                TextField("Hugging Face model ID", text: mlxModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())

                if let preset = MLXModelPreset.preset(for: container.settingsStore.mlxModelID) {
                    ModelsMLXPresetSummary(preset: preset)
                    Button("Use Recommended Parameters") {
                        applyMLXPresetParameters(preset)
                    }
                } else {
                    LabeledContent("Preset") {
                        Text("Custom")
                    }
                    Text("Custom IDs must be compatible with MLX Swift LM's LLMRegistry.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Max Tokens") {
                    Stepper("\(container.settingsStore.mlxMaxTokens)", value: mlxMaxTokens, in: 64...4096, step: 64)
                }
                LabeledContent("Temperature") {
                    Stepper(String(format: "%.1f", container.settingsStore.mlxTemperature), value: mlxTemperature, in: 0.0...2.0, step: 0.1)
                }
                LabeledContent("Network") {
                    Text(container.settingsStore.remoteProviderEnabled ? "Allowed" : "Off")
                }

                Button {
                    useMLXModel()
                } label: {
                    Label("Use MLX Model", systemImage: "checkmark.circle")
                }
                .disabled(normalizedMLXModelID.isEmpty)

                Button {
                    Task { await prepareMLXModel() }
                } label: {
                    if isPreparingMLXModel {
                        Label("Preparing...", systemImage: "arrow.down.circle")
                    } else {
                        Label("Download to Device", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(!canPrepareMLXModel)

                if let mlxPreparationBlockReason {
                    Text(mlxPreparationBlockReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let mlxPreparationNote {
                    Text(mlxPreparationNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote Model Settings") {
                Toggle("Enable network provider and tools", isOn: remoteProviderEnabled)
                Toggle("Allow localhost and private LAN hosts", isOn: developerModeEnabled)
                TextField("Endpoint", text: remoteEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Active model", text: remoteModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent("Timeout") {
                    Stepper("\(Int(container.settingsStore.networkTimeoutSeconds))s", value: networkTimeoutSeconds, in: 5...90, step: 5)
                }
                LabeledContent("Retries") {
                    Stepper("\(container.settingsStore.networkMaxRetries)", value: networkMaxRetries, in: 0...5)
                }
                Text("Remote calls stay disabled unless network access is enabled. Local Ollama endpoints also require localhost access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Download") {
                Picker("Suggested model", selection: $selectedPresetID) {
                    ForEach(RemoteModelPreset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    Text("Custom").tag(RemoteModelPreset.customID)
                }
                .onChange(of: selectedPresetID) { _, value in
                    guard let preset = RemoteModelPreset.preset(id: value) else { return }
                    modelName = preset.model
                }

                if let preset = RemoteModelPreset.preset(id: selectedPresetID) {
                    Text(preset.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TextField("Model to download", text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    container.settingsStore.remoteModel = normalizedModelName
                    modelStatus = "Active remote model set to \(normalizedModelName)."
                } label: {
                    Label("Use This Model", systemImage: "checkmark.circle")
                }
                .disabled(normalizedModelName.isEmpty)

                Button {
                    Task { await downloadModel() }
                } label: {
                    if isDownloading {
                        Label("Downloading...", systemImage: "arrow.down.circle")
                    } else {
                        Label("Download with Ollama", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(!canDownload)

                if let remoteDownloadBlockReason {
                    Text(remoteDownloadBlockReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Downloads use Ollama-compatible model management endpoints. OpenAI-compatible remote endpoints do not expose an in-app model download API.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Installed Remote Models") {
                Button {
                    Task { await refreshInstalledModels() }
                } label: {
                    if isRefreshing {
                        Label("Refreshing...", systemImage: "arrow.clockwise")
                    } else {
                        Label("Refresh Installed Models", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!canRefreshInstalledModels)

                if let remoteManagementBlockReason {
                    Text(remoteManagementBlockReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if installedModels.isEmpty {
                    Text("No installed models loaded from the configured endpoint.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installedModels) { model in
                        Button {
                            container.settingsStore.remoteModel = model.name
                            modelStatus = "Active remote model set to \(model.name)."
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name)
                                    if let detail = model.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if container.settingsStore.remoteModel == model.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }

            if let modelStatus {
                Section("Status") {
                    Text(modelStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Models")
        .task {
            if modelName.isEmpty {
                modelName = container.settingsStore.remoteModel
                selectedPresetID = RemoteModelPreset.matchingID(for: container.settingsStore.remoteModel)
            }
            container.diagnostics.providerStatus = await container.llmProvider().status
        }
    }

    private var providerMode: Binding<ProviderMode> {
        Binding {
            container.settingsStore.providerMode
        } set: { value in
            container.settingsStore.providerMode = value
            Task {
                container.diagnostics.providerStatus = await container.llmProvider().status
            }
        }
    }

    private var remoteProviderEnabled: Binding<Bool> {
        Binding {
            container.settingsStore.remoteProviderEnabled
        } set: { value in
            container.settingsStore.remoteProviderEnabled = value
        }
    }

    private var developerModeEnabled: Binding<Bool> {
        Binding {
            container.settingsStore.developerModeEnabled
        } set: { value in
            container.settingsStore.developerModeEnabled = value
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
            modelName = value
            selectedPresetID = RemoteModelPreset.matchingID(for: value)
        }
    }

    private var mlxModelID: Binding<String> {
        Binding {
            container.settingsStore.mlxModelID
        } set: { value in
            container.settingsStore.mlxModelID = value
        }
    }

    private var mlxModelSelection: Binding<String> {
        Binding {
            MLXModelPreset.preset(for: container.settingsStore.mlxModelID)?.id ?? MLXModelPreset.customID
        } set: { value in
            guard value != MLXModelPreset.customID else {
                container.settingsStore.mlxModelID = ""
                return
            }
            container.settingsStore.mlxModelID = value
            if let preset = MLXModelPreset.preset(for: value) {
                applyMLXPresetParameters(preset)
            }
        }
    }

    private var mlxMaxTokens: Binding<Int> {
        Binding {
            container.settingsStore.mlxMaxTokens
        } set: { value in
            container.settingsStore.mlxMaxTokens = value
        }
    }

    private var mlxTemperature: Binding<Double> {
        Binding {
            container.settingsStore.mlxTemperature
        } set: { value in
            container.settingsStore.mlxTemperature = value
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

    private var normalizedModelName: String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedMLXModelID: String {
        container.settingsStore.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var mlxPreparationBlockReason: String? {
        ModelManagementReadiness.mlxPreparationBlockReason(
            modelID: container.settingsStore.mlxModelID,
            isLinked: MLXLocalProvider.isLinked
        )
    }

    private var mlxPreparationNote: String? {
        guard !container.settingsStore.remoteProviderEnabled else { return nil }
        return "Network access is off. Cached MLX models can still prepare; new Hugging Face downloads need network access."
    }

    private var canPrepareMLXModel: Bool {
        !isPreparingMLXModel && mlxPreparationBlockReason == nil
    }

    private var remoteManagementBlockReason: String? {
        ModelManagementReadiness.remoteManagementBlockReason(
            endpoint: container.settingsStore.remoteEndpoint,
            networkEnabled: container.settingsStore.remoteProviderEnabled,
            allowsLocalNetworkHosts: container.settingsStore.developerModeEnabled
        )
    }

    private var remoteDownloadBlockReason: String? {
        ModelManagementReadiness.remoteDownloadBlockReason(
            modelName: modelName,
            endpoint: container.settingsStore.remoteEndpoint,
            networkEnabled: container.settingsStore.remoteProviderEnabled,
            allowsLocalNetworkHosts: container.settingsStore.developerModeEnabled
        )
    }

    private var canRefreshInstalledModels: Bool {
        !isRefreshing && remoteManagementBlockReason == nil
    }

    private var canDownload: Bool {
        !isDownloading && remoteDownloadBlockReason == nil
    }

    private func refreshInstalledModels() async {
        if let remoteManagementBlockReason {
            modelStatus = remoteManagementBlockReason
            return
        }

        isRefreshing = true
        modelStatus = "Loading installed models..."
        defer { isRefreshing = false }

        do {
            let client = try modelManagementClient()
            installedModels = try await client.installedModels()
            modelStatus = installedModels.isEmpty ? "No installed models were reported by the endpoint." : "Loaded \(installedModels.count) installed model(s)."
        } catch {
            modelStatus = "Unable to load installed models: \(error.localizedDescription)"
        }
    }

    private func downloadModel() async {
        let requestedModel = normalizedModelName
        guard !requestedModel.isEmpty else { return }
        if let remoteDownloadBlockReason {
            modelStatus = remoteDownloadBlockReason
            return
        }

        isDownloading = true
        modelStatus = "Starting download for \(requestedModel)..."
        defer { isDownloading = false }

        do {
            let client = try modelManagementClient()
            for try await event in client.pullModel(named: requestedModel) {
                modelStatus = event
            }
            container.settingsStore.providerMode = .remote
            container.settingsStore.remoteModel = requestedModel
            modelStatus = "Downloaded \(requestedModel) and set it as the active remote model."
            await refreshInstalledModels()
        } catch {
            modelStatus = "Download failed: \(error.localizedDescription)"
        }
    }

    private func useMLXModel() {
        let requestedModel = normalizedMLXModelID
        guard !requestedModel.isEmpty else { return }
        container.settingsStore.mlxModelID = requestedModel
        container.settingsStore.providerMode = .mlx
        modelStatus = "Active MLX model set to \(requestedModel)."
        Task {
            container.diagnostics.providerStatus = await container.llmProvider().status
        }
    }

    private func prepareMLXModel() async {
        let requestedModel = normalizedMLXModelID
        guard !requestedModel.isEmpty else { return }
        if let mlxPreparationBlockReason {
            modelStatus = mlxPreparationBlockReason
            return
        }

        isPreparingMLXModel = true
        modelStatus = "Preparing MLX model \(requestedModel)..."
        defer { isPreparingMLXModel = false }

        do {
            container.settingsStore.mlxModelID = requestedModel
            try await MLXLocalProvider.prepareModel(
                id: requestedModel,
                allowsModelDownload: container.settingsStore.remoteProviderEnabled
            )
            container.settingsStore.providerMode = .mlx
            modelStatus = "MLX model \(requestedModel) is ready on device."
            container.diagnostics.providerStatus = await container.llmProvider().status
        } catch is CancellationError {
            return
        } catch {
            modelStatus = "MLX model preparation failed: \(error.localizedDescription)"
        }
    }

    private func applyMLXPresetParameters(_ preset: MLXModelPreset) {
        container.settingsStore.mlxModelID = preset.id
        container.settingsStore.mlxMaxTokens = preset.recommendedMaxTokens
        container.settingsStore.mlxTemperature = preset.recommendedTemperature
    }

    private func modelManagementClient() throws -> ModelManagementClient {
        try ModelManagementClient(
            endpoint: container.settingsStore.remoteEndpoint,
            apiKey: container.settingsStore.remoteAPIKey,
            networkClient: AppNetworkConfiguration.client()
        )
    }
}

struct RemoteModelPreset: Identifiable, Equatable {
    static let customID = "custom"
    static let `default` = RemoteModelPreset(
        id: "llama32",
        name: "Llama 3.2",
        model: "llama3.2",
        detail: "General chat model with a small local footprint."
    )

    static let all: [RemoteModelPreset] = [
        .default,
        RemoteModelPreset(id: "gemma4", name: "Gemma 4", model: "gemma4", detail: "Ollama documentation example model."),
        RemoteModelPreset(id: "qwen3", name: "Qwen 3", model: "qwen3", detail: "General reasoning and multilingual work."),
        RemoteModelPreset(id: "mistral", name: "Mistral", model: "mistral", detail: "Compact general-purpose instruction model."),
        RemoteModelPreset(id: "phi4mini", name: "Phi 4 Mini", model: "phi4-mini", detail: "Small model for lighter local runs.")
    ]

    let id: String
    let name: String
    let model: String
    let detail: String

    static func preset(id: String) -> RemoteModelPreset? {
        all.first { $0.id == id }
    }

    static func matchingID(for model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.model == normalized }?.id ?? customID
    }
}

struct InstalledRemoteModel: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var sizeBytes: Int?
    var family: String?
    var parameterSize: String?
    var quantizationLevel: String?

    var detail: String? {
        [
            parameterSize,
            quantizationLevel,
            family,
            sizeDescription
        ]
        .compactMap { $0 }
        .joined(separator: " - ")
        .nilIfEmpty
    }

    private var sizeDescription: String? {
        guard let sizeBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(sizeBytes))
    }
}

private struct ModelsMLXPresetSummary: View {
    var preset: MLXModelPreset

    var body: some View {
        LabeledContent("Family") {
            Text(preset.family)
        }
        LabeledContent("Size") {
            Text(preset.size)
        }
        LabeledContent("Fit") {
            Text(preset.fit)
        }
        Text(preset.notes)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

struct ModelManagementClient: Sendable {
    var baseURL: URL
    var apiKey: String
    var networkClient: NetworkClient

    init(endpoint: String, apiKey: String, networkClient: NetworkClient) throws {
        guard let baseURL = Self.ollamaBaseURL(for: endpoint) else {
            throw ModelManagementError.unsupportedEndpoint
        }
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.networkClient = networkClient
    }

    func installedModels() async throws -> [InstalledRemoteModel] {
        let url = baseURL.appending(path: "api/tags")
        let response = try await networkClient.send(NetworkRequest(
            url: url,
            headers: headers,
            acceptedContentTypes: ["application/json"]
        ))
        return try response.decodedJSON(OllamaTagsResponse.self).models.map {
            InstalledRemoteModel(
                name: $0.name,
                sizeBytes: $0.size,
                family: $0.details?.family,
                parameterSize: $0.details?.parameterSize,
                quantizationLevel: $0.details?.quantizationLevel
            )
        }
    }

    func pullModel(named model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let requestBody = try JSONEncoder().encode(OllamaPullRequest(model: model, stream: true))
                    let stream = networkClient.streamLines(NetworkRequest(
                        url: baseURL.appending(path: "api/pull"),
                        method: .post,
                        headers: headers,
                        body: requestBody,
                        acceptedContentTypes: ["application/json"]
                    ))
                    for try await line in stream {
                        if let message = Self.pullStatusMessage(from: line.line) {
                            continuation.yield(message)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func ollamaBaseURL(for endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              components.host != nil else {
            return nil
        }

        let path = components.path.lowercased()
        guard path.isEmpty || path == "/" || path == "/api/generate" || path == "/api/chat" else {
            return nil
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func pullStatusMessage(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let status = try? JSONDecoder().decode(OllamaPullStatus.self, from: data) else {
            return nil
        }

        if let completed = status.completed, let total = status.total, total > 0 {
            let percent = Int((Double(completed) / Double(total) * 100).rounded())
            return "\(status.status) \(percent)%"
        }
        return status.status
    }

    private var headers: [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            headers["Authorization"] = "Bearer \(trimmedKey)"
        }
        return headers
    }
}

enum ModelManagementReadiness {
    static func remoteDownloadBlockReason(modelName: String, endpoint: String, networkEnabled: Bool, allowsLocalNetworkHosts: Bool) -> String? {
        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a model name before downloading."
        }
        return remoteManagementBlockReason(
            endpoint: endpoint,
            networkEnabled: networkEnabled,
            allowsLocalNetworkHosts: allowsLocalNetworkHosts
        )
    }

    static func remoteManagementBlockReason(endpoint: String, networkEnabled: Bool, allowsLocalNetworkHosts: Bool) -> String? {
        guard networkEnabled else {
            return "Enable network access before contacting an Ollama endpoint."
        }
        guard let baseURL = ModelManagementClient.ollamaBaseURL(for: endpoint) else {
            return "Use an Ollama-compatible endpoint such as http://localhost:11434/api/generate."
        }
        if let host = baseURL.host, NetworkPolicy.isBlockedHost(host), !allowsLocalNetworkHosts {
            return "Allow localhost and private LAN hosts before contacting \(host)."
        }
        return nil
    }

    static func mlxPreparationBlockReason(modelID: String, isLinked: Bool) -> String? {
        guard isLinked else {
            return "MLX Swift LM is not linked in this app build."
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose an MLX model before preparing it on device."
        }
        return nil
    }
}

enum ModelManagementError: LocalizedError, Equatable {
    case unsupportedEndpoint

    var errorDescription: String? {
        switch self {
        case .unsupportedEndpoint:
            "Model downloads are available only for Ollama-compatible /api/generate or /api/chat endpoints."
        }
    }
}

private struct OllamaPullRequest: Encodable {
    var model: String
    var stream: Bool
}

private struct OllamaPullStatus: Decodable {
    var status: String
    var completed: Int?
    var total: Int?
}

private struct OllamaTagsResponse: Decodable {
    var models: [OllamaModel]

    struct OllamaModel: Decodable {
        var name: String
        var size: Int?
        var details: Details?

        struct Details: Decodable {
            var family: String?
            var parameterSize: String?
            var quantizationLevel: String?

            enum CodingKeys: String, CodingKey {
                case family
                case parameterSize = "parameter_size"
                case quantizationLevel = "quantization_level"
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
