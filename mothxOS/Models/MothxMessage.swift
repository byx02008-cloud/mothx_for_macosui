import Foundation

struct MothxMessage: Identifiable, Hashable {
    let id: String
    let role: String
    let content: String
    let createdAt: String?
}
