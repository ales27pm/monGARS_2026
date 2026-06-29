import CryptoKit
import Foundation

enum ApprovalPolicy {
    static let defaultRiskLevel: ToolRiskLevel = .high
    static let defaultExpirationInterval: TimeInterval = 5 * 60

    static func expirationDate(from createdAt: Date = .now) -> Date {
        createdAt.addingTimeInterval(defaultExpirationInterval)
    }

    static func normalizedRisk(_ rawValue: String) -> ToolRiskLevel {
        ToolRiskLevel(rawValue: rawValue) ?? defaultRiskLevel
    }
}

struct ApprovalTuple: Sendable, Codable, Equatable {
    let toolName: String
    let target: String?
    let normalizedArgumentsJSON: String
    let payloadHash: String
    let riskLevel: ToolRiskLevel
    let expiresAt: Date
    let sessionID: UUID
    let userVisibleDiff: String

    init(
        toolName: String,
        target: String?,
        normalizedArgumentsJSON: String,
        riskLevel: ToolRiskLevel,
        expiresAt: Date = ApprovalPolicy.expirationDate(),
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
        let payload: [String: Any] = [
            "normalized_arguments": normalizedJSONObject(from: normalizedArgumentsJSON),
            "risk_level": ApprovalPolicy.normalizedRisk(riskLevel).rawValue,
            "session_id": sessionID.uuidString,
            "target": target.map { $0 as Any } ?? NSNull(),
            "tool_name": toolName
        ]
        return hashCanonical(canonicalJSONString(payload))
    }

    static func hashCanonical(_ canonical: String) -> String {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedJSON(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        return canonicalJSONString(normalizedJSONObject(from: trimmed), fallback: trimmed)
    }

    static func normalizedArguments(toolName: String, input: String, target: String?) -> String {
        canonicalJSONString([
            "input": input,
            "target": target.map { $0 as Any } ?? NSNull(),
            "tool_name": toolName
        ])
    }

    static func canonicalJSONString(_ dictionary: [String: Any]) -> String {
        canonicalJSONString(canonicalObject(dictionary), fallback: "{}")
    }

    private static func canonicalJSONString(_ object: Any, fallback: String) -> String {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let string = object as? String {
            return string
        }
        return fallback
    }

    private static func normalizedJSONObject(from text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            return trimmed
        }
        return canonicalObject(object)
    }

    private static func canonicalObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.keys.sorted().reduce(into: [String: Any]()) { result, key in
                if let value = dictionary[key] {
                    result[key] = canonicalObject(value)
                } else {
                    result[key] = NSNull()
                }
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
            case let value where value.value < 0x20:
                escaped += String(format: "\\u%04x", value.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
