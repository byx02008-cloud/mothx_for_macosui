import AppKit
import PDFKit
import SwiftUI

struct EmptyPreviewSidebar: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.viewfinder")
                    .foregroundStyle(.secondary)
                Text(languageStore.copy.preview)
                    .font(.headline)
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
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(languageStore.copy.noPreviewInfo)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(languageStore.copy.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct ChangeSummaryCard: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let changes: MothxTurnChanges
    let onReview: () -> Void
    let onPreview: () -> Void

    /// A turn can mix exact (before/after) diffs with preview-only summaries.
    /// If any file only has an approximate server count, the aggregate cannot
    /// be trusted, so it is suppressed instead of shown as if precise.
    private var countsAreApproximate: Bool {
        changes.files.contains { $0.countsAreApproximate }
    }

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
                    DiffStatView(
                        added: changes.added,
                        deleted: changes.deleted,
                        approximate: countsAreApproximate,
                        font: .system(size: 12, weight: .medium).monospacedDigit(),
                        unavailableLabel: c.text("行数不可用", "counts n/a")
                    )
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
                    DiffStatView(
                        added: file.added,
                        deleted: file.deleted,
                        approximate: file.countsAreApproximate,
                        font: .system(size: 12, weight: .medium).monospacedDigit(),
                        unavailableLabel: c.text("行数不可用", "counts n/a")
                    )
                }
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

// MARK: - Async detail loading

enum DiffLineKind: Hashable {
    case context, added, deleted
}

struct DiffLine: Identifiable, Hashable {
    let index: Int
    let text: String
    let kind: DiffLineKind
    var id: Int { index }
}

/// Turns a unified-diff string into colored lines.
nonisolated private func makeDiffLines(_ unifiedDiff: String) -> [DiffLine] {
    MothxDiffBuilder.normalizedNewlines(unifiedDiff)
        .split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { offset, raw in
        let line = String(raw)
        let kind: DiffLineKind = line.hasPrefix("+ ") ? .added : (line.hasPrefix("- ") ? .deleted : .context)
        return DiffLine(index: offset, text: line, kind: kind)
    }
}

/// Turns a plain text blob into context lines (truncated before/after views
/// and plain-text file previews).
nonisolated private func makePlainLines(_ text: String) -> [DiffLine] {
    MothxDiffBuilder.normalizedNewlines(text)
        .split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
        DiffLine(index: $0.offset, text: String($0.element), kind: .context)
    }
}

/// Renders the green `+added` / red `-deleted` convention. When the counts are
/// only a server-side approximation for a very large file (mothx reports the
/// whole file as changed) or could not be resolved, they are suppressed rather
/// than shown as if they were exact.
private struct DiffStatView: View {
    let added: Int
    let deleted: Int
    let approximate: Bool
    let font: Font
    let unavailableLabel: String

    var body: some View {
        if approximate {
            Text(unavailableLabel)
                .font(font)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 5) {
                Text("+\(added)").foregroundStyle(.green)
                Text("-\(deleted)").foregroundStyle(.red)
            }
            .font(font)
        }
    }
}

/// Renders a potentially huge list of lines without blocking the main thread:
/// only the first page is materialized as views, with a one-click "show all"
/// escape hatch for genuinely enormous files.
private struct ChunkedLinesView: View {
    let lines: [DiffLine]
    @State private var showAll = false

    var body: some View {
        let visible = showAll ? lines : Array(lines.prefix(1000))
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text("（空）")
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
            ForEach(visible) { line in
                Text(line.text)
                    .foregroundStyle(line.kind == .added ? Color.green : (line.kind == .deleted ? Color.red : .secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(line.kind == .added ? Color.green.opacity(0.10) : (line.kind == .deleted ? Color.red.opacity(0.10) : Color.clear))
            }
            if !showAll && lines.count > 1000 {
                Button {
                    showAll = true
                } label: {
                    Text("显示全部 \(lines.count) 行 / Show all \(lines.count) lines")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum ChangeDetailContent {
    case loading
    case diff([DiffLine])
    case beforeAfter(before: [DiffLine], after: [DiffLine])
    case image(NSImage)
    case pdf(URL)
    case text([DiffLine])
    case markdown(AttributedString)
    case missing
}

/// Bounded in-memory cache for prepared change/preview content.
///
/// Keys embed the file's size + modification time for on-disk previews, so a
/// file edited after a run (or still being written) never surfaces stale
/// content: the key simply stops matching and the next preview recomputes.
/// Reviewable diffs are keyed by turn+path because their before/after content
/// is a fixed snapshot captured when the change arrived. Entries are capped by
/// count and estimated bytes and evicted in LRU order, so decoded images and
/// megabyte line arrays cannot balloon memory.
nonisolated final class ChangePreviewCache: @unchecked Sendable {
    static let shared = ChangePreviewCache()

    private let lock = NSLock()
    private var entries: [String: ChangeDetailContent] = [:]
    private var lruOrder: [String] = []
    private var totalBytes = 0
    private let maxEntries = 48
    private let maxTotalBytes = 96 * 1024 * 1024
    /// Contents bigger than this are rendered but never cached, so one huge
    /// image or megabyte diff cannot evict everything else.
    private let maxEntryBytes = 24 * 1024 * 1024

    func value(for key: String) -> ChangeDetailContent? {
        lock.lock(); defer { lock.unlock() }
        guard let content = entries[key] else { return nil }
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
        return content
    }

    func store(_ content: ChangeDetailContent, for key: String) {
        lock.lock(); defer { lock.unlock() }
        let bytes = estimatedBytes(content)
        if entries[key] == nil && bytes > maxEntryBytes { return }
        if let old = entries.removeValue(forKey: key) {
            totalBytes -= estimatedBytes(old)
            lruOrder.removeAll { $0 == key }
        }
        entries[key] = content
        totalBytes += bytes
        lruOrder.append(key)
        evictIfNeeded()
    }

    /// Warms the cache for every file of one turn off the main thread, so
    /// clicking any file in the review sidebar hits the cache instead of
    /// recomputing (disk reads, markdown parsing, image decoding, diff
    /// splitting) on the spot.
    func prefetch(changes: MothxTurnChanges, workDirectory: String) {
        let files = changes.files
        let turnID = changes.id
        guard !files.isEmpty else { return }
        Task.detached(priority: .utility) {
            for file in files {
                _ = ChangeDetailLoader.prepareCached(file: file, workDirectory: workDirectory, turnID: turnID)
            }
        }
    }

    private func evictIfNeeded() {
        while (entries.count > maxEntries || totalBytes > maxTotalBytes), let oldest = lruOrder.first {
            if let old = entries.removeValue(forKey: oldest) {
                totalBytes -= estimatedBytes(old)
            }
            lruOrder.removeFirst()
        }
    }

    private func estimatedBytes(_ content: ChangeDetailContent) -> Int {
        func linesBytes(_ lines: [DiffLine]) -> Int {
            lines.reduce(0) { $0 + $1.text.utf8.count + 24 }
        }
        switch content {
        case .loading, .missing: return 0
        case .diff(let lines), .text(let lines): return linesBytes(lines)
        case .beforeAfter(let before, let after): return linesBytes(before) + linesBytes(after)
        case .image(let image):
            let width = max(1, Int(image.size.width))
            let height = max(1, Int(image.size.height))
            return width * height * 4
        case .pdf: return 4096
        case .markdown(let markdown): return markdown.characters.count * 2
        }
    }
}

/// All heavy work (file reads, markdown parsing, splitting huge strings) runs
/// off the main thread here so the sidebar shell can slide in immediately and
/// only swap in the real content when it is ready.
private enum ChangeDetailLoader {
    /// Stable identity of the prepared content.
    /// - Reviewable diffs: turn+path (before/after is a fixed snapshot).
    /// - On-disk previews: workDir+path+size+mtime, so edits invalidate.
    nonisolated static func cacheKey(file: MothxFileChange, workDirectory: String, turnID: String) -> String {
        if file.isReviewable {
            return "rev|\(turnID)|\(file.path)"
        }
        guard let url = safePreviewURL(path: file.path, workDirectory: workDirectory) else {
            return "pre|\(workDirectory)|\(file.path)|missing"
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "pre|\(workDirectory)|\(file.path)|\(size)|\(mtime)"
    }

    /// Cache-first variant used by the sidebar: returns the prepared content
    /// immediately when it was prefetched, otherwise computes and stores it.
    nonisolated static func prepareCached(file: MothxFileChange, workDirectory: String, turnID: String) -> ChangeDetailContent {
        let key = cacheKey(file: file, workDirectory: workDirectory, turnID: turnID)
        if let cached = ChangePreviewCache.shared.value(for: key) { return cached }
        let content = prepare(file: file, workDirectory: workDirectory)
        ChangePreviewCache.shared.store(content, for: key)
        return content
    }

    nonisolated static func prepare(file: MothxFileChange, workDirectory: String) -> ChangeDetailContent {
        if file.isReviewable {
            if file.truncated {
                return .beforeAfter(before: makePlainLines(file.oldText ?? ""), after: makePlainLines(file.newText ?? ""))
            }
            return .diff(makeDiffLines(file.unifiedDiff))
        }
        guard let url = safePreviewURL(path: file.path, workDirectory: workDirectory),
              FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf(url) }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(ext) {
            if let image = NSImage(contentsOf: url) { return .image(image) }
            return .missing
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .missing }
        if ["md", "markdown", "mdown"].contains(ext), text.count < 100_000,
           let markdown = try? AttributedString(markdown: text) {
            return .markdown(markdown)
        }
        return .text(makePlainLines(text))
    }

    nonisolated static func safePreviewURL(path: String, workDirectory: String) -> URL? {
        guard !workDirectory.isEmpty else { return nil }
        let root = URL(fileURLWithPath: workDirectory).standardizedFileURL
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath) else { return nil }
        return url
    }
}

/// The review/diff/preview pane of the sidebar. Shows a spinner while the
/// heavy content is prepared off-main, keeping the sidebar opening instant.
private struct ChangeDetailView: View {
    let file: MothxFileChange
    let workDirectory: String
    let turnID: String
    @State private var content: ChangeDetailContent = .loading

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .diff(let lines):
                ScrollView([.vertical, .horizontal]) {
                    ChunkedLinesView(lines: lines)
                        .font(.system(size: 12, design: .monospaced))
                }
                .textSelection(.enabled)
            case .beforeAfter(let before, let after):
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("修改前 / Before").font(.caption.weight(.semibold)).foregroundStyle(.red)
                        ChunkedLinesView(lines: before).font(.system(size: 12, design: .monospaced))
                        Divider()
                        Text("修改后 / After").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        ChunkedLinesView(lines: after).font(.system(size: 12, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
            case .image(let image):
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .pdf(let url):
                PDFPreviewView(url: url)
            case .text(let lines):
                ScrollView([.vertical, .horizontal]) {
                    ChunkedLinesView(lines: lines)
                        .font(.system(size: 12, design: .monospaced))
                }
                .textSelection(.enabled)
            case .markdown(let markdown):
                ScrollView([.vertical, .horizontal]) {
                    Text(markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
            case .missing:
                ContentUnavailableView("文件不存在", systemImage: "doc.questionmark", description: Text(file.path))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: file.id) {
            // Fast path: the content was already prefetched/loaded before, so
            // show it immediately instead of flashing a spinner.
            let key = ChangeDetailLoader.cacheKey(file: file, workDirectory: workDirectory, turnID: turnID)
            if let cached = ChangePreviewCache.shared.value(for: key) {
                content = cached
                return
            }
            content = .loading
            let prepared = await Task.detached(priority: .userInitiated) {
                ChangeDetailLoader.prepareCached(file: file, workDirectory: workDirectory, turnID: turnID)
            }.value
            guard !Task.isCancelled else { return }
            content = prepared
        }
        .id(file.path)
    }
}

/// Lightweight display row for the sidebar's file list. It carries only the
/// fields the rows actually draw (path/kind/stats) — never the megabyte
/// unifiedDiff/oldText/newText payloads — so the list can be projected off the
/// main thread without copying huge strings into the view hierarchy.
private nonisolated struct ReviewFileRow: Identifiable, Hashable {
    let path: String
    let kind: MothxFileChangeKind
    let added: Int
    let deleted: Int
    let isReviewable: Bool
    let truncated: Bool
    let countsAreApproximate: Bool
    var id: String { path }
}

struct ChangeReviewSidebar: View {
    @EnvironmentObject private var languageStore: LanguageStore
    let changes: MothxTurnChanges
    let workDirectory: String
    let initialPath: String?
    let onClose: () -> Void
    /// nil while the (potentially huge) change payload is being projected off
    /// the main thread. The shell pushes open instantly; the list fills in as
    /// soon as the light rows are ready.
    @State private var rows: [ReviewFileRow]? = nil
    @State private var selectedPath: String?

    private var selectedFile: MothxFileChange? {
        guard rows != nil else { return nil }
        guard let selectedPath else { return changes.files.first }
        return changes.files.first { $0.path == selectedPath }
    }

    private var fileListHeight: CGFloat {
        // Keep the list compact for small changes, while reserving space for
        // at most four rows. List remains scrollable when there are more.
        let rowCount = min(max(rows?.count ?? 1, 1), 4)
        return CGFloat(rowCount) * 64 + 12
    }

    /// Suppress the aggregate when any file only has an approximate count.
    private var countsAreApproximate: Bool {
        rows?.contains { $0.countsAreApproximate } ?? changes.files.contains { $0.countsAreApproximate }
    }

    var body: some View {
        let c = languageStore.copy
        let isReview = changes.files.contains(where: \.isReviewable)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isReview ? c.reviewChanges : c.preview)
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
                Text(isReview ? c.viewChanges : c.preview)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                DiffStatView(
                    added: changes.added,
                    deleted: changes.deleted,
                    approximate: countsAreApproximate,
                    font: .caption.monospacedDigit(),
                    unavailableLabel: c.text("行数不可用", "counts n/a")
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            if let rows {
                List(rows, selection: $selectedPath) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.path).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(file.kind.label(using: c)).foregroundStyle(.secondary)
                            DiffStatView(
                                added: file.added,
                                deleted: file.deleted,
                                approximate: file.countsAreApproximate,
                                font: .caption.monospacedDigit(),
                                unavailableLabel: c.text("行数不可用", "counts n/a")
                            )
                        }
                    }
                    .tag(file.path)
                    .padding(.vertical, 3)
                }
                .frame(height: fileListHeight)
            } else {
                // Stand-in with the exact list frame so nothing re-lays-out
                // when the rows arrive; the shell keeps its final size.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: fileListHeight)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            if rows != nil, let file = selectedFile {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(file.path).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        if file.isReviewable {
                            if file.truncated { Text(c.diffTooLarge).font(.caption).foregroundStyle(.orange) }
                        } else {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(c.text("当前文件预览", "Current file preview"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(c.text("服务端未提供修改前后内容，无法显示逐行增删",
                                            "No before/after from server; per-line markers unavailable"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Divider()
                    ChangeDetailView(file: file, workDirectory: workDirectory, turnID: changes.id)
                        .id(file.path)
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
        .task(id: changes.id) {
            // Header + shell render immediately; the file list is projected off
            // the main thread. Rows only carry light display fields, never the
            // huge diff payloads.
            rows = nil
            let files = changes.files
            let projected = await Task.detached(priority: .userInitiated) {
                files.map {
                    ReviewFileRow(path: $0.path, kind: $0.kind, added: $0.added, deleted: $0.deleted, isReviewable: $0.isReviewable, truncated: $0.truncated, countsAreApproximate: $0.countsAreApproximate)
                }
            }.value
            guard !Task.isCancelled else { return }
            rows = projected
            if selectedPath == nil { selectedPath = projected.first?.path }
            // Warm every file of this turn in the background while the user
            // reads the list, so selecting any row is instant on first click.
            ChangePreviewCache.shared.prefetch(changes: changes, workDirectory: workDirectory)
        }
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

    @State private var skillText: String?
    @State private var isLoading = true

    private var skillDocumentURL: URL? {
        guard !skill.directory.isEmpty else { return nil }
        return URL(fileURLWithPath: skill.directory).appendingPathComponent("SKILL.md")
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
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let skillText {
                ScrollView([.vertical, .horizontal]) {
                    if skillText.count < 100_000, let markdown = try? AttributedString(markdown: skillText) {
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
        .task(id: skill.id) {
            isLoading = true
            skillText = nil
            if let url = skillDocumentURL {
                skillText = await Task.detached(priority: .userInitiated) {
                    try? String(contentsOf: url, encoding: .utf8)
                }.value
            }
            isLoading = false
        }
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

private extension MothxFileChangeKind {
    func label(using copy: Copy) -> String {
        switch self {
        case .created: return copy.fileCreated
        case .modified: return copy.fileModified
        case .deleted: return copy.fileDeleted
        }
    }
}

private extension MothxFileChange {
    func kindLabel(using copy: Copy) -> String {
        kind.label(using: copy)
    }
}
