import Foundation

enum DiagnosticsRedactor {
    static func redact(_ text: String, maxLength: Int = 500) -> String {
        var redacted = text
        redacted = redactURLQueryItem("body", in: redacted)
        redacted = redacted.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Z0-9._\-]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(authorization|x-api-key|api-key|apikey|token|secret|password)\s*[:=]\s*([^\s,;&]+)"#,
            with: "$1: [REDACTED]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token)=([^&\s]+)"#,
            with: "$1=[REDACTED]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            with: "[EMAIL REDACTED]",
            options: [.regularExpression, .caseInsensitive]
        )
        redacted = redactPhoneNumbers(in: redacted)

        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return "\(trimmed.prefix(maxLength))... [TRUNCATED]"
    }

    static func redactOptional(_ text: String?, maxLength: Int = 500) -> String? {
        guard let text else { return nil }
        return redact(text, maxLength: maxLength)
    }

    private static func redactURLQueryItem(_ name: String, in text: String) -> String {
        text.replacingOccurrences(
            of: "(?i)([?&]\(NSRegularExpression.escapedPattern(for: name))=)([^&\\s]+)",
            with: "$1[REDACTED]",
            options: .regularExpression
        )
    }

    private static func redactPhoneNumbers(in text: String) -> String {
        let schemeRedacted = text.replacingOccurrences(
            of: #"(?i)\b(sms|tel|telprompt):/{0,2}\+?\d{7,15}\b"#,
            with: "$1:[PHONE REDACTED]",
            options: .regularExpression
        )
        let plusPrefixed = schemeRedacted.replacingOccurrences(
            of: #"(?<![\w-])\+\d{7,15}(?![\w-])"#,
            with: "[PHONE REDACTED]",
            options: .regularExpression
        )
        return plusPrefixed.replacingOccurrences(
            of: #"(?<![\w.-])\+?\d(?=[\d \t\-\(\)]*[- \t\(\)])[\d \t\-\(\)]{6,}\d(?![\w.-])"#,
            with: "[PHONE REDACTED]",
            options: .regularExpression
        )
    }
}
