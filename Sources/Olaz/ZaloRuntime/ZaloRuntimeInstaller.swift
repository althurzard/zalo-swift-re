import CryptoKit
import Foundation
import Security
import os

private let runtimeLog = Logger(subsystem: "app.olaz", category: "runtime")

/// The official Zalo PC code Olaz runs, kept in Olaz's own Application Support folder so Zalo PC never has to be
/// installed. Olaz does not ship VNG's code: on first launch `ZaloRuntimeInstaller` fetches the official installer from
/// VNG (or copies an installed Zalo.app of the same version), checks VNG's code signature and keeps the parts Olaz uses:
///
///   ZaloRuntime/current/Contents/Info.plist             version
///   ZaloRuntime/current/Contents/Resources/app.asar     the renderer (`pc-dist`), served by `AsarSchemeHandler`
///   ZaloRuntime/current/Contents/ZaloHelper.app         ZaloCall (calls) and ZaloCap (screenshots), signed by VNG
///
/// Electron and the main process's native modules (`app.asar.unpacked`) are not needed: Swift plays the main process.
/// The folder keeps Zalo.app's `Contents/…` layout, so paths resolve as they did inside Zalo.app, but is not named
/// `.app`: LaunchServices must not register a partial Zalo (it declares `zalo://`).
enum ZaloRuntime {
    struct Release: Equatable, Sendable {
        var version: String
        var url: URL
        /// SHA-256 (hex) of the DMG when the release is pinned.
        var sha256: String?
    }

    /// The Zalo PC release this Olaz build is tested with. Bumping it (version, DMG URL, DMG checksum) is how Olaz moves
    /// to a newer Zalo: an older runtime is upgraded in the background and swapped in at the next launch.
    static let pinned = Release(
        version: "26.10.20",
        url: URL(string: "https://res-download-pc.zadn.vn/mac/ZaloSetup-universal-26.10.20.dmg")!,
        sha256: "a45d30b7f7b060f76b87722ef419b8f41d23a2913cdef084dcb0955dde8d85a0")

    /// The download button of zalo.me/pc: redirects a Mac browser to the current DMG. Used when the pinned one is gone.
    static let latestLink = URL(string: "https://zalo.me/download/zalo-pc")!

    /// What is copied out of Zalo.app.
    static let parts = ["Contents/Info.plist", "Contents/Resources/app.asar", "Contents/ZaloHelper.app"]

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz/ZaloRuntime", isDirectory: true)
    }
    /// The runtime in use.
    static var current: URL { root.appendingPathComponent("current", isDirectory: true) }
    /// A verified upgrade, swapped in by `prepareForLaunch`.
    static var pending: URL { root.appendingPathComponent("pending", isDirectory: true) }
    /// Downloads, mounts and half-copied folders; emptied at every launch.
    static var work: URL { root.appendingPathComponent("work", isDirectory: true) }

    static func helper(_ name: String, in runtime: URL) -> URL {
        runtime.appendingPathComponent("Contents/ZaloHelper.app/Contents/MacOS/\(name)")
    }

    static func isComplete(_ runtime: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: runtime.appendingPathComponent("Contents/Info.plist").path)
            && fm.fileExists(atPath: runtime.appendingPathComponent("Contents/Resources/app.asar").path)
            && fm.isExecutableFile(atPath: helper("ZaloCall", in: runtime).path)
    }

    /// `CFBundleShortVersionString` of a Zalo.app or runtime folder.
    static func version(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// At launch, before anything reads the runtime: drops leftovers of interrupted installs and swaps in a prepared upgrade.
    static func prepareForLaunch(root: URL = root) {
        let fm = FileManager.default
        let current = root.appendingPathComponent("current", isDirectory: true)
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try? fm.removeItem(at: work)
        guard fm.fileExists(atPath: pending.path) else { return }
        guard isComplete(pending) else {
            try? fm.removeItem(at: pending)
            return
        }
        let retired = work.appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            if fm.fileExists(atPath: current.path) { try fm.moveItem(at: current, to: retired) }
            try fm.moveItem(at: pending, to: current)
            runtimeLog.info("runtime: switched to Zalo \(version(of: current) ?? "?", privacy: .public)")
        } catch {
            // Keep the old runtime; the upgrade is prepared again later.
            if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: retired.path) { try? fm.moveItem(at: retired, to: current) }
            runtimeLog.error("runtime: upgrade not applied: \(error.localizedDescription, privacy: .public)")
        }
        try? fm.removeItem(at: retired)
    }

    /// `26.10.20` is newer than `26.9.10`: compared component-wise as numbers.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// `ZaloSetup-universal-26.10.20.dmg` → `26.10.20`.
    static func version(fromInstallerName name: String) -> String? {
        name.firstMatch(of: /^ZaloSetup-[A-Za-z0-9]+-(\d+(?:\.\d+)+)\.dmg$/).map { String($0.1) }
    }
}

/// Puts a verified runtime into a folder: `ZaloRuntime.current` on first launch, `ZaloRuntime.pending` for an upgrade.
///
/// Sources, in order: an installed Zalo.app of the pinned version (no download), the pinned DMG, and — when that is
/// gone — the DMG zalo.me/pc offers now. Whatever the source, the whole Zalo.app must pass VNG's code signature
/// (`kSecCSCheckNestedCode` covers app.asar and the helper app) before anything is copied.
struct ZaloRuntimeInstaller: Sendable {
    enum Step: Equatable, Sendable {
        case looking
        case downloading(received: Int64, total: Int64?)
        case verifying
        case installing
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Zalo's Developer ID team (VNG ONLINE CO.,LTD) and Zalo.app's bundle identifier.
    static let requirement = #"anchor apple generic and identifier "com.vng.zalo" and certificate leaf[subject.OU] = "CVB6BX97VM""#
    /// zalo.me only redirects a Mac browser to the Mac installer.
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    var release = ZaloRuntime.pinned
    /// Whether the DMG zalo.me/pc offers now may stand in when the pinned one cannot be had.
    var allowsLatest = true
    var work = ZaloRuntime.work
    var progress: @Sendable (Step) -> Void = { _ in }

    /// Installs into `destination`, replacing what is there; returns the Zalo version installed.
    func install(into destination: URL) async throws -> String {
        progress(.looking)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if let local = Self.installedZalo(version: release.version) {
            do {
                return try await stage(from: local, into: destination)
            } catch {
                runtimeLog.error("runtime: installed Zalo.app not usable: \(error.localizedDescription, privacy: .public)")
            }
        }
        let dmg = work.appendingPathComponent("ZaloSetup-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: dmg) }
        do {
            try await fetch(release, to: dmg)
        } catch let error where allowsLatest && !(error is CancellationError) {
            runtimeLog.error("runtime: Zalo \(release.version, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            try await fetch(try await Self.latestRelease(), to: dmg)
        }
        return try await installFromDiskImage(dmg, into: destination)
    }

    /// An installed Zalo.app of exactly `version`: copying it saves the download.
    static func installedZalo(version: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications/Zalo.app"), home.appendingPathComponent("Applications/Zalo.app")]
            .first { ZaloRuntime.version(of: $0) == version }
    }

    /// The release zalo.me/pc offers now, read from its redirect (nothing is downloaded).
    static func latestRelease() async throws -> ZaloRuntime.Release {
        var request = URLRequest(url: ZaloRuntime.latestLink)
        request.httpMethod = "HEAD"
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        // Ephemeral: the account's zalo.me cookies have no business on a download link.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: ZaloRuntime.latestLink)?.absoluteURL, url.scheme == "https",
              let version = ZaloRuntime.version(fromInstallerName: url.lastPathComponent) else {
            throw Failure(message: "Không tìm thấy bản Zalo PC cho Mac trên zalo.me.")
        }
        return ZaloRuntime.Release(version: version, url: url, sha256: nil)
    }

    static func verifySignature(of app: URL, requirement: String = requirement) throws {
        var code: SecStaticCode?
        var parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            throw Failure(message: "Không đọc được chữ ký của Zalo.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, parsed)
        guard status == errSecSuccess else {
            throw Failure(message: "Bộ cài Zalo không có chữ ký hợp lệ của VNG nên Olaz không dùng nó (mã \(status)).")
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Steps

    private func fetch(_ release: ZaloRuntime.Release, to file: URL) async throws {
        let report = downloadReporter()
        report(0, nil)
        do {
            try await Self.download(release.url, to: file, progress: report)
        } catch let error as URLError where [.cannotFindHost, .dnsLookupFailed].contains(error.code) {
            // Some ISP resolvers fail on *.zadn.vn; resolve over HTTPS as the media loader does.
            try await Self.downloadResolvingOverHTTPS(release.url, to: file, progress: report)
        }
        progress(.verifying)
        if let expected = release.sha256, try Self.sha256(of: file) != expected {
            throw Failure(message: "Bộ cài Zalo \(release.version) tải về không khớp mã kiểm tra.")
        }
    }

    private func installFromDiskImage(_ dmg: URL, into destination: URL) async throws -> String {
        let mount = work.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        let result: Result<String, Error>
        do {
            result = .success(try await stage(from: try Self.zaloApp(in: mount), into: destination))
        } catch {
            result = .failure(error)
        }
        try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        try? FileManager.default.removeItem(at: mount)
        return try result.get()
    }

    /// Checks VNG's signature on the whole Zalo.app, then copies `ZaloRuntime.parts` into `destination`.
    private func stage(from app: URL, into destination: URL) async throws -> String {
        progress(.verifying)
        try Self.verifySignature(of: app)
        guard let version = ZaloRuntime.version(of: app) else { throw Failure(message: "Không đọc được phiên bản Zalo.") }
        progress(.installing)
        let fm = FileManager.default
        let staging = work.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        for part in ZaloRuntime.parts {
            let target = staging.appendingPathComponent(part)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // ditto keeps the extended attributes some signed files carry.
            try await Self.run("/usr/bin/ditto", [app.appendingPathComponent(part).path, target.path])
        }
        try CallHelperSignature.verify(executable: ZaloRuntime.helper("ZaloCall", in: staging))
        guard ZaloRuntime.isComplete(staging) else { throw Failure(message: "Bản sao Zalo không đầy đủ.") }
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: destination)
        // ~270 MB that can always be fetched again: not worth a place in Time Machine.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = destination
        try? excluded.setResourceValues(values)
        runtimeLog.info("runtime: Zalo \(version, privacy: .public) installed from \(app.path, privacy: .public)")
        return version
    }

    // MARK: Plumbing

    private static func zaloApp(in volume: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: {
            $0.pathExtension == "app"
                && NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String == "com.vng.zalo"
        }) else { throw Failure(message: "Bộ cài không chứa Zalo.app.") }
        return app
    }

    /// Download progress, at most once per MB so the window is not redrawn for every packet.
    private func downloadReporter() -> @Sendable (Int64, Int64?) -> Void {
        let last = OSAllocatedUnfairLock(initialState: Int64.min)
        let progress = progress
        return { received, total in
            let due = last.withLock { last in
                guard received == 0 || received == total || received - last >= 1 << 20 else { return false }
                last = received
                return true
            }
            if due { progress(.downloading(received: received, total: total)) }
        }
    }

    private static func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        let delegate = DownloadDelegate(file: file, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// `download` for hosts the system resolver cannot find: DoH addresses, TLS still checked against the host name.
    private static func downloadResolvingOverHTTPS(_ url: URL, to file: URL,
                                                   progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let resolver = DoHResolver()
        var url = url
        for _ in 0..<5 {
            guard let host = url.host() else { break }
            let response = try await PinnedHTTPSClient.download(url, addresses: try await resolver.resolve(host), to: file,
                                                                idleTimeout: 60, maxBody: 2 << 30) { received, total in
                progress(Int64(received), total.map(Int64.init))
            }
            if (200..<300).contains(response.status) { return }
            guard (300..<400).contains(response.status), let location = response.headers["location"],
                  let next = URL(string: location, relativeTo: url)?.absoluteURL, next.scheme == "https" else {
                throw Failure(message: "Máy chủ tải Zalo trả về lỗi HTTP \(response.status).")
            }
            url = next
        }
        throw Failure(message: "Không tải được bộ cài Zalo (chuyển hướng quá nhiều lần).")
    }

    /// Runs a system tool to completion; its stderr becomes the error.
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let errors = stderr.fileHandleForReading
        let name = process.executableURL?.lastPathComponent ?? tool
        let output = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                drained.wait() // the reader below hits EOF once the tool is gone
                let message = String(decoding: output.withLock { $0 }, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure(message: "\(name) lỗi \(process.terminationStatus): \(message)"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            // Drain stderr while the tool runs: reading only after exit deadlocks once it fills the 64 KB pipe
            // buffer (the tool blocks on write, never exits, the termination handler never runs).
            DispatchQueue.global(qos: .utility).async {
                let data = errors.readDataToEndOfFile()
                output.withLock { $0 = data }
                drained.signal()
            }
        }
    }
}

/// Reports the redirect instead of following it.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Download task with progress. The file is moved into place before the delegate returns (URLSession deletes it after).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let file: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.file = file
        self.progress = progress
    }

    func start(_ task: URLSessionTask, continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        var error: Error?
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            error = ZaloRuntimeInstaller.Failure(message: "Máy chủ tải Zalo trả về lỗi HTTP \(status).")
        } else {
            do {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: location, to: file)
            } catch let moveError {
                error = moveError
            }
        }
        lock.lock(); failure = error; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        let failure = error ?? self.failure
        self.continuation = nil
        lock.unlock()
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    }
}
