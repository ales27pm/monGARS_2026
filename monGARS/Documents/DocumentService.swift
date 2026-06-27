import Foundation
import SwiftData
import UniformTypeIdentifiers

struct DocumentService: Sendable {
    func importDocument(url: URL, context: ModelContext) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw PersistenceError.importFailed("The selected file could not be opened.")
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw PersistenceError.importFailed("Only UTF-8 text and Markdown files are supported.")
        }
        context.insert(DocumentRecord(title: url.lastPathComponent, content: content))
        try context.safeSave()
    }

    func documents(context: ModelContext) throws -> [DocumentRecord] {
        try context.fetch(FetchDescriptor<DocumentRecord>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
    }

    func snippets(matching query: String, context: ModelContext) throws -> [String] {
        let terms = query.searchTerms
        guard !terms.isEmpty else { return [] }
        return try documents(context: context).compactMap { document in
            let lower = document.content.lowercased()
            guard let term = terms.first(where: { lower.contains($0) }),
                  let range = lower.range(of: term) else { return nil }
            let start = document.content.index(range.lowerBound, offsetBy: -120, limitedBy: document.content.startIndex) ?? document.content.startIndex
            let end = document.content.index(range.upperBound, offsetBy: 220, limitedBy: document.content.endIndex) ?? document.content.endIndex
            return "\(document.title): \(document.content[start..<end])"
        }
    }

    func delete(_ record: DocumentRecord, context: ModelContext) throws {
        context.delete(record)
        try context.safeSave()
    }
}

