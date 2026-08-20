import SwiftUI

struct TextMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: MothxMessage
    let isCurrentRunning: Bool

    private var isUser: Bool { message.isUser }

    @State private var displayedCharCount = 0
    @State private var typewriterTimer: Timer?
    @State private var blinkOpacity: Double = 1.0

    private var displayText: String {
        if isCurrentRunning { return String(message.displayText.prefix(displayedCharCount)) }
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
            if isCurrentRunning && !message.displayText.isEmpty { startTypewriter() }
            else { displayedCharCount = message.displayText.count }
        }
        .onChange(of: message.displayText) { _, newText in
            // When running, let the typewriter timer naturally catch up.
            // Only jump to end when not running or when the run is done.
            if !isCurrentRunning {
                displayedCharCount = newText.count
            }
        }
        .onDisappear { typewriterTimer?.invalidate(); typewriterTimer = nil }
    }

    private var isTyping: Bool { isCurrentRunning && displayedCharCount < message.displayText.count }

    private func startTypewriter() {
        displayedCharCount = 0
        typewriterTimer?.invalidate()
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            let fullText = message.displayText
            if displayedCharCount < fullText.count { displayedCharCount += 1 }
            else { timer.invalidate(); typewriterTimer = nil }
        }
        withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blinkOpacity = 0.0 }
    }

    private var assistantBackground: Color { colorScheme == .light ? .white : .codexCard }
    private var userBackground: Color { colorScheme == .light ? Color(red: 0.94, green: 0.94, blue: 0.95) : Color.orange.opacity(0.18) }
}