import Foundation
import SQLite3

/// SQLite3 のエラーを Swift の throws に変換するためのエラー型。
public enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let msg): return "sqlite3_open failed: \(msg)"
        case .execFailed(let msg): return "sqlite3_exec failed: \(msg)"
        case .prepareFailed(let msg): return "sqlite3_prepare_v2 failed: \(msg)"
        case .bindFailed(let msg): return "sqlite3_bind failed: \(msg)"
        case .stepFailed(let msg): return "sqlite3_step failed: \(msg)"
        }
    }
}

// sqlite3_bind_text / sqlite3_bind_blob に渡す「呼び出し完了後にコピー済みでよい」ことを示す定数。
// SQLITE_TRANSIENT は C のマクロで Swift に直接インポートされないため、ここで定義する。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// sqlite3 の薄いラッパー。open / exec / prepare-bind-step の最小限の API のみを提供する。
public final class Database {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError.openFailed(msg)
        }
        self.handle = db

        // WAL・外部キー制約は設計書 4.2 のとおり常時有効化する
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// 結果行を返さない SQL を実行する（DDL・トランザクション制御など）
    public func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw DatabaseError.execFailed(msg)
        }
    }

    /// プレースホルダ付き SQL を準備する
    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(errorMessage)
        }
        return Statement(handle: stmt, dbHandle: handle)
    }

    /// 直近の INSERT で採番された rowid（= items.id / representations.id）
    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }
}

/// 準備済みステートメント。bind → step → column読み出し の最小 API を提供する。
public final class Statement {
    private let stmt: OpaquePointer
    private let dbHandle: OpaquePointer?

    init(handle: OpaquePointer, dbHandle: OpaquePointer?) {
        self.stmt = handle
        self.dbHandle = dbHandle
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(dbHandle))
    }

    public func bind(_ index: Int32, _ value: Int64) throws {
        let rc = sqlite3_bind_int64(stmt, index, value)
        guard rc == SQLITE_OK else { throw DatabaseError.bindFailed(errorMessage) }
    }

    public func bind(_ index: Int32, _ value: String) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        guard rc == SQLITE_OK else { throw DatabaseError.bindFailed(errorMessage) }
    }

    public func bind(_ index: Int32, _ value: Data) throws {
        let rc = value.withUnsafeBytes { rawBuffer -> Int32 in
            sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(rawBuffer.count), sqliteTransient)
        }
        guard rc == SQLITE_OK else { throw DatabaseError.bindFailed(errorMessage) }
    }

    public func bindNull(_ index: Int32) throws {
        let rc = sqlite3_bind_null(stmt, index)
        guard rc == SQLITE_OK else { throw DatabaseError.bindFailed(errorMessage) }
    }

    /// 1行読み進める。行があれば true、終端に達したら false を返す。
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw DatabaseError.stepFailed(errorMessage)
    }

    public func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    public func columnText(_ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    public func columnBlob(_ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let count = sqlite3_column_bytes(stmt, index)
        guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: Int(count))
    }
}
