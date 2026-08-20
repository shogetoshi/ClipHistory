import Foundation
import Testing
@testable import ClipHistoryCore

@Suite("Database / Migrations")
struct DatabaseTests {
    @Test("マイグレーションは複数回適用しても安全である（冪等）")
    func migrationIsIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("history.db").path
        let db = try Database(path: dbPath)

        try Migrations.migrate(db)
        try Migrations.migrate(db)
        try Migrations.migrate(db)

        let stmt = try db.prepare("SELECT value FROM meta WHERE key = 'schema_version';")
        #expect(try stmt.step())
        #expect(stmt.columnText(0) == String(Migrations.currentVersion))
    }

    @Test("prepare/bind/step の基本動作")
    func basicPrepareBindStep() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("history.db").path
        let db = try Database(path: dbPath)
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);")

        let insertStmt = try db.prepare("INSERT INTO t (name) VALUES (?);")
        try insertStmt.bind(1, "hello")
        _ = try insertStmt.step()
        let insertedID = db.lastInsertRowID

        let selectStmt = try db.prepare("SELECT id, name FROM t WHERE id = ?;")
        try selectStmt.bind(1, insertedID)
        #expect(try selectStmt.step())
        #expect(selectStmt.columnInt64(0) == insertedID)
        #expect(selectStmt.columnText(1) == "hello")
        #expect(try selectStmt.step() == false)
    }
}
