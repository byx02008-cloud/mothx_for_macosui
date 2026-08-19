import Foundation

struct MothxModelConfig: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var reasoning: Bool = false
    var contextWindow: Int = 0
    var maxTokens: Int = 0
    var temperature: Double?
    var topP: Double?
    var input: [String] = []

    var displayName: String { name.isEmpty ? id : name }
}
