import Foundation

enum MothxFileChangeKind: String, Codable, Hashable {
    case created
    case modified
    case deleted
}

struct MothxFileChange: Identifiable, Codable, Hashable {
    let id: String
    let path: String
    let kind: MothxFileChangeKind
    let added: Int
    let deleted: Int
    let unifiedDiff: String
    let oldText: String?
    let newText: String
    let truncated: Bool

    init(path: String, oldText: String?, newText: String, unifiedDiff: String, added: Int, deleted: Int, truncated: Bool = false) {
        self.id = path
        self.path = path
        self.kind = oldText == nil ? .created : (newText.isEmpty ? .deleted : .modified)
        self.added = added
        self.deleted = deleted
        self.unifiedDiff = unifiedDiff
        self.oldText = oldText
        self.newText = newText
        self.truncated = truncated
    }
}

struct MothxTurnChanges: Identifiable, Codable, Hashable {
    let id: String
    let runID: String
    let files: [MothxFileChange]
    let capturedAt: Date

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var deleted: Int { files.reduce(0) { $0 + $1.deleted } }
}

/// A small local cache. The server is deliberately not changed for this
/// feature, so the desktop keeps the Diff received/calculated during a run.
final class MothxChangeStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothxOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("changes.json")
    }

    func load() -> [String: MothxTurnChanges] {
        guard let data = try? Data(contentsOf: url),
              let values = try? decoder.decode([String: MothxTurnChanges].self, from: data) else { return [:] }
        return values
    }

    func save(_ values: [String: MothxTurnChanges]) {
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum MothxDiffBuilder {
    static func make(path: String, oldText: String?, newText: String) -> MothxFileChange? {
        guard oldText != newText else { return nil }
        let oldLines = lines(oldText ?? "")
        let newLines = lines(newText)
        let truncated = oldLines.count * max(newLines.count, 1) > 200_000
        if truncated {
            return MothxFileChange(path: path, oldText: oldText, newText: newText,
                                   unifiedDiff: "详细 Diff 过大，无法在此处展开。",
                                   added: newLines.count, deleted: oldLines.count, truncated: true)
        }

        var table = Array(repeating: Array(repeating: 0, count: newLines.count + 1), count: oldLines.count + 1)
        if !oldLines.isEmpty && !newLines.isEmpty {
            for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
                for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                    table[i][j] = oldLines[i] == newLines[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        enum Record { case context(String), added(String), deleted(String) }
        var records: [Record] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count && j < newLines.count && oldLines[i] == newLines[j] {
                records.append(.context(oldLines[i])); i += 1; j += 1
            } else if j < newLines.count && (i == oldLines.count || table[i][j + 1] >= table[i + 1][j]) {
                records.append(.added(newLines[j])); j += 1
            } else if i < oldLines.count {
                records.append(.deleted(oldLines[i])); i += 1
            }
        }

        let added = records.reduce(0) { partial, record in
            if case .added = record { return partial + 1 }
            return partial
        }
        let deleted = records.reduce(0) { partial, record in
            if case .deleted = record { return partial + 1 }
            return partial
        }
        let diff = records.map { record in
            switch record { case .context(let line): return "  (line)"; case .added(let line): return "+ (line)"; case .deleted(let line): return "- (line)" }
        }.joined(separator: "\n")
        return MothxFileChange(path: path, oldText: oldText, newText: newText, unifiedDiff: diff, added: added, deleted: deleted)
    }

    private static func lines(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        return value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLastIfTrailingEmpty()
    }

}

private extension Array where Element == String {
    func dropLastIfTrailingEmpty() -> [String] {
        var value = self
        if value.last == "" { value.removeLast() }
        return value
    }
}
