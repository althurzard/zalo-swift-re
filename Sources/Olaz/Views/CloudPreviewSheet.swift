import SwiftUI
import QuickLookUI

/// Preview of one cloud item: downloads it through the official downloader, then shows the photo (zoomable), plays the
/// video / voice message (the media viewer's player, without its full-screen button), or previews the file with
/// QuickLook. Save goes through an NSSavePanel.
struct CloudPreviewSheet: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let item: CloudItem

    private enum Phase {
        case loading
        case ready(CloudFile, staged: URL?)
        case expired
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var playback: VideoPlayback?
    @State private var zoom = ZoomController()
    @State private var saved = false
    @State private var note: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 720, idealWidth: 980, minHeight: 520, idealHeight: 700)
        .task(id: attempt) { await load() }
        .onDisappear { playback?.stop(); playback = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .file ? item.fileSymbol : item.kind.symbol)
                .font(.system(size: 18)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text([CloudFormat.size(item.size), item.conversationLabel, CloudFormat.date(item.date)].joined(separator: " • "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass).buttonBorderShape(.circle).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Đang tải từ zCloud…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        case .expired:
            ContentUnavailableView("Nội dung đã hết hạn", systemImage: "clock.badge.xmark",
                                   description: Text("Nội dung này không còn trên zCloud."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Không tải được", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Thử lại") { phase = .loading; attempt += 1 }
            }
        case .ready(let file, let staged):
            switch item.kind {
            case .photo:
                RemoteImage(url: file.url, contentMode: .fit, maxPixelSize: 6144) { ProgressView() }
                    .uncached()
                    .rendering { image in ZoomableImageView(image: image, zoom: zoom) }
                    .overlay(alignment: .topTrailing) {
                        ZoomControls(zoom: zoom, showsShortcuts: false).padding(12)
                    }
            case .video, .voice:
                if let playback {
                    VideoPlayerView(playback: playback)
                } else {
                    ContentUnavailableView("Không phát được", systemImage: "play.slash",
                                           description: Text("Định dạng này không phát được trong ứng dụng. Hãy lưu về máy hoặc mở bằng ứng dụng khác."))
                }
            default:
                if let staged {
                    QuickLookPreview(url: staged)
                } else {
                    ContentUnavailableView(item.displayName, systemImage: item.fileSymbol)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if saved { Label("Đã lưu về máy", systemImage: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(.green) }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2) }
            Spacer()
            if case .ready(_, let staged) = phase {
                Button("Mở bằng ứng dụng khác") { openElsewhere(staged) }
                    .buttonStyle(.glass).disabled(staged == nil)
                Button("Lưu về máy…", systemImage: "square.and.arrow.down") { save() }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func load() async {
        saved = false
        let result = await engine.cloudFetch(item.id)
        // The sheet closed (or moved on to another item) during the fetch: no player for a preview nobody sees, it would
        // never be stopped (`onDisappear` already ran).
        guard !Task.isCancelled else { return }
        switch result {
        case .expired: phase = .expired
        case .failed(let message): phase = .failed(message)
        case .ready(let file):
            let container = CloudContainer(fileAt: file.url)
            let output = CloudFiles.outputName(item: item, container: container)
            let staged = CloudFiles.stage(file.url, name: output.name, ext: output.ext)
            guard !Task.isCancelled else { return }
            if (item.kind == .video || item.kind == .voice), let staged {
                playback?.stop()
                playback = VideoPlayback(url: staged)
            }
            phase = .ready(file, staged: staged)
        }
    }

    private func save() {
        guard case .ready(let file, _) = phase else { return }
        note = nil
        Task {
            switch await CloudSaver.save(file, item: item) {
            case .saved: saved = true
            case .cancelled: break
            case .failed(let message): saved = false; note = message
            }
        }
    }

    /// Anything that could run code is revealed in Finder instead of opened (the name comes from the sender).
    private func openElsewhere(_ staged: URL?) {
        guard let staged else { return }
        if CloudFiles.mayExecute(staged, displayName: item.displayName) {
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            note = "Đã mở trong Finder vì tệp có thể chạy mã"
        } else {
            NSWorkspace.shared.open(staged)
        }
    }
}

/// QuickLook preview of a local file.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
