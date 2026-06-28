import Foundation
import SwiftData
import UniformTypeIdentifiers

#if canImport(CoreML)
import CoreML
#endif

struct DocumentRetrievalResult: Sendable, Equatable {
    var documentID: UUID
    var title: String
    var chunkText: String
    var highlightedText: String
    var score: Double
    var matchedTerms: [String]
    var source: String
}

enum EmbeddingProviderStatus: Sendable, Equatable {
    case available
    case unavailable(String)
}

protocol EmbeddingProvider: Sendable {
    var status: EmbeddingProviderStatus { get }
    var providerName: String { get }
    func embedding(for text: String) throws -> [Float]
}

extension EmbeddingProvider {
    var providerName: String { String(describing: Self.self) }
}

struct CoreMLEmbeddingProvider: EmbeddingProvider {
    var providerName: String { "CoreML DocumentEmbedding" }

    var status: EmbeddingProviderStatus {
        #if canImport(CoreML)
        guard Self.modelURL() != nil else {
            return .unavailable("DocumentEmbedding Core ML model is not bundled.")
        }
        return .available
        #else
        return .unavailable("CoreML is unavailable on this platform.")
        #endif
    }

    func embedding(for text: String) throws -> [Float] {
        #if canImport(CoreML)
        guard Self.modelURL() != nil else {
            throw PersistenceError.importFailed("DocumentEmbedding Core ML model is not bundled.")
        }
        throw PersistenceError.importFailed("DocumentEmbedding model I/O is not wired yet.")
        #else
        throw PersistenceError.importFailed("CoreML is unavailable on this platform.")
        #endif
    }

    private static func modelURL() -> URL? {
        Bundle.main.url(forResource: "DocumentEmbedding", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "DocumentEmbedding", withExtension: "mlpackage")
    }
}

struct DocumentService: Sendable {
    private static let semanticInclusionThreshold = 0.20
    private static let semanticScoreWeight = 10.0

    var embeddingProvider: any EmbeddingProvider = DefaultEmbeddingProvider()

    var embeddingStatusDescription: String {
        if let provider = embeddingProvider as? DefaultEmbeddingProvider {
            return provider.diagnosticDescription
        }
        switch embeddingProvider.status {
        case .available:
            return "available via \(embeddingProvider.providerName)"
        case .unavailable(let reason):
            return "unavailable: \(reason)"
        }
    }

    func importDocument(url: URL, context: ModelContext) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        guard scoped || FileManager.default.isReadableFile(atPath: url.path) else {
            throw PersistenceError.importFailed("The selected file could not be opened.")
        }
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let content: String
        if Self.isPDF(url: url) {
            content = try PDFTextExtractor.extract(data: data).text
        } else if let text = String(data: data, encoding: .utf8) {
            content = text
        } else {
            throw PersistenceError.importFailed("Only UTF-8 text, Markdown, and selectable-text PDF files are supported.")
        }
        let record = DocumentRecord(title: url.lastPathComponent, content: content)
        context.insert(record)
        try rebuildChunks(for: record, context: context)
        try context.safeSave()
    }

    private static func isPDF(url: URL) -> Bool {
        if url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame {
            return true
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }

    func documents(context: ModelContext) throws -> [DocumentRecord] {
        try context.fetch(FetchDescriptor<DocumentRecord>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
    }

    func rankedSnippets(matching query: String, context: ModelContext, limit: Int = 6) throws -> [DocumentRetrievalResult] {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return [] }
        try ensureChunksExist(context: context)
        let chunks = try context.fetch(FetchDescriptor<DocumentChunkRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        let queryEmbedding = embeddingIfAvailable(for: query)
        return chunks.compactMap { chunk in
            let lexicalScore = lexicalScore(for: chunk, terms: terms, query: query)
            let semanticScore = semanticScore(for: chunk, queryEmbedding: queryEmbedding)
            let semanticContributed = semanticScore >= Self.semanticInclusionThreshold
            guard lexicalScore > 0 || semanticContributed else { return nil }
            let matched = terms.filter { term in
                chunk.title.localizedCaseInsensitiveContains(term) || chunk.text.localizedCaseInsensitiveContains(term)
            }
            let score = lexicalScore + semanticScore * Self.semanticScoreWeight
            return DocumentRetrievalResult(
                documentID: chunk.documentID,
                title: chunk.title,
                chunkText: chunk.text,
                highlightedText: highlighted(chunk.text, terms: matched),
                score: score,
                matchedTerms: matched,
                source: resultSource(lexicalScore: lexicalScore, semanticContributed: semanticContributed)
            )
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                if lhs.title == rhs.title {
                    return chunkIndex(for: lhs, in: chunks) < chunkIndex(for: rhs, in: chunks)
                }
                return lhs.title < rhs.title
            }
            return lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    func snippets(matching query: String, context: ModelContext) throws -> [String] {
        try rankedSnippets(matching: query, context: context).map { result in
            "\(result.title): \(result.highlightedText)"
        }
    }

    func rebuildChunks(for document: DocumentRecord, context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<DocumentChunkRecord>()).filter { $0.documentID == document.id }
        for chunk in existing {
            context.delete(chunk)
        }

        let chunks = chunkedText(document.content)
        let canEmbed: Bool
        if case .available = embeddingProvider.status {
            canEmbed = true
        } else {
            canEmbed = false
        }
        for (index, text) in chunks.enumerated() {
            let embeddingData: Data?
            if canEmbed, let embedding = try? embeddingProvider.embedding(for: text) {
                embeddingData = DocumentEmbeddingVector.encode(embedding)
            } else {
                embeddingData = nil
            }
            context.insert(DocumentChunkRecord(
                documentID: document.id,
                title: document.title,
                text: text,
                chunkIndex: index,
                tokenEstimate: max(1, text.count / 4),
                lexicalTerms: Array(normalizedTerms(text).prefix(80)),
                embeddingData: embeddingData
            ))
        }
    }

    func delete(_ record: DocumentRecord, context: ModelContext) throws {
        let chunks = try context.fetch(FetchDescriptor<DocumentChunkRecord>()).filter { $0.documentID == record.id }
        for chunk in chunks {
            context.delete(chunk)
        }
        context.delete(record)
        try context.safeSave()
    }

    private func ensureChunksExist(context: ModelContext) throws {
        let documents = try documents(context: context)
        let chunks = try context.fetch(FetchDescriptor<DocumentChunkRecord>())
        let chunkedDocumentIDs = Set(chunks.map(\.documentID))
        var changed = false
        for document in documents where !chunkedDocumentIDs.contains(document.id) {
            try rebuildChunks(for: document, context: context)
            changed = true
        }
        if changed {
            try context.safeSave()
        }
    }

    private func lexicalScore(for chunk: DocumentChunkRecord, terms: [String], query: String) -> Double {
        let text = chunk.text.lowercased()
        let title = chunk.title.lowercased()
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var score = phrase.count > 2 && text.contains(phrase) ? 8.0 : 0.0

        for term in terms {
            let textMatches = text.components(separatedBy: term).count - 1
            let titleMatches = title.contains(term) ? 1 : 0
            let lexicalMatches = chunk.lexicalTerms.filter { $0 == term }.count
            score += Double(textMatches * 2 + titleMatches * 4 + lexicalMatches)
        }

        guard score > 0 else { return 0 }
        let recencyHours = abs(chunk.updatedAt.timeIntervalSinceNow) / 3_600
        return score + max(0, 0.25 - min(0.25, recencyHours / 10_000))
    }

    private func embeddingIfAvailable(for text: String) -> [Float]? {
        guard case .available = embeddingProvider.status else { return nil }
        return try? embeddingProvider.embedding(for: text)
    }

    private func semanticScore(for chunk: DocumentChunkRecord, queryEmbedding: [Float]?) -> Double {
        guard let queryEmbedding,
              let embeddingData = chunk.embeddingData,
              let chunkEmbedding = DocumentEmbeddingVector.decode(embeddingData),
              let similarity = DocumentEmbeddingVector.cosineSimilarity(queryEmbedding, chunkEmbedding) else {
            return 0
        }
        return max(0, similarity)
    }

    private func resultSource(lexicalScore: Double, semanticContributed: Bool) -> String {
        if lexicalScore > 0, semanticContributed {
            return "hybrid"
        }
        if semanticContributed {
            return "embedding"
        }
        return "lexical"
    }

    private func chunkIndex(for result: DocumentRetrievalResult, in chunks: [DocumentChunkRecord]) -> Int {
        chunks.first { chunk in
            chunk.documentID == result.documentID && chunk.text == result.chunkText
        }?.chunkIndex ?? Int.max
    }

    private func chunkedText(_ content: String, wordsPerChunk: Int = 160, overlap: Int = 32) -> [String] {
        let words = content.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        guard words.count > wordsPerChunk else { return [content.trimmingCharacters(in: .whitespacesAndNewlines)] }

        var chunks: [String] = []
        var start = 0
        while start < words.count {
            let end = min(words.count, start + wordsPerChunk)
            chunks.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start = max(end - overlap, start + 1)
        }
        return chunks
    }

    private func normalizedTerms(_ text: String) -> [String] {
        Array(NSOrderedSet(array: text.searchTerms).compactMap { $0 as? String })
    }

    private func highlighted(_ text: String, terms: [String]) -> String {
        var highlightedText = text
        for term in terms.sorted(by: { $0.count > $1.count }) {
            highlightedText = highlight(term: term, in: highlightedText)
        }
        return highlightedText
    }

    private func highlight(term: String, in text: String) -> String {
        guard !term.isEmpty else { return text }
        var result = ""
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: term, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            result += text[searchStart..<range.lowerBound]
            result += "**\(text[range])**"
            searchStart = range.upperBound
        }
        result += text[searchStart..<text.endIndex]
        return result
    }
}
