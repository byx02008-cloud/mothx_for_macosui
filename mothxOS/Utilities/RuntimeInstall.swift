import Foundation

/// Shared helpers for installing/updating the global `mothx-installer` npm
/// package, including the admin-elevated path needed when npm's global prefix
/// is root-owned (the official Node.js pkg installs to /usr/local as root).
enum RuntimeInstall {
    /// True when npm-style output spells a permission problem that an
    /// elevated install could fix.
    static func isPermissionError(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("eacces")
            || t.contains("eperm")
            || t.contains("permission denied")
            || t.contains("operation not permitted")
    }

    /// The absolute npm path used by this login shell, so an elevated process
    /// can invoke it without relying on PATH (`do shell script` runs with a
    /// minimal environment). Returns nil when npm isn't resolvable.
    static func npmExecutablePath() async -> String? {
        let result = await runShell("command -v npm")
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `npm install -g mothx-installer` through the system authorization
    /// prompt (`osascript ... with administrator privileges`). macOS npm
    /// locations contain no spaces, so no quoting is needed.
    static func installGloballyAsAdmin(onOutput: @escaping (String) -> Void) async -> Int32 {
        let npmPath = await npmExecutablePath()
        let installCommand = npmPath.map { "\($0) install -g mothx-installer 2>&1" }
            ?? "npm install -g mothx-installer 2>&1"
        // Escape backslashes and quotes for the AppleScript string literal.
        let escaped = installCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await runProcessStreaming(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            onOutput: onOutput
        )
    }

    /// Runs `command` in an interactive login shell (so nvm/homebrew PATH
    /// entries are honored) and returns its combined stdout+stderr output
    /// and exit code.
    static func runShell(_ command: String) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-i", "-l", "-c", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("", -1))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (text, process.terminationStatus))
            }
        }
    }

    /// Runs `executable` directly with explicit arguments — no shell in
    /// between — delivering output incrementally via `onOutput` (called on the
    /// main actor). Used for `/usr/bin/osascript` so the AppleScript source is
    /// never re-interpreted by a shell layer.
    private static func runProcessStreaming(executable: String, arguments: [String], onOutput: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in onOutput(text) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}