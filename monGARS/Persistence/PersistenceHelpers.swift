import Foundation
import SwiftData

enum PersistenceError: LocalizedError {
    case saveFailed(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let message):
            "Could not save local data: \(message)"
        case .importFailed(let message):
            "Could not import document: \(message)"
        }
    }
}

extension ModelContext {
    func safeSave() throws {
        do {
            try save()
        } catch {
            throw PersistenceError.saveFailed(error.localizedDescription)
        }
    }
}

