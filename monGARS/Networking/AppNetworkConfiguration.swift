import Foundation

enum AppNetworkConfiguration {
    enum Keys {
        static let timeoutSeconds = "networkTimeoutSeconds"
        static let maxRetries = "networkMaxRetries"
        static let remoteModel = "remoteModel"
        static let remoteAPIKey = "remoteAPIKey"
        static let weatherEndpoint = "weatherEndpoint"
        static let weatherAPIKey = "weatherAPIKey"
        static let weatherUnits = "weatherUnits"
        static let remoteNetworkHeaders = "remoteNetworkHeaders"
    }

    static func client() -> NetworkClient {
        let defaults = UserDefaults.standard
        let timeout = defaults.double(forKey: Keys.timeoutSeconds)
        let retries = defaults.object(forKey: Keys.maxRetries) as? Int ?? 2
        return NetworkClient(configuration: NetworkClientConfiguration(
            timeoutSeconds: timeout > 0 ? timeout : 20,
            maxRetries: max(0, min(retries, 5)),
            retryBaseDelaySeconds: 0.35,
            maxResponseBytes: 1_000_000
        ))
    }

    static var remoteModel: String {
        let value = UserDefaults.standard.string(forKey: Keys.remoteModel) ?? "llama3.2"
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "llama3.2" : value
    }

    static var remoteAPIKey: String {
        KeychainStore.string(for: Keys.remoteAPIKey)
    }

    static var weatherEndpoint: String {
        let value = UserDefaults.standard.string(forKey: Keys.weatherEndpoint) ?? "https://api.openweathermap.org/data/2.5/weather"
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "https://api.openweathermap.org/data/2.5/weather" : value
    }

    static var weatherAPIKey: String {
        KeychainStore.string(for: Keys.weatherAPIKey)
    }

    static var weatherUnits: String {
        let value = UserDefaults.standard.string(forKey: Keys.weatherUnits) ?? "metric"
        return ["metric", "imperial", "standard"].contains(value) ? value : "metric"
    }

    static var remoteNetworkHeaders: [String: String] {
        guard let data = UserDefaults.standard.data(forKey: Keys.remoteNetworkHeaders),
              let headers = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return headers
    }
}
