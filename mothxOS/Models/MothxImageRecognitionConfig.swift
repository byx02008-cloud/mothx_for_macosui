import Foundation

/// Client-owned routing for image understanding. Provider credentials remain
/// in mothx settings; the app only remembers which existing provider/model to
/// use as the vision fallback.
struct MothxImageRecognitionConfig: Codable, Hashable {
    var enabled: Bool = false
    var providerID: String = ""
    var modelID: String = ""
}
