import Foundation

struct MothxProject: Identifiable, Hashable {
    let id: String
    var name: String
    var workDir: String = ""
    var sessionIDs: [String] = []
}
