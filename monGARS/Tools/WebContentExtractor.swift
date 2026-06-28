import Foundation

struct ExtractedWebContent: Sendable, Equatable {
    var title: String?
    var metaDescription: String?
    var canonicalURL: String?
    var readableText: String

    func preview(limit: Int) -> String {
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        if let metaDescription, !metaDescription.isEmpty {
            lines.append("Description: \(metaDescription)")
        }
        if let canonicalURL, !canonicalURL.isEmpty {
            lines.append("Canonical: \(canonicalURL)")
        }
        let body = String(readableText.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }
}

enum WebContentExtractor {
    static func extractHTML(_ html: String) -> ExtractedWebContent {
        let body = html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<noscript[\s\S]*?</noscript>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<(header|footer|nav|aside)[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(p|div|section|article|li|h[1-6])>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)

        return ExtractedWebContent(
            title: firstCapture(in: html, pattern: #"<title[^>]*>([\s\S]*?)</title>"#).map(cleanEntities),
            metaDescription: metaContent(named: "description", in: html).map(cleanEntities),
            canonicalURL: canonicalURL(in: html).map(cleanEntities),
            readableText: normalizeWhitespace(cleanEntities(body))
        )
    }

    static func extractPlainText(_ text: String, limit: Int) -> String {
        String(normalizeWhitespace(text).prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func metaContent(named name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            #"<meta[^>]+name\s*=\s*['"]\#(escaped)['"][^>]+content\s*=\s*['"]([^'"]*)['"][^>]*>"#,
            #"<meta[^>]+content\s*=\s*['"]([^'"]*)['"][^>]+name\s*=\s*['"]\#(escaped)['"][^>]*>"#
        ]
        for pattern in patterns {
            if let value = firstCapture(in: html, pattern: pattern) {
                return value
            }
        }
        return nil
    }

    private static func canonicalURL(in html: String) -> String? {
        let patterns = [
            #"<link[^>]+rel\s*=\s*['"]canonical['"][^>]+href\s*=\s*['"]([^'"]*)['"][^>]*>"#,
            #"<link[^>]+href\s*=\s*['"]([^'"]*)['"][^>]+rel\s*=\s*['"]canonical['"][^>]*>"#
        ]
        for pattern in patterns {
            if let value = firstCapture(in: html, pattern: pattern) {
                return value
            }
        }
        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanEntities(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func normalizeWhitespace(_ input: String) -> String {
        input
            .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
