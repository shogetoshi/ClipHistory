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

    /// XDG Base Directory の `$XDG_CONFIG_HOME`（未設定・空・相対パスなら `~/.config`）配下の
    /// `cliphistory/` ディレクトリ。読み込み専用なので作成はしない。
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"],
           !xdgConfigHome.isEmpty,
           xdgConfigHome.hasPrefix("/") {
            base = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("cliphistory", isDirectory: true)
    }

    /// 設定ファイル `.../cliphistory/config.toml`
    public static func configFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDirectory(environment: environment).appendingPathComponent("config.toml")
    }

    /// 利用者の nvim 設定より「前」に読ませる、このアプリ専用の nvim 設定
    /// （`.../cliphistory/init-pre.lua`）。読み込み専用なので作成はしない。
    public static func nvimInitPreURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDirectory(environment: environment).appendingPathComponent("init-pre.lua")
    }

    /// 利用者の nvim 設定より「後」に読ませる、このアプリ専用の nvim 設定
    /// （`.../cliphistory/init.lua`）。読み込み専用なので作成はしない。
    public static func nvimInitURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDirectory(environment: environment).appendingPathComponent("init.lua")
    }
}
