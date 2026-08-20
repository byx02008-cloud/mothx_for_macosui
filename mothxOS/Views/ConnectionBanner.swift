import SwiftUI

struct ConnectionBanner: View {
    let state: MothxServiceManager.State

    var body: some View {
        Group {
            switch state {
            case .checking: status("Checking mothx server…", .orange)
            case .starting: status("Starting mothx server…", .orange)
            case .failed(let message): status(message, .red)
            case .connected: EmptyView()
            case .needsInstall: status("mothx not found — please reinstall", .red)
            }
        }.padding(.top, 8)
    }

    private func status(_ title: String, _ color: Color) -> some View {
        Label(title, systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.codexCard)
            .clipShape(Capsule())
            .shadow(radius: 8)
    }
}
