import Foundation

/// `$znode.fs`, `$znode.fsPromise`, `$znode.fsExtra` — the Node file APIs the
/// preload exposed (member list taken from the live client). Writes are confined
/// to Olaz's data and temp directories; errors carry Node codes (`ENOENT`…).
@MainActor
enum FileSystemBridge {
    struct FSError: LocalizedError {
        let code: String
        let path: String
        var errorDescription: String? { "\(code): \(path)" }
    }

    static func install(on bridge: ZaloBridge, platform: ZaloPlatform) {
        let fm = platform.fileManager

        func writable(_ path: String) throws -> String {
            guard platform.isWritable(path) else { throw FSError(code: "EACCES", path: path) }
            return path
        }
        // Reads (and the source of move/copy/link) are confined like writes, to `readableRoots` (issue #1.3).
        // Outside them a path looks absent: exists → false, stat/access → ENOENT; content reads → EACCES.
        func readable(_ path: String) -> Bool { isReadable(path, platform: platform) }
        func exists(_ path: String) -> Bool { readable(path) && fm.fileExists(atPath: path) }
        func requireExists(_ path: String) throws -> String {
            guard exists(path) else { throw FSError(code: "ENOENT", path: path) }
            return path
        }
        func requireReadable(_ path: String) throws -> String {
            guard readable(path) else { throw FSError(code: "EACCES", path: path) }
            return try requireExists(path)
        }

        /// Node `fs.Stats`-shaped object; methods are rebuilt in JS (`local-modules.js`).
        func stat(_ path: String) throws -> [String: Any] {
            let attrs = try fm.attributesOfItem(atPath: try requireExists(path))
            let type = attrs[.type] as? FileAttributeType
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date ?? .distantPast).timeIntervalSince1970 * 1000
            let birth = (attrs[.creationDate] as? Date ?? .distantPast).timeIntervalSince1970 * 1000
            return [
                "__stats": true,
                "size": size,
                "mode": (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0,
                "mtimeMs": mtime, "ctimeMs": mtime, "atimeMs": mtime, "birthtimeMs": birth,
                "isFile": type == .typeRegular,
                "isDirectory": type == .typeDirectory,
                "isSymbolicLink": type == .typeSymbolicLink,
            ]
        }
        func mkdir(_ path: String, recursive: Bool) throws {
            var isDir: ObjCBool = false
            // fs-extra ensureDir / mkdir -p: an existing directory is success.
            if recursive, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return }
            try fm.createDirectory(atPath: try writable(path), withIntermediateDirectories: recursive)
        }
        func remove(_ path: String) throws {
            if exists(path) { try fm.removeItem(atPath: try writable(path)) }
        }
        func readdir(_ path: String) throws -> [String] {
            try fm.contentsOfDirectory(atPath: try requireExists(path)).sorted()
        }
        func move(_ from: String, _ to: String) throws {
            _ = try writable(to)
            if exists(to) { try fm.removeItem(atPath: to) }
            try fm.moveItem(atPath: try requireReadable(from), toPath: to)
        }
        func copy(_ from: String, _ to: String) throws {
            _ = try writable(to)
            if exists(to) { try fm.removeItem(atPath: to) }
            try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.copyItem(atPath: try requireReadable(from), toPath: to)
        }
        func recursive(_ options: Any?) -> Bool {
            ((options as? [String: Any])?["recursive"] as? NSNumber)?.boolValue ?? false
        }

        // Each operation is available as async (callback/promise) and, where Node has one, *Sync.
        func both(_ names: [String], sync syncNames: [String] = [], _ body: @escaping ZaloBridge.SyncHandler) {
            for name in names { bridge.async(name) { args in try body(args) } }
            for name in syncNames { bridge.sync(name, body) }
        }

        both(["$znode.fs.access", "$znode.fsPromise.access"], sync: ["$znode.fs.accessSync"]) { args in
            _ = try requireExists(args.string(0) ?? "")
            return nil
        }
        // Node's legacy fs.exists(path, cb) calls back with a bare boolean.
        bridge.sync("$znode.fs.existsSync") { args in exists(args.string(0) ?? "") }
        bridge.sync("$znode.fsExtra.existsSync") { args in exists(args.string(0) ?? "") }
        bridge.async("$znode.fsExtra.pathExists") { args in exists(args.string(0) ?? "") }
        both(["$znode.fs.stat", "$znode.fs.lstat", "$znode.fsPromise.stat", "$znode.fsPromise.lstat"],
             sync: ["$znode.fs.statSync", "$znode.fsExtra.statSync"]) { args in try stat(args.string(0) ?? "") }
        both(["$znode.fs.mkdir", "$znode.fsPromise.mkdir"], sync: ["$znode.fs.mkdirSync"]) { args in
            try mkdir(args.string(0) ?? "", recursive: recursive(args.count > 1 ? args[1] : nil))
            return nil
        }
        both(["$znode.fsExtra.ensureDir"], sync: ["$znode.fsExtra.ensureDirSync"]) { args in
            try mkdir(args.string(0) ?? "", recursive: true)
            return nil
        }
        both(["$znode.fs.readdir", "$znode.fsPromise.readdir"], sync: ["$znode.fs.readdirSync"]) { args in
            try readdir(args.string(0) ?? "")
        }
        both(["$znode.fs.unlink", "$znode.fsPromise.unlink", "$znode.fs.rmdir", "$znode.fsPromise.rmdir",
              "$znode.fsPromise.rm", "$znode.fsExtra.remove"],
             sync: ["$znode.fs.unlinkSync", "$znode.fsExtra.removeSync"]) { args in
            try remove(args.string(0) ?? "")
            return nil
        }
        both(["$znode.fsExtra.move", "$znode.fsExtra.rename"], sync: ["$znode.fsExtra.renameSync"]) { args in
            try move(args.string(0) ?? "", args.string(1) ?? "")
            return nil
        }
        both(["$znode.fsExtra.copy"], sync: ["$znode.fsExtra.copySync"]) { args in
            try copy(args.string(0) ?? "", args.string(1) ?? "")
            return nil
        }
        both(["$znode.fs.link", "$znode.fsPromise.link"]) { args in
            try fm.linkItem(atPath: try requireReadable(args.string(0) ?? ""), toPath: try writable(args.string(1) ?? ""))
            return nil
        }
        bridge.async("$znode.fs.exists") { args in exists(args.string(0) ?? "") }
        // rimraf v3 (`rimraf(path, cb(err))`): recursive delete, a missing path is success. Used when a deleted photo's cached copies
        // under ZaloDownloads/resource go, and by the resource / temp-folder cleanups. Paths are taken literally (no glob expansion).
        bridge.async("$znode.rimraf") { args in
            try remove(args.string(0) ?? "")
            return nil
        }

        // nativelibs.fileUtilities().detectHardlinksAsync(file, dir) → the paths under `dir` that are hard links of `file` (itself included
        // when it is there). The media cleanup asks it before removing a cached copy that may be shared with another resource.
        bridge.async("$znode.nativelibs.fileUtilitiesAddon.detectHardlinksAsync") { args in
            let file = args.string(0) ?? "", scope = args.string(1) ?? ""
            // Outside the readable roots: "not shared" (the official callers' answer for a missing file).
            guard readable(file), readable(scope) else { return [String]() }
            return try await Task.detached(priority: .utility) { try FileSystemBridge.hardlinks(of: file, under: scope) }.value
        }

        // nativelibs.fileUtils().getDiskUsage(path) — synchronous volume stats.
        bridge.sync("$znode.nativelibs.fileUtilsAddon.getDiskUsage") { args in
            let url = URL(fileURLWithPath: args.string(0) ?? "/")
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return ["total": total, "free": available, "available": available, "used": max(0, total - available)]
        }

        // Whole-file helpers used across $zFileManager.
        bridge.async("$znode.fs.readFile") { args in
            let path = try requireReadable(args.string(0) ?? "")
            let data = fm.contents(atPath: path) ?? Data()
            let encoding = args.string(1) ?? args.dict(1)?["encoding"] as? String
            return encoding == nil ? data : String(decoding: data, as: UTF8.self)
        }
        bridge.async("$znode.fs.writeFile") { args in
            let path = try writable(args.string(0) ?? "")
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try (args.data(1) ?? Data()).write(to: URL(fileURLWithPath: path), options: .atomic)
            return nil
        }
    }

    /// Folders the renderer may read from (the write roots of `ZaloPlatform.isWritable` plus read-only extras):
    /// - Zalo data (`userData`: stores, z_u.txt, logs, ZaloDownloads/resource caches, db),
    /// - Olaz's temp folder and the whole per-user temp dir (`os.tmpdir()` reports it),
    /// - the Downloads folder (where Zalo saves received files),
    /// - `~/Library/Caches/Olaz` (media / file caches, download temps, staged previews written by Swift),
    /// - the installed Zalo runtime (official code; nothing private).
    /// Files the user picks reach the page as WebKit `File`s (`evaluate(_:providingFiles:)`), not through this bridge.
    static func readableRoots(platform: ZaloPlatform) -> [String] {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Olaz", isDirectory: true)
        return [platform.userData.path, platform.path("temp"), platform.path("downloads"),
                fm.temporaryDirectory.path, caches.path, ZaloRuntime.current.path]
    }

    /// Whether `path` (symlinks resolved, like `ZaloPlatform.isWritable`) lies inside `readableRoots`.
    static func isReadable(_ path: String, platform: ZaloPlatform) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        let resolved = canonical(path)
        return readableRoots(platform: platform).map(canonical).contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }

    /// Absolute, standardized, symlinks resolved on the longest existing ancestor (components that do not exist yet cannot be links).
    nonisolated static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
            rest.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for part in rest { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL.path
    }

    /// Hard links of `file` under `scope` (same device and inode). A missing file, or one with a single link, has none: the official callers
    /// treat both as "not shared". The walk is bounded so a huge resource folder cannot stall a cleanup.
    nonisolated static func hardlinks(of file: String, under scope: String, limit: Int = 200_000) throws -> [String] {
        var target = stat()
        guard !file.isEmpty, lstat(file, &target) == 0, target.st_nlink > 1, !scope.isEmpty,
              let walker = FileManager.default.enumerator(atPath: scope) else { return [] }
        let root = (scope as NSString).standardizingPath
        var links: [String] = []
        var seen = 0
        while let relative = walker.nextObject() as? String, seen < limit {
            seen += 1
            let path = (root as NSString).appendingPathComponent(relative)
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if info.st_ino == target.st_ino, info.st_dev == target.st_dev { links.append(path) }
        }
        return links
    }
}
