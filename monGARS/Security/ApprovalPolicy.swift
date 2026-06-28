import CryptoKit
import Foundation

struct ApprovalTuple: Sendable, Codable, Equatable {
    var toolName: String
    var target: String?
    var normalizedArgumentsJSON: String
    var payloadHash: String
    var riskLevel: ToolRiskLevel
    var expiresAt: Date
    var sessionID: UUID
    var userVisibleDiff: String

    init(
        toolName: String,
        target: String?,
        normalizedArgumentsJSON: String,
        riskLevel: ToolRiskLevel,
        expiresAt: Date = Date().addingTimeInterval(5 * 60),
        sessionID: UUID,
        userVisibleDiff: String
    ) {
        let canonicalArguments = ApprovalTupleHasher.normalizedJSON(normalizedArgumentsJSON)
        self.toolName = toolName
        self.target = target
        self.normalizedArgumentsJSON = canonicalArguments
        self.riskLevel = riskLevel
        self.expiresAt = expiresAt
        self.sessionID = sessionID
        self.userVisibleDiff = userVisibleDiff
        self.payloadHash = ApprovalTupleHasher.payloadHash(
            toolName: toolName,
            target: target,
            normalizedArgumentsJSON: canonicalArguments,
            riskLevel: riskLevel.rawValue,
            sessionID: sessionID
        )
    }

    func isExpired(at date: Date = .now) -> Bool {
        date > expiresAt
    }

    func matches(toolName: String, target: String?, normalizedArgumentsJSON: String, riskLevel: ToolRiskLevel, sessionID: UUID) -> Bool {
        guard self.toolName == toolName,
              self.target == target,
              self.riskLevel == riskLevel,
              self.sessionID == sessionID else {
            return false
        }
        let canonicalArguments = ApprovalTupleHasher.normalizedJSON(normalizedArgumentsJSON)
        return payloadHash == ApprovalTupleHasher.payloadHash(
            toolName: toolName,
            target: target,
            normalizedArgumentsJSON: canonicalArguments,
            riskLevel: riskLevel.rawValue,
            sessionID: sessionID
        )
    }
}

enum ApprovalTupleHasher {
    static func payloadHash(toolName: String, target: String?, normalizedArgumentsJSON: String, riskLevel: String, sessionID: UUID) -> String {
        let canonical = [
            "risk_level=\(riskLevel)",
            "session_id=\(sessionID.uuidString)",
            "target=\(target ?? "")",
            "tool_name=\(toolName)",
            "normalized_arguments=\(normalizedJSON(normalizedArgumentsJSON))"
        ].joined(separator: "\n")
        return hashCanonical(canonical)
    }

    static func hashCanonical(_ canonical: String) -> String {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedJSON(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: canonicalObject(object), options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8) else {
            return trimmed
        }
        return canonical
    }

    static func normalizedArguments(toolName: String, input: String, target: String?) -> String {
        canonicalJSONString([
            "input": input,
            "target": target ?? "",
            "tool_name": toolName
        ])
    }

    static func canonicalJSONString(_ dictionary: [String: String]) -> String {
        let canonical = dictionary.keys.sorted().map { key in
            "\"\(escape(key))\":\"\(escape(dictionary[key] ?? ""))\""
        }.joined(separator: ",")
        return "{\(canonical)}"
    }

    private static func canonicalObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.keys.sorted().reduce(into: [String: Any]()) { result, key in
                result[key] = canonicalObject(dictionary[key] as Any)
            }
        }
        if let array = object as? [Any] {
            return array.map { canonicalObject($0) }
        }
        return object
    }

    private static func escape(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
