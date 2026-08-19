import Foundation

struct MothxProviderConfig: Codable, Identifiable, Hashable {
    var id: String
    var vendor: String = ""
    var apiKey: String = ""
    var baseUrl: String = ""
    var httpProxy: String = ""
    var forceHTTP11: Bool = false
    var headers: [String: String] = [:]
    var api: String = "openai-chat"
    var thinkingFormat: String = ""
    var models: [MothxModelConfig] = []

    enum CodingKeys: String, CodingKey { case vendor, apiKey, baseUrl, httpProxy, forceHTTP11, headers, api, thinkingFormat, models }
    init(id: String = "", vendor: String = "", apiKey: String = "", baseUrl: String = "", httpProxy: String = "", forceHTTP11: Bool = false, headers: [String: String] = [:], api: String = "openai-chat", thinkingFormat: String = "", models: [MothxModelConfig] = []) {
        self.id = id; self.vendor = vendor; self.apiKey = apiKey; self.baseUrl = baseUrl; self.httpProxy = httpProxy; self.forceHTTP11 = forceHTTP11; self.headers = headers; self.api = api; self.thinkingFormat = thinkingFormat; self.models = models
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(vendor: try c.decodeIfPresent(String.self, forKey: .vendor) ?? "", apiKey: try c.decodeIfPresent(String.self, forKey: .apiKey) ?? "", baseUrl: try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? "", httpProxy: try c.decodeIfPresent(String.self, forKey: .httpProxy) ?? "", forceHTTP11: try c.decodeIfPresent(Bool.self, forKey: .forceHTTP11) ?? false, headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:], api: try c.decodeIfPresent(String.self, forKey: .api) ?? "openai-chat", thinkingFormat: try c.decodeIfPresent(String.self, forKey: .thinkingFormat) ?? "", models: try c.decodeIfPresent([MothxModelConfig].self, forKey: .models) ?? [])
    }
}
