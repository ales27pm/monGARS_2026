import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

enum DocumentEmbeddingVector {
    static func encode(_ vector: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(vector.count * MemoryLayout<Float>.size)
        for value in vector {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            return nil
        }

        var result: [Float] = []
        result.reserveCapacity(data.count / MemoryLayout<Float>.size)
        var offset = 0
        while offset < data.count {
            var rawValue: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &rawValue) { destination in
                data.copyBytes(to: destination, from: offset..<(offset + MemoryLayout<UInt32>.size))
            }
            result.append(Float(bitPattern: UInt32(littleEndian: rawValue)))
            offset += MemoryLayout<UInt32>.size
        }
        return result
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }

        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }

        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        let similarity = dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
        guard similarity.isFinite, !similarity.isNaN else { return nil }
        return min(1.0, max(-1.0, similarity))
    }
}

struct NaturalLanguageEmbeddingProvider: EmbeddingProvider {
    var providerName: String { "NaturalLanguage" }

    var status: EmbeddingProviderStatus {
        #if canImport(NaturalLanguage)
        if NLEmbedding.sentenceEmbedding(for: .english) != nil {
            return .available
        }
        return .unavailable("NaturalLanguage sentence embeddings are unavailable.")
        #else
        return .unavailable("NaturalLanguage is unavailable on this platform.")
        #endif
    }

    func embedding(for text: String) throws -> [Float] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw PersistenceError.importFailed("Cannot embed empty document text.")
        }

        #if canImport(NaturalLanguage)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw PersistenceError.importFailed("NaturalLanguage sentence embeddings are unavailable.")
        }
        guard let rawVector = embedding.vector(for: normalized) else {
            throw PersistenceError.importFailed("NaturalLanguage returned no embedding.")
        }
        let vector = rawVector.map(Float.init)
        guard !vector.isEmpty else {
            throw PersistenceError.importFailed("NaturalLanguage returned an empty embedding.")
        }
        return vector
        #else
        throw PersistenceError.importFailed("NaturalLanguage is unavailable on this platform.")
        #endif
    }
}

struct DefaultEmbeddingProvider: EmbeddingProvider {
    var coreMLProvider: any EmbeddingProvider = CoreMLEmbeddingProvider()
    var naturalLanguageProvider: any EmbeddingProvider = NaturalLanguageEmbeddingProvider()

    var providerName: String {
        if case .available = coreMLProvider.status {
            return coreMLProvider.providerName
        }
        if case .available = naturalLanguageProvider.status {
            return naturalLanguageProvider.providerName
        }
        return "Unavailable"
    }

    var status: EmbeddingProviderStatus {
        if case .available = coreMLProvider.status {
            return .available
        }
        if case .available = naturalLanguageProvider.status {
            return .available
        }
        let coreMLReason: String
        if case .unavailable(let reason) = coreMLProvider.status {
            coreMLReason = reason
        } else {
            coreMLReason = "CoreML provider unavailable."
        }
        let naturalReason: String
        if case .unavailable(let reason) = naturalLanguageProvider.status {
            naturalReason = reason
        } else {
            naturalReason = "NaturalLanguage provider unavailable."
        }
        return .unavailable("\(coreMLReason) \(naturalReason)")
    }

    var diagnosticDescription: String {
        switch status {
        case .available:
            return "available via \(providerName)"
        case .unavailable(let reason):
            return "unavailable: \(reason)"
        }
    }

    func embedding(for text: String) throws -> [Float] {
        if case .available = coreMLProvider.status {
            do {
                return try coreMLProvider.embedding(for: text)
            } catch {
                if case .unavailable = naturalLanguageProvider.status {
                    throw error
                }
            }
        }
        if case .available = naturalLanguageProvider.status {
            return try naturalLanguageProvider.embedding(for: text)
        }
        throw PersistenceError.importFailed(diagnosticDescription)
    }
}
