import AppKit
import SwiftUI

private enum CheckState: Equatable {
    case pending
    case passed
    case failed
}

private enum Phase: Equatable {
    case checking
    case nodeMissing(hasBrew: Bool)
    case installingBrewNode
    case installingMothx
    case allPassed
    case connecting
    case failed(String)
}

/// Launch-time preflight checklist: verifies Node.js and mothx are
/// installed, guides the user through installing whichever is missing (one
/// at a time), then hands off to MothxServiceManager.connectAtLaunch() once
/// both are confirmed present. Shown unconditionally on every launch so the
/// "all clear" path is visible too, not just the failure path.
struct EnvironmentCheckSheet: View {
    @EnvironmentObject private var languageStore: LanguageStore
    @EnvironmentObject private var mothx: MothxServiceManager
    @Binding var isPresented: Bool

    @State private var phase: Phase = .checking
    @State private var nodeState: CheckState = .pending
    @State private var mothxState: CheckState = .pending
    @State private var log = ""

    var body: some View {
        let c = languageStore.copy
        VStack(alignment: .leading, spacing: 16) {
            Label(c.envCheckTitle, systemImage: "checklist")
                .font(.title3.bold())
            Text(c.envCheckSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                checklistRow(label: c.envCheckNodeLabel, state: nodeState)
                checklistRow(label: c.envCheckMothxLabel, state: mothxState)
                checklistRow(label: c.envCheckSyncLabel, state: syncCheckState)
            }

            switch phase {
            case .checking:
                EmptyView()
            case .nodeMissing(let hasBrew):
                nodeMissingView(hasBrew: hasBrew, c: c)
            case .installingBrewNode, .installingMothx, .connecting:
                progressView(c: c)
            case .allPassed:
                Label(c.envCheckPassed, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button(c.installRetry) { Task { await runChecklist() } }
                        .buttonStyle(.borderedProminent)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 520, height: 450)
        .interactiveDismissDisabled()
        .task { await runChecklist() }
    }

    private var syncCheckState: CheckState {
        switch mothx.workspaceSyncState {
        case .pending: return .pending
        case .passed: return .passed
        case .failed: return .failed
        }
    }

    @ViewBuilder
    private func checklistRow(label: String, state: CheckState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .pending:
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            case .passed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            Text(label)
        }
    }

    @ViewBuilder
    private func nodeMissingView(hasBrew: Bool, c: Copy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(c.installNodeMissingTitle).font(.headline)
            Text(c.installNodeMissingMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Button(c.installOpenNodeSite) {
                    NSWorkspace.shared.open(URL(string: "https://nodejs.org")!)
                }
                .buttonStyle(.borderedProminent)
                if hasBrew {
                    Button(c.installUseHomebrew) { Task { await installNodeViaBrew() } }
                        .buttonStyle(.bordered)
                }
                Button(c.installRecheck) { Task { await runChecklist() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func progressView(c: Copy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stageLabel(c)).font(.subheadline).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(log.isEmpty ? c.installWaitingForOutput : log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func stageLabel(_ c: Copy) -> String {
        switch phase {
        case .installingBrewNode: return c.installStageInstallingBrewNode
        case .installingMothx: return c.installStageInstallingMothx
        case .connecting: return c.installStageConnecting
        default: return ""
        }
    }

    private func runChecklist() async {
        phase = .checking
        nodeState = .pending
        mothxState = .pending
        log = ""

        async let nodeVersionResult = EnvironmentCheckSheet.detectNodeVersion()
        async let mothxInstalledResult = MothxServiceManager.isMothxInstalled()
        let (nodeVersion, mothxInstalled) = await (nodeVersionResult, mothxInstalledResult)
        nodeState = nodeVersion != nil ? .passed : .failed
        mothxState = mothxInstalled ? .passed : .failed

        guard nodeVersion != nil else {
            phase = .nodeMissing(hasBrew: await EnvironmentCheckSheet.commandExists("brew"))
            return
        }

        guard mothxInstalled else {
            await installMothx()
            return
        }

        await proceedNowThatChecksPassed()
    }

    private func installNodeViaBrew() async {
        phase = .installingBrewNode
        log = ""
        let exitCode = await EnvironmentCheckSheet.runShellStreaming("brew install node") { chunk in
            log += chunk
        }
        guard exitCode == 0 else {
            phase = .failed(languageStore.copy.installBrewFailedPrefix(exitCode))
            return
        }
        let nodeVersion = await EnvironmentCheckSheet.detectNodeVersion()
        nodeState = nodeVersion != nil ? .passed : .failed
        guard nodeVersion != nil else {
            phase = .failed(languageStore.copy.installNodeMissingMessage)
            return
        }
        await installMothx()
    }

    private func installMothx() async {
        phase = .installingMothx
        log = ""
        let exitCode = await EnvironmentCheckSheet.runShellStreaming("npm install -g mothx-installer") { chunk in
            log += chunk
        }
        guard exitCode == 0 else {
            mothxState = .failed
            phase = .failed(languageStore.copy.installMothxFailedPrefix(exitCode))
            return
        }
        let installed = await MothxServiceManager.isMothxInstalled()
        mothxState = installed ? .passed : .failed
        guard installed else {
            phase = .failed(languageStore.copy.installStillNotFoundAfterInstall)
            return
        }
        await proceedNowThatChecksPassed()
    }

    private func proceedNowThatChecksPassed() async {
        phase = .allPassed
        try? await Task.sleep(for: .seconds(2))
        phase = .connecting
        await mothx.connectAtLaunch()
        languageStore.update(setting: mothx.tuilang)
        await mothx.loadWorkspace()
        if mothx.workspaceSyncState == .passed {
            phase = .allPassed
            try? await Task.sleep(for: .seconds(2))
            isPresented = false
        } else {
            phase = .failed(languageStore.copy.envCheckSyncFailed)
        }
    }

    private static func commandExists(_ command: String) async -> Bool {
        let result = await runShell("command -v \(command)")
        return result.exitCode == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func detectNodeVersion() async -> String? {
        let result = await runShell("node --version")
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `command` in an interactive login shell (so nvm/homebrew PATH
    /// entries are honored) and returns its combined stdout+stderr output
    /// and exit code.
    private static func runShell(_ command: String) async -> (output: String, exitCode: Int32) {
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
