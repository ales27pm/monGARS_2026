import Foundation

@Observable
final class SettingsStore {
    var providerMode: ProviderMode {
        didSet { UserDefaults.standard.set(providerMode.rawValue, forKey: Keys.providerMode) }
    }

    var remoteEndpoint: String {
        didSet { UserDefaults.standard.set(remoteEndpoint, forKey: Keys.remoteEndpoint) }
    }

    var remoteModel: String {
        didSet { UserDefaults.standard.set(remoteModel, forKey: AppNetworkConfiguration.Keys.remoteModel) }
    }

    var remoteAPIKey: String {
        didSet { KeychainStore.set(remoteAPIKey, for: AppNetworkConfiguration.Keys.remoteAPIKey) }
    }

    var remoteProviderEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteProviderEnabled, forKey: Keys.remoteProviderEnabled) }
    }

    var mlxModelID: String {
        didSet {
            let trimmed = mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != mlxModelID {
                mlxModelID = trimmed
            }
            UserDefaults.standard.set(trimmed, forKey: Keys.mlxModelID)
        }
    }

    var mlxMaxTokens: Int {
        didSet { UserDefaults.standard.set(mlxMaxTokens, forKey: Keys.mlxMaxTokens) }
    }

    var mlxTemperature: Double {
        didSet { UserDefaults.standard.set(mlxTemperature, forKey: Keys.mlxTemperature) }
    }

    var networkTimeoutSeconds: Double {
        didSet { UserDefaults.standard.set(networkTimeoutSeconds, forKey: AppNetworkConfiguration.Keys.timeoutSeconds) }
    }

    var networkMaxRetries: Int {
        didSet { UserDefaults.standard.set(networkMaxRetries, forKey: AppNetworkConfiguration.Keys.maxRetries) }
    }

    var weatherEndpoint: String {
        didSet { UserDefaults.standard.set(weatherEndpoint, forKey: AppNetworkConfiguration.Keys.weatherEndpoint) }
    }

    var weatherAPIKey: String {
        didSet { KeychainStore.set(weatherAPIKey, for: AppNetworkConfiguration.Keys.weatherAPIKey) }
    }

    var weatherUnits: String {
        didSet { UserDefaults.standard.set(weatherUnits, forKey: AppNetworkConfiguration.Keys.weatherUnits) }
    }

    var remoteNetworkHeadersText: String {
        didSet {
            if let headers = Self.parseHeaders(remoteNetworkHeadersText),
               let data = try? JSONEncoder().encode(headers) {
                UserDefaults.standard.set(data, forKey: AppNetworkConfiguration.Keys.remoteNetworkHeaders)
            }
        }
    }

    var autonomyLevel: AutonomyLevel {
        didSet { UserDefaults.standard.set(autonomyLevel.rawValue, forKey: Keys.autonomyLevel) }
    }

    var developerModeEnabled: Bool {
        didSet { UserDefaults.standard.set(developerModeEnabled, forKey: AppNetworkConfiguration.Keys.developerModeEnabled) }
    }

    init() {
        let rawMode = UserDefaults.standard.string(forKey: Keys.providerMode) ?? ProviderMode.foundation.rawValue
        providerMode = ProviderMode(rawValue: rawMode) ?? .foundation
        remoteEndpoint = UserDefaults.standard.string(forKey: Keys.remoteEndpoint) ?? "http://localhost:11434/api/generate"
        remoteModel = AppNetworkConfiguration.remoteModel
        remoteAPIKey = AppNetworkConfiguration.remoteAPIKey
        remoteProviderEnabled = UserDefaults.standard.bool(forKey: Keys.remoteProviderEnabled)
        mlxModelID = UserDefaults.standard.string(forKey: Keys.mlxModelID) ?? MLXModelPreset.default.id
        mlxMaxTokens = UserDefaults.standard.object(forKey: Keys.mlxMaxTokens) as? Int ?? 512
        if UserDefaults.standard.object(forKey: Keys.mlxTemperature) != nil {
            mlxTemperature = UserDefaults.standard.double(forKey: Keys.mlxTemperature)
        } else {
            mlxTemperature = 0.2
        }
        let timeout = UserDefaults.standard.double(forKey: AppNetworkConfiguration.Keys.timeoutSeconds)
        networkTimeoutSeconds = timeout > 0 ? timeout : 20
        networkMaxRetries = UserDefaults.standard.object(forKey: AppNetworkConfiguration.Keys.maxRetries) as? Int ?? 2
        weatherEndpoint = AppNetworkConfiguration.weatherEndpoint
        weatherAPIKey = AppNetworkConfiguration.weatherAPIKey
        weatherUnits = AppNetworkConfiguration.weatherUnits
        remoteNetworkHeadersText = Self.headersText(AppNetworkConfiguration.remoteNetworkHeaders)
        let rawAutonomy = UserDefaults.standard.string(forKey: Keys.autonomyLevel) ?? AutonomyLevel.assisted.rawValue
        autonomyLevel = AutonomyLevel(rawValue: rawAutonomy) ?? .assisted
        developerModeEnabled = UserDefaults.standard.bool(forKey: AppNetworkConfiguration.Keys.developerModeEnabled)
    }

    func resetNetworkConfiguration() {
        remoteProviderEnabled = false
        remoteEndpoint = "http://localhost:11434/api/generate"
        remoteModel = "llama3.2"
        remoteAPIKey = ""
        networkTimeoutSeconds = 20
        networkMaxRetries = 2
        weatherEndpoint = "https://api.openweathermap.org/data/2.5/weather"
        weatherAPIKey = ""
        weatherUnits = "metric"
        remoteNetworkHeadersText = ""
        developerModeEnabled = false
        UserDefaults.standard.removeObject(forKey: AppNetworkConfiguration.Keys.remoteNetworkHeaders)
    }

    static func parseHeaders(_ text: String) -> [String: String]? {
        let pairs = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var headers: [String: String] = [:]
        for pair in pairs {
            guard let separator = pair.firstIndex(of: ":") else { return nil }
            let key = pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            headers[key] = value
        }
        return headers
    }

    private static func headersText(_ headers: [String: String]) -> String {
        headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private enum Keys {
        static let providerMode = "providerMode"
        static let remoteEndpoint = "remoteEndpoint"
        static let remoteProviderEnabled = "remoteProviderEnabled"
        static let mlxModelID = "mlxModelID"
        static let mlxMaxTokens = "mlxMaxTokens"
        static let mlxTemperature = "mlxTemperature"
        static let autonomyLevel = "autonomyLevel"
    }
}

enum ProviderMode: String, CaseIterable, Identifiable, Codable {
    case foundation
    case mlx
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .foundation:
            "Foundation Models"
        case .mlx:
            "MLX Local"
        case .remote:
            "Remote Endpoint"
        }
    }
}

struct MLXModelPreset: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var family: String
    var size: String
    var fit: String
    var notes: String
    var recommendedMaxTokens: Int
    var recommendedTemperature: Double

    static let customID = "__custom_mlx_model__"

    static let all: [MLXModelPreset] = [
        MLXModelPreset(
            id: "mlx-community/Qwen3-0.6B-4bit",
            name: "Qwen3 0.6B",
            family: "Qwen3",
            size: "Very small",
            fit: "Fastest default",
            notes: "Good first-load choice for quick local checks and compact devices.",
            recommendedMaxTokens: 512,
            recommendedTemperature: 0.2
        ),
        MLXModelPreset(
            id: "mlx-community/Qwen3-1.7B-4bit",
            name: "Qwen3 1.7B",
            family: "Qwen3",
            size: "Small",
            fit: "Better chat quality",
            notes: "Still practical on device while improving instruction following over 0.6B.",
            recommendedMaxTokens: 768,
            recommendedTemperature: 0.2
        ),
        MLXModelPreset(
            id: "mlx-community/Qwen3-4B-4bit",
            name: "Qwen3 4B",
            family: "Qwen3",
            size: "Medium",
            fit: "Balanced reasoning",
            notes: "Higher quality local model; needs more storage, memory, and patience.",
            recommendedMaxTokens: 1024,
            recommendedTemperature: 0.2
        ),
        MLXModelPreset(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            name: "Llama 3.2 1B",
            family: "Llama",
            size: "Small",
            fit: "General assistant",
            notes: "Useful alternate lightweight instruct model.",
            recommendedMaxTokens: 768,
            recommendedTemperature: 0.3
        ),
        MLXModelPreset(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            name: "Llama 3.2 3B",
            family: "Llama",
            size: "Medium",
            fit: "General quality",
            notes: "Better general responses than 1B with a larger local footprint.",
            recommendedMaxTokens: 1024,
            recommendedTemperature: 0.3
        ),
        MLXModelPreset(
            id: "mlx-community/gemma-3-1b-it-qat-4bit",
            name: "Gemma 3 1B",
            family: "Gemma",
            size: "Small",
            fit: "Instruction tuned",
            notes: "Compact instruction model with Gemma chat formatting.",
            recommendedMaxTokens: 768,
            recommendedTemperature: 0.3
        ),
        MLXModelPreset(
            id: "mlx-community/gemma-3n-E2B-it-lm-4bit",
            name: "Gemma 3n E2B",
            family: "Gemma",
            size: "Small/medium",
            fit: "Mobile tuned",
            notes: "Good candidate for on-device assistant quality when storage allows.",
            recommendedMaxTokens: 1024,
            recommendedTemperature: 0.3
        ),
        MLXModelPreset(
            id: "mlx-community/granite-3.3-2b-instruct-4bit",
            name: "Granite 3.3 2B",
            family: "Granite",
            size: "Small/medium",
            fit: "Enterprise style",
            notes: "Alternative instruct model for concise task-oriented responses.",
            recommendedMaxTokens: 1024,
            recommendedTemperature: 0.2
        ),
        MLXModelPreset(
            id: "mlx-community/SmolLM3-3B-4bit",
            name: "SmolLM3 3B",
            family: "SmolLM",
            size: "Medium",
            fit: "Compact quality",
            notes: "Larger local option for stronger answers on capable devices.",
            recommendedMaxTokens: 1024,
            recommendedTemperature: 0.25
        ),
        MLXModelPreset(
            id: "mlx-community/bitnet-b1.58-2B-4T-4bit",
            name: "BitNet b1.58 2B",
            family: "BitNet",
            size: "Small/medium",
            fit: "Experimental",
            notes: "Try only when you want to compare experimental local behavior.",
            recommendedMaxTokens: 768,
            recommendedTemperature: 0.2
        )
    ]

    static let `default` = all[0]

    static func preset(for modelID: String) -> MLXModelPreset? {
        all.first { $0.id == modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
