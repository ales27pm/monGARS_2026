import Foundation

struct NetworkPolicy: Sendable {
    var allowsLocalNetworkHosts: Bool = false

    func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw NetworkClientError.invalidScheme
        }
        guard !allowsLocalNetworkHosts, let host = url.host?.lowercased() else {
            return
        }
        if Self.isBlockedHost(host) {
            throw NetworkClientError.blockedHost(host)
        }
    }

    static func isBlockedHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "localhost." || normalized == "0.0.0.0" {
            return true
        }
        if normalized.hasSuffix(".local") || normalized.hasSuffix(".localdomain") {
            return true
        }
        if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
            return true
        }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true
        }

        let parts = normalized.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        switch parts[0] {
        case 10, 127:
            return true
        case 169:
            return parts[1] == 254
        case 172:
            return (16...31).contains(parts[1])
        case 192:
            return parts[1] == 168
        default:
            return false
        }
    }
}
