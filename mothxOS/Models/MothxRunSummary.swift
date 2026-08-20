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
        let end = finishedAt ?? updatedAt ?? Date()
        return max(0, end.timeIntervalSince(startedAt))
    }
}
