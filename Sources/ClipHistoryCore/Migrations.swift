import Foundation

/// スキーマの適用・バージョン管理。設計書「4.2 スキーマ」の DDL をそのまま適用する。
/// `meta` テーブルに `schema_version` を記録し、複数回呼び出しても安全（冪等）に動作する。
public enum Migrations {
    /// 現行のスキーマバージョン
    public static let currentVersion: Int64 = 1

    public static func migrate(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        let version = try schemaVersion(db)
        guard version < currentVersion else { return }

        try applyV1(db)
        try setSchemaVersion(db, currentVersion)
    }

    private static func schemaVersion(_ db: Database) throws -> Int64 {
        let stmt = try db.prepare("SELECT value FROM meta WHERE key = 'schema_version';")
        defer { try? stmt.reset() }
        guard try stmt.step(), let value = stmt.columnText(0), let version = Int64(value) else {
            return 0
        }
        return version
    }

    private static func setSchemaVersion(_ db: Database, _ version: Int64) throws {
        let stmt = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?);")
        try stmt.bind(1, String(version))
        _ = try stmt.step()
    }

    private static func applyV1(_ db: Database) throws {
        // 1回のコピー = 1レコード
        try db.exec("""
        CREATE TABLE IF NOT EXISTS items (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at           INTEGER NOT NULL,
            kind                 TEXT    NOT NULL
                                         CHECK (kind IN ('text','image','file','rtf')),
            preview_text         TEXT,
            search_key           TEXT,
            content_hash         TEXT    NOT NULL,
            byte_size            INTEGER NOT NULL,
            source_app_bundle_id TEXT,
            source_app_name      TEXT,
            pinned               INTEGER NOT NULL DEFAULT 0
        );
        """)

        try db.exec("CREATE INDEX IF NOT EXISTS idx_items_created_at ON items (created_at DESC);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_items_hash       ON items (content_hash);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_items_pinned     ON items (pinned) WHERE pinned = 1;")

        // 1コピーが持つ各UTIの実データ
        try db.exec("""
        CREATE TABLE IF NOT EXISTS representations (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            uti         TEXT    NOT NULL,
            inline_blob BLOB,
            file_path   TEXT,
            byte_size   INTEGER NOT NULL,
            UNIQUE (item_id, uti),
            CHECK ((inline_blob IS NOT NULL) <> (file_path IS NOT NULL))
        );
        """)

        try db.exec("CREATE INDEX IF NOT EXISTS idx_reps_item ON representations (item_id);")
    }
}
