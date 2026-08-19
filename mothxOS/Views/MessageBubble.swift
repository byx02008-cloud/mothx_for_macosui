import SwiftUI

struct MessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: MothxMessage
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            HStack(alignment: .top, spacing: 10) {
                if !isUser { Image("MothxLogo").resizable().scaledToFit().frame(width: 18, height: 18) }
                Text(message.content.isEmpty ? (isUser ? "…" : "Thinking…") : message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
                if isUser { Image(systemName: "person.circle").foregroundStyle(Color.secondary) }
            }
            .padding(14)
            .background(isUser ? userBackground : assistantBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .id(message.id)
    }

    private var assistantBackground: Color {
        colorScheme == .light ? .white : .codexCard
    }

    private var userBackground: Color {
        colorScheme == .light ? Color(red: 0.94, green: 0.94, blue: 0.95) : Color.orange.opacity(0.18)
    }
}
