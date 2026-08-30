import AppKit
import PDFKit
import SwiftUI

struct ChangeSummaryCard: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let changes: MothxTurnChanges
    let onReview: () -> Void
    let onPreview: () -> Void

    var body: some View {
        let c = languageStore.copy
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.filesChanged(changes.files.count))
                        .font(.system(size: 15, weight: .semibold))
                    if changes.files.contains(where: \.isReviewable) {
                        Button {
                            onReview()
                        } label: {
                            Label(c.viewChanges, systemImage: "arrow.up.right")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else if !changes.files.isEmpty {
                        Button {
                            onPreview()
                        } label: {
                            Label(c.preview, systemImage: "eye")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Text("+\(changes.added)").foregroundStyle(.green)
                        Text("-\(changes.deleted)").foregroundStyle(.red)
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
                Spacer()
                if changes.files.contains(where: \.isReviewable) {
                    Button(c.reviewChanges, action: onReview)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                } else if !changes.files.isEmpty {
                    Button(c.preview, action: onPreview)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            ForEach(changes.files) { file in
                HStack(spacing: 6) {
                    Text(file.path)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text("+\(file.added)").foregroundStyle(.green)
                    Text("-\(file.deleted)").foregroundStyle(.red)
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 6)
    }
}

struct ChangeReviewSidebar: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let changes: MothxTurnChanges
    let workDirectory: String
    let initialPath: String?
    let onClose: () -> Void
    @State private var selectedPath: String?

    private var selectedFile: MothxFileChange? {
        changes.files.first { $0.path == (selectedPath ?? changes.files.first?.path) }
    }

    private var fileListHeight: CGFloat {
        // Keep the list compact for small changes, while reserving space for
        // at most four rows. List remains scrollable when there are more.
        let rowCount = min(max(changes.files.count, 1), 4)
        return CGFloat(rowCount) * 64 + 12
    }

    var body: some View {
        let c = languageStore.copy
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(changes.files.contains(where: \.isReviewable) ? c.reviewChanges : c.preview)
                        .font(.headline)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("收起审核栏")
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()

            HStack {
                Text(changes.files.contains(where: \.isReviewable) ? c.viewChanges : c.preview)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("+\(changes.added)  -\(changes.deleted)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            List(changes.files, selection: $selectedPath) { file in
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.path).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(file.kindLabel(using: c)).foregroundStyle(.secondary)
                        Text("+\(file.added)").foregroundStyle(.green)
                        Text("-\(file.deleted)").foregroundStyle(.red)
                    }
                    .font(.caption.monospacedDigit())
                }
                .tag(file.path)
                .padding(.vertical, 3)
            }
            .frame(height: fileListHeight)

            Divider()
            if let file = selectedFile {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(file.path).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        if file.isReviewable {
                            if file.truncated { Text(c.diffTooLarge).font(.caption).foregroundStyle(.orange) }
                        } else {
                            Text("当前文件预览")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    if file.isReviewable {
                        ScrollView([.vertical, .horizontal]) {
                            if file.truncated {
                                Text(file.unifiedDiff).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(file.unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, rawLine in
                                        let line = String(rawLine)
                                        Text(line)
                                            .foregroundStyle(line.hasPrefix("+ ") ? .green : (line.hasPrefix("- ") ? .red : .secondary))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 1)
                                            .background(line.hasPrefix("+ ") ? Color.green.opacity(0.10) : (line.hasPrefix("- ") ? Color.red.opacity(0.10) : Color.clear))
                                    }
                                }
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    } else if let url = currentFileURL(for: file) {
                        FilePreviewView(url: url)
                    } else {
                        ContentUnavailableView("文件不存在", systemImage: "doc.questionmark", description: Text(file.path))
                    }
                }
                .padding(14)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { selectedPath = selectedPath ?? initialPath ?? changes.files.first?.path }
        .onChange(of: changes.id) { _, _ in selectedPath = changes.files.first?.path }
    }

    private func currentFileURL(for file: MothxFileChange) -> URL? {
        guard !workDirectory.isEmpty else { return nil }
        let root = URL(fileURLWithPath: workDirectory).standardizedFileURL
        let url = (file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : root.appendingPathComponent(file.path)).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

private struct FilePreviewView: View {
    let url: URL

    var body: some View {
        let ext = url.pathExtension.lowercased()
        Group {
            if ext == "pdf" {
                PDFPreviewView(url: url)
            } else if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(ext),
                      let image = NSImage(contentsOf: url) {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                ScrollView([.vertical, .horizontal]) {
                    if ["md", "markdown", "mdown"].contains(ext),
                       let markdown = try? AttributedString(markdown: text) {
                        Text(markdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ContentUnavailableView("无法预览文件", systemImage: "doc", description: Text(url.lastPathComponent))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

struct SkillPreviewSidebar: View {
    let skill: MothxSkill
    let onClose: () -> Void

    private var skillDocumentURL: URL? {
        guard !skill.directory.isEmpty else { return nil }
        return URL(fileURLWithPath: skill.directory).appendingPathComponent("SKILL.md")
    }

    private var skillText: String? {
        guard let url = skillDocumentURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("技能")
                        .font(.headline)
                    Text(skill.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("收起右侧栏")
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()
            if let skillText {
                ScrollView([.vertical, .horizontal]) {
                    if let markdown = try? AttributedString(markdown: skillText) {
                        Text(markdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(skillText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            } else {
                ContentUnavailableView("技能信息不可用", systemImage: "doc.questionmark", description: Text(skill.directory.isEmpty ? skill.name : skill.directory))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct ToolDetailSidebar: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    let sessionID: String
    let item: ToolInvocationSummary
    let onClose: () -> Void
    @State private var detail: MothxToolResultDetail?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolDisplayName(item.toolName, language: mothx.languageStore?.language ?? .zh))
                        .font(.headline)
                    if !item.argumentsPreview.isEmpty {
                        Text(item.argumentsPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("收起右侧栏")
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail {
                ScrollView([.vertical, .horizontal]) {
                    Text(detail.content)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            } else {
                ContentUnavailableView("内容不可用", systemImage: "doc.questionmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: item.id) {
            isLoading = true
            detail = await mothx.loadToolResultDetail(sessionID: sessionID, toolCallID: item.id)
            isLoading = false
        }
    }
}

private extension MothxFileChange {
    func kindLabel(using copy: Copy) -> String {
        switch kind {
        case .created: return copy.fileCreated
        case .modified: return copy.fileModified
        case .deleted: return copy.fileDeleted
        }
    }
}
