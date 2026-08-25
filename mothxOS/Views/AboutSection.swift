import AppKit
import SwiftUI

private enum UpdateStage {
    case stoppingService
    case installing
    case restartingService
    case succeeded
    case failed
    case needsAdmin

    var isFinished: Bool { self == .succeeded || self == .failed }
    /// Stages where the progress sheet may be closed by the user (finished
    /// states plus the admin-rights prompt, which is parked awaiting input).
    var isDismissable: Bool { isFinished || self == .needsAdmin }
}

extension UpdateStage: Equatable {}

struct AboutSection: View {
    @EnvironmentObject private var languageStore: LanguageStore
    @EnvironmentObject private var mothx: MothxServiceManager
    @State private var mothxVersion: String?
    @State private var latestVersion: String?
    @State private var isChecking = false
    @State private var isUpdating = false
    @State private var errorHint: String?

    @State private var showUpdateProgress = false
    @State private var updateStage: UpdateStage = .stoppingService
    @State private var updateLog = ""

    private let appDisplayName = "Mothx UI for MacOS"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var updateAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOTHXOS_SIMULATE_UPDATE_AVAILABLE"] == "1" { return true }
        #endif
        guard let mothxVersion, let latestVersion, !latestVersion.isEmpty else { return false }
        return mothxVersion != latestVersion
    }

    var body: some View {
        let c = languageStore.copy
        return SettingsCard(title: c.about, subtitle: c.aboutSubtitle) {
            VStack(alignment: .leading, spacing: 14) {
                infoRow(c.appNameLabel, appDisplayName)
                infoRow(c.appVersionLabel, appVersion)
                infoRow(c.mothxVersionLabel, mothxVersion ?? c.versionUnknown)
                HStack {
                    Text(c.latestVersionLabel)
                    Spacer()
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(latestVersion ?? c.versionUnknown).foregroundStyle(.secondary)
                    }
                }

                if !isChecking {
                    if updateAvailable {
                        Text(c.updateAvailableHint).font(.caption).foregroundStyle(.orange)
                    } else if mothxVersion != nil && latestVersion != nil {
                        Text(c.upToDateHint).font(.caption).foregroundStyle(.secondary)
                    } else if latestVersion == nil {
                        Text(c.npmUnavailableHint).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let errorHint {
                    Text(errorHint).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Button(c.refreshVersion) { Task { await checkVersions() } }
                        .buttonStyle(.bordered)
                        .disabled(isChecking || isUpdating)
                    if updateAvailable {
                        Button(isUpdating ? c.updating : c.updateButton) { Task { await performUpdate() } }
                            .buttonStyle(.borderedProminent).tint(.orange)
                            .disabled(isUpdating)
                    }
                }
            }
        }
        .task { await checkVersions() }
        .sheet(isPresented: $showUpdateProgress) {
            UpdateProgressSheet(
                stage: updateStage,
                log: updateLog,
                onClose: { showUpdateProgress = false },
                onInstallAsAdmin: { Task { await installUpdateAsAdmin() } }
            )
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private func checkVersions() async {
        isChecking = true
        errorHint = nil
        async let mothxResult = fetchMothxVersion()
        async let npmResult = fetchLatestNpmVersion()
        let (mv, lv) = await (mothxResult, npmResult)
        mothxVersion = mv
        latestVersion = lv
        isChecking = false
    }

    private func fetchMothxVersion() async -> String? {
        let result = await AboutSection.runShell("mothx --version")
        guard result.exitCode == 0 else { return nil }
        return AboutSection.extractVersion(from: result.output)
    }

    private func fetchLatestNpmVersion() async -> String? {
        let result = await AboutSection.runShell("npm view mothx-installer version")
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : AboutSection.normalizeVersion(trimmed)
    }

    /// Stops the mothx service, runs `npm install -g mothx-installer` with
    /// live output shown in a small progress window, restarts the service,
    /// and reflects the new version once everything comes back up.
    private func performUpdate() async {
        let c = languageStore.copy
        isUpdating = true
        errorHint = nil
        updateLog = ""
        updateStage = .stoppingService
        showUpdateProgress = true

        if mothx.ownsRunningProcess {
            appendUpdateLog(c.updateLogStoppingService)
            await mothx.stopOwnedService()
        } else {
            appendUpdateLog(c.updateLogExternalServiceSkipped)
        }

        updateStage = .installing
        appendUpdateLog(c.updateLogRunningNpmInstall)
        #if DEBUG
        let simulatedEACCES = ProcessInfo.processInfo.environment["MOTHXOS_SIMULATE_UPDATE_EACCES"] == "1"
        #else
        let simulatedEACCES = false
        #endif
        let exitCode: Int32
        if simulatedEACCES {
            updateLog += "\nnpm error code EACCES"
            exitCode = 1
        } else {
            exitCode = await AboutSection.runShellStreaming("npm install -g mothx-installer") { chunk in
                updateLog += chunk
            }
        }

        if exitCode == 0 {
            updateStage = .restartingService
            appendUpdateLog(c.updateLogRestartingService)
            await mothx.connect()
            if let latestVersion { mothxVersion = latestVersion }
            updateStage = .succeeded
            appendUpdateLog(c.updateLogSucceeded)
        } else if RuntimeInstall.isPermissionError(updateLog) {
            // The service was already stopped for the update attempt; bring
            // it back, then park at the admin-rights prompt.
            updateStage = .restartingService
            appendUpdateLog(c.updateLogRestartingService)
            await mothx.connect()
            updateStage = .needsAdmin
            appendUpdateLog(c.updateLogNeedsAdmin)
            errorHint = c.updateNeedsAdminHint
        } else {
            // The service was already stopped for the update attempt; bring
            // it back regardless of whether the install itself succeeded.
            updateStage = .restartingService
            appendUpdateLog(c.updateLogRestartingService)
            await mothx.connect()
            updateStage = .failed
            appendUpdateLog(c.updateLogFailedPrefix(exitCode))
            errorHint = c.updateFailedPrefix("exit \(exitCode)")
        }

        isUpdating = false
    }

    /// Retries the install via the system authorization prompt after the
    /// plain `npm install -g` failed with a permission error. Stops the
    /// owned service, installs as admin, then brings the service back.
    private func installUpdateAsAdmin() async {
        let c = languageStore.copy
        isUpdating = true
        errorHint = nil
        updateLog = ""
        updateStage = .stoppingService

        if mothx.ownsRunningProcess {
            appendUpdateLog(c.updateLogStoppingService)
            await mothx.stopOwnedService()
        } else {
            appendUpdateLog(c.updateLogExternalServiceSkipped)
        }

        updateStage = .installing
        appendUpdateLog(c.updateLogRunningNpmInstall)
        let exitCode = await RuntimeInstall.installGloballyAsAdmin { chunk in
            updateLog += chunk
        }
        let lower = updateLog.lowercased()
        let canceled = lower.contains("cancel") || lower.contains("取消")

        updateStage = .restartingService
        appendUpdateLog(c.updateLogRestartingService)
        await mothx.connect()

        if exitCode == 0 {
            if let latestVersion { mothxVersion = latestVersion }
            updateStage = .succeeded
            appendUpdateLog(c.updateLogSucceeded)
        } else if canceled {
            // User dismissed the password prompt — park at the choices again.
            updateStage = .needsAdmin
            appendUpdateLog(c.updateLogNeedsAdmin)
            errorHint = c.updateNeedsAdminHint
        } else {
            updateStage = .failed
            appendUpdateLog(c.updateLogFailedPrefix(exitCode))
            let detail = String(updateLog.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            errorHint = c.updateFailedPrefix(detail.isEmpty ? "exit \(exitCode)" : detail)
        }

        isUpdating = false
    }

    private func appendUpdateLog(_ line: String) {
        updateLog += (updateLog.isEmpty ? "" : "\n") + line
    }

    private static func extractVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        return normalizeVersion(String(last))
    }

    private static func normalizeVersion(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }

    private static func runShell(_ command: String) async -> (output: String, exitCode: Int32) {
        await runProcess(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-i", "-l", "-c", command])
    }

    private static func runProcess(executable: URL, arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
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

    /// Runs a shell command, delivering output incrementally via `onOutput`
    /// (called on the main actor) as it's produced, rather than waiting for
    /// the process to exit before returning any text.
    private static func runShellStreaming(_ command: String, onOutput: @escaping (String) -> Void) async -> Int32 {
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
}

private struct UpdateProgressSheet: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let stage: UpdateStage
    let log: String
    let onClose: () -> Void
    let onInstallAsAdmin: () -> Void

    var body: some View {
        let c = languageStore.copy
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(c.updateProgressTitle, systemImage: "arrow.triangle.2.circlepath")
                    .font(.title3.bold())
                Spacer()
                if stage.isDismissable {
                    Button(c.close) { onClose() }
                }
            }

            HStack(spacing: 8) {
                if !stage.isDismissable {
                    ProgressView().controlSize(.small)
                }
                Text(stageLabel(c))
                    .font(.subheadline)
                    .foregroundStyle(stage == .failed ? .red : .secondary)
            }

            if stage == .needsAdmin {
                VStack(alignment: .leading, spacing: 10) {
                    Text(c.installMothxPermissionTitle).font(.headline)
                    Text(c.installMothxPermissionMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(c.installUseAdminPassword) { onInstallAsAdmin() }
                        .buttonStyle(.borderedProminent)
                    HStack(spacing: 8) {
                        Button(c.installCopySudoCommand) {
                            copyToPasteboard("sudo npm install -g mothx-installer")
                        }
                        .buttonStyle(.bordered)
                        Button(c.installOpenTerminal) { openTerminal() }
                            .buttonStyle(.bordered)
                    }
                    Label(c.installPrefixHint, systemImage: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(c.installCopyPrefixCommand) {
                        copyToPasteboard("npm config set prefix ~/.npm-global\nexport PATH=\"$HOME/.npm-global/bin:$PATH\"")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            ScrollView {
                Text(log.isEmpty ? c.updateWaitingForOutput : log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 560, height: 380)
        .interactiveDismissDisabled(!stage.isDismissable)
    }

    private func stageLabel(_ c: Copy) -> String {
        switch stage {
        case .stoppingService: return c.updateStageStoppingService
        case .installing: return c.updateStageInstalling
        case .restartingService: return c.updateStageRestartingService
        case .succeeded: return c.updateStageSucceeded
        case .failed: return c.updateStageFailed
        case .needsAdmin: return c.updateStageNeedsAdmin
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(url)
        }
    }
}
