import Foundation
import SwiftData

enum RepoSymbolKind: String, Codable, CaseIterable, Sendable {
    case module
    case actor
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case function
    case property
    case unknown
}

enum RepoPrivacyLevel: String, Codable, CaseIterable, Sendable {
    case publicAPI
    case `internal`
    case `private`
}

struct RepoSourceFile: Sendable, Equatable {
    var path: String
    var content: String
    var privacyLevel: RepoPrivacyLevel = .internal
}

struct RepoSymbolNode: Sendable, Equatable, Identifiable {
    var id: String
    var repositoryName: String
    var commitHash: String
    var path: String
    var moduleName: String
    var name: String
    var kind: RepoSymbolKind
    var parentName: String?
    var lineStart: Int
    var lineEnd: Int
    var privacyLevel: RepoPrivacyLevel
    var signature: String

    var provenance: String {
        "\(commitHash):\(path):L\(lineStart)-L\(lineEnd)"
    }
}

struct RepoSymbolGraphSnapshot: Sendable, Equatable {
    var repositoryName: String
    var commitHash: String
    var generatedAt: Date
    var symbols: [RepoSymbolNode]
}

@Model
final class RepoIndexRecord {
    var id: UUID
    var repositoryName: String
    var commitHash: String
    var rootPath: String
    var symbolCount: Int
    var privacyLevelRawValue: String
    var generatedAt: Date

    init(
        id: UUID = UUID(),
        repositoryName: String,
        commitHash: String,
        rootPath: String = "",
        symbolCount: Int = 0,
        privacyLevelRawValue: String = RepoPrivacyLevel.internal.rawValue,
        generatedAt: Date = .now
    ) {
        self.id = id
        self.repositoryName = repositoryName
        self.commitHash = commitHash
        self.rootPath = rootPath
        self.symbolCount = symbolCount
        self.privacyLevelRawValue = privacyLevelRawValue
        self.generatedAt = generatedAt
    }

    var privacyLevel: RepoPrivacyLevel {
        RepoPrivacyLevel(rawValue: privacyLevelRawValue) ?? .internal
    }
}

@Model
final class RepoSymbolRecord {
    var id: UUID
    var symbolID: String
    var repositoryName: String
    var commitHash: String
    var path: String
    var moduleName: String
    var name: String
    var kindRawValue: String
    var parentName: String?
    var lineStart: Int
    var lineEnd: Int
    var privacyLevelRawValue: String
    var signature: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        symbolID: String,
        repositoryName: String,
        commitHash: String,
        path: String,
        moduleName: String,
        name: String,
        kindRawValue: String,
        parentName: String? = nil,
        lineStart: Int,
        lineEnd: Int,
        privacyLevelRawValue: String,
        signature: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.symbolID = symbolID
        self.repositoryName = repositoryName
        self.commitHash = commitHash
        self.path = path
        self.moduleName = moduleName
        self.name = name
        self.kindRawValue = kindRawValue
        self.parentName = parentName
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.privacyLevelRawValue = privacyLevelRawValue
        self.signature = signature
        self.createdAt = createdAt
    }

    convenience init(node: RepoSymbolNode, createdAt: Date = .now) {
        self.init(
            symbolID: node.id,
            repositoryName: node.repositoryName,
            commitHash: node.commitHash,
            path: node.path,
            moduleName: node.moduleName,
            name: node.name,
            kindRawValue: node.kind.rawValue,
            parentName: node.parentName,
            lineStart: node.lineStart,
            lineEnd: node.lineEnd,
            privacyLevelRawValue: node.privacyLevel.rawValue,
            signature: node.signature,
            createdAt: createdAt
        )
    }

    var kind: RepoSymbolKind {
        RepoSymbolKind(rawValue: kindRawValue) ?? .unknown
    }

    var privacyLevel: RepoPrivacyLevel {
        RepoPrivacyLevel(rawValue: privacyLevelRawValue) ?? .internal
    }

    var provenance: String {
        "\(commitHash):\(path):L\(lineStart)-L\(lineEnd)"
    }
}

struct RepoSelfModelSnapshot: Sendable, Equatable {
    var repositoryName: String
    var commitHash: String
    var generatedAt: Date
    var symbolCount: Int
    var modules: [String]
    var capabilities: [String]
}

struct RepoSymbolGraphBuilder: Sendable {
    private enum ScopeKind {
        case type
        case nonType
    }

    private struct ScopeFrame {
        var kind: ScopeKind
        var name: String?
        var endLine: Int
    }

    private struct DeclarationInfo {
        var accessModifier: String?
        var kind: RepoSymbolKind
        var name: String
    }

    private static let declarationRegex: NSRegularExpression = {
        let pattern = #"^\s*((?:(?:@\w+(?:\([^)]*\))?|open|public|package|internal|fileprivate|private(?:\([^)]*\))?|static|final|class|mutating|nonmutating|override|required|convenience|lazy|weak|unowned|indirect|distributed|isolated|nonisolated)\s+)*)\b(actor|class|struct|enum|protocol|extension|func|var|let)\s+([A-Za-z_][A-Za-z0-9_\.]*)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let accessModifierRegex: NSRegularExpression = {
        let pattern = #"\b(open|public|package|internal|fileprivate|private)(?:\([^)]*\))?\b"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    func build(files: [RepoSourceFile], repositoryName: String, commitHash: String, generatedAt: Date = .now) -> RepoSymbolGraphSnapshot {
        let symbols = files.flatMap { file in
            parse(file: file, repositoryName: repositoryName, commitHash: commitHash)
        }.sorted { lhs, rhs in
            if lhs.path == rhs.path {
                return lhs.lineStart < rhs.lineStart
            }
            return lhs.path < rhs.path
        }
        return RepoSymbolGraphSnapshot(repositoryName: repositoryName, commitHash: commitHash, generatedAt: generatedAt, symbols: symbols)
    }

    private func parse(file: RepoSourceFile, repositoryName: String, commitHash: String) -> [RepoSymbolNode] {
        let lines = file.content.components(separatedBy: .newlines)
        let moduleName = moduleName(for: file.path)
        var nodes: [RepoSymbolNode] = []
        var scopes: [ScopeFrame] = []

        for index in lines.indices {
            let lineNumber = index + 1
            let line = lines[index]
            while let last = scopes.last, last.endLine < lineNumber {
                scopes.removeLast()
            }
            guard let parsed = Self.parseDeclaration(line) else { continue }
            guard !scopes.contains(where: { $0.kind == .nonType }) else { continue }

            let kind = parsed.kind
            let lineEnd = endLine(startingAt: index, in: lines)
            let privacy = privacyLevel(accessModifier: parsed.accessModifier, defaultPrivacy: file.privacyLevel)
            let parent = scopes.last(where: { $0.kind == .type })?.name
            let signature = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let symbolID = [commitHash, file.path, "L\(lineNumber)", parsed.name, kind.rawValue].joined(separator: ":")
            let node = RepoSymbolNode(
                id: symbolID,
                repositoryName: repositoryName,
                commitHash: commitHash,
                path: file.path,
                moduleName: moduleName,
                name: parsed.name,
                kind: kind,
                parentName: parent,
                lineStart: lineNumber,
                lineEnd: lineEnd,
                privacyLevel: privacy,
                signature: signature
            )
            nodes.append(node)

            if kind.isTypeScope {
                scopes.append(ScopeFrame(kind: .type, name: parsed.name, endLine: lineEnd))
            } else if kind == .function || kind == .property && lineEnd > lineNumber && line.contains("{") {
                scopes.append(ScopeFrame(kind: .nonType, name: parsed.name, endLine: lineEnd))
            }
        }

        if !nodes.contains(where: { $0.kind == .module }) {
            let moduleID = [commitHash, file.path, "module", moduleName].joined(separator: ":")
            nodes.insert(RepoSymbolNode(
                id: moduleID,
                repositoryName: repositoryName,
                commitHash: commitHash,
                path: file.path,
                moduleName: moduleName,
                name: moduleName,
                kind: .module,
                parentName: nil,
                lineStart: 1,
                lineEnd: max(1, lines.count),
                privacyLevel: file.privacyLevel,
                signature: "module \(moduleName)"
            ), at: 0)
        }

        return nodes
    }

    private static func parseDeclaration(_ line: String) -> DeclarationInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = declarationRegex.firstMatch(in: trimmed, range: range), match.numberOfRanges >= 4,
              let kindRange = Range(match.range(at: 2), in: trimmed),
              let nameRange = Range(match.range(at: 3), in: trimmed) else {
            return nil
        }
        let modifiers = Range(match.range(at: 1), in: trimmed).map { String(trimmed[$0]) } ?? ""
        let accessModifier = accessModifier(in: modifiers)
        let rawKind = String(trimmed[kindRange])
        let kind = RepoSymbolKind(swiftKeyword: rawKind)
        let rawName = String(trimmed[nameRange])
        let name = rawName.split(separator: "(").first.map(String.init) ?? rawName
        return DeclarationInfo(accessModifier: accessModifier, kind: kind, name: name)
    }

    private static func accessModifier(in modifiers: String) -> String? {
        let range = NSRange(modifiers.startIndex..<modifiers.endIndex, in: modifiers)
        guard let match = accessModifierRegex.firstMatch(in: modifiers, range: range),
              let modifierRange = Range(match.range(at: 1), in: modifiers) else {
            return nil
        }
        return String(modifiers[modifierRange])
    }

    private func endLine(startingAt index: Int, in lines: [String]) -> Int {
        var balance = 0
        var sawBrace = false
        for cursor in index..<lines.count {
            for character in lines[cursor] {
                if character == "{" {
                    sawBrace = true
                    balance += 1
                } else if character == "}" {
                    balance -= 1
                }
            }
            if sawBrace && balance <= 0 {
                return cursor + 1
            }
        }
        return index + 1
    }

    private func moduleName(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count > 1 {
            return parts.dropLast().last ?? parts.first ?? "root"
        }
        return parts.first?.replacingOccurrences(of: ".swift", with: "") ?? "root"
    }

    private func privacyLevel(accessModifier: String?, defaultPrivacy: RepoPrivacyLevel) -> RepoPrivacyLevel {
        switch accessModifier {
        case "open", "public": .publicAPI
        case "private", "fileprivate": .private
        case "internal", "package": .internal
        default: defaultPrivacy
        }
    }
}

struct RepoSelfModelService: Sendable {
    let builder: RepoSymbolGraphBuilder

    init(builder: RepoSymbolGraphBuilder = RepoSymbolGraphBuilder()) {
        self.builder = builder
    }

    @discardableResult
    func rebuildIndex(files: [RepoSourceFile], repositoryName: String, commitHash: String, rootPath: String = "", context: ModelContext) throws -> RepoIndexRecord {
        let snapshot = builder.build(files: files, repositoryName: repositoryName, commitHash: commitHash)
        let staleSymbols = try symbolsDescriptor(repositoryName: repositoryName).fetch(from: context)
        for record in staleSymbols {
            context.delete(record)
        }
        let staleIndexes = try indexesDescriptor(repositoryName: repositoryName).fetch(from: context)
        for record in staleIndexes {
            context.delete(record)
        }

        for node in snapshot.symbols {
            context.insert(RepoSymbolRecord(node: node, createdAt: snapshot.generatedAt))
        }
        let index = RepoIndexRecord(
            repositoryName: repositoryName,
            commitHash: commitHash,
            rootPath: rootPath,
            symbolCount: snapshot.symbols.count,
            privacyLevelRawValue: aggregatePrivacy(for: snapshot.symbols).rawValue,
            generatedAt: snapshot.generatedAt
        )
        context.insert(index)
        try context.safeSave()
        return index
    }

    func symbols(matching query: String, limit: Int = 10, repositoryName: String? = nil, commitHash: String? = nil, context: ModelContext) throws -> [RepoSymbolRecord] {
        let terms = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        guard let scope = try activeScope(repositoryName: repositoryName, commitHash: commitHash, context: context) else { return [] }

        let records = try symbolsDescriptor(repositoryName: scope.repositoryName, commitHash: scope.commitHash).fetch(from: context)
        return records
            .map { record in (record, score(record: record, terms: terms)) }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.lineStart < rhs.0.lineStart
                }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    func latestSnapshot(context: ModelContext) throws -> RepoSelfModelSnapshot? {
        guard let index = try latestIndex(context: context) else { return nil }
        let symbols = try symbolsDescriptor(repositoryName: index.repositoryName, commitHash: index.commitHash).fetch(from: context)
        let modules = Set(symbols.map(\.moduleName)).sorted()
        let capabilities = symbols
            .filter { $0.kind == .function || $0.kind == .struct || $0.kind == .class || $0.kind == .actor }
            .map { "\($0.kindRawValue):\($0.name)" }
            .sorted()
        return RepoSelfModelSnapshot(
            repositoryName: index.repositoryName,
            commitHash: index.commitHash,
            generatedAt: index.generatedAt,
            symbolCount: index.symbolCount,
            modules: modules,
            capabilities: Array(capabilities.prefix(50))
        )
    }

    private func latestIndex(repositoryName: String? = nil, commitHash: String? = nil, context: ModelContext) throws -> RepoIndexRecord? {
        let descriptor: FetchDescriptor<RepoIndexRecord>
        if let repositoryName, let commitHash {
            descriptor = indexesDescriptor(repositoryName: repositoryName, commitHash: commitHash, limit: 1)
        } else if let repositoryName {
            descriptor = indexesDescriptor(repositoryName: repositoryName, limit: 1)
        } else if let commitHash {
            descriptor = indexesDescriptor(commitHash: commitHash, limit: 1)
        } else {
            descriptor = indexesDescriptor(limit: 1)
        }
        return try context.fetch(descriptor).first
    }

    private func activeScope(repositoryName: String?, commitHash: String?, context: ModelContext) throws -> (repositoryName: String, commitHash: String)? {
        if let repositoryName, let commitHash {
            return (repositoryName, commitHash)
        }
        guard let index = try latestIndex(repositoryName: repositoryName, commitHash: commitHash, context: context) else {
            return nil
        }
        return (index.repositoryName, index.commitHash)
    }

    private func symbolsDescriptor(repositoryName: String, commitHash: String? = nil) -> FetchDescriptor<RepoSymbolRecord> {
        if let commitHash {
            return FetchDescriptor<RepoSymbolRecord>(predicate: #Predicate { record in
                record.repositoryName == repositoryName && record.commitHash == commitHash
            })
        }
        return FetchDescriptor<RepoSymbolRecord>(predicate: #Predicate { record in
            record.repositoryName == repositoryName
        })
    }

    private func indexesDescriptor(repositoryName: String? = nil, commitHash: String? = nil, limit: Int? = nil) -> FetchDescriptor<RepoIndexRecord> {
        var descriptor: FetchDescriptor<RepoIndexRecord>
        if let repositoryName, let commitHash {
            descriptor = FetchDescriptor<RepoIndexRecord>(
                predicate: #Predicate { record in
                    record.repositoryName == repositoryName && record.commitHash == commitHash
                },
                sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
            )
        } else if let repositoryName {
            descriptor = FetchDescriptor<RepoIndexRecord>(
                predicate: #Predicate { record in
                    record.repositoryName == repositoryName
                },
                sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
            )
        } else if let commitHash {
            descriptor = FetchDescriptor<RepoIndexRecord>(
                predicate: #Predicate { record in
                    record.commitHash == commitHash
                },
                sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<RepoIndexRecord>(sortBy: [SortDescriptor(\.generatedAt, order: .reverse)])
        }
        if let limit {
            descriptor.fetchLimit = limit
        }
        return descriptor
    }

    private func aggregatePrivacy(for symbols: [RepoSymbolNode]) -> RepoPrivacyLevel {
        let levels = Set(symbols.map(\.privacyLevel))
        if levels.contains(.private) { return .private }
        if levels.contains(.internal) { return .internal }
        if levels.contains(.publicAPI) { return .publicAPI }
        return .internal
    }

    private func score(record: RepoSymbolRecord, terms: [String]) -> Double {
        let fields = [
            record.name.lowercased(),
            record.path.lowercased(),
            record.moduleName.lowercased(),
            record.kindRawValue.lowercased(),
            record.parentName?.lowercased() ?? "",
            record.signature.lowercased()
        ]
        var score = 0.0
        for term in terms {
            if record.name.lowercased() == term { score += 4 }
            if record.name.lowercased().contains(term) { score += 2 }
            if record.path.lowercased().contains(term) { score += 1.5 }
            if record.parentName?.lowercased().contains(term) == true { score += 1 }
            if fields.contains(where: { $0.contains(term) }) { score += 0.5 }
        }
        if record.kind == .module { score *= 0.7 }
        return score
    }
}

private extension FetchDescriptor {
    func fetch(from context: ModelContext) throws -> [T] {
        try context.fetch(self)
    }
}

private extension RepoSymbolKind {
    init(swiftKeyword: String) {
        switch swiftKeyword {
        case "actor": self = .actor
        case "class": self = .class
        case "struct": self = .struct
        case "enum": self = .enum
        case "protocol": self = .protocol
        case "extension": self = .extension
        case "func": self = .function
        case "var", "let": self = .property
        default: self = .unknown
        }
    }

    var isTypeScope: Bool {
        switch self {
        case .actor, .class, .struct, .enum, .protocol, .extension:
            true
        default:
            false
        }
    }
}
