import SwiftUI

struct TextMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: MothxMessage
    let isCurrentRunning: Bool

    private var isUser: Bool { message.isUser }

    @State private var displayedCharCount = 0
    @State private var typewriterTimer: Timer?
    @State private var blinkOpacity: Double = 1.0
    // Tracks the latest known text while running; the Timer closure reads
    // this @State (stable storage) instead of `message` (a frozen value-type
    // snapshot from whenever the closure was created), so newly polled
    // content keeps getting typed out instead of appearing in one jump.
    @State private var typingTarget: String = ""

    private var displayText: String {
        if isCurrentRunning { return String(typingTarget.prefix(displayedCharCount)) }
        return message.displayText
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            HStack(alignment: .top, spacing: 10) {
                if !isUser { Image("MothxLogo").resizable().scaledToFit().frame(width: 18, height: 18) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayText.isEmpty ? (isUser ? "…" : "Thinking…") : displayText)
                        .textSelection(.enabled).frame(maxWidth: 560, alignment: .leading)
                    if isTyping {
                        Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 8, height: 16)
                            .opacity(blinkOpacity).padding(.leading, 2).padding(.top, -16)
                    }
                }
                if isUser { Image(systemName: "person.circle").foregroundStyle(Color.secondary) }
            }
            .padding(14)
            .background(isUser ? userBackground : assistantBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onAppear {
            if isCurrentRunning && !message.displayText.isEmpty {
                typingTarget = message.displayText
                startTypewriter()
            } else {
                displayedCharCount = message.displayText.count
            }
        }
        .onChange(of: message.displayText) { _, newText in
            if isCurrentRunning {
                // New content arrived from polling — extend the typing
                // target and keep (or restart) the timer so it keeps
                // catching up smoothly instead of stalling.
                typingTarget = newText
                if typewriterTimer == nil { startTypewriter(resetProgress: false) }
            } else {
                typewriterTimer?.invalidate(); typewriterTimer = nil
                displayedCharCount = newText.count
            }
        }
        .onChange(of: isCurrentRunning) { _, running in
            if !running {
                // Run finished (or its grace period ended) — stop and show
                // whatever text remains in full rather than freezing mid-type.
                typewriterTimer?.invalidate(); typewriterTimer = nil
                displayedCharCount = message.displayText.count
            }
        }
        .onDisappear { typewriterTimer?.invalidate(); typewriterTimer = nil }
    }

    private var isTyping: Bool { isCurrentRunning && displayedCharCount < typingTarget.count }

    private func startTypewriter(resetProgress: Bool = true) {
        if resetProgress { displayedCharCount = 0 }
        typewriterTimer?.invalidate()
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if displayedCharCount < typingTarget.count {
                displayedCharCount += 1
            }
            // Don't invalidate on catching up — more text may still arrive
            // from the next poll while the run is in progress; onDisappear
            // and the isCurrentRunning onChange handle teardown instead.
        }
        withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blinkOpacity = 0.0 }
    }

    private var assistantBackground: Color { colorScheme == .light ? .white : .codexCard }
    private var userBackground: Color { colorScheme == .light ? Color(red: 0.94, green: 0.94, blue: 0.95) : Color.orange.opacity(0.18) }
}