import Testing
import Foundation
@testable import Olaz

/// `SQLiteHost` reproduces what the official `utility-process-sqlite` does with node-sqlite3 for the statements the
/// data access layer sends through `sqlite-host.js`. Databases live in a temporary directory.
@Suite struct SQLiteHostTests {
    private func host() throws -> SQLiteHost {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OlazSQLiteHostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SQLiteHost(root: root)
    }

    private func statement(_ query: String, _ params: [Any] = []) -> SQLiteHost.Statement {
        SQLiteHost.Statement(query: query, params: params)
    }

    @Test func runReportsLastIdAndChangesAndToleratesUniqueFailures() async throws {
        let h = try host()
        _ = try await h.open("user/messages", requestedVersion: nil, sessional: false)
        _ = try await h.run("user/messages", statement("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT UNIQUE, data BLOB)"))
        let first = try await h.run("user/messages", statement("INSERT INTO t (name) VALUES (?)", ["a"]))
        #expect(first["lastID"] as? Int64 == 1 && first["changes"] as? Int64 == 1)
        // The official `run` resolves on a failed UNIQUE constraint instead of rejecting.
        let duplicate = try await h.run("user/messages", statement("INSERT INTO t (name) VALUES (?)", ["a"]))
        #expect(duplicate["changes"] as? Int64 == 0)
        // Other errors carry node-sqlite3's errno / code and the "CODE: message" text.
        await #expect(throws: SQLiteHost.SQLiteError.self) {
            try await h.all("user/messages", statement("SELECT * FROM nope"))
        }
        do { _ = try await h.all("user/messages", statement("SELECT * FROM nope")) } catch let error as SQLiteHost.SQLiteError {
            #expect(error.errno == 1 && error.code == "SQLITE_ERROR" && error.message.hasPrefix("SQLITE_ERROR: no such table"))
            #expect(error.errorDescription == "SQLITE_ERROR:1:no such table: nope")
        }
    }

    @Test func runsSerializeAllGetAndOptimizedAll() async throws {
        let h = try host()
        _ = try await h.run("shared/contacts", statement("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, data BLOB)"))
        try await h.runs("shared/contacts", query: "INSERT INTO t (name, score, data) VALUES (?, ?, ?)",
                         rows: SQLiteHost.Unchecked(value: [["a", 1.5, Data([1, 2, 3])], ["b", NSNumber(value: true), NSNull()]]))
        try await h.serialize("shared/contacts", [
            .run(statement("INSERT INTO t (name) VALUES (?)", ["c"])),
            .runs(query: "INSERT INTO t (name) VALUES (?)", rows: [["d"], ["e"]]),
        ])
        let rows = try await h.all("shared/contacts", statement("SELECT id, name, score, data FROM t ORDER BY id"))
        #expect(rows.count == 5)
        #expect(rows[0]["name"] as? String == "a" && rows[0]["score"] as? Double == 1.5 && rows[0]["data"] as? Data == Data([1, 2, 3]))
        // Booleans bind as 1; `score` has REAL affinity, so 1 comes back as Double 1.0 (not Int64),
        // and nulls come back as null.
        #expect(rows[1]["score"] as? Double == 1 && rows[1]["data"] is NSNull)
        let one = try await h.get("shared/contacts", statement("SELECT name FROM t WHERE id = ?", [3]))
        #expect(one?["name"] as? String == "c")
        let none = try await h.get("shared/contacts", statement("SELECT name FROM t WHERE id = ?", [99]))
        #expect(none == nil)
        let many = try await h.optimizedAll("shared/contacts", queries: ["SELECT name FROM t WHERE id = ?"], params: SQLiteHost.Unchecked(value: [[[1], [2]]]))
        #expect(many.map { $0["name"] as? String } == ["a", "b"])
        // A failing `runs` rolls its rows back.
        await #expect(throws: SQLiteHost.SQLiteError.self) {
            try await h.runs("shared/contacts", query: "INSERT INTO t (id, name) VALUES (?, ?)", rows: SQLiteHost.Unchecked(value: [[100, "x"], [100, "y"]]))
        }
        let after = try await h.all("shared/contacts", statement("SELECT count(*) AS n FROM t WHERE id = 100"))
        #expect(after.first?["n"] as? Int64 == 0)
    }

    @Test func schemaVersionHandshakeRunsOnceAndLaterOpenersWait() async throws {
        let h = try host()
        // A fresh file is at version 0: the renderer asking for 3 must migrate it.
        let first = try await h.open("user/db", requestedVersion: 3, sessional: true)
        #expect(first.userVersion == 0 && first.migrate)
        // Someone else opening meanwhile waits for the migration, then needs none.
        let waiter = Task { try await h.open("user/db", requestedVersion: 3, sessional: false) }
        _ = try await h.run("user/db", statement("PRAGMA user_version = 3;"))
        h.migrated("user/db")
        let second = try await waiter.value
        #expect(second.userVersion == 3 && !second.migrate)
        // `null` version: whatever the file has, no migration.
        let any = try await h.open("user/db", requestedVersion: nil, sessional: false)
        #expect(any.userVersion == 3 && !any.migrate)
        await h.closeSessional()
        await h.closeAll()
    }

    @Test func filesPartitionsAndDelete() async throws {
        let h = try host()
        #expect(h.fileURL("a/../b/c").path.hasSuffix("/a/b/c.db"))
        _ = try await h.run("family/group/key1", statement("CREATE TABLE t (x)"))
        _ = try await h.run("family/group/key2", statement("CREATE TABLE t (x)"))
        #expect(Set(h.partitionKeys("family")) == ["key1", "key2"])
        _ = try await h.run("single", statement("CREATE TABLE t (x)"))
        #expect(h.partitionKeys("single") == [""])
        #expect(h.partitionKeys("missing").isEmpty)
        await h.delete("single")
        #expect(!FileManager.default.fileExists(atPath: h.fileURL("single").path))
        #expect(h.partitionKeys("single").isEmpty)
    }
}
