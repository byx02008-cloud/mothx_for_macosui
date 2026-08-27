//
//  TerminalPanelView.swift
//  mothxOS
//
//  Created by YangDongFeng on 2026/8/23.
//

import SwiftTerm
import SwiftUI

/// Embeds the mothx TUI in a real VT100 terminal (SwiftTerm) running inside a
/// PTY. The process is started once per opened session: `mothx -r <sessionID>`
/// from the session's working directory, with the login shell environment so
/// PATH and provider API key references resolve exactly as in a Terminal.
struct TerminalPanelView: NSViewRepresentable {
    @ObservedObject var store: TerminalSessionStore
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, sessionID: store.sessionID)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = store.terminal(for: context.coordinator.sessionID ?? "")
        terminal.processDelegate = context.coordinator
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // The caret must stay visible regardless of keyboard focus: SwiftTerm's
        // macOS TerminalView only becomes first responder in a few paths, and
        // with `tracksFocus` on the cursor is not drawn at all when unfocused.
        terminal.caretViewTracksFocus = false
        context.coordinator.installShiftEnterMonitor(terminal: terminal)
        context.coordinator.installFocusHandling(terminal: terminal)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        applyAppearance(nsView, context: context)
        guard !context.coordinator.hasStarted, store.isOpen else { return }
        context.coordinator.hasStarted = true
        guard let sessionID = store.sessionID else { return }
        guard !store.hasStarted(sessionID: sessionID) else { return }
        store.markStarting(sessionID: sessionID)
        Task { @MainActor in
            // The panel may have been closed (or switched to another session)
            // while the executable/environment resolution was in flight; do
            // not start a process for a panel that is no longer current.
            guard store.isOpen, store.sessionID == sessionID else { return }
            guard let executable = await MothxServiceManager.resolveGlobalMothxExecutable() else {
                store.markTerminated(sessionID: sessionID, exitCode: 127)
                return
            }
            let environment = await Self.terminalEnvironment()
            nsView.startProcess(
                executable: executable.path,
                args: ["-r", sessionID],
                environment: environment.isEmpty ? nil : environment,
                currentDirectory: store.workDir.isEmpty ? nil : store.workDir
            )
        }
    }

    /// The login-shell environment is needed for PATH and provider secrets,
    /// but it is not necessarily a terminal environment when the app was
    /// launched by LaunchServices. In particular, GUI/test environments often
    /// carry TERM=dumb or NO_COLOR=1; passing those through makes Lipgloss
    /// strip the ANSI styles that mothx uses for its input cursor and
    /// autocomplete selection. Keep the full environment, then normalize only
    /// terminal/color-related variables for the embedded PTY.
    private static func terminalEnvironment() async -> [String] {
        var environment = await MothxServiceManager.loginShellEnvironment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment.removeValue(forKey: "NO_COLOR")
        environment.removeValue(forKey: "CLICOLOR")
        environment.removeValue(forKey: "CLICOLOR_FORCE")
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// Light mode: white background with dark text; dark mode keeps the classic
    /// black background with light text. Applied whenever the effective color
    /// scheme changes; the mothx TUI renders with these defaults.
    private func applyAppearance(_ terminal: LocalProcessTerminalView, context: Context) {
        guard colorScheme != context.coordinator.lastScheme else { return }
        context.coordinator.lastScheme = colorScheme
        switch colorScheme {
        case .dark:
            terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.0, alpha: 1)
            terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
            terminal.installColors(SwiftTerm.Color.terminalAppColors)
            terminal.ansi256PaletteStrategy = .base16Lab
        case .light:
            terminal.nativeBackgroundColor = NSColor(calibratedWhite: 1.0, alpha: 1)
            terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
            // mothx uses ANSI 15 for assistant/history text. SwiftTerm's
            // default ANSI 15 is bright white, which is readable on the
            // dark terminal but nearly disappears against a light background.
            // Keep the service's ANSI output unchanged and remap only this
            // presentation color in the host app.
            var lightPalette = SwiftTerm.Color.terminalAppColors
            lightPalette[15] = SwiftTerm.Color(red8: 32, green8: 32, blue8: 32)
            terminal.installColors(lightPalette)
            // mothx draws its input cursor by reversing a cell whose ANSI
            // background is color 236. On a light host, the normal base16Lab
            // palette puts that grayscale ramp too close to the dark default
            // foreground, making the reversed cell hard to distinguish. The
            // harmonious palette keeps the ramp light on light backgrounds,
            // so the cursor's dark reversed cell has clear contrast.
            terminal.ansi256PaletteStrategy = .base16LabHarmonious
        @unknown default:
            break
        }
    }

    final class Coordinator: LocalProcessTerminalViewDelegate {
        let store: TerminalSessionStore
        /// Session this coordinator's terminal was created for. Termination
        /// callbacks from a superseded process must not overwrite the state
        /// of a newer session's terminal.
        let sessionID: String?
        var hasStarted = false
        /// Last color scheme applied to the terminal's default colors.
        var lastScheme: ColorScheme?

        init(store: TerminalSessionStore, sessionID: String?) {
            self.store = store
            self.sessionID = sessionID
        }

        private var shiftEnterMonitor: Any?
        private var focusMonitor: Any?

        /// macOS does not deliver Shift+Enter to terminals: SwiftTerm's
        /// `doCommand` only handles `insertNewline:` (which sends CR) and has
        /// no `insertLineBreak:` branch, so the keystroke is swallowed there.
        /// This local event monitor maps Shift+Enter to a Line Feed (^J) — the
        /// mothx TUI's documented Ctrl+J newline shortcut — while the terminal
        /// has keyboard focus. Plain Enter keeps sending CR (submit).
        func installShiftEnterMonitor(terminal: LocalProcessTerminalView) {
            shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak terminal] event in
                guard let terminal else { return event }
                let responder = NSApp.keyWindow?.firstResponder as? NSView
                guard let responder, responder.isDescendant(of: terminal) else { return event }
                // macOS key codes: 36 = Return, 76 = keypad Enter.
                guard [36, 76].contains(event.keyCode),
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.shift] else { return event }
                terminal.send(txt: "\n")
                return nil
            }
        }

        /// SwiftTerm's macOS TerminalView only grabs first responder in a few
        /// paths (e.g. after the find bar closes); mouseDown and viewDidMoveToWindow
        /// do not. Without focus, `hasFocus` stays false and the caret is not
        /// drawn (MacCaretView renders its cursor only when focused). This makes
        /// the terminal first responder when the panel appears and on any click
        /// inside it, so the TUI cursor is visible and typing works immediately.
        func installFocusHandling(terminal: LocalProcessTerminalView) {
            // The view may not be attached to a window yet during makeNSView;
            // retry once layout is done.
            DispatchQueue.main.async {
                terminal.window?.makeFirstResponder(terminal)
            }
            focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak terminal] event in
                guard let terminal, let window = terminal.window, event.window === window else { return event }
                let point = terminal.convert(event.locationInWindow, from: nil)
                if terminal.bounds.contains(point) {
                    window.makeFirstResponder(terminal)
                }
                return event
            }
        }

        deinit {
            if let shiftEnterMonitor {
                NSEvent.removeMonitor(shiftEnterMonitor)
            }
            if let focusMonitor {
                NSEvent.removeMonitor(focusMonitor)
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            // Record termination for the owning session even when its terminal
            // is detached because another session is currently visible.
            guard store.sessionID == sessionID else { return }
            store.markTerminated(sessionID: sessionID ?? "", exitCode: exitCode)
        }
    }
}
/// Slim header bar for the TUI terminal panel: working directory, exit status
/// when the process has ended, and a close control.
struct TUIPanelHeader: View {
    @ObservedObject var store: TerminalSessionStore
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore

    var body: some View {
        let c = languageStore.copy
        return HStack(spacing: 8) {
            Image(systemName: "terminal.fill").font(.caption2).foregroundStyle(.secondary)
            Text(c.terminal).font(.caption).foregroundStyle(.secondary)
            Text(store.workDir)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let exitCode = store.exitCode {
                Text(c.terminalExited(exitCode)).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button {
                guard let sessionID = store.sessionID else {
                    store.close()
                    return
                }
                Task { @MainActor in
                    // The TUI process remains alive while idle, so process
                    // liveness is not sufficient to decide whether closing
                    // it would stop an Agent Run.
                    let activeRun = await mothx.sessionHasActiveRun(sessionID)
                    mothx.requestModeSwitch(
                        isRunning: activeRun,
                        continueAction: { store.detach() },
                        { store.close() }
                    )
                }
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help(c.terminalCloseHelp)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.codexSidebar.opacity(0.5))
    }
}
