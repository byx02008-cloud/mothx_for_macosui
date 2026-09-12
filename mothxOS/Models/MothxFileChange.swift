import Foundation

nonisolated enum MothxFileChangeKind: String, Codable, Hashable {
    case created
    case modified
    case deleted
}

nonisolated struct MothxFileChange: Identifiable, Codable, Hashable {
    let id: String
    let path: String
    let kind: MothxFileChangeKind
    let added: Int
    let deleted: Int
    let unifiedDiff: String
    let oldText: String?
    let newText: String?
    let truncated: Bool

    /// Only an authoritative before/after pair returned by mothx can be
    /// reviewed. Summaries and locally readable files are preview-only.
    var isReviewable: Bool {
        oldText != nil && newText != nil
    }

    /// True when the change has no authoritative before/after pair and its
    /// line counts were derived from a mothx tool summary that flagged them as
    /// approximate, or could not be resolved at all. mothx reports a very
    /// large file as a complete replacement (its LCS guard), so those numbers
    /// describe the whole file, not the edit, and must never be shown as exact.
    var countsAreApproximate: Bool {
        guard !isReviewable else { return false }
        if unifiedDiff.contains("line ranges approximate") { return true }
        if unifiedDiff.contains("无法在此处展开") { return true }
        if unifiedDiff.contains("Diff too large") { return true }
        return added == 0 && deleted == 0
    }

    init(path: String, oldText: String, newText: String, unifiedDiff: String, added: Int, deleted: Int, truncated: Bool = false) {
        self.id = path
        self.path = path
        // This initializer is reachable only when the server returned both
        // oldText and newText. An empty old version represents a newly
        // created file for display purposes.
        self.kind = oldText.isEmpty ? .created : .modified
        self.added = added
        self.deleted = deleted
        self.unifiedDiff = unifiedDiff
        self.oldText = oldText
        self.newText = newText
        self.truncated = truncated
    }

    /// Rebuilds a change from the local SQLite store, where the kind and the
    /// before/after payload are already known and must not be re-derived.
    init(path: String, kind: MothxFileChangeKind, added: Int, deleted: Int, unifiedDiff: String, oldText: String?, newText: String?, truncated: Bool) {
        self.id = path
        self.path = path
        self.kind = kind
        self.added = added
        self.deleted = deleted
        self.unifiedDiff = unifiedDiff
        self.oldText = oldText
        self.newText = newText
        self.truncated = truncated
    }

    /// Creates a compact historical change when the server only persisted a
    /// tool summary and not the structured before/after file contents.
    init(previewPath path: String, unifiedDiff: String, added: Int, deleted: Int, kind: MothxFileChangeKind = .modified) {
        self.id = path
        self.path = path
        self.kind = kind
        self.added = added
        self.deleted = deleted
        self.unifiedDiff = unifiedDiff
        self.oldText = nil
        self.newText = nil
        self.truncated = false
    }
}

nonisolated struct MothxTurnChanges: Identifiable, Codable, Hashable {
    let id: String
    let runID: String
    let files: [MothxFileChange]
    let capturedAt: Date

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var deleted: Int { files.reduce(0) { $0 + $1.deleted } }
}

/// A file change captured from one ACP tool call. The tool-call key is kept
/// separately from the turn projection because ACP's client Run ID is
/// temporary and cannot be used to restore a conversation after relaunch.
struct MothxToolChangeRecord: Codable, Hashable {
    let sessionID: String
    let toolCallID: String
    let files: [MothxFileChange]
    let capturedAt: Date
}

struct MothxChangeStoreState {
    let turns: [String: MothxTurnChanges]
    let toolChanges: [String: MothxToolChangeRecord]
}

nonisolated enum MothxDiffBuilder {
    static func make(path: String, oldText: String, newText: String) -> MothxFileChange {
        let oldLines = lines(oldText)
        let newLines = lines(newText)
        // Do not use N*M as a size limit: it measures the quadratic LCS
        // workspace, not the amount of change. A 2,324-line file would be
        // incorrectly reported as a complete replacement here.
        let records = myersRecords(oldLines: oldLines, newLines: newLines)

        // `records` is produced by Myers' shortest-edit-script algorithm.

        let added = records.reduce(0) { partial, record in
            if case .added = record { return partial + 1 }; return partial
        }
        let deleted = records.reduce(0) { partial, record in
            if case .deleted = record { return partial + 1 }; return partial
        }
        let diff = records.map { record in
            switch record { case .context(let line): return "  \(line)"; case .added(let line): return "+ \(line)"; case .deleted(let line): return "- \(line)" }
        }.joined(separator: "\n")
        return MothxFileChange(path: path, oldText: oldText, newText: newText, unifiedDiff: diff, added: added, deleted: deleted)
    }

    private enum Record {
        case context(String), added(String), deleted(String)
    }

    private static func myersRecords(oldLines: [String], newLines: [String]) -> [Record] {
        let n = oldLines.count
        let m = newLines.count
        let maxDistance = n + m
        guard maxDistance > 0 else { return [] }
        let offset = maxDistance
        var frontier = Array(repeating: 0, count: maxDistance * 2 + 1)
        var trace: [[Int]] = []
        var finishDistance = 0

        search: for distance in 0...maxDistance {
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                let index = offset + diagonal
                let startX: Int
                if diagonal == -distance || (diagonal != distance && frontier[index - 1] < frontier[index + 1]) {
                    startX = frontier[index + 1]
                } else {
                    startX = frontier[index - 1] + 1
                }
                var x = startX
                var y = x - diagonal
                while x < n && y < m && oldLines[x] == newLines[y] {
                    x += 1; y += 1
                }
                frontier[index] = x
                if x >= n && y >= m {
                    trace.append(frontier)
                    finishDistance = distance
                    break search
                }
            }
            trace.append(frontier)
        }

        var result: [Record] = []
        var x = n
        var y = m
        for distance in stride(from: finishDistance, through: 1, by: -1) {
            let previous = trace[distance - 1]
            let diagonal = x - y
            let index = offset + diagonal
            let previousDiagonal: Int
            if diagonal == -distance || (diagonal != distance && previous[index - 1] < previous[index + 1]) {
                previousDiagonal = diagonal + 1
            } else {
                previousDiagonal = diagonal - 1
            }
            let previousX = previous[offset + previousDiagonal]
            let previousY = previousX - previousDiagonal
            while x > previousX && y > previousY {
                result.append(.context(oldLines[x - 1])); x -= 1; y -= 1
            }
            if x == previousX {
                result.append(.added(newLines[y - 1])); y -= 1
            } else {
                result.append(.deleted(oldLines[x - 1])); x -= 1
            }
        }
        while x > 0 && y > 0 {
            result.append(.context(oldLines[x - 1])); x -= 1; y -= 1
        }
        while x > 0 { result.append(.deleted(oldLines[x - 1])); x -= 1 }
        while y > 0 { result.append(.added(newLines[y - 1])); y -= 1 }
        return result.reversed()
    }

    private static func lines(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var result = normalizedNewlines(value)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Splits on `\n`, `\r\n` and `\r`. Swift treats a `\r\n` pair as a single
    /// `Character`, so `split(separator: "\n")` alone leaves an entire CRLF
    /// file as one line, which made every CRLF edit look like a whole-file
    /// replacement and produced meaningless counts and diffs.
    static func normalizedNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
