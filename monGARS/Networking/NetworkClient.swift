import Foundation
import os

enum HTTPMethod: String, CaseIterable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    var requiresExplicitApproval: Bool {
        self != .get
    }
}

struct NetworkClientConfiguration: Sendable {
    var timeoutSeconds: TimeInterval = 20
    var maxRetries: Int = 2
    var retryBaseDelaySeconds: TimeInterval = 0.35
    var maxResponseBytes: Int = 1_000_000
    var allowsLocalNetworkHosts: Bool = false

    static let defaultProduction = NetworkClientConfiguration()
}

struct NetworkRequest: Sendable {
    var url: URL
    var method: HTTPMethod = .get
    var headers: [String: String] = [:]
    var body: Data?
    var acceptedContentTypes: Set<String> = []

    init(url: URL, method: HTTPMethod = .get, headers: [String: String] = [:], body: Data? = nil, acceptedContentTypes: Set<String> = []) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.acceptedContentTypes = acceptedContentTypes
    }
}

struct NetworkResponse: Sendable {
    var finalURL: URL
    var statusCode: Int
    var contentType: String?
    var data: Data
    var latencyMs: Double

    var text: String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func decodedJSON<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: data)
    }
}

struct NetworkStreamLine: Sendable {
    var line: String
    var statusCode: Int
    var finalURL: URL
    var contentType: String?
}

enum NetworkClientError: LocalizedError, Equatable {
    case invalidScheme
    case blockedHost(String)
    case missingHTTPResponse
    case unacceptableStatus(Int)
    case unacceptableContentType(String?)
    case responseTooLarge(Int)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidScheme:
            "Only HTTP and HTTPS URLs are supported."
        case .blockedHost(let host):
            "Network requests to \(host) are blocked by policy."
        case .missingHTTPResponse:
            "The network response was not an HTTP response."
        case .unacceptableStatus(let status):
            "The service returned HTTP \(status)."
        case .unacceptableContentType(let contentType):
            "The service returned unsupported content type \(contentType ?? "unknown")."
        case .responseTooLarge(let limit):
            "The service response exceeded the \(limit) byte limit."
        case .requestFailed(let message):
            message
        }
    }
}

struct NetworkClient: Sendable {
    private static let logger = Logger(subsystem: "app.27pm.monGARS", category: "NetworkClient")

    var configuration: NetworkClientConfiguration
    var session: URLSession

    init(configuration: NetworkClientConfiguration = .defaultProduction, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        try validatePolicy(for: request.url)

        var attempt = 0
        var lastError: Error?

        while attempt <= configuration.maxRetries {
            do {
                return try await sendOnce(request)
            } catch {
                lastError = error
                guard shouldRetry(error: error), attempt < configuration.maxRetries else { break }
                let delay = configuration.retryBaseDelaySeconds * pow(2, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }

        throw lastError ?? NetworkClientError.requestFailed("Network request failed.")
    }

    func streamLines(_ request: NetworkRequest) -> AsyncThrowingStream<NetworkStreamLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validatePolicy(for: request.url)
                    let urlRequest = buildURLRequest(from: request)
                    let started = ContinuousClock.now
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw NetworkClientError.missingHTTPResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw NetworkClientError.unacceptableStatus(http.statusCode)
                    }

                    let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                    if !request.acceptedContentTypes.isEmpty, !Self.contentType(contentType, matchesAny: request.acceptedContentTypes) {
                        throw NetworkClientError.unacceptableContentType(contentType)
                    }

                    let finalURL = http.url ?? request.url
                    var receivedBytes = 0
                    for try await line in bytes.lines {
                        receivedBytes += line.utf8.count
                        guard receivedBytes <= configuration.maxResponseBytes else {
                            throw NetworkClientError.responseTooLarge(configuration.maxResponseBytes)
                        }
                        continuation.yield(NetworkStreamLine(line: line, statusCode: http.statusCode, finalURL: finalURL, contentType: contentType))
                    }

                    let elapsed = started.duration(to: ContinuousClock.now)
                    let latencyMs = Self.latencyMilliseconds(elapsed)
                    let host = finalURL.host ?? request.url.host ?? "unknown"
                    Self.logger.info("network stream completed host=\(host, privacy: .public) method=\(request.method.rawValue, privacy: .public) status=\(http.statusCode, privacy: .public) latency_ms=\(latencyMs, privacy: .public)")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func validatePolicy(for url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw NetworkClientError.invalidScheme
        }
        if !configuration.allowsLocalNetworkHosts, let host = url.host?.lowercased(), isBlockedHost(host) {
            throw NetworkClientError.blockedHost(host)
        }
    }

    private func buildURLRequest(from request: NetworkRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: configuration.timeoutSeconds)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        request.headers.forEach { key, value in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        return urlRequest
    }

    private func sendOnce(_ request: NetworkRequest) async throws -> NetworkResponse {
        let urlRequest = buildURLRequest(from: request)

        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: urlRequest)
        let elapsed = started.duration(to: ContinuousClock.now)
        let latencyMs = Self.latencyMilliseconds(elapsed)

        guard let http = response as? HTTPURLResponse else {
            throw NetworkClientError.missingHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkClientError.unacceptableStatus(http.statusCode)
        }
        guard data.count <= configuration.maxResponseBytes else {
            throw NetworkClientError.responseTooLarge(configuration.maxResponseBytes)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        if !request.acceptedContentTypes.isEmpty, !Self.contentType(contentType, matchesAny: request.acceptedContentTypes) {
            throw NetworkClientError.unacceptableContentType(contentType)
        }

        let host = http.url?.host ?? request.url.host ?? "unknown"
        Self.logger.info("network request completed host=\(host, privacy: .public) method=\(request.method.rawValue, privacy: .public) status=\(http.statusCode, privacy: .public) latency_ms=\(latencyMs, privacy: .public)")

        return NetworkResponse(
            finalURL: http.url ?? request.url,
            statusCode: http.statusCode,
            contentType: contentType,
            data: data,
            latencyMs: latencyMs
        )
    }

    private func shouldRetry(error: Error) -> Bool {
        if Task.isCancelled { return false }
        if case NetworkClientError.unacceptableStatus(let status) = error {
            return status == 408 || status == 429 || (500..<600).contains(status)
        }
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .userCancelledAuthentication:
                return false
            default:
                return true
            }
        }
        return false
    }

    private func isBlockedHost(_ host: String) -> Bool {
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

    private static func latencyMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds * 1_000) + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func contentType(_ contentType: String?, matchesAny accepted: Set<String>) -> Bool {
        guard let contentType else { return false }
        return accepted.contains { acceptedType in
            contentType.contains(acceptedType.lowercased())
        }
    }
}
