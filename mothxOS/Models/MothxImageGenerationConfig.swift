import Foundation

struct MothxImageGenerationConfig: Codable, Hashable {
    var enabled: Bool = false
    var providerID: String = ""
    var modelID: String = ""
}
