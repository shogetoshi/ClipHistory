import Foundation

/// アプリのデータ配置先パスを一元管理する。
/// 設計書のとおり `~/Library/Application Support/ClipHistory/` を基点とし、
/// DB は `history.db`、BLOB は `blobs/` に配置する。
public enum AppPaths {
    /// `~/Library/Application Support/ClipHistory/` ディレクトリ（未作成なら作成する）
    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("ClipHistory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func databaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("history.db")
    }

    public static func blobsDirectory() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("blobs", isDirectory: true)
    }
}
