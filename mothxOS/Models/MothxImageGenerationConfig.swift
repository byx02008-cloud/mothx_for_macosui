import Foundation

struct MothxImageGenerationConfig: Codable, Hashable {
    var enabled: Bool = false
    var provider: String = "openai"
    var apiType: String = "openai-images"
    var baseUrl: String = "https://api.openai.com/v1"
    var token: String = ""
    var model: String = "gpt-image-1"
}
