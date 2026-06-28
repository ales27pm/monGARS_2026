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
        static let autonomyLevel = "autonomyLevel"
    }
}

enum ProviderMode: String, CaseIterable, Identifiable, Codable {
    case foundation
    case mock
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .foundation:
            "Foundation Models"
        case .mock:
            "Mock Local"
        case .remote:
            "Remote Endpoint"
        }
    }
}
