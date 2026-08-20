import SwiftUI

/// Thinking indicator: 3 dots breathing sequentially when the agent is thinking.
struct ThinkingIndicator: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let isActive: Bool

    var body: some View {
        if isActive {
            HStack(spacing: 10) {
                Image("MothxLogo")
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)

                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 5, height: 5)
                            .scaleEffect(dotScales[index])
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever()
                                    .delay(Double(index) * 0.3),
                                value: dotScales[index]
                            )
                    }
                }

                Text(languageStore.copy.thinking)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .onAppear {
                for i in 0..<3 {
                    dotScales[i] = 1.5
                }
            }
            .onDisappear {
                for i in 0..<3 {
                    dotScales[i] = 1.0
                }
            }
        }
    }

    @State private var dotScales: [CGFloat] = [1.0, 1.0, 1.0]
}