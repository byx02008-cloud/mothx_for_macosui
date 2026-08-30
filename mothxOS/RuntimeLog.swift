import Foundation

/// Low-overhead client diagnostics for stalls, expensive view updates and
/// failed requests. It deliberately records metadata only, never transcript
/// text, tool output, credentials or request bodies.
final class RuntimeLog {
    static let shared = RuntimeLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "mothxOS.runtime-log", qos: .utility)
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mothxOS", isDirectory: true)
        fileURL = directory.appendingPathComponent("runtime.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    func write(_ category: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)\n"
        queue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 5_000_000 else { return }
        let oldURL = fileURL.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: fileURL, to: oldURL)
    }
}
