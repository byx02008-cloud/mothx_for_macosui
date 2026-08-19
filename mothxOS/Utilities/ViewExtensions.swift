import SwiftUI

struct HoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
    }
}

extension View {
    func sectionLabel() -> some View { font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(1.1) }
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

extension Color {
    static let codexBackground = Color(nsColor: .windowBackgroundColor)
    static let codexSidebar = Color(nsColor: .controlBackgroundColor)
    static let codexCard = Color(nsColor: .underPageBackgroundColor)
}
