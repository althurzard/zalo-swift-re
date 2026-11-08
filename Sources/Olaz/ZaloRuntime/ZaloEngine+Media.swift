import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the official client's media loader made of a message's photo / video thumbnail / video.
enum MediaResolution: Equatable, Sendable {
    /// A local file (the official `ZaloDownloads` copy) to load.
    case file(URL)
    /// Every source is gone and the message is past the official shelf life (Zalo shows "expired").
    case expired
    /// Could not be loaded now (offline, server error, not synced…); worth a retry.
    case unavailable
    /// This kind of media is not resolved through the official image loader.
    case unsupported

    init(json: Any?) {
        guard let dict = json as? [String: Any], let state = dict["state"] as? String else { self = .unavailable; return }
        switch state {
        case "ok":
            if let path = dict["path"] as? String, path.hasPrefix("/") { self = .file(URL(fileURLWithPath: path)) } else { self = .unavailable }
        case "expired": self = .expired
        case "unsupported": self = .unsupported
        default: self = .unavailable
        }
    }
}

enum MediaKind: String, Sendable {
    case photo
    case videoThumb
    /// The video itself, as the official inline player gets it (downloaded and, for E2EE, decrypted).
    case video
}

/// De-duplicates and throttles `window.__zaloChat.resolveMedia` calls: a screenful of retired CDN links
/// must not start dozens of official downloads at once, and the same message is resolved once.
///
/// Queued work is dropped when every view waiting for it is gone (scrolled away), and the newest request
/// goes first, so photos on screen are not stuck behind off-screen dead ones.
@MainActor
final class MediaResolver {
    static let unavailableTTL: TimeInterval = 30

    private final class Flight: @unchecked Sendable {
        var task: Task<MediaResolution?, Never>!
        var waiters = 0
    }
    private final class Waiter: @unchecked Sendable { var released = false }

    private var settled: [String: (resolution: MediaResolution, until: Date)] = [:]
    private var flights: [String: Flight] = [:]
    private var running = 0
    private var queue: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    let maxConcurrent: Int

    init(maxConcurrent: Int = 3) { self.maxConcurrent = maxConcurrent }

    /// The remembered verdict for `key`, if any.
    func known(_ key: String) -> MediaResolution? { settled[key]?.resolution }

    /// `force` (the retry button) ignores any remembered verdict except a final "expired": a remembered
    /// "unavailable" is retried, and a remembered file that turned out not to be loadable is looked up again.
    func resolve(key: String, force: Bool = false, run: @escaping @MainActor () async -> MediaResolution) async -> MediaResolution {
        if let known = settled[key], known.until > Date() {
            switch known.resolution {
            case .unavailable where force: break
            case .file where force: break
            case .file(let url) where !FileManager.default.fileExists(atPath: url.path): break
            default: return known.resolution
            }
        }
        let flight: Flight
        if let existing = flights[key] {
            flight = existing
        } else {
            flight = Flight()
            flight.task = Task { @MainActor [weak self] () -> MediaResolution? in
                guard let self, await self.acquire() else { return nil }
                defer { self.release() }
                if Task.isCancelled { return nil }
                return await run()
            }
            flights[key] = flight
        }
        flight.waiters += 1
        let waiter = Waiter()
        let outcome = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { @MainActor in self.leave(key, flight, waiter) }
        }
        leave(key, flight, waiter)
        guard let resolution = outcome else { return .unavailable }          // dropped before it started
        if flights[key] === flight { flights[key] = nil }
        switch resolution {
        case .unavailable: settled[key] = (resolution, Date().addingTimeInterval(Self.unavailableTTL))
        case .file, .expired, .unsupported: settled[key] = (resolution, .distantFuture)
        }
        if settled.count > 2000 { settled = settled.filter { $0.value.until > Date() } }
        return resolution
    }

    /// One waiter left; with none remaining the flight is cancelled (it only dies if it has not started).
    private func leave(_ key: String, _ flight: Flight, _ waiter: Waiter) {
        guard !waiter.released else { return }
        waiter.released = true
        flight.waiters -= 1
        if flight.waiters <= 0 {
            if flights[key] === flight { flights[key] = nil }
            flight.task.cancel()
        }
    }

    /// Takes a slot; false when cancelled while queued. Newest waiter is served first.
    private func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < maxConcurrent { running += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                queue.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.queue.firstIndex(where: { $0.id == id }) else { return }
                self.queue.remove(at: index).continuation.resume(returning: false)
            }
        }
    }

    private func release() {
        if let next = queue.popLast() { next.continuation.resume(returning: true) } else { running -= 1 }
    }
}

extension ZaloEngine {
    /// Runs the official image loader for one message (`window.__zaloChat.resolveMedia`): local copy →
    /// hd/normal/ori candidates through the official download path (incl. the Zalo Cloud fallback) →
    /// "expired" past the official shelf life. Used when the plain CDN link failed to load.
    func resolveMedia(conversationId: String, messageId: String, kind: MediaKind = .photo, force: Bool = false) async -> MediaResolution {
        guard host != nil else { return .unavailable }
        let key = "\(conversationId)|\(messageId)|\(kind.rawValue)"
        // A retry after a downloaded file failed to decode: that file is bad, remove it so it is fetched again.
        if force, case .file(let bad)? = mediaResolver.known(key), MediaLoader.isOwnLocalFile(bad) {
            try? FileManager.default.removeItem(at: bad)
        }
        return await mediaResolver.resolve(key: key, force: force) { [weak self] in
            guard let self, let host = self.host else { return .unavailable }
            let args = [conversationId, messageId, kind.rawValue] as [Any]
            guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else { return .unavailable }
            let script = "const c = window.__zaloChat; if (!c || !c.resolveMedia) return {state: 'unavailable', reason: 'missing'}; return await c.resolveMedia(...\(json));"
            let result = await host.evaluate(script)
            var resolution = MediaResolution(json: result)
            // The Zalo Cloud fallback for a dead video thumbnail link saves the video itself at the thumbnail path.
            if kind == .videoThumb, case .file(let file) = resolution, VideoPoster.isVideo(file) {
                resolution = await VideoPoster.poster(for: file).map(MediaResolution.file) ?? .unavailable
                EngineLog.shared.write("resolveMedia videoThumb is a video → poster \(resolution.logName)")
            }
            EngineLog.shared.write("resolveMedia kind=\(kind.rawValue) → \(resolution.logName)")
            return resolution
        }
    }
}

extension MediaResolution {
    var logName: String {
        switch self {
        case .file: "file"
        case .expired: "expired"
        case .unavailable: "unavailable"
        case .unsupported: "unsupported"
        }
    }
}

/// First-frame poster for a video file sitting where a thumbnail image was expected.
enum VideoPoster {
    /// ISO-BMFF (`ftyp` box at offset 4: mp4/mov/3gp) — never a decodable image.
    nonisolated static func isVideo(_ file: URL) -> Bool { mimeType(of: file) != nil }

    /// Container MIME type from the `ftyp` major brand; AVFoundation goes by the (here: `.jpg`) extension otherwise.
    nonisolated static func mimeType(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              head[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        if brand == "qt  " { return "video/quicktime" }
        if brand.hasPrefix("3g") { return "video/3gpp" }
        return "video/mp4"
    }

    /// `<file>.poster.jpg` next to the video, generated once.
    nonisolated static func poster(for video: URL) async -> URL? {
        let poster = video.appendingPathExtension("poster.jpg")
        let fm = FileManager.default
        func modified(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        if let made = modified(poster), let source = modified(video), made.timeIntervalSince(source) >= 0 { return poster }

        guard let mime = mimeType(of: video) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video, options: [AVURLAssetOverrideMIMETypeKey: mime]))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1040, height: 1040)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }

        let temp = poster.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).poster.part")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? fm.removeItem(at: temp); return nil }
        try? fm.removeItem(at: poster)
        do { try fm.moveItem(at: temp, to: poster) } catch { try? fm.removeItem(at: temp); return nil }
        return poster
    }
}
