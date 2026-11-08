import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `view_media` for the assistant: one message's photo / sticker / GIF (downscaled JPEG), video (a few frames + duration)
/// or file (saved to a private cache folder, small text files inlined). Only the message asked for is fetched.
@MainActor
enum AssistantMedia {
    nonisolated static let maxImagePixels = 1024
    nonisolated static let maxFramePixels = 768
    static let maxFileBytes = 50 * 1024 * 1024
    static let inlineTextBytes = 200 * 1024

    static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz/assistant-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    typealias Err = AssistantDesk.AssistantError

    static func view(_ engine: ZaloEngine, conversationId: String, messageId: String, frames: Int) async throws -> [String: Any] {
        if (engine.messages[conversationId] ?? []).isEmpty, engine.openConversationId != conversationId {
            engine.navigationRequest = conversationId
            for _ in 0..<40 where (engine.messages[conversationId] ?? []).isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        }
        guard let message = engine.messages[conversationId]?.first(where: { $0.id == messageId }) else {
            throw Err("Không thấy tin \(messageId) — gọi read_messages trước")
        }
        switch message.kind {
        case .photo(let url, _, _):
            let data = try await photoData(engine, url: url, conversationId: conversationId, messageId: messageId)
            return try image(data, kind: "photo", caption: message.text)
        case .sticker(let url), .gif(let url):
            guard let url else { throw Err("Tin không có ảnh") }
            return try image(try await MediaLoader.shared.data(for: url), kind: "sticker", caption: "")
        case .video(let thumbnail, let duration, let url):
            return try await video(engine, thumbnail: thumbnail, url: url, duration: duration, frames: frames,
                                   conversationId: conversationId, messageId: messageId, caption: message.text)
        case .file(let name, let size, let url):
            return try await file(name: name, size: size, url: url, messageId: messageId)
        case .voice:
            throw Err("Chưa hỗ trợ nghe tin thoại")
        default:
            throw Err("Tin này không có ảnh/video/file")
        }
    }

    private static func photoData(_ engine: ZaloEngine, url: URL?, conversationId: String, messageId: String) async throws -> Data {
        if let url, let data = try? await MediaLoader.shared.data(for: url) { return data }
        // Dead CDN link: the official loader (local copy, hd/ori candidates, Zalo Cloud).
        switch await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .photo) {
        case .file(let file): return try Data(contentsOf: file)
        case .expired: throw Err("Ảnh đã hết hạn trên Zalo")
        default: throw Err("Không tải được ảnh lúc này")
        }
    }

    private static func image(_ data: Data, kind: String, caption: String) throws -> [String: Any] {
        guard let jpeg = downscaledJPEG(data, maxPixels: maxImagePixels) else { throw Err("Không giải mã được ảnh") }
        return ["kind": kind, "caption": caption, "images": [jpeg.base64EncodedString()], "mimeType": "image/jpeg"]
    }

    private static func video(_ engine: ZaloEngine, thumbnail: URL?, url: URL?, duration: Int, frames: Int,
                              conversationId: String, messageId: String, caption: String) async throws -> [String: Any] {
        var local: URL?
        if case .file(let f) = await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .video) { local = f }
        if local == nil, let url, let data = try? await MediaLoader.shared.data(for: url, deadline: 90) {
            let f = cacheDir.appendingPathComponent("\(messageId).mp4")
            try? data.write(to: f)
            local = f
        }
        var result: [String: Any] = ["kind": "video", "caption": caption, "durationSeconds": duration, "mimeType": "image/jpeg"]
        if let local, let shots = await extractFrames(local, count: frames), !shots.isEmpty {
            result["images"] = shots.map { $0.base64EncodedString() }
            result["note"] = "\(shots.count) khung hình rải đều trong video (không có âm thanh)"
            return result
        }
        // Fall back to the poster.
        var poster: Data?
        if let thumbnail { poster = try? await MediaLoader.shared.data(for: thumbnail) }
        if poster == nil, case .file(let f) = await engine.resolveMedia(conversationId: conversationId, messageId: messageId, kind: .videoThumb) {
            poster = try? Data(contentsOf: f)
        }
        guard let poster, let jpeg = downscaledJPEG(poster, maxPixels: maxImagePixels) else { throw Err("Không tải được video lẫn ảnh bìa") }
        result["images"] = [jpeg.base64EncodedString()]
        result["note"] = "Chỉ có ảnh bìa (không tải được video)"
        return result
    }

    private nonisolated static func extractFrames(_ file: URL, count: Int) async -> [Data]? {
        let asset = AVURLAsset(url: file)
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxFramePixels, height: maxFramePixels)
        var out: [Data] = []
        for i in 0..<count {
            let t = CMTime(seconds: seconds * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            guard let (cg, _) = try? await generator.image(at: t), let jpeg = encodeJPEG(cg) else { continue }
            out.append(jpeg)
        }
        return out
    }

    private static func file(name: String, size: Int64, url: URL?, messageId: String) async throws -> [String: Any] {
        guard let url else { throw Err("File không có đường tải") }
        guard size <= maxFileBytes else { throw Err("File lớn quá 50 MB") }
        let data: Data
        do { data = try await MediaLoader.shared.data(for: url, deadline: 120) } catch { throw Err("Không tải được file: \(error.localizedDescription)") }
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let dest = cacheDir.appendingPathComponent("\(messageId)-\(safe)")
        try data.write(to: dest, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        var result: [String: Any] = ["kind": "file", "name": name, "bytes": data.count, "path": dest.path]
        let ext = (name as NSString).pathExtension.lowercased()
        if data.count <= inlineTextBytes, ["txt", "csv", "tsv", "json", "md", "xml", "html", "log"].contains(ext),
           let text = String(data: data, encoding: .utf8) {
            result["text"] = text
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .image), let jpeg = downscaledJPEG(data, maxPixels: maxImagePixels) {
            result["images"] = [jpeg.base64EncodedString()]
            result["mimeType"] = "image/jpeg"
        } else {
            result["note"] = "Đã lưu file cục bộ; dùng công cụ đọc file (PDF, Excel…) với đường dẫn path"
        }
        return result
    }

    nonisolated static func downscaledJPEG(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encodeJPEG(cg)
    }

    nonisolated static func encodeJPEG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
