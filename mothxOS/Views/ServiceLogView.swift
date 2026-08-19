import SwiftUI

struct ServiceLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mothx: MothxServiceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("运行日志", systemImage: "doc.text.magnifyingglass")
                    .font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
            }

            if mothx.serviceLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("暂无运行日志", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(mothx.serviceLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
    }
}
