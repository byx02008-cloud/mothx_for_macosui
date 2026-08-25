import AppKit
import SwiftUI

/// Helpers shared by the About section's update flow and the launch-time
/// update prompt in ContentView.
enum UpdateFlowSupport {
    /// The progress-sheet log line for a stage transition, or "" when the
    /// stage doesn't carry a step log line.
    static func stageLogLine(_ stage: MothxUpdateStage, c: Copy) -> String {
        switch stage {
        case .stoppingService: return c.updateLogStoppingService
        case .installing: return c.updateLogRunningNpmInstall
        case .restartingService: return c.updateLogRestartingService
        default: return ""
        }
    }

    /// The terminal sheet stage for an update outcome.
    static func terminalStage(for result: MothxUpdateResult) -> MothxUpdateStage {
        switch result {
        case .succeeded: return .succeeded
        case .needsAdmin, .canceled: return .needsAdmin
        case .failed: return .failed
        }
    }
}

struct UpdateProgressSheet: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let stage: MothxUpdateStage
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