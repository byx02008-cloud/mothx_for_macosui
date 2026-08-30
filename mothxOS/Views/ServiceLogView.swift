import SwiftUI

struct ServiceLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(languageStore.copy.serviceLogTitle, systemImage: "doc.text.magnifyingglass")
                    .font(.title2.bold())
                Spacer()
                Button("复制日志路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(RuntimeLog.shared.fileURL.path, forType: .string)
                }
                .font(.caption)
                .help(RuntimeLog.shared.fileURL.path)
                Button(languageStore.copy.close) { dismiss() }
            }

            Text("客户端诊断日志：\(RuntimeLog.shared.fileURL.path)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if mothx.serviceLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(languageStore.copy.noServiceLog, systemImage: "doc.text")
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
