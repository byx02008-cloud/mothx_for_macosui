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

    /// Creates a compact historical change when the server only persisted a
    /// tool summary and not the structured before/after file contents.
    init(previewPath path: String, unifiedDiff: String, added: Int, deleted: Int) {
        self.id = path
        self.path = path
        self.kind = .modified
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

/// Persists the change database off the main thread. `save` is cheap to call
/// from the UI thread: encoding and the atomic write happen synchronously
/// inside the caller-started background task, so the main run loop is never
/// blocked by multi-megabyte diff serialization while a large file is being
/// edited. A generation counter drops stale snapshots that would otherwise
/// overwrite a newer save that already landed.
nonisolated final class MothxChangeStore: @unchecked Sendable {
    private static let currentVersion = 2

    private struct Envelope: Codable {
        let version: Int
        let turns: [String: MothxTurnChanges]
        let toolChanges: [String: MothxToolChangeRecord]
    }

    private let url: URL
    private let saveLock = NSLock()
    private var lastSavedGeneration = 0
    private let decoder = JSONDecoder()

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothxOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("changes.json")
    }

    func load() -> MothxChangeStoreState {
        guard let data = try? Data(contentsOf: url) else {
            return MothxChangeStoreState(turns: [:], toolChanges: [:])
        }

        if let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.version >= Self.currentVersion {
            return MothxChangeStoreState(turns: envelope.turns, toolChanges: envelope.toolChanges)
        }

        // Legacy files were keyed only by the temporary Run ID. They may also
        // contain content from an older experimental format without a stable
        // ACP tool-call key, so intentionally downgrade them to preview-only.
        guard let legacy = try? decoder.decode([String: MothxTurnChanges].self, from: data) else {
            return MothxChangeStoreState(turns: [:], toolChanges: [:])
        }
        let previewTurns = legacy.mapValues { turn in
            MothxTurnChanges(
                id: turn.id,
                runID: turn.runID,
                files: turn.files.map { file in
                    MothxFileChange(
                        previewPath: file.path,
                        unifiedDiff: "历史运行已完成，详细 Diff 未持久化。",
                        added: file.added,
                        deleted: file.deleted
                    )
                },
                capturedAt: turn.capturedAt
            )
        }
        return MothxChangeStoreState(turns: previewTurns, toolChanges: [:])
    }

    /// Serializes the given snapshot and writes it atomically. Meant to be
    /// called from a background task; the generation guard ensures an older
    /// snapshot that finishes late never clobbers a newer one.
    func save(turns: [String: MothxTurnChanges], toolChanges: [String: MothxToolChangeRecord], generation: Int) {
        saveLock.lock()
        defer { saveLock.unlock() }
        guard generation >= lastSavedGeneration else { return }
        lastSavedGeneration = generation
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(version: Self.currentVersion, turns: turns, toolChanges: toolChanges)
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }
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
        var result = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if result.last == "" { result.removeLast() }
        return result
    }
}
