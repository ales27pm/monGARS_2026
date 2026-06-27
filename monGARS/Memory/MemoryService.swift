import Foundation
import SwiftData

struct MemoryService: Sendable {
    func save(content: String, context: ModelContext) throws {
        let tags = content.lowercased().split(separator: " ").filter { $0.count > 4 }.prefix(4).map(String.init)
        context.insert(MemoryRecord(content: content, tags: Array(tags)))
        try context.safeSave()
    }

    func search(query: String, context: ModelContext) throws -> [MemoryRecord] {
        let records = try context.fetch(FetchDescriptor<MemoryRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        let terms = query.searchTerms
        guard !terms.isEmpty else { return records }
        return records.filter { record in
            let haystack = (record.content + " " + record.tags.joined(separator: " ")).lowercased()
            return terms.contains { haystack.contains($0) }
        }
    }

    func delete(_ record: MemoryRecord, context: ModelContext) throws {
        context.delete(record)
        try context.safeSave()
    }
}

extension String {
    var searchTerms: [String] {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
}

