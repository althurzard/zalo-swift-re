import Foundation
import SQLite3

/// Native SQLite behind the official client's data access layer (DAL).
///
/// Zalo PC 26.10 keeps every database (messages, conversations, contacts, search, …) in SQLite, served by a
/// `utility-process-sqlite` Electron utility process that the renderer reaches through a MessagePort channel. In Olaz
/// `HostScripts/sqlite-host.js` plays that process inside each page: it answers the official channel protocol and
/// executes every statement here, through the `$znode.sqliteHost.*` bridge members (`SQLiteHost.install`). This class
/// reproduces what the official connection class does with node-sqlite3 (`main-dist/utility-process-sqlite.js`):
///
/// - one database file per `fullname` under `<userData>/sqlite/_production/<fullname>.db` (the official
///   `getDBFilePath`), opened read-write/create with `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`;
/// - `run` resolves `{lastID, changes}` and treats a failed UNIQUE constraint as success (the official `run` does);
///   `runs` binds every parameter row of one prepared statement inside a transaction; `serialize` runs a list of
///   `run` / `runs` inside a transaction; `all` / `get` / `optimized-all` return rows as objects;
/// - errors carry node-sqlite3's shape: `errno` (SQLite result code) and `code` (`SQLITE_CONSTRAINT`, …), with the
///   message `"<code>: <sqlite message>"`;
/// - the schema-version handshake (`PRAGMA user_version` vs the version the renderer asks for) is coordinated here so
///   two pages opening the same database cannot both run the renderer's migration.
///
/// The official binding is SQLCipher; a database is only encrypted once the official "DB encryption" job ran on it,
/// which Olaz never starts (`DB_ENCRYPTION/CHECKSTT` → not started), so files stay plain SQLite — as IndexedDB was.
/// All work runs on one serial queue per database; the bridge handlers hop there and back to the main actor.
final class SQLiteHost: @unchecked Sendable {
    struct SQLiteError: LocalizedError {
        let errno: Int32
        let code: String
        let detail: String
        /// node-sqlite3 message: "SQLITE_CONSTRAINT: UNIQUE constraint failed: t.id".
        var message: String { "\(code): \(detail)" }
        /// Wire form for the bridge (`sqlite-host.js` parses it back into `{errno, code, message}`).
        var errorDescription: String? { "\(code):\(errno):\(detail)" }
        var isUniqueConstraint: Bool { errno == SQLITE_CONSTRAINT && detail.contains("UNIQUE constraint failed") }
    }

    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer
        let queue: DispatchQueue
        var sessional: Bool
        /// Set (on `queue`) right before `sqlite3_close_v2`: work queued behind a `close` must not touch the freed `db`.
        var closed = false
        init(db: OpaquePointer, name: String, sessional: Bool) {
            self.db = db
            self.sessional = sessional
            queue = DispatchQueue(label: "app.olaz.sqlite." + name)
        }
    }

    /// JSON payloads (`[Any]`, rows) crossing the database queue; the values are never shared.
    struct Unchecked<T>: @unchecked Sendable { let value: T }

    /// Schema-version handshake in flight for a database: later openers wait for it. Guarded by `lock`.
    private final class Migration: @unchecked Sendable {
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    /// How long an opener waits for another page's migration before treating it as abandoned (that page died
    /// mid-migration without `closeAll`).
    private static let migrationTimeout: TimeInterval = 60

    /// node-sqlite3's error for a statement on a closed database.
    static let closedError = SQLiteError(errno: SQLITE_MISUSE, code: "SQLITE_MISUSE", detail: "Database is closed")

    let root: URL
    private let lock = NSLock()
    private var connections: [String: Connection] = [:]
    private var migrations: [String: Migration] = [:]

    /// `root`: the directory that holds the database files (`<userData>/sqlite/_production`).
    init(root: URL) {
        self.root = root
    }

    // MARK: Files

    /// `<root>/<fullname>.db` (a fullname may hold path components: partitioned databases live in sub-directories).
    func fileURL(_ fullname: String) -> URL {
        var url = root
        for part in fullname.split(separator: "/").map(String.init) where part != "." && part != ".." && !part.isEmpty {
            url.appendPathComponent(part)
        }
        return url.appendingPathExtension("db")
    }

    private func sanitized(_ fullname: String) -> String {
        fullname.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty }.joined(separator: "/")
    }

    // MARK: Open / close

    /// Opens (creating) the database and returns its `PRAGMA user_version`. `requestedVersion` nil = whatever the file
    /// has (the official `null` version). `migrate` is true when the file is at another version and this caller must
    /// run the renderer's schema migration (`NEED-SCHEMA-MIGRATION`); it then calls `migrated(_:)`. A second opener
    /// during that time waits and gets `migrate: false`.
    func open(_ fullname: String, requestedVersion: Int?, sessional: Bool) async throws -> (userVersion: Int, migrate: Bool) {
        let name = sanitized(fullname)
        while true {
            if let pending = lock.withLock({ migrations[name] }) {
                await waitForMigration(pending, name: name)
                continue
            }
            // Connect after any wait: a `close` that released the wait also closed the previous connection.
            let connection = try connect(name, sessional: sessional)
            let current = try await onQueue(connection) { c in try Self.userVersion(c.db) }
            var requested = requestedVersion ?? current
            requested = max(requested, 1)
            guard current != requested else { return (current, false) }
            // Re-check under the lock: another opener may have claimed the migration during the `await` above.
            let claimed: Bool = lock.withLock {
                guard migrations[name] == nil else { return false }
                migrations[name] = Migration()
                return true
            }
            if claimed { return (current, true) }
        }
    }

    /// Suspends until `pending` ends (`migrated` / `close` / `closeAll`) or `migrationTimeout` elapses; returns at once
    /// when `pending` already ended. On timeout the migration is dropped as abandoned, so `open`'s loop re-reads the
    /// version and one opener may claim it.
    private func waitForMigration(_ pending: Migration, name: String) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let registered: Bool = lock.withLock {
                guard migrations[name] === pending else { return false }
                pending.waiters[id] = continuation
                return true
            }
            guard registered else { continuation.resume(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.migrationTimeout) { [self] in
                let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                    guard pending.waiters[id] != nil else { return [] } // already released
                    if migrations[name] === pending { migrations.removeValue(forKey: name) }
                    defer { pending.waiters.removeAll() }
                    return Array(pending.waiters.values)
                }
                waiters.forEach { $0.resume() }
            }
        }
    }

    /// Removes `name`'s migration (if any) and returns its waiters, to resume outside the lock. Call with `lock` held.
    private func endMigrationLocked(_ name: String) -> [CheckedContinuation<Void, Never>] {
        guard let pending = migrations.removeValue(forKey: name) else { return [] }
        defer { pending.waiters.removeAll() }
        return Array(pending.waiters.values)
    }

    /// The renderer finished (or failed) the schema migration started by `open`.
    func migrated(_ fullname: String) {
        let name = sanitized(fullname)
        let waiters = lock.withLock { endMigrationLocked(name) }
        waiters.forEach { $0.resume() }
    }

    func close(_ fullname: String) async {
        let name = sanitized(fullname)
        // A migration cannot outlive its database: release anyone waiting for it.
        let (connection, waiters) = lock.withLock { (connections.removeValue(forKey: name), endMigrationLocked(name)) }
        waiters.forEach { $0.resume() }
        guard let connection else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.queue.async {
                connection.closed = true
                sqlite3_close_v2(connection.db)
                continuation.resume()
            }
        }
    }

    func closeAll() async {
        // Also drop migrations whose page died mid-handshake (otherwise every later `open` waits on them).
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            Array(migrations.keys).flatMap { endMigrationLocked($0) }
        }
        waiters.forEach { $0.resume() }
        for name in lock.withLock({ Array(connections.keys) }) { await close(name) }
    }

    func closeSessional() async {
        for name in lock.withLock({ connections.filter { $0.value.sessional }.map(\.key) }) { await close(name) }
    }

    /// Closes and removes the database and its WAL / shm files.
    func delete(_ fullname: String) async {
        await close(fullname)
        let url = fileURL(fullname)
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(atPath: url.path + suffix)
        }
    }

    /// Official `DAL_UTILITY/GET_PARTITION_KEYS`: `[""]` when `<fullname>.db` exists, else the names of the `.db`
    /// files in every sub-directory of `<root>/<fullname>/`.
    func partitionKeys(_ fullname: String) -> [String] {
        let fm = FileManager.default
        let base = fileURL(fullname).deletingPathExtension()
        if fm.fileExists(atPath: base.path + ".db") { return [""] }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let groups = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        var keys: [String] = []
        for group in groups {
            let dir = base.appendingPathComponent(group)
            var isSub: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isSub), isSub.boolValue,
                  let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            keys += files.filter { $0.hasSuffix(".db") }.map { String($0.dropLast(3)) }
        }
        return keys
    }

    private func connect(_ name: String, sessional: Bool) throws -> Connection {
        if let existing = lock.withLock({ connections[name] }) {
            lock.withLock { existing.sessional = existing.sessional || sessional }
            return existing
        }
        let url = fileURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let error = Self.error(handle, fallback: rc)
            if let handle { sqlite3_close_v2(handle) }
            throw error
        }
        // The official connection: WAL, journal_size_limit, busy_timeout, synchronous NORMAL, cache_spill, analysis_limit…
        let setup = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000; PRAGMA journal_size_limit=67108864; PRAGMA temp_store=MEMORY;"
        if sqlite3_exec(db, setup, nil, nil, nil) != SQLITE_OK {
            let error = Self.error(db, fallback: SQLITE_ERROR)
            sqlite3_close_v2(db)
            throw error
        }
        let connection = Connection(db: db, name: name, sessional: sessional)
        return lock.withLock {
            if let raced = connections[name] {
                sqlite3_close_v2(db)
                return raced
            }
            connections[name] = connection
            return connection
        }
    }

    private func connection(_ fullname: String) throws -> Connection {
        let name = sanitized(fullname)
        if let existing = lock.withLock({ connections[name] }) { return existing }
        return try connect(name, sessional: false)
    }

    // MARK: Statements (the official `libMethod`s)

    struct Statement: @unchecked Sendable {
        var query: String
        var params: [Any]
    }

    /// `run`: `{lastID, changes}`; a failed UNIQUE constraint still resolves (official behaviour).
    func run(_ fullname: String, _ statement: Statement) async throws -> [String: Any] {
        let connection = try connection(fullname)
        return try await onQueue(connection) { c in
            do { try Self.execute(c.db, statement) } catch let error as SQLiteError where error.isUniqueConstraint {}
            return Unchecked(value: ["lastID": sqlite3_last_insert_rowid(c.db), "changes": Int64(sqlite3_changes(c.db))] as [String: Any])
        }.value
    }

    /// `runs`: one prepared statement bound with every row of `rows`, in a transaction.
    /// Rows arrive `Unchecked`-boxed: the bridge arguments are freshly decoded JSON, but Swift 6.4's
    /// region isolation cannot prove that at the (main-actor → serial-queue) hop, and `sending` alone
    /// no longer suffices for `[[Any]]`.
    func runs(_ fullname: String, query: String, rows: Unchecked<[[Any]]>) async throws {
        let connection = try connection(fullname)
        let boxed = rows
        try await onQueue(connection) { c in
            try Self.transaction(c.db) {
                let prepared = try Self.prepare(c.db, query)
                defer { sqlite3_finalize(prepared) }
                for row in boxed.value {
                    sqlite3_reset(prepared)
                    sqlite3_clear_bindings(prepared)
                    try Self.bind(prepared, row, c.db)
                    try Self.stepToEnd(prepared, c.db)
                }
            }
        }
    }

    enum SerializedItem: @unchecked Sendable {
        case run(Statement)
        case runs(query: String, rows: [[Any]])
    }

    /// `serialize`: a list of `run` / `runs` in one transaction.
    func serialize(_ fullname: String, _ items: [SerializedItem]) async throws {
        let connection = try connection(fullname)
        try await onQueue(connection) { c in
            try Self.transaction(c.db) {
                for item in items {
                    switch item {
                    case .run(let statement):
                        try Self.execute(c.db, statement)
                    case .runs(let query, let rows):
                        let prepared = try Self.prepare(c.db, query)
                        defer { sqlite3_finalize(prepared) }
                        for row in rows {
                            sqlite3_reset(prepared)
                            sqlite3_clear_bindings(prepared)
                            try Self.bind(prepared, row, c.db)
                            try Self.stepToEnd(prepared, c.db)
                        }
                    }
                }
            }
        }
    }

    func all(_ fullname: String, _ statement: Statement) async throws -> [[String: Any]] {
        let connection = try connection(fullname)
        return try await onQueue(connection) { c in Unchecked(value: try Self.rows(c.db, statement)) }.value
    }

    func get(_ fullname: String, _ statement: Statement) async throws -> [String: Any]? {
        let connection = try connection(fullname)
        return try await onQueue(connection) { c in Unchecked(value: try Self.rows(c.db, statement, limit: 1).first) }.value
    }

    /// `optimized-all`: every query bound with each of its parameter rows; all rows concatenated.
    /// Params arrive `Unchecked`-boxed (same reason as `runs`).
    func optimizedAll(_ fullname: String, queries: [String], params: Unchecked<[[[Any]]]>) async throws -> [[String: Any]] {
        let connection = try connection(fullname)
        let boxed = params
        return try await onQueue(connection) { c in
            var out: [[String: Any]] = []
            let rowsPerQuery = boxed.value
            for (index, query) in queries.enumerated() {
                let prepared = try Self.prepare(c.db, query)
                defer { sqlite3_finalize(prepared) }
                for row in index < rowsPerQuery.count ? rowsPerQuery[index] : [] {
                    sqlite3_reset(prepared)
                    sqlite3_clear_bindings(prepared)
                    try Self.bind(prepared, row, c.db)
                    out += try Self.collect(prepared, c.db, limit: nil)
                }
            }
            return Unchecked(value: out)
        }.value
    }

    // MARK: SQLite plumbing (always on the connection's queue)

    private func onQueue<T: Sendable>(_ connection: Connection, _ body: @escaping @Sendable (Connection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            connection.queue.async {
                // Queued before a `close` that already ran: `db` is freed (node-sqlite3 answers SQLITE_MISUSE).
                guard !connection.closed else { continuation.resume(throwing: Self.closedError); return }
                do { continuation.resume(returning: try body(connection)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int {
        let prepared = try prepare(db, "PRAGMA user_version;")
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_step(prepared) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(prepared, 0))
    }

    private static func transaction(_ db: OpaquePointer, _ body: () throws -> Void) throws {
        try exec(db, "BEGIN TRANSACTION")
        do {
            try body()
            try exec(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db, fallback: SQLITE_ERROR) }
    }

    /// Runs `statement`: with parameters a single statement; without, every statement of the text (pragmas, DDL).
    private static func execute(_ db: OpaquePointer, _ statement: Statement) throws {
        if statement.params.isEmpty {
            try statement.query.withCString { text in
                var tail: UnsafePointer<CChar>? = text
                while let current = tail, current.pointee != 0 {
                    var prepared: OpaquePointer?
                    guard sqlite3_prepare_v2(db, current, -1, &prepared, &tail) == SQLITE_OK else { throw error(db, fallback: SQLITE_ERROR) }
                    guard let prepared else { continue } // whitespace / comments only
                    defer { sqlite3_finalize(prepared) }
                    try stepToEnd(prepared, db)
                }
            }
            return
        }
        let prepared = try prepare(db, statement.query)
        defer { sqlite3_finalize(prepared) }
        try bind(prepared, statement.params, db)
        try stepToEnd(prepared, db)
    }

    private static func rows(_ db: OpaquePointer, _ statement: Statement, limit: Int? = nil) throws -> [[String: Any]] {
        let prepared = try prepare(db, statement.query)
        defer { sqlite3_finalize(prepared) }
        try bind(prepared, statement.params, db)
        return try collect(prepared, db, limit: limit)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw error(db, fallback: SQLITE_ERROR) }
        return prepared
    }

    private static func stepToEnd(_ prepared: OpaquePointer, _ db: OpaquePointer) throws {
        while true {
            let rc = sqlite3_step(prepared)
            if rc == SQLITE_DONE { return }
            if rc == SQLITE_ROW { continue }
            throw error(db, fallback: rc)
        }
    }

    private static func collect(_ prepared: OpaquePointer, _ db: OpaquePointer, limit: Int?) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        let count = Int(sqlite3_column_count(prepared))
        let names = (0..<count).map { String(cString: sqlite3_column_name(prepared, Int32($0))) }
        while true {
            let rc = sqlite3_step(prepared)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(db, fallback: rc) }
            var row: [String: Any] = [:]
            row.reserveCapacity(count)
            for i in 0..<count {
                let column = Int32(i)
                switch sqlite3_column_type(prepared, column) {
                case SQLITE_INTEGER: row[names[i]] = sqlite3_column_int64(prepared, column)
                case SQLITE_FLOAT: row[names[i]] = sqlite3_column_double(prepared, column)
                case SQLITE_TEXT: row[names[i]] = String(cString: sqlite3_column_text(prepared, column))
                case SQLITE_BLOB:
                    let bytes = Int(sqlite3_column_bytes(prepared, column))
                    if bytes > 0, let base = sqlite3_column_blob(prepared, column) { row[names[i]] = Data(bytes: base, count: bytes) }
                    else { row[names[i]] = Data() }
                default: row[names[i]] = NSNull()
                }
            }
            out.append(row)
            if let limit, out.count >= limit { break }
        }
        return out
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Binds JS values the way node-sqlite3 does: numbers as INTEGER / REAL, booleans as 0 / 1, strings as TEXT,
    /// bytes as BLOB, null / undefined / anything else as NULL.
    private static func bind(_ prepared: OpaquePointer, _ params: [Any], _ db: OpaquePointer) throws {
        let expected = Int(sqlite3_bind_parameter_count(prepared))
        for index in 0..<expected {
            let position = Int32(index + 1)
            let value: Any? = index < params.count ? params[index] : nil
            let rc: Int32
            switch value {
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    rc = sqlite3_bind_int64(prepared, position, number.boolValue ? 1 : 0)
                } else if CFNumberIsFloatType(number) {
                    let double = number.doubleValue
                    if double.rounded() == double, abs(double) < 9.0e15 { rc = sqlite3_bind_int64(prepared, position, Int64(double)) }
                    else { rc = sqlite3_bind_double(prepared, position, double) }
                } else {
                    rc = sqlite3_bind_int64(prepared, position, number.int64Value)
                }
            case let text as String:
                rc = sqlite3_bind_text(prepared, position, text, -1, transient)
            case let data as Data:
                rc = data.withUnsafeBytes { sqlite3_bind_blob(prepared, position, $0.baseAddress, Int32(data.count), transient) }
            default:
                rc = sqlite3_bind_null(prepared, position)
            }
            guard rc == SQLITE_OK else { throw error(db, fallback: rc) }
        }
    }

    private static func error(_ db: OpaquePointer?, fallback: Int32) -> SQLiteError {
        let errno = db.map { sqlite3_extended_errcode($0) & 0xff } ?? fallback
        let primary = errno == 0 ? fallback : errno
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(fallback))
        return SQLiteError(errno: primary, code: codeName(primary), detail: detail)
    }

    /// node-sqlite3's `code` strings for the primary result codes.
    static func codeName(_ errno: Int32) -> String {
        let names: [Int32: String] = [
            1: "SQLITE_ERROR", 2: "SQLITE_INTERNAL", 3: "SQLITE_PERM", 4: "SQLITE_ABORT", 5: "SQLITE_BUSY", 6: "SQLITE_LOCKED",
            7: "SQLITE_NOMEM", 8: "SQLITE_READONLY", 9: "SQLITE_INTERRUPT", 10: "SQLITE_IOERR", 11: "SQLITE_CORRUPT",
            12: "SQLITE_NOTFOUND", 13: "SQLITE_FULL", 14: "SQLITE_CANTOPEN", 15: "SQLITE_PROTOCOL", 16: "SQLITE_EMPTY",
            17: "SQLITE_SCHEMA", 18: "SQLITE_TOOBIG", 19: "SQLITE_CONSTRAINT", 20: "SQLITE_MISMATCH", 21: "SQLITE_MISUSE",
            22: "SQLITE_NOLFS", 23: "SQLITE_AUTH", 24: "SQLITE_FORMAT", 25: "SQLITE_RANGE", 26: "SQLITE_NOTADB",
            27: "SQLITE_NOTICE", 28: "SQLITE_WARNING", 100: "SQLITE_ROW", 101: "SQLITE_DONE",
        ]
        return names[errno] ?? "SQLITE_ERROR"
    }
}

// MARK: - Bridge members (`$znode.sqliteHost.*`, called by sqlite-host.js)

extension SQLiteHost {
    /// Registers the executor on a page's bridge. Arguments are the JSON the host script sends; results go back through
    /// the bridge's value conversion (bytes as `{__bytes}`, nil as undefined).
    @MainActor
    func install(on bridge: ZaloBridge) {
        bridge.async("$znode.sqliteHost.open") { [self] args in
            guard let name = args.string(0) else { throw ZaloBridge.BridgeError(message: "open: missing fullname") }
            let version = (args.count > 1 ? args[1] as? NSNumber : nil)?.intValue
            let result = try await open(name, requestedVersion: version, sessional: args.bool(2) ?? false)
            return ["userVersion": result.userVersion, "migrate": result.migrate]
        }
        bridge.async("$znode.sqliteHost.migrated") { [self] args in
            if let name = args.string(0) { migrated(name) }
            return nil
        }
        bridge.async("$znode.sqliteHost.exec") { [self] args in
            guard let name = args.string(0), let method = args.string(1) else { throw ZaloBridge.BridgeError(message: "exec: bad arguments") }
            let statement = args.dict(2) ?? [:]
            switch method {
            case "run":
                return try await run(name, Self.statement(statement))
            case "runs":
                try await runs(name, query: Self.query(statement["query"]), rows: Unchecked(value: Self.rows(statement["params"])))
                return nil
            case "all":
                return try await all(name, Self.statement(statement))
            case "get":
                return try await get(name, Self.statement(statement))
            case "optimized-all":
                let queries = (statement["queries"] as? [Any] ?? []).map(Self.query)
                let params = (statement["params"] as? [Any] ?? []).map(Self.rows)
                return try await optimizedAll(name, queries: queries, params: Unchecked(value: params))
            case "serialize":
                let items = (statement["data"] as? [[String: Any]] ?? []).map { item -> SerializedItem in
                    if item["method"] as? String == "runs" { return .runs(query: Self.query(item["query"]), rows: Self.rows(item["params"])) }
                    return .run(Statement(query: Self.query(item["query"]), params: item["params"] as? [Any] ?? []))
                }
                try await serialize(name, items)
                return nil
            default:
                throw ZaloBridge.BridgeError(message: "exec: unknown method \(method)")
            }
        }
        bridge.async("$znode.sqliteHost.close") { [self] args in
            if let name = args.string(0) { await close(name) }
            return nil
        }
        bridge.async("$znode.sqliteHost.delete") { [self] args in
            if let name = args.string(0) { await delete(name) }
            return nil
        }
        bridge.async("$znode.sqliteHost.partitionKeys") { [self] args in
            args.string(0).map(partitionKeys) ?? []
        }
        bridge.async("$znode.sqliteHost.closeSessional") { [self] _ in
            await closeSessional()
            return nil
        }
        bridge.async("$znode.sqliteHost.closeAll") { [self] _ in
            await closeAll()
            return nil
        }
    }

    /// Official statement objects: `{query: {query, params: <count>}, params: [...]}`; `query` may also be the SQL text.
    private static func query(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [String: Any])?["query"] as? String ?? ""
    }

    private static func statement(_ object: [String: Any]) -> Statement {
        Statement(query: query(object["query"]), params: object["params"] as? [Any] ?? [])
    }

    private static func rows(_ value: Any?) -> [[Any]] {
        (value as? [Any] ?? []).map { $0 as? [Any] ?? [] }
    }
}
