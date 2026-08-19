import Foundation

struct MothxSession: Identifiable, Hashable {
    let id: String
    var title: String
    var projectID: String?
    var updatedAt: String?
    var workDir: String?
}
