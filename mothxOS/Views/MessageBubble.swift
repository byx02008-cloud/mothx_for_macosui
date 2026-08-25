import SwiftUI

/// Simple message bubble for user and assistant text messages.
/// Tool calls and tool results are rendered in the process block (TurnBlock).
struct MessageBubble: View {
    let message: MothxMessage
    let isCurrentRunning: Bool
    var onFork: (() -> Void)? = nil
    var isForking = false

    var body: some View {
        TextMessageBubble(message: message, isCurrentRunning: isCurrentRunning, onFork: onFork, isForking: isForking)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
