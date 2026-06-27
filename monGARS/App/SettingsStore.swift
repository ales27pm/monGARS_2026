import Foundation

@Observable
final class SettingsStore {
    var providerMode: ProviderMode {
        didSet { UserDefaults.standard.set(providerMode.rawValue, forKey: Keys.providerMode) }
    }

    var remoteEndpoint: String {
        didSet { UserDefaults.standard.set(remoteEndpoint, forKey: Keys.remoteEndpoint) }
    }

    var remoteProviderEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteProviderEnabled, forKey: Keys.remoteProviderEnabled) }
    }

    var autonomyLevel: AutonomyLevel {
        didSet { UserDefaults.standard.set(autonomyLevel.rawValue, forKey: Keys.autonomyLevel) }
    }

    init() {
        let rawMode = UserDefaults.standard.string(forKey: Keys.providerMode) ?? ProviderMode.foundation.rawValue
        providerMode = ProviderMode(rawValue: rawMode) ?? .foundation
        remoteEndpoint = UserDefaults.standard.string(forKey: Keys.remoteEndpoint) ?? "http://localhost:11434/api/generate"
        remoteProviderEnabled = UserDefaults.standard.bool(forKey: Keys.remoteProviderEnabled)
        let rawAutonomy = UserDefaults.standard.string(forKey: Keys.autonomyLevel) ?? AutonomyLevel.assisted.rawValue
        autonomyLevel = AutonomyLevel(rawValue: rawAutonomy) ?? .assisted
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
