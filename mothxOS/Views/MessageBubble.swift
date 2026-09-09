import SwiftUI
import AppKit
import AVKit

/// Simple message bubble for user and assistant text messages.
/// Tool calls and tool results are rendered in the process block (TurnBlock).
struct MessageBubble: View {
    let message: MothxMessage
    let isCurrentRunning: Bool
    var onFork: (() -> Void)? = nil
    var isForking = false
    var onPreviewImage: ((MothxImagePreview) -> Void)? = nil

    var body: some View {
        TextMessageBubble(message: message, isCurrentRunning: isCurrentRunning, onFork: onFork, isForking: isForking, onPreviewImage: onPreviewImage)
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
