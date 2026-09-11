import SwiftUI
import AppKit
import AVKit
import QuickLookUI

/// Simple message bubble for user and assistant text messages.
/// Tool calls and tool results are rendered in the process block (TurnBlock).
struct MessageBubble: View {
    let message: MothxMessage
    let isCurrentRunning: Bool
    var onFork: (() -> Void)? = nil
    var isForking = false
    var onPreviewImage: ((MothxImagePreview) -> Void)? = nil
    var onPreviewDocument: ((MothxDocumentPreview) -> Void)? = nil

    var body: some View {
        TextMessageBubble(message: message, isCurrentRunning: isCurrentRunning, onFork: onFork, isForking: isForking, onPreviewImage: onPreviewImage, onPreviewDocument: onPreviewDocument)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct ImagePreviewStrip: View {
    let images: [MothxImagePreview]
    let onSelect: (MothxImagePreview) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(images) { image in
                Button { onSelect(image) } label: {
                    ImagePreviewThumbnail(image: image)
                }
                .buttonStyle(.plain)
                .help("点击在右侧栏预览图片")
            }
        }
        .padding(.top, 8)
    }
}

/// Card shown after a turn's final answer when the run published locally
/// generated image files (`publish_artifact uploadimg/…/xxx.png`). Its layout
/// follows the file-change card; clicking a file row opens the image in the
/// right sidebar without rendering an inline thumbnail.
struct PublishArtifactCard: View {
    let images: [MothxImagePreview]
    /// The durable/current Run that owns these artifacts. Keeping this on the
    /// card makes the turn-to-Run association explicit at the render boundary.
    let runID: String
    let onPreview: (MothxImagePreview) -> Void

    var body: some View {
        let title = images.count > 1 ? "生成图片（\(images.count)）" : "生成图片"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Button {
                        if let first = images.first { onPreview(first) }
                    } label: {
                        Label("预览图片", systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                Spacer()
                Button("预览", action: {
                    if let first = images.first { onPreview(first) }
                })
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            ForEach(images) { image in
                Button {
                    onPreview(image)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                        Text(image.name?.isEmpty == false ? image.name! : "图片")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 10)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击在右侧栏预览图片")
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 6)
        .accessibilityIdentifier("publish-artifact-card-\(runID)")
    }
}


/// Card shown after a turn's final answer when a video-generation skill
/// downloaded and published a local video file. The file rows deliberately
/// stay compact; clicking one opens the playable preview in the right sidebar.
struct PublishArtifactVideoCard: View {
    let videos: [MothxVideoPreview]
    let runID: String
    let onPreview: (MothxVideoPreview) -> Void

    var body: some View {
        let title = videos.count > 1 ? "生成视频（\(videos.count)）" : "生成视频"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Button {
                        if let first = videos.first { onPreview(first) }
                    } label: {
                        Label("预览视频", systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                Spacer()
                Button("预览") {
                    if let first = videos.first { onPreview(first) }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            ForEach(videos) { video in
                Button { onPreview(video) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "video")
                            .foregroundStyle(.secondary)
                        Text(video.name?.isEmpty == false ? video.name! : "视频文件")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 10)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击在右侧栏预览视频")
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 6)
        .accessibilityIdentifier("publish-artifact-video-card-\(runID)")
    }
}

/// Compact strip used when an assistant message directly references one or
/// more generated Office/PDF files. The actual rendering happens in Quick
/// Look in the right sidebar so large documents do not inflate the message.
struct DocumentPreviewStrip: View {
    let documents: [MothxDocumentPreview]
    let onSelect: (MothxDocumentPreview) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(documents) { document in
                Button { onSelect(document) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: documentIcon(for: document))
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(documentColor(for: document))
                            .frame(width: 42, height: 42)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        Text(document.name ?? "生成文件")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 110)
                    }
                    .padding(6)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("点击在右侧栏预览文件")
            }
        }
        .padding(.top, 8)
    }
}

/// Card shown after a turn's final answer when the run published local PDF,
/// PowerPoint, Word, or Excel files. Each row opens the source file in the
/// right sidebar through macOS Quick Look.
struct PublishArtifactDocumentCard: View {
    let documents: [MothxDocumentPreview]
    let runID: String
    let onPreview: (MothxDocumentPreview) -> Void

    var body: some View {
        let title = documents.count > 1 ? "生成文件（\(documents.count)）" : "生成文件"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Button {
                        if let first = documents.first { onPreview(first) }
                    } label: {
                        Label("预览文件", systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                Spacer()
                Button("预览") {
                    if let first = documents.first { onPreview(first) }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            ForEach(documents) { document in
                Button { onPreview(document) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: documentIcon(for: document))
                            .foregroundStyle(documentColor(for: document))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.name ?? "生成文件")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(document.fileExtension.uppercased())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击在右侧栏预览文件")
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 6)
        .accessibilityIdentifier("publish-artifact-document-card-\(runID)")
    }
}

private extension MothxDocumentPreview {
    var fileExtension: String {
        URL(fileURLWithPath: source).pathExtension.isEmpty
            ? "文件"
            : URL(fileURLWithPath: source).pathExtension
    }
}

private func documentIcon(for document: MothxDocumentPreview) -> String {
    switch document.fileExtension.lowercased() {
    case "ppt", "pptx", "key": return "rectangle.on.rectangle"
    case "pdf": return "doc.richtext"
    case "doc", "docx", "pages": return "doc.text"
    case "xls", "xlsx", "numbers", "csv": return "tablecells"
    default: return "doc"
    }
}

private func documentColor(for document: MothxDocumentPreview) -> Color {
    switch document.fileExtension.lowercased() {
    case "ppt", "pptx", "key": return .orange
    case "pdf": return .red
    case "doc", "docx", "pages": return .blue
    case "xls", "xlsx", "numbers", "csv": return .green
    default: return .secondary
    }
}


private struct ImagePreviewThumbnail: View {
    let image: MothxImagePreview

    var body: some View {
        Group {
            if image.isDataURL, let nsImage = decodedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else if let fileURL = localImageFileURL(for: image.source) {
                LocalImageThumbnail(url: fileURL)
            } else if let url = remoteImageURL(for: image.source) {
                AsyncImage(url: url) { phase in
                    if case .success(let loaded) = phase {
                        loaded.resizable().scaledToFill()
                    } else if case .failure = phase {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 108, height: 82)
        .clipped()
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.13)))
    }

    private var decodedImage: NSImage? {
        guard let comma = image.source.firstIndex(of: ",") else { return nil }
        let encoded = String(image.source[image.source.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }
}

/// Loads a thumbnail from a local file when the preview source points at a
/// file on disk (absolute path, `file://` URL, or a path resolved against the
/// session work directory). Falls back to an error glyph when the file cannot
/// be decoded.
private struct LocalImageThumbnail: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}

struct ImagePreviewSidebar: View {
    let image: MothxImagePreview
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("图片预览")
                        .font(.headline)
                    if let name = image.name, !name.isEmpty {
                        Text(name)
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

            VStack(alignment: .leading, spacing: 12) {
                ImagePreviewContent(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let fileURL = localImageFileURL(for: image.source) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                } else if !image.isDataURL, let url = remoteImageURL(for: image.source) {
                    Link(destination: url) {
                        Label("打开图片链接", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
                Text(image.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}



/// Quick Look-backed document preview. QLPreviewView asks the system to render
/// the original file, preserving the layout and compatibility of the app that
/// produced it instead of displaying the publish metadata JSON.
private final class QuickLookPreviewCoordinator {
    weak var previewView: ControllableQLPreviewView?

    func previousPage() {
        previewView?.navigatePage(.previous)
    }

    func nextPage() {
        previewView?.navigatePage(.next)
    }
}

private enum PreviewPageDirection {
    case previous
    case next

    var keyCode: UInt16 {
        // Page Up / Page Down are also what Quick Look uses when the user
        // scrolls through a multi-page document with the keyboard.
        switch self {
        case .previous: return 116 // Page Up
        case .next: return 121 // Page Down
        }
    }

    var characters: String {
        switch self {
        case .previous: return String(UnicodeScalar(NSPageUpFunctionKey)!)
        case .next: return String(UnicodeScalar(NSPageDownFunctionKey)!)
        }
    }
}

private final class ControllableQLPreviewView: QLPreviewView {
    override var acceptsFirstResponder: Bool { true }

    func navigatePage(_ direction: PreviewPageDirection) {
        guard let window else { return }
        window.makeFirstResponder(self)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: direction.characters,
            charactersIgnoringModifiers: direction.characters,
            isARepeat: false,
            keyCode: direction.keyCode
        ) else { return }

        // Sending the event through the window keeps this compatible with
        // Quick Look's private document renderer. It is the same navigation
        // path used by Page Up/Page Down and trackpad/scroll-wheel paging.
        window.sendEvent(event)
    }
}

private struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL
    let coordinator: QuickLookPreviewCoordinator

    func makeNSView(context: Context) -> ControllableQLPreviewView {
        let view = ControllableQLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        coordinator.previewView = view
        return view
    }

    func updateNSView(_ view: ControllableQLPreviewView, context: Context) {
        coordinator.previewView = view
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
    }
}

private struct DocumentPreviewControls: View {
    let coordinator: QuickLookPreviewCoordinator
    let isFullscreen: Bool
    let onFullscreen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.previousPage()
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("上一页（Page Up）")

            Button {
                coordinator.nextPage()
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("下一页（Page Down）")

            Spacer(minLength: 8)

            Button(action: onFullscreen) {
                Label(
                    isFullscreen ? "退出全屏" : "全屏",
                    systemImage: isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("全屏预览")
        }
    }
}

private struct FullscreenDocumentPreviewView: View {
    let document: MothxDocumentPreview
    let fileURL: URL
    let onClose: () -> Void
    @State private var coordinator = QuickLookPreviewCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: documentIcon(for: document))
                    .foregroundStyle(documentColor(for: document))
                Text(document.name ?? "生成文件")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("关闭") {
                    onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Divider()

            QuickLookPreviewView(url: fileURL, coordinator: coordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))

            Divider()
            DocumentPreviewControls(
                coordinator: coordinator,
                isFullscreen: true,
                onFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) }
            )
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(.background)
    }
}

private final class DocumentPreviewWindowController: NSWindowController, NSWindowDelegate {
    private static var activeController: DocumentPreviewWindowController?

    static func present(document: MothxDocumentPreview, fileURL: URL) {
        let controller = DocumentPreviewWindowController(document: document, fileURL: fileURL)
        activeController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            controller.window?.toggleFullScreen(nil)
        }
    }

    init(document: MothxDocumentPreview, fileURL: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = document.name ?? "文件预览"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let rootView = FullscreenDocumentPreviewView(
            document: document,
            fileURL: fileURL,
            onClose: { [weak self] in self?.close() }
        )
        window.contentViewController = NSHostingController(rootView: rootView)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        if DocumentPreviewWindowController.activeController === self {
            DocumentPreviewWindowController.activeController = nil
        }
    }
}

struct DocumentPreviewSidebar: View {
    let document: MothxDocumentPreview
    let onClose: () -> Void
    @State private var coordinator = QuickLookPreviewCoordinator()

    private var fileURL: URL? {
        let url = URL(fileURLWithPath: document.source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: documentIcon(for: document))
                    .foregroundStyle(documentColor(for: document))
                VStack(alignment: .leading, spacing: 2) {
                    Text("文件预览")
                        .font(.headline)
                    Text(document.name ?? "生成文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

            if let fileURL {
                VStack(alignment: .leading, spacing: 10) {
                    QuickLookPreviewView(url: fileURL, coordinator: coordinator)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    DocumentPreviewControls(coordinator: coordinator, isFullscreen: false) {
                        DocumentPreviewWindowController.present(document: document, fileURL: fileURL)
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    Text(fileURL.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(14)
            } else {
                ContentUnavailableView("文件不存在", systemImage: "doc.badge.exclamationmark", description: Text(document.source))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct VideoPreviewSidebar: View {
    let video: MothxVideoPreview
    let onClose: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("视频预览")
                        .font(.headline)
                    if let name = video.name, !name.isEmpty {
                        Text(name)
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

            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if let player {
                        // Use the AppKit AVPlayerView bridge instead of SwiftUI's
                        // VideoPlayer. The latter goes through _AVKit_SwiftUI's
                        // NSViewRepresentable metadata path and can abort in an
                        // optimized/archive build on macOS 26, even though Debug
                        // runs from Xcode work correctly.
                        MacVideoPlayerView(player: player)
                            .onDisappear { player.pause() }
                    } else if localVideoFileURL(for: video.source) != nil || remoteVideoURL(for: video.source) != nil {
                        ProgressView("正在加载视频…")
                    } else {
                        ContentUnavailableView("视频内容不可用", systemImage: "video.slash")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                if let fileURL = localVideoFileURL(for: video.source) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                } else if let url = remoteVideoURL(for: video.source) {
                    Link(destination: url) {
                        Label("打开视频链接", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
                Text(video.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: video.source) {
            player?.pause()
            let url = localVideoFileURL(for: video.source) ?? remoteVideoURL(for: video.source)
            player = url.map(AVPlayer.init(url:))
        }
    }
}

private struct ImagePreviewContent: View {
    let image: MothxImagePreview

    var body: some View {
        Group {
            if image.isDataURL, let nsImage = decodedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            } else if let fileURL = localImageFileURL(for: image.source) {
                if let nsImage = NSImage(contentsOf: fileURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView("图片加载失败", systemImage: "photo.badge.exclamationmark")
                }
            } else if let url = remoteImageURL(for: image.source) {
                AsyncImage(url: url) { phase in
                    if case .success(let loaded) = phase {
                        loaded.resizable().scaledToFit()
                    } else if case .failure = phase {
                        ContentUnavailableView("图片加载失败", systemImage: "photo.badge.exclamationmark")
                    } else {
                        ProgressView("正在加载图片…")
                    }
                }
            } else {
                ContentUnavailableView("图片内容不可用", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var decodedImage: NSImage? {
        guard let comma = image.source.firstIndex(of: ",") else { return nil }
        let encoded = String(image.source[image.source.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - Video player

/// AppKit-backed video rendering for the macOS app.
///
/// SwiftUI's `VideoPlayer` is convenient, but its private `_AVKit_SwiftUI`
/// bridge has a release/archive-only metadata crash on the macOS 26 runtime
/// used by this app. `AVPlayerView` is the supported AppKit counterpart and
/// avoids that fragile SwiftUI bridge while retaining native playback controls.
private struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

// MARK: - Local video source resolution

private func localVideoFileURL(for source: String) -> URL? {
    guard !source.hasPrefix("data:") else { return nil }
    let path: String
    if source.hasPrefix("file://") {
        guard let url = URL(string: source) else { return nil }
        path = url.path
    } else {
        path = source
    }
    guard path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
}

private func remoteVideoURL(for source: String) -> URL? {
    guard !source.hasPrefix("data:"),
          let url = URL(string: source),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme) else { return nil }
    return url
}

// MARK: - Local image source resolution

/// Resolves a preview source to an on-disk image file when it points at a
/// local path (absolute path or `file://` URL). Returns nil for data URLs,
/// remote http(s) URLs, unresolvable relative paths, and missing files, so
/// callers can fall back to the remote/data rendering path.
private func localImageFileURL(for source: String) -> URL? {
    guard !source.hasPrefix("data:") else { return nil }
    let path: String
    if source.hasPrefix("file://") {
        guard let url = URL(string: source) else { return nil }
        path = url.path
    } else {
        path = source
    }
    guard path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
}

/// Returns the URL only for remote http(s) sources. Bare local paths (even
/// when they happen to parse as a URL) must go through `localImageFileURL`
/// instead of `AsyncImage`, which cannot load them.
private func remoteImageURL(for source: String) -> URL? {
    guard !source.hasPrefix("data:"),
          let url = URL(string: source),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme) else { return nil }
    return url
}
