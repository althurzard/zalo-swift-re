import Foundation
import AppKit
import ImageIO
import Network
import CoreServices

/// `NSImage` is not `Sendable`; images handed out by the loader are immutable after creation.
struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

/// Loads Zalo CDN media (avatars, photos, stickers, voice, files).
///
/// 1. Disk+memory `URLCache` lookup.
/// 2. For Zalo CDN hosts only: a de-duplicated getaddrinfo probe decides whether the system resolver works.
/// 3. Normal `URLSession` fetch.
/// 4. On DNS failure the host is resolved via DNS-over-HTTPS (`DoHResolver`) and fetched with
///    `PinnedHTTPSClient` (SNI + certificate validation for the original hostname). Hosts that needed
///    DoH are remembered so later requests skip the failing system lookup.
/// Decoded (downsampled) images are kept in an `NSCache`; concurrent requests for the same URL share
/// one download, which is cancelled when every waiter cancels. Downloads are capped at 6 concurrent.
actor MediaLoader {
    static let shared = MediaLoader()

    enum LoadError: Error, LocalizedError {
        case badURL
        case http(Int)
        case undecodable
        case timedOut
        case tooLarge
        /// The CDN host does not exist (authoritative NXDOMAIN): nothing to retry.
        case hostNotFound
        var errorDescription: String? {
            switch self {
            case .badURL: "Unsupported media URL"
            case .http(let code): "Media request failed with HTTP \(code)"
            case .undecodable: "Media data is not a decodable image"
            case .timedOut: "Media download timed out"
            case .tooLarge: "Media file is too large"
            case .hostNotFound: "Media host no longer exists"
            }
        }
    }

    /// Hosts for which the DoH fallback is allowed (so arbitrary hosts embedded in message content
    /// cannot bypass the user's own DNS / hosts-file blocking).
    static let dohHostSuffixes = ["zadn.vn", "zdn.vn", "zalo.me", "zaloapp.com", "zingcdn.me", "zalo.vn", "zing.vn"]

    nonisolated static func isZaloCDN(_ host: String) -> Bool {
        let host = host.lowercased()
        return dohHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    struct Fetched: Sendable {
        let data: Data
        let framed: Bool
        let finalURL: URL
    }

    private let session: URLSession
    private let fileSession: URLSession
    /// Where `localFile` stores completed downloads (and `.part` temp files). Derived from the injected
    /// cache directory so tests never touch the user's real cache.
    nonisolated let filesDirectory: URL
    private let filesCacheLimit: Int
    private var didStartMaintenance = false
    private let urlCache: URLCache
    private let resolver: DoHResolver
    private var dohHosts: [String: Date] = [:]          // host -> when to retry system DNS
    private var systemOK: [String: Date] = [:]          // host -> system DNS treated as good until
    private var probes: [String: Task<Bool, Never>] = [:]
    private var flights: [String: FlightBase] = [:]
    private var failures: [String: Date] = [:]
    /// Zalo CDN hosts that DoH reported NXDOMAIN for (migrated messages point at retired `fNN-zpc` hosts):
    /// requests fail immediately until the entry expires instead of re-probing DNS per image.
    private var deadHosts: [String: Date] = [:]
    private let maxConcurrentDownloads: Int
    private var activeDownloads = 0
    private var slotWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    private static let dohStickiness: TimeInterval = 600
    static let deadHostTTL: TimeInterval = 300
    private static let failureBackoff: TimeInterval = 20
    static let imageDeadline: TimeInterval = 25
    static let fileDeadline: TimeInterval = 120
    /// Files have no total deadline: a transfer fails only after this long without receiving any bytes.
    static let fileIdleTimeout: TimeInterval = 30
    /// Largest file `localFile` will download (Zalo allows up to 1 GB).
    static let maxFileBytes = 2 * 1024 * 1024 * 1024
    /// Size cap for Caches/Olaz/files; least recently used files are evicted beyond it.
    static let defaultFilesCacheLimit = 2 * 1024 * 1024 * 1024
    /// `.part` files untouched for this long are leftovers from a crash / force-quit.
    static let stalePartAge: TimeInterval = 600

    init(cacheDirectory: URL? = nil, resolver: DoHResolver = DoHResolver(), maxConcurrentDownloads: Int = 6,
         filesCacheLimit: Int = MediaLoader.defaultFilesCacheLimit) {
        self.filesCacheLimit = filesCacheLimit
        if let cacheDirectory {
            filesDirectory = cacheDirectory.appendingPathComponent("files", isDirectory: true)
        } else {
            filesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Olaz/files", isDirectory: true)
        }
        let directory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Olaz/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 400 << 20, directory: directory)
        let config = URLSessionConfiguration.default
        config.urlCache = nil                       // we manage `urlCache` explicitly (DoH path shares it)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = Self.fileDeadline
        // Fallback only: every request also sets the headers itself in `applyClientHeaders`,
        // which follows a runtime upgrade without recreating the sessions.
        config.httpAdditionalHeaders = ["User-Agent": ClientFingerprint.userAgent]
        session = URLSession(configuration: config)
        let fileConfig = URLSessionConfiguration.default
        fileConfig.urlCache = nil
        fileConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        fileConfig.timeoutIntervalForRequest = Self.fileIdleTimeout     // idle timeout between received bytes
        fileConfig.timeoutIntervalForResource = 7 * 24 * 3600           // effectively no total deadline
        fileConfig.httpAdditionalHeaders = ["User-Agent": ClientFingerprint.userAgent]
        fileSession = URLSession(configuration: fileConfig)
        self.resolver = resolver
        self.maxConcurrentDownloads = maxConcurrentDownloads
    }

    // MARK: Decoded-image memory cache (synchronous access for views)

    private final class CachedImage: @unchecked Sendable {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    /// NSCache is thread-safe but not annotated `Sendable`.
    private final class MemoryCache: @unchecked Sendable {
        private let cache: NSCache<NSString, CachedImage> = {
            let cache = NSCache<NSString, CachedImage>()
            cache.countLimit = 600
            cache.totalCostLimit = 160 << 20
            return cache
        }()
        private let lock = NSLock()
        private var stills: Set<URL> = []       // URLs known to be single-frame (skip animation checks)
        func object(forKey key: NSString) -> CachedImage? { cache.object(forKey: key) }
        func setObject(_ object: CachedImage, forKey key: NSString, cost: Int) {
            cache.setObject(object, forKey: key, cost: cost)
        }
        func markStill(_ url: URL) { lock.lock(); if stills.count > 5000 { stills.removeAll() }; stills.insert(url); lock.unlock() }
        func isStill(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return stills.contains(url) }
    }

    private static let memory = MemoryCache()

    static func pixelBucket(_ maxPixelSize: CGFloat) -> Int {
        max(64, Int((maxPixelSize / 32).rounded(.up)) * 32)
    }

    private static func imageKey(_ url: URL, _ pixels: Int) -> String { "\(url.absoluteString)#\(pixels)" }

    /// Already-decoded image, if any; lets views render without a placeholder flash.
    nonisolated static func cachedImage(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        memory.object(forKey: imageKey(url, pixelBucket(maxPixelSize)) as NSString)?.image
    }

    nonisolated static func cachedAnimatedImage(for url: URL) -> NSImage? {
        memory.object(forKey: imageKey(url, 0) as NSString)?.image
    }

    /// True when a previous check found `url` to be a single-frame image.
    nonisolated static func isKnownStill(_ url: URL) -> Bool { memory.isStill(url) }

    // MARK: Shared in-flight work (cancelled when every waiter cancels)

    private class FlightBase: @unchecked Sendable {
        var waiters = 0
        let progress: FileProgress
        init(progress: FileProgress) { self.progress = progress }
        func cancel() {}
    }
    private final class Flight<T: Sendable>: FlightBase, @unchecked Sendable {
        let task: Task<T, Error>
        init(_ task: Task<T, Error>, progress: FileProgress) {
            self.task = task
            super.init(progress: progress)
        }
        override func cancel() { task.cancel() }
    }
    private final class Waiter: @unchecked Sendable { var released = false }

    private func join<T: Sendable>(key: String, start: @escaping @Sendable () async throws -> T) async throws -> T {
        try await join(key: key, observer: nil) { _ in try await start() }
    }

    /// Like `join`; `start` receives the flight's progress hub (created with the flight, so every waiter,
    /// including late joiners, observes the same download). `observer` is removed when the caller leaves.
    private func join<T: Sendable>(key: String, observer: (@Sendable (Double) -> Void)?,
                                   start: @escaping @Sendable (FileProgress) async throws -> T) async throws -> T {
        let flight: Flight<T>
        if let existing = flights[key] as? Flight<T> {
            flight = existing
        } else {
            let progress = FileProgress()
            flight = Flight(Task { try await start(progress) }, progress: progress)
            flights[key] = flight
        }
        flight.waiters += 1
        let waiter = Waiter()
        let observerID = observer.map { flight.progress.add($0) }
        defer {
            if let observerID { flight.progress.remove(observerID) }
            release(waiter, flight, key)
        }
        return try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.release(waiter, flight, key) }
        }
    }

    private func release(_ waiter: Waiter, _ flight: FlightBase, _ key: String) {
        guard !waiter.released else { return }
        waiter.released = true
        flight.waiters -= 1
        if flight.waiters <= 0 {
            if flights[key] === flight { flights[key] = nil }
            flight.cancel()
        }
    }

    // MARK: Images

    /// Decoded image whose longest side is at most `maxPixelSize` pixels. Nil on failure.
    ///
    /// `cache: false` keeps the result out of the shared memory cache (the viewer's full-size photos: one 48 MP decode is
    /// ~113 MB and would evict most thumbnails and avatars). Concurrent callers still share one download and decode;
    /// uncached ones are told apart in the flight table so a cached caller never joins a flight that skips the store.
    func image(for url: URL, maxPixelSize: CGFloat, cache: Bool = true) async -> SendableImage? {
        let pixels = Self.pixelBucket(maxPixelSize)
        let key = Self.imageKey(url, pixels)
        if let hit = Self.memory.object(forKey: key as NSString) { return SendableImage(image: hit.image) }
        if let until = failures[key], until > Date() { return nil }
        do {
            return try await join(key: (cache ? "i:" : "i!:") + key) { [self] in
                do {
                    let data = try await self.data(for: url)
                    guard let decoded = await Task.detached(priority: .userInitiated, operation: {
                        Self.decode(data, maxPixelSize: pixels)
                    }).value else { throw LoadError.undecodable }
                    if cache {
                        let cost = Int(decoded.size.width * decoded.size.height) * 4
                        Self.memory.setObject(CachedImage(decoded), forKey: key as NSString, cost: cost)
                    }
                    return SendableImage(image: decoded)
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    MediaDiagnostics.report(url: url, error: error, kind: "image")
                    await self.noteFailure(key)
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    /// Multi-frame (GIF/APNG/WebP) image with all frames, or nil if the data is a still image / failed.
    func animatedImage(for url: URL) async -> SendableImage? {
        let key = Self.imageKey(url, 0)
        if let hit = Self.memory.object(forKey: key as NSString) { return SendableImage(image: hit.image) }
        if Self.memory.isStill(url) { return nil }
        if let until = failures[key], until > Date() { return nil }
        do {
            return try await join(key: "a:" + key) { [self] () -> SendableImage? in
                do {
                    let data = try await self.data(for: url)
                    guard let image = await Task.detached(priority: .userInitiated, operation: {
                        Self.decodeAnimated(data)
                    }).value else {
                        Self.memory.markStill(url)
                        return nil
                    }
                    Self.memory.setObject(CachedImage(image), forKey: key as NSString, cost: data.count * 4)
                    return SendableImage(image: image)
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    await self.noteFailure(key)
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    private func noteFailure(_ key: String) {
        failures[key] = Date().addingTimeInterval(Self.failureBackoff)
    }

    /// Drops the short failure backoff for `url` (an explicit retry must really try again).
    func forgetFailures(for url: URL) {
        let prefix = url.absoluteString + "#"
        for key in failures.keys where key.hasPrefix(prefix) { failures[key] = nil }
    }

    nonisolated static func decodeAnimated(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1 else { return nil }
        return NSImage(data: data)
    }

    /// Decodes `data`, downsampling so the longest side is at most `maxPixelSize`. A photo stored rotated (EXIF orientation)
    /// is turned upright either way: the full-size path would leave it sideways.
    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var longest = 0
        var rotated = false
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                longest = max(w, h)
            }
            rotated = (props[kCGImagePropertyOrientation] as? Int).map { $0 != 1 } ?? false
        }
        let cgImage: CGImage?
        if longest > maxPixelSize || rotated {
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                // Unknown source size (no pixel properties): the cap itself, never a 1 px thumbnail.
                kCGImageSourceThumbnailMaxPixelSize: longest > 0 ? min(maxPixelSize, longest) : maxPixelSize,
            ] as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: Raw data

    /// Bytes for `url` (cached, de-duplicated, concurrency-capped, with an overall deadline).
    func data(for url: URL, deadline: TimeInterval = MediaLoader.imageDeadline) async throws -> Data {
        if url.isFileURL {
            // Files the official download path wrote under ZaloDownloads (`resolveMedia`), or our own caches.
            guard Self.isAllowedLocalFile(url) else { throw LoadError.badURL }
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        }
        guard let url = Self.normalized(url) else { throw LoadError.badURL }
        if let cached = urlCache.cachedResponse(for: URLRequest(url: url)) { return cached.data }
        return try await join(key: "d:" + url.absoluteString) { [self] in
            try await self.withSlot {
                try await Self.withDeadline(deadline) {
                    let fetched = try await self.download(url, redirectsLeft: 3)
                    if fetched.framed, fetched.finalURL != url {
                        await self.store(fetched.data, for: url, contentType: nil)     // also under the original URL
                    }
                    return fetched.data
                }
            }
        }
    }

    private nonisolated static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LoadError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Concurrency cap

    private func withSlot<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        try await acquireSlot()
        defer { releaseSlot() }
        try Task.checkCancellation()
        return try await work()
    }

    private func acquireSlot() async throws {
        if activeDownloads < maxConcurrentDownloads { activeDownloads += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                slotWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(id) }
        }
    }

    private func cancelSlotWaiter(_ id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        slotWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty { activeDownloads -= 1 } else { slotWaiters.removeFirst().continuation.resume() }
    }

    // MARK: Requests with custom headers

    /// Headers that must never travel to a host outside Zalo's CDN / cloud domains, nor survive a
    /// cross-host redirect (Zalo Cloud's `cloud-viewer-key`, cookies, credentials).
    nonisolated static let sensitiveHeaderNames: Set<String> = ["cloud-viewer-key", "cookie", "authorization", "proxy-authorization"]
    /// Connection-level headers a caller must not set.
    nonisolated static let forbiddenHeaderNames: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "te", "trailer", "transfer-encoding", "upgrade",
        "host", "content-length", "expect", "accept-encoding",
    ]

    /// The flavour of a media request: which Chromium load it corresponds to.
    enum RequestFlavour {
        /// An `<img>` load: no-cors, image Accept.
        case image
        /// A `fetch()`/XHR by the renderer: cors mode.
        case cors
    }

    /// Headers Chromium 108 sends with the equivalent load (captured from the official client —
    /// `ClientFingerprint`, `reanalysis/wire-fingerprint.md`). Only names the caller did not set
    /// are filled in. URLSession decodes gzip and brotli even when Accept-Encoding is set by us.
    nonisolated static func applyClientHeaders(to request: inout URLRequest, flavour: RequestFlavour) {
        func setDefault(_ name: String, _ value: String) {
            if request.value(forHTTPHeaderField: name) == nil { request.setValue(value, forHTTPHeaderField: name) }
        }
        setDefault("User-Agent", ClientFingerprint.userAgent)
        setDefault("sec-ch-ua", ClientFingerprint.secCHUA)
        setDefault("sec-ch-ua-mobile", ClientFingerprint.secCHUAMobile)
        setDefault("sec-ch-ua-platform", ClientFingerprint.secCHUAPlatform)
        setDefault("accept-language", ClientFingerprint.acceptLanguage())
        setDefault("accept-encoding", ClientFingerprint.acceptEncoding)
        switch flavour {
        case .image:
            setDefault("Accept", ClientFingerprint.imageAccept)
            setDefault("sec-fetch-dest", "image")
            setDefault("sec-fetch-mode", "no-cors")
        case .cors:
            setDefault("Accept", "*/*")
            setDefault("sec-fetch-dest", "empty")
            setDefault("sec-fetch-mode", "cors")
        }
        setDefault("sec-fetch-site", "cross-site")
    }

    /// The same header set as a dict, for `PinnedHTTPSClient` — which builds its own HTTP/1.1
    /// requests and cannot accept compressed responses (no Accept-Encoding passed).
    nonisolated static func clientHeaders(_ flavour: RequestFlavour) -> [String: String] {
        var headers: [String: String] = [
            "sec-ch-ua": ClientFingerprint.secCHUA,
            "sec-ch-ua-mobile": ClientFingerprint.secCHUAMobile,
            "sec-ch-ua-platform": ClientFingerprint.secCHUAPlatform,
            "accept-language": ClientFingerprint.acceptLanguage(),
            "sec-fetch-site": "cross-site",
        ]
        switch flavour {
        case .image:
            headers["Accept"] = ClientFingerprint.imageAccept
            headers["sec-fetch-dest"] = "image"
            headers["sec-fetch-mode"] = "no-cors"
        case .cors:
            headers["Accept"] = "*/*"
            headers["sec-fetch-dest"] = "empty"
            headers["sec-fetch-mode"] = "cors"
        }
        return headers
    }

    /// Headers safe to send to `url`: names are RFC 7230 tokens, values hold no CR/LF/control characters,
    /// hop-by-hop names are dropped, and sensitive ones only go to https Zalo hosts.
    nonisolated static func sanitizedHeaders(_ headers: [String: String], for url: URL) -> [String: String] {
        let tokenChars = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~").union(.alphanumerics)
        let toZalo = url.scheme?.lowercased() == "https" && isZaloCDN(url.host ?? "")
        var out: [String: String] = [:]
        for (name, value) in headers {
            let lower = name.lowercased()
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenChars.contains($0) }),
                  !forbiddenHeaderNames.contains(lower),
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f || $0.value == 0x09 }) else { continue }
            if sensitiveHeaderNames.contains(lower), !toZalo { continue }
            out[name] = value
        }
        return out
    }

    /// The request to follow for a redirect: sensitive headers do not leave the host they were meant for.
    nonisolated static func redirectedRequest(_ request: URLRequest, originHost: String?) -> URLRequest {
        var next = request
        if let originHost, next.url?.host?.lowercased() != originHost {
            for name in sensitiveHeaderNames { next.setValue(nil, forHTTPHeaderField: name) }
            for name in next.allHTTPHeaderFields?.keys ?? [:].keys where sensitiveHeaderNames.contains(name.lowercased()) {
                next.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return next
    }

    /// GET with caller-supplied headers (Zalo Cloud downloads carry `cloud-viewer-key`), streamed to a
    /// temporary file that the caller moves into place (and must delete on failure paths it handles).
    /// Plain URLSession: no URL cache and no DoH (which cannot carry the headers). Capped at `maxBytes`,
    /// stalls fail after 30 s without data, and `ttfb` bounds the wait for the first byte only.
    /// Sensitive headers are dropped when a redirect changes host. Does not use the image download slots.
    func downloadWithHeaders(_ url: URL, headers: [String: String], maxBytes: Int = MediaLoader.maxFileBytes,
                             ttfb: TimeInterval? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let url = Self.normalized(url) else { throw LoadError.badURL }
        try failIfDead(url.host?.lowercased() ?? "")
        if let file = try await downloadWithHeadersViaHelper(url, headers: headers, maxBytes: maxBytes, ttfb: ttfb,
                                                             progress: progress, redirectsLeft: 5) {
            return file
        }
        var request = URLRequest(url: url)
        for (name, value) in Self.sanitizedHeaders(headers, for: url) { request.setValue(value, forHTTPHeaderField: name) }
        Self.applyClientHeaders(to: &request, flavour: .cors)
        let hub = FileProgress()
        let observer = progress.map { hub.add($0) }
        defer { if let observer { hub.remove(observer) } }
        let delegate = FileDownloadDelegate(progress: hub, limit: Int64(maxBytes), originHost: url.host?.lowercased())
        let watchdog: Task<Void, Never>? = ttfb.map { seconds in
            Task { [delegate] in
                try? await Task.sleep(for: .seconds(seconds))
                delegate.expireIfNoData()
            }
        }
        defer { watchdog?.cancel() }
        let downloaded: URL, response: URLResponse
        do {
            (downloaded, response) = try await fileSession.download(for: request, delegate: delegate)
        } catch {
            if delegate.exceeded { throw LoadError.tooLarge }
            if delegate.ttfbExpired { throw LoadError.timedOut }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: downloaded)
            throw LoadError.http(status)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else {
            try? FileManager.default.removeItem(at: downloaded)
            throw LoadError.tooLarge
        }
        return downloaded
    }

    // MARK: Fingerprint-helper paths (Chromium 108's TLS/HTTP2; URLSession/DoH are the fallback)

    /// nil = helper unavailable, caller falls back. A helper *upstream* failure is thrown
    /// (a retry on the other stack would change the fingerprint), except name-resolution
    /// failures, which the DoH machinery may still recover.
    private func helperOrFallback(_ error: Error) -> Error? {
        guard let failure = error as? FingerprintProxy.Error else { return error }
        switch failure {
        case .unavailable, .connectionLost:
            return nil
        case .tooLarge:
            return LoadError.tooLarge
        case .requestFailed(let message, _):
            if message.lowercased().contains("timeout") || message.lowercased().contains("canceled") {
                return LoadError.timedOut
            }
            let dnsish = ["no such host", "lookup", "dns", "connection refused", "connection reset"]
            if dnsish.contains(where: { message.lowercased().contains($0) }) { return nil }
            return failure
        }
    }

    private func helperHeaders(base: [String: String], url: URL, flavour: RequestFlavour) -> [(String, String)] {
        var ordered: [(String, String)] = Self.sanitizedHeaders(base, for: url).map { ($0.key, $0.value) }
        let defaults = Self.clientHeaders(flavour)
        let present = Set(ordered.map { $0.0.lowercased() })
        ordered.append(contentsOf: defaults.filter { !present.contains($0.0.lowercased()) }.map { ($0.key, $0.value) })
        return ordered
    }

    private func fetchImageViaHelper(_ url: URL) async throws -> Fetched? {
        guard await FingerprintProxy.shared.ready(seconds: 2) else { return nil }
        var request = FingerprintProxy.Request(url: url)
        request.headers = helperHeaders(base: [:], url: url, flavour: .image)
        request.timeoutMs = 20_000
        request.maxBytes = 96 << 20
        do {
            let response = try await FingerprintProxy.shared.perform(request)
            guard (200..<300).contains(response.head.status) else { throw LoadError.http(response.head.status) }
            let contentType = response.head.headers.first { $0.0.lowercased() == "content-type" }?.1
            store(response.body, for: url, contentType: contentType)
            return Fetched(data: response.body, framed: true, finalURL: URL(string: response.head.url) ?? url)
        } catch {
            if let fallback = helperOrFallback(error) { throw fallback }
            return nil
        }
    }

    private func fetchFileViaHelper(_ url: URL, directory: URL, progress: FileProgress) async throws -> URL? {
        guard await FingerprintProxy.shared.ready(seconds: 2) else { return nil }
        var request = FingerprintProxy.Request(url: url)
        request.headers = helperHeaders(base: [:], url: url, flavour: .cors)
        request.maxBytes = Int64(Self.maxFileBytes)
        request.idleMs = Int(Self.fileIdleTimeout * 1000)
        do {
            let start = try await FingerprintProxy.shared.stream(request)
            let head: FingerprintProxy.ResponseHead
            let events: AsyncThrowingStream<FingerprintProxy.StreamEvent, Swift.Error>
            switch start {
            case .head(let responseHead, let body):
                head = responseHead
                events = body
            case .complete(let response):
                head = response.head
                guard (200..<300).contains(head.status) else { throw LoadError.http(head.status) }
                let temp = Self.partFile(in: directory)
                try response.body.write(to: temp)
                return temp
            }
            guard (200..<300).contains(head.status) else { throw LoadError.http(head.status) }
            progress.reset()
            return try await streamToPartFile(events, directory: directory, progress: progress, head: head)
        } catch {
            if let fallback = helperOrFallback(error) { throw fallback }
            return nil
        }
    }

    private func downloadWithHeadersViaHelper(_ url: URL, headers: [String: String], maxBytes: Int,
                                              ttfb: TimeInterval?, progress: (@Sendable (Double) -> Void)?,
                                              redirectsLeft: Int) async throws -> URL? {
        guard await FingerprintProxy.shared.ready(seconds: 2) else { return nil }
        var request = FingerprintProxy.Request(url: url)
        request.follow = false // redirects are re-issued here, so per-hop headers stay under our control
        request.headers = helperHeaders(base: headers, url: url, flavour: .cors)
        request.maxBytes = Int64(maxBytes)
        request.idleMs = 30_000
        if let ttfb { request.firstByteMs = Int(ttfb * 1000) }
        let hub = FileProgress()
        let observer = progress.map { hub.add($0) }
        defer { if let observer { hub.remove(observer) } }
        do {
            let start = try await FingerprintProxy.shared.stream(request)
            switch start {
            case .complete(let response):
                // The helper's no-redirect answer: a 3xx to follow (sensitive headers do not
                // leave the host they were meant for, like the URLSession path), a 2xx with its
                // whole body, or an error status.
                if (300..<400).contains(response.head.status), redirectsLeft > 0,
                   let location = response.head.headers.first(where: { $0.0.lowercased() == "location" })?.1,
                   let next = URL(string: location, relativeTo: url)?.absoluteURL,
                   let normalized = Self.normalized(next) {
                    var nextHeaders = headers
                    if url.host?.lowercased() != normalized.host?.lowercased() {
                        for name in Self.sensitiveHeaderNames { nextHeaders.removeValue(forKey: name) }
                    }
                    return try await downloadWithHeadersViaHelper(normalized, headers: nextHeaders, maxBytes: maxBytes,
                                                                  ttfb: ttfb, progress: progress, redirectsLeft: redirectsLeft - 1)
                }
                guard (200..<300).contains(response.head.status) else { throw LoadError.http(response.head.status) }
                let temp = Self.partFile(in: Self.partsDirectory())
                try response.body.write(to: temp)
                return temp
            case .head(let head, let events):
                guard (200..<300).contains(head.status) else { throw LoadError.http(head.status) }
                hub.reset()
                return try await streamToPartFile(events, directory: Self.partsDirectory(), progress: hub, head: head)
            }
        } catch {
            if let fallback = helperOrFallback(error) { throw fallback }
            return nil
        }
    }

    /// Where `.part` files of helper downloads live until the caller moves them into place.
    private nonisolated static func partsDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Olaz-parts", isDirectory: true)
    }

    private func expectedBytes(_ head: FingerprintProxy.ResponseHead) -> Int? {
        head.headers.first { $0.0.lowercased() == "content-length" }.flatMap { Int($0.1) }
    }

    /// Streams a body into a fresh `.part` file; progress and cancellation are honoured.
    private func streamToPartFile(_ events: AsyncThrowingStream<FingerprintProxy.StreamEvent, Swift.Error>,
                                  directory: URL, progress: FileProgress?,
                                  head: FingerprintProxy.ResponseHead) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = Self.partFile(in: directory)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temp)
        let expected = expectedBytes(head)
        do {
            var received = 0
            for try await event in events {
                switch event {
                case .chunk(let data):
                    try handle.write(contentsOf: data)
                    received += data.count
                    progress?.report(received: received, total: expected)
                case .end:
                    break
                }
            }
            try handle.close()
            return temp
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: Local files

    /// Roots `file://` media may be read from: Olaz's data directory (the official client's
    /// `ZaloDownloads`), its caches, and temporary attachment/screenshot staging folders.
    nonisolated(unsafe) static var allowedLocalRoots: [String] = [
        ZaloPlatform.defaultUserData.resolvingSymlinksInPath().path,
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz", isDirectory: true).resolvingSymlinksInPath().path,
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OlazAttachments", isDirectory: true).path,
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("olaz-screenshots", isDirectory: true).path,
    ]

    /// SwiftZalo's data directory (before the move to Olaz). The migrated message database still points at files the
    /// official client downloaded there (the migration clones, it does not move), so they stay readable, but never deletable.
    nonisolated static let legacyLocalRoots: [String] = [
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftZalo/ZaloData", isDirectory: true).resolvingSymlinksInPath().path,
    ]

    private nonisolated static let userPickedLock = NSLock()
    private nonisolated(unsafe) static var userPickedLocalPaths: Set<String> = []

    /// Marks a user-picked/dropped attachment file as readable by `MediaLoader` (never deletable by `isOwnLocalFile`).
    nonisolated static func allowUserAttachment(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        userPickedLock.lock()
        if userPickedLocalPaths.count > 500 { userPickedLocalPaths.removeAll() }
        userPickedLocalPaths.insert(path)
        userPickedLock.unlock()
    }

    /// A `file://` URL media may be read from: Olaz's own roots, the legacy one, or a user-picked attachment.
    nonisolated static func isAllowedLocalFile(_ url: URL) -> Bool {
        if isLocalFile(url, under: allowedLocalRoots + legacyLocalRoots) { return true }
        guard url.isFileURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        userPickedLock.lock()
        defer { userPickedLock.unlock() }
        return userPickedLocalPaths.contains(path)
    }

    /// A file Olaz may also delete (a corrupt download to fetch again): its own roots only.
    nonisolated static func isOwnLocalFile(_ url: URL) -> Bool {
        isLocalFile(url, under: allowedLocalRoots)
    }

    private nonisolated static func isLocalFile(_ url: URL, under roots: [String]) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    // MARK: Download

    private static func normalized(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              parts.host?.isEmpty == false else { return nil }
        if scheme == "http" { parts.scheme = "https" }     // ATS; Zalo CDN serves https
        return parts.url
    }

    private func download(_ url: URL, redirectsLeft: Int) async throws -> Fetched {
        guard let host = url.host?.lowercased() else { throw LoadError.badURL }
        try failIfDead(host)
        if let fetched = try await fetchImageViaHelper(url) { return fetched }
        return try await withDNSFallback(host: host, doh: {
            try await self.fetchViaDoHFetched(url, redirectsLeft: redirectsLeft)
        }, system: {
            var request = URLRequest(url: url)
            Self.applyClientHeaders(to: &request, flavour: .image)
            let (data, response) = try await self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw LoadError.http(status) }
            self.store(data, for: url, contentType: response.mimeType)
            return Fetched(data: data, framed: true, finalURL: url)
        })
    }

    /// Runs `system` (normal URLSession fetch) and `doh` (DoH + pinned SNI) with the DNS fallback policy:
    /// DoH first for hosts whose system lookup is known/probed bad, DoH as a retry when the system fetch
    /// fails like a DNS problem. DoH is only ever used for Zalo CDN hosts.
    private func withDNSFallback<T: Sendable>(host: String,
                                              confirmTimeouts: Bool = false,
                                              doh: () async throws -> T,
                                              system: () async throws -> T) async throws -> T {
        let allowDoH = Self.isZaloCDN(host)
        // Known-bad (or just probed as bad) system DNS: go straight to DoH.
        if allowDoH, await !systemResolves(host) {
            do {
                let result = try await doh()
                dohHosts[host] = Date().addingTimeInterval(Self.dohStickiness)
                return result
            } catch let loadError as LoadError {
                throw loadError
            } catch is CancellationError {
                throw CancellationError()
            } catch DoHResolver.ResolveError.notFound {
                markDead(host)                          // authoritative NXDOMAIN: the system resolver cannot know better
                throw LoadError.hostNotFound
            } catch {
                dohHosts[host] = nil                    // DoH path broke; give the system resolver a go
                systemOK[host] = Date().addingTimeInterval(30)
            }
        }
        do {
            return try await system()
        } catch let urlError as URLError where allowDoH && Self.isDNSFailure(urlError) {
            // A mid-transfer stall (file downloads) is not evidence of broken DNS: only fall back to DoH
            // (and remember the host) when a fresh lookup really fails.
            if confirmTimeouts, urlError.code == .timedOut, await Self.probeSystemDNS(host, timeout: 3) {
                throw LoadError.timedOut
            }
            // The system resolver can fail as -1003/-1006, as a bogus -1009 (stream error 50) or by stalling
            // until the request times out. Retry through DoH; remember the host only if that works.
            do {
                let result = try await doh()
                dohHosts[host] = Date().addingTimeInterval(Self.dohStickiness)
                return result
            } catch let loadError as LoadError {
                throw loadError                         // reached the server through DoH: a real HTTP error
            } catch is CancellationError {
                throw CancellationError()
            } catch DoHResolver.ResolveError.notFound {
                markDead(host)
                throw LoadError.hostNotFound
            } catch {
                throw urlError                          // DoH failed too (offline?): report the system error
            }
        }
    }

    private func failIfDead(_ host: String) throws {
        guard let until = deadHosts[host] else { return }
        if until > Date() { throw LoadError.hostNotFound }
        deadHosts[host] = nil
    }

    private func markDead(_ host: String) {
        if deadHosts.count > 1000 { deadHosts.removeAll() }
        deadHosts[host] = Date().addingTimeInterval(Self.deadHostTTL)
    }

    /// Cheap pre-flight: does the system resolver answer for `host` within a few seconds? One shared probe
    /// per host, so a stalled resolver cannot pile up blocked threads.
    private func systemResolves(_ host: String) async -> Bool {
        if let retryAt = dohHosts[host], retryAt > Date() { return false }
        if let until = systemOK[host], until > Date() { return true }
        let probe: Task<Bool, Never>
        if let existing = probes[host] {
            probe = existing
        } else {
            probe = Task { await Self.probeSystemDNS(host, timeout: 3) }
            probes[host] = probe
        }
        let ok = await probe.value
        if probes[host] != nil {
            probes[host] = nil
            if ok { systemOK[host] = Date().addingTimeInterval(300) } else { dohHosts[host] = Date().addingTimeInterval(20) }
        }
        return ok
    }

    nonisolated static func probeSystemDNS(_ host: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let code = getaddrinfo(host, "443", &hints, &result)
                if let result { freeaddrinfo(result) }
                once.resume(code == 0)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }

    nonisolated static func isDNSFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .timedOut: true
        default: false
        }
    }

    /// DoH-resolved, SNI-pinned fetch. Exposed for tests; normal callers use `data(for:)`.
    func fetchViaDoH(_ url: URL, redirectsLeft: Int = 3) async throws -> Data {
        try await fetchViaDoHFetched(url, redirectsLeft: redirectsLeft).data
    }

    private func fetchViaDoHFetched(_ url: URL, redirectsLeft: Int) async throws -> Fetched {
        guard let host = url.host?.lowercased(), url.scheme == "https", Self.isZaloCDN(host) else { throw LoadError.badURL }
        let addresses = try await resolver.resolve(host)
        let response: PinnedHTTPSClient.Response
        do {
            response = try await PinnedHTTPSClient.get(url, addresses: addresses, clientHeaders: Self.clientHeaders(.image))
        } catch {
            await resolver.invalidate(host)
            throw error
        }
        if [301, 302, 303, 307, 308].contains(response.status),
           let location = response.headers["location"],
           let next = URL(string: location, relativeTo: url)?.absoluteURL, redirectsLeft > 0,
           let normalized = Self.normalized(next) {
            return try await download(normalized, redirectsLeft: redirectsLeft - 1)
        }
        guard (200..<300).contains(response.status) else { throw LoadError.http(response.status) }
        if response.framed { store(response.body, for: url, contentType: response.headers["content-type"]) }
        return Fetched(data: response.body, framed: response.framed, finalURL: url)
    }

    /// Only ever called with complete (framed) bodies.
    private func store(_ data: Data, for url: URL, contentType: String?) {
        guard let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": contentType ?? "application/octet-stream",
            "Content-Length": String(data.count),
        ]) else { return }
        urlCache.storeCachedResponse(CachedURLResponse(response: http, data: data, userInfo: nil, storagePolicy: .allowed),
                                     for: URLRequest(url: url))
    }

    // MARK: Files (voice, documents, video)

    /// Fan-out of download progress to every caller sharing one in-flight file download.
    private final class FileProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [UUID: @Sendable (Double) -> Void] = [:]
        private var last = -1.0
        func add(_ observer: @escaping @Sendable (Double) -> Void) -> UUID {
            let id = UUID()
            lock.lock(); observers[id] = observer; lock.unlock()
            return id
        }
        func remove(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }
        /// A new attempt (redirect, DoH fallback) restarts the transfer from zero.
        func reset() {
            lock.lock()
            last = 0
            let callbacks = Array(observers.values)
            lock.unlock()
            for callback in callbacks { callback(0) }
        }
        /// Throttled to ~0.5% steps; unknown totals report nothing.
        func report(received: Int, total: Int?) {
            guard let total, total > 0 else { return }
            let fraction = min(1, Double(received) / Double(total))
            lock.lock()
            guard fraction - last >= 0.005 else { lock.unlock(); return }
            last = fraction
            let callbacks = Array(observers.values)
            lock.unlock()
            for callback in callbacks { callback(fraction) }
        }
    }

    private nonisolated static func partFile(in directory: URL) -> URL {
        directory.appendingPathComponent(".\(UUID().uuidString).part")
    }

    /// Downloads `url` through the same DoH-capable path and stores it under
    /// Caches/Olaz/files/<hash>.<ext> (reused when present). Returns the file URL.
    ///
    /// The body is streamed to a temporary file (no in-memory buffering, no 50 MB cap; the limit is
    /// `maxFileBytes`) and only renamed to its final name once complete, so a truncated or cancelled
    /// download never leaves a partial file behind. There is no total deadline, only a 30 s stall timeout.
    /// `progress` (called on arbitrary threads, 0...1) is optional.
    func localFile(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let normalized = Self.normalized(url) else { throw LoadError.badURL }
        let directory = filesDirectory
        let ext = normalized.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(8)
        let name = Self.stableHash(normalized.absoluteString) + (ext.isEmpty ? "" : "." + ext)
        let file = directory.appendingPathComponent(name)
        startMaintenanceIfNeeded()
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)   // LRU use
            progress?(1)
            return file
        }
        do {
            let result = try await join(key: "f:" + file.path, observer: progress) { [self] hub -> URL in
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let temp = try await self.fetchFileToTemp(normalized, directory: directory, redirectsLeft: 3, progress: hub)
                    defer { try? FileManager.default.removeItem(at: temp) }     // no-op once moved
                    if FileManager.default.fileExists(atPath: file.path) { return file }   // lost a race: other copy is complete
                    // Quarantine before the final name appears, so the file is never visible without it.
                    Self.applyQuarantine(to: temp, origin: normalized)
                    Self.syncToDisk(temp)
                    do {
                        try FileManager.default.moveItem(at: temp, to: file)    // same directory: atomic rename
                    } catch {
                        guard FileManager.default.fileExists(atPath: file.path) else { throw error }
                    }
                    return file
                } catch {
                    // The URLSession path reports cancellation as URLError(.cancelled).
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    throw error
                }
            }
            progress?(1)
            scheduleTrim(keeping: file)
            return result
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }
    }

    /// Marks a downloaded file with `com.apple.quarantine` so Gatekeeper vets it when opened.
    nonisolated static func applyQuarantine(to file: URL, origin: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Olaz",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineOriginURLKey as String: origin,
        ]
        var target = file
        try? target.setResourceValues(values)
    }

    private nonisolated static func syncToDisk(_ file: URL) {
        guard let handle = try? FileHandle(forUpdating: file) else { return }
        try? handle.synchronize()
        try? handle.close()
    }

    // MARK: Files cache maintenance

    private func startMaintenanceIfNeeded() {
        guard !didStartMaintenance else { return }
        didStartMaintenance = true
        scheduleTrim(keeping: nil)
    }

    private func scheduleTrim(keeping keep: URL?) {
        let directory = filesDirectory, limit = filesCacheLimit
        Task.detached(priority: .utility) {
            Self.trimFiles(in: directory, limit: limit, keeping: keep)
        }
    }

    /// Deletes stale `.part` files (older than `partAge`, so never one an active download is still writing)
    /// and evicts least-recently-used completed files until the total is within `limit`. `keep` is never evicted.
    nonisolated static func trimFiles(in directory: URL, limit: Int, keeping keep: URL? = nil,
                                      partAge: TimeInterval = MediaLoader.stalePartAge, now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .contentAccessDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: []) else { return }
        var entries: [(url: URL, size: Int, used: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if name.hasSuffix(".part"), now.timeIntervalSince(modified) > partAge { try? fm.removeItem(at: url) }
                continue
            }
            entries.append((url, values.fileSize ?? 0, max(modified, values.contentAccessDate ?? .distantPast)))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > limit {
            if let keep, entry.url.standardizedFileURL == keep.standardizedFileURL { continue }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Downloads `url` into a fresh `.part` file in `directory` and returns it; throws (leaving no file)
    /// on any failure, truncation or cancellation.
    private func fetchFileToTemp(_ url: URL, directory: URL, redirectsLeft: Int, progress: FileProgress) async throws -> URL {
        guard let host = url.host?.lowercased() else { throw LoadError.badURL }
        try failIfDead(host)
        if let file = try await fetchFileViaHelper(url, directory: directory, progress: progress) { return file }
        return try await withDNSFallback(host: host, confirmTimeouts: true, doh: {
            try await self.fetchFileViaDoH(url, directory: directory, redirectsLeft: redirectsLeft, progress: progress)
        }, system: {
            try await self.fetchFileViaSession(url, directory: directory, progress: progress)
        })
    }

    private func fetchFileViaDoH(_ url: URL, directory: URL, redirectsLeft: Int, progress: FileProgress) async throws -> URL {
        guard let host = url.host?.lowercased(), url.scheme == "https", Self.isZaloCDN(host) else { throw LoadError.badURL }
        let addresses = try await resolver.resolve(host)
        progress.reset()
        let temp = Self.partFile(in: directory)
        let response: PinnedHTTPSClient.Response
        do {
            response = try await PinnedHTTPSClient.download(url, addresses: addresses, to: temp,
                                                            idleTimeout: Self.fileIdleTimeout,
                                                            maxBody: Self.maxFileBytes,
                                                            clientHeaders: Self.clientHeaders(.cors)) { received, total in
                progress.report(received: received, total: total)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if error is CancellationError { throw error }
            if let parseError = error as? HTTPResponseParser.ParseError, parseError == .tooLarge { throw LoadError.tooLarge }
            if let clientError = error as? PinnedHTTPSClient.ClientError, clientError == .timedOut { throw LoadError.timedOut }
            await resolver.invalidate(host)
            throw error
        }
        if [301, 302, 303, 307, 308].contains(response.status),
           let location = response.headers["location"],
           let next = URL(string: location, relativeTo: url)?.absoluteURL, redirectsLeft > 0,
           let normalized = Self.normalized(next) {
            try? FileManager.default.removeItem(at: temp)
            return try await fetchFileToTemp(normalized, directory: directory, redirectsLeft: redirectsLeft - 1, progress: progress)
        }
        guard (200..<300).contains(response.status) else {
            try? FileManager.default.removeItem(at: temp)
            throw LoadError.http(response.status)
        }
        return temp
    }

    /// Per-task delegate: reports progress, aborts transfers larger than `limit`, optionally enforces a
    /// time-to-first-byte, and drops sensitive headers when a redirect leaves the original host.
    private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progress: FileProgress
        private let limit: Int64
        private let originHost: String?
        private let lock = NSLock()
        private var _exceeded = false
        private var _gotData = false
        private var _ttfbExpired = false
        private weak var task: URLSessionTask?
        var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return _exceeded }
        var ttfbExpired: Bool { lock.lock(); defer { lock.unlock() }; return _ttfbExpired }
        init(progress: FileProgress, limit: Int64 = Int64(MediaLoader.maxFileBytes), originHost: String? = nil) {
            self.progress = progress; self.limit = limit; self.originHost = originHost
        }

        func expireIfNoData() {
            lock.lock()
            let expire = !_gotData
            if expire { _ttfbExpired = true }
            let task = self.task
            lock.unlock()
            if expire { task?.cancel() }
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.lock(); self.task = task; lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(MediaLoader.redirectedRequest(request, originHost: originHost))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            lock.lock(); _gotData = true; lock.unlock()
            if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
                lock.lock(); _exceeded = true; lock.unlock()
                downloadTask.cancel()
                return
            }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else { return }
            progress.report(received: Int(totalBytesWritten),
                            total: totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite) : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            lock.lock(); _gotData = true; lock.unlock()
        }
    }

    private func fetchFileViaSession(_ url: URL, directory: URL, progress: FileProgress) async throws -> URL {
        progress.reset()
        let delegate = FileDownloadDelegate(progress: progress)
        var request = URLRequest(url: url)
        Self.applyClientHeaders(to: &request, flavour: .cors)
        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await fileSession.download(for: request, delegate: delegate)
        } catch {
            if delegate.exceeded { throw LoadError.tooLarge }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: downloaded)
            throw LoadError.http(status)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? Int) ?? 0
        guard size <= Self.maxFileBytes else {
            try? FileManager.default.removeItem(at: downloaded)
            throw LoadError.tooLarge
        }
        let temp = Self.partFile(in: directory)
        do {
            try FileManager.default.moveItem(at: downloaded, to: temp)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return temp
    }

    /// FNV-1a 64-bit, hex (stable across launches, unlike `hashValue`).
    nonisolated static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    /// Test hook: has this host been switched to the DoH path?
    func usesDoH(host: String) -> Bool { (dohHosts[host.lowercased()] ?? .distantPast) > Date() }
}
