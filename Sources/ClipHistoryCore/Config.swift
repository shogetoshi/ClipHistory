import Foundation

/// 設定ファイル（`~/.config/cliphistory/config.toml`）の内容を保持する（Issue 0011）。
/// 設定ファイルが無くてもこれまでどおり動くよう、読み込み失敗時は空の設定にフォールバックする。
public struct Config: Equatable {
    /// nvim 起動時に追加で渡す環境変数（TOML の `[nvim.env]` テーブル）。
    public var nvimEnvironment: [String: String]

    public static let empty = Config(nvimEnvironment: [:])

    public init(nvimEnvironment: [String: String] = [:]) {
        self.nvimEnvironment = nvimEnvironment
    }

    /// TOML テキストをパースして組み立てる。未知のテーブル・未知のキーはエラーにせず無視する
    /// （将来の設定項目追加で古いバイナリが壊れないようにするため）。
    public static func parse(_ text: String) throws -> Config {
        let tables = try TOMLParser.parse(text)
        let nvimEnvironment = tables["nvim.env"] ?? [:]
        return Config(nvimEnvironment: nvimEnvironment)
    }

    /// ファイルが存在しなければ `empty`。パース失敗は throw。
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    /// 既定の場所から読む。失敗時は `NSLog` にエラーを残して `empty` を返す
    /// （設定ファイルの不備でアプリが起動できなくなるのを避けるため。design 13.3 と同じ方針）。
    public static func loadDefault() -> Config {
        do {
            return try load(from: AppPaths.configFileURL())
        } catch {
            NSLog("ClipHistory: Config.loadDefault() failed: \(error)")
            return .empty
        }
    }

    /// プロセス起動後に一度だけ `loadDefault()` した結果を共有する。
    public static let shared: Config = loadDefault()
}
