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

struct NaturalLanguageContextualEmbeddingProvider: EmbeddingProvider {
    var providerName: String { "NaturalLanguage contextual embeddings" }

    var status: EmbeddingProviderStatus {
        #if canImport(NaturalLanguage)
        guard let embedding = NLContextualEmbedding(language: .english) else {
            return .unavailable("NaturalLanguage contextual embedding model is unavailable for English.")
        }
        if embedding.hasAvailableAssets {
            return .available
        }
        return .unavailable("NaturalLanguage contextual embedding assets are not available on this device.")
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
        guard let embedding = NLContextualEmbedding(language: .english) else {
            throw PersistenceError.importFailed("NaturalLanguage contextual embedding model is unavailable for English.")
        }
        guard embedding.hasAvailableAssets else {
            throw PersistenceError.importFailed("NaturalLanguage contextual embedding assets are not available on this device.")
        }
        do {
            try embedding.load()
            defer { embedding.unload() }
            let result = try embedding.embeddingResult(for: normalized, language: .english)
            var vectorSum: [Double] = []
            var vectorCount = 0
            let fullRange = normalized.startIndex..<normalized.endIndex
            result.enumerateTokenVectors(in: fullRange) { tokenVector, _ in
                if vectorSum.isEmpty {
                    vectorSum = Array(repeating: 0, count: tokenVector.count)
                }
                guard vectorSum.count == tokenVector.count else {
                    return true
                }
                for index in tokenVector.indices {
                    vectorSum[index] += tokenVector[index]
                }
                vectorCount += 1
                return true
            }
            guard vectorCount > 0, !vectorSum.isEmpty else {
                throw PersistenceError.importFailed("NaturalLanguage contextual embedding returned no token vectors.")
            }
            let averaged = vectorSum.map { Float($0 / Double(vectorCount)) }
            guard !averaged.isEmpty else {
                throw PersistenceError.importFailed("NaturalLanguage contextual embedding returned an empty vector.")
            }
            return averaged
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.importFailed("NaturalLanguage contextual embedding failed: \(error.localizedDescription)")
        }
        #else
        throw PersistenceError.importFailed("NaturalLanguage is unavailable on this platform.")
        #endif
    }
}

struct DefaultEmbeddingProvider: EmbeddingProvider {
    var naturalLanguageProvider: any EmbeddingProvider = NaturalLanguageContextualEmbeddingProvider()

    var providerName: String {
        if case .available = naturalLanguageProvider.status {
            return naturalLanguageProvider.providerName
        }
        return "Unavailable"
    }

    var status: EmbeddingProviderStatus {
        if case .available = naturalLanguageProvider.status {
            return .available
        }
        let naturalReason: String
        if case .unavailable(let reason) = naturalLanguageProvider.status {
            naturalReason = reason
        } else {
            naturalReason = "NaturalLanguage provider unavailable."
        }
        return .unavailable(naturalReason)
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
        if case .available = naturalLanguageProvider.status {
            return try naturalLanguageProvider.embedding(for: text)
        }
        throw PersistenceError.importFailed(diagnosticDescription)
    }
}
