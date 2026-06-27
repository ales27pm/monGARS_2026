import Foundation
import SwiftData

struct MemoryService: Sendable {
    func save(content: String, context: ModelContext) throws {
        try save(content: content, source: "user", scope: "longTerm", context: context)
    }

    func save(content: String, source: String, scope: String, context: ModelContext) throws {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let tags = content.lowercased().split(separator: " ").filter { $0.count > 4 }.prefix(4).map(String.init)
        if let existing = try exactMatch(content: normalized, context: context) {
            existing.importance = min(1.0, existing.importance + 0.1)
            existing.updatedAt = .now
            try context.safeSave()
            return
        }
        context.insert(MemoryRecord(content: normalized, tags: Array(tags), importance: importanceScore(for: normalized), source: source, scope: scope))
        try context.safeSave()
    }

    func search(query: String, context: ModelContext) throws -> [MemoryRecord] {
        let records = try context.fetch(FetchDescriptor<MemoryRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        let terms = query.searchTerms
        guard !terms.isEmpty else { return records }
        return records.filter { record in
            let haystack = (record.content + " " + record.tags.joined(separator: " ")).lowercased()
            return terms.contains { haystack.contains($0) }
        }.sorted { lhs, rhs in
            if lhs.importance == rhs.importance {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.importance > rhs.importance
        }
    }

    func edit(_ record: MemoryRecord, content: String, context: ModelContext) throws {
        record.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        record.tags = Array(record.content.searchTerms.prefix(4))
        record.importance = importanceScore(for: record.content)
        record.updatedAt = .now
        try context.safeSave()
    }

    func delete(_ record: MemoryRecord, context: ModelContext) throws {
        context.delete(record)
        try context.safeSave()
    }

    func forgetAll(context: ModelContext) throws -> Int {
        let records = try context.fetch(FetchDescriptor<MemoryRecord>())
        for record in records {
            context.delete(record)
        }
        try context.safeSave()
        return records.count
    }

    func exportText(context: ModelContext) throws -> String {
        let records = try context.fetch(FetchDescriptor<MemoryRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        return records.map { record in
            "- [\(record.scope), \(String(format: "%.2f", record.importance))] \(record.content)"
        }.joined(separator: "\n")
    }

    private func exactMatch(content: String, context: ModelContext) throws -> MemoryRecord? {
        let records = try context.fetch(FetchDescriptor<MemoryRecord>())
        return records.first { $0.content.caseInsensitiveCompare(content) == .orderedSame }
    }

    private func importanceScore(for content: String) -> Double {
        let lower = content.lowercased()
        var score = min(0.95, 0.35 + Double(content.count) / 500.0)
        if lower.contains("important") || lower.contains("remember") || lower.contains("prefer") {
            score += 0.2
        }
        return min(1.0, score)
    }
}

extension String {
    var searchTerms: [String] {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
}
