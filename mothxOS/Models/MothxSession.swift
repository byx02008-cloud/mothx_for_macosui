import Foundation

struct MothxSession: Identifiable, Hashable {
    let id: String
    var title: String
    var projectID: String?
    var updatedAt: String?
    var workDir: String?
    // v1.2.92+ session-fork lineage; empty for non-forked sessions.
    var parentSessionId: String?
    var forkBoundarySeq: Int?
    var seedLength: Int?
    var forkKind: String?

    /// True when this session is a forked child (has a parent session).
    var isForked: Bool {
        guard let parentSessionId, !parentSessionId.isEmpty else { return false }
        return true
    }
}