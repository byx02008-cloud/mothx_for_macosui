//
//  TerminalSessionStore.swift
//  mothxOS
//
//  Created by YangDongFeng on 2026/8/23.
//

import Combine
import SwiftTerm
import SwiftUI

/// Owns the state of the embedded mothx TUI terminal panel at the bottom of
/// the workspace. A session's TUI keeps running until the panel is closed;
/// closing the panel terminates the child process.
final class TerminalSessionStore: ObservableObject {
    @Published var isOpen = false
    @Published var sessionID: String?
    @Published var workDir: String = ""
    /// Set when the TUI process exits; the panel header shows the exit code.
    @Published var exitCode: Int32?

    /// Weak reference to the live terminal view so `close()` can terminate
    /// the child process deterministically instead of relying on deallocation.
    private weak var terminal: LocalProcessTerminalView?

    /// Opens the mothx TUI for `sessionID`. Reopening the same session is a
    /// no-op for the process; switching to a different session terminates the
    /// previous TUI process first.
    func open(sessionID: String, workDir: String) {
        if isOpen, self.sessionID == sessionID {
            self.workDir = workDir
            return
        }
        if isOpen {
            terminal?.terminate()
        }
        terminal = nil
        self.sessionID = sessionID
        self.workDir = workDir
        exitCode = nil
        isOpen = true
    }

    /// Registers the live terminal view created by the panel.
    func attach(_ terminal: LocalProcessTerminalView) {
        self.terminal = terminal
    }

    /// Closes the panel and terminates the child process (SIGTERM via the
    /// PTY), so a closed panel never leaves an orphaned mothx TUI behind.
    func close() {
        terminal?.terminate()
        terminal = nil
        isOpen = false
        sessionID = nil
        workDir = ""
        exitCode = nil
    }

    func markTerminated(exitCode: Int32?) {
        self.exitCode = exitCode
    }
}