import Foundation

struct MothxRunSummary: Hashable {
    let id: String
    let intentID: String?
    let status: String
    let startedAt: Date?
    let finishedAt: Date?
    let updatedAt: Date?
    let error: String?

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        // Historical summaries must remain stable when another Run causes
        // SwiftUI to refresh. Live Run duration is supplied separately by
        // MothxServiceManager.runElapsed for the final active turn.
        guard let end = finishedAt ?? updatedAt else { return 0 }
        return max(0, end.timeIntervalSince(startedAt))
    }
}
