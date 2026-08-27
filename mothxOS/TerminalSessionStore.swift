//
//  TerminalSessionStore.swift
//  mothxOS
//
//  Created by YangDongFeng on 2026/8/23.
//

import Combine
import SwiftTerm
import SwiftUI

/// Owns embedded TUI terminals by session. Switching sessions detaches the
/// visible terminal but keeps each session's PTY/process alive. Only an
/// explicit close of the current TUI terminates that session's process.
final class TerminalSessionStore: ObservableObject {
    @Published var isOpen = false
    @Published var sessionID: String?
    @Published var workDir: String = ""
    /// Set when the TUI process exits; the panel header shows the exit code.
    @Published var exitCode: Int32?

    private var terminals: [String: LocalProcessTerminalView] = [:]
    private var startedSessionIDs: Set<String> = []
    private var exitCodes: [String: Int32] = [:]

    /// Opens the TUI for a session. Switching sessions only changes which
    /// retained terminal view is displayed; it does not terminate the old PTY.
    func open(sessionID: String, workDir: String) {
        if isOpen, self.sessionID == sessionID {
            self.workDir = workDir
            exitCode = exitCodes[sessionID]
            return
        }
        self.sessionID = sessionID
        self.workDir = workDir
        exitCode = exitCodes[sessionID]
        isOpen = true
    }

    func terminal(for sessionID: String) -> LocalProcessTerminalView {
        if let terminal = terminals[sessionID] { return terminal }
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminals[sessionID] = terminal
        return terminal
    }

    /// True when this session already has a retained TUI terminal. A retained
    /// terminal can be reattached without stopping its Run.
    func hasTerminal(sessionID: String) -> Bool {
        terminals[sessionID] != nil
    }

    func hasStarted(sessionID: String) -> Bool {
        startedSessionIDs.contains(sessionID)
    }

    func markStarting(sessionID: String) {
        startedSessionIDs.insert(sessionID)
    }

    func isRunning(sessionID: String) -> Bool {
        terminals[sessionID]?.process?.running == true
    }

    /// Explicitly closes the current TUI and terminates only its child process.
    func close() {
        if let sessionID, let terminal = terminals[sessionID] {
            terminal.terminate()
            terminals.removeValue(forKey: sessionID)
            startedSessionIDs.remove(sessionID)
            exitCodes.removeValue(forKey: sessionID)
        }
        isOpen = false
        sessionID = nil
        workDir = ""
        exitCode = nil
    }

    /// Detaches the visible terminal without terminating its TUI process.
    /// The process and terminal view remain retained for later reattachment.
    func detach() {
        isOpen = false
        sessionID = nil
        workDir = ""
        exitCode = nil
    }

    func markTerminated(sessionID: String, exitCode: Int32?) {
        guard !sessionID.isEmpty else { return }
        exitCodes[sessionID] = exitCode
        startedSessionIDs.insert(sessionID)
        if self.sessionID == sessionID {
            self.exitCode = exitCode
        }
    }
}
