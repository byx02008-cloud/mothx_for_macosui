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

    /// Runs a shell command, delivering output incrementally via `onOutput`
    /// (called on the main actor) as it's produced, rather than waiting for
    /// the process to exit before returning any text.
    static func runShellStreaming(_ command: String, onOutput: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-i", "-l", "-c", command]
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

    /// `mothx --version` output, e.g. "v1.2.95" or "v1.2.95-dirty", or nil
    /// when mothx isn't resolvable.
    static func mothxVersionString() async -> String? {
        let result = await runShell("mothx --version")
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Shell wrapper output looks like "mothx version v1.2.95-dirty".
        return trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
    }

    /// `npm view mothx-installer version`, or nil when npm/network fails.
    static func latestNpmVersion() async -> String? {
        let result = await runShell("npm view mothx-installer version")
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when `current` is older than `latest`, comparing numeric
    /// components only. Pre-release/build suffixes like "-dirty" are ignored
    /// so a locally-built `1.2.95-dirty` isn't reported as newer/older than
    /// the published `1.2.95`.
    static func versionNeedsUpdate(current: String, latest: String) -> Bool {
        compareVersion(current, latest) < 0
    }

    /// Latest publishable version if one is available, else nil.
    static func checkMothxUpdate() async -> String? {
        guard let current = await mothxVersionString(),
              let latest = await latestNpmVersion(),
              versionNeedsUpdate(current: current, latest: latest) else { return nil }
        return latest
    }

    private static func compareVersion(_ a: String, _ b: String) -> Int {
        let av = numericComponents(a)
        let bv = numericComponents(b)
        let count = max(av.count, bv.count)
        for i in 0..<count {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func numericComponents(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip pre-release/build suffixes ("-dirty") and a leading "v".
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        let noV = core.hasPrefix("v") || core.hasPrefix("V") ? String(core.dropFirst()) : core
        return noV.split(separator: ".").compactMap { Int($0) }
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