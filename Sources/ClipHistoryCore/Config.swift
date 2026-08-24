import Foundation

/// 設定ファイル（`~/.config/cliphistory/config.toml`）の内容を保持する（Issue 0011）。
/// 設定ファイルが無くてもこれまでどおり動くよう、読み込み失敗時は空の設定にフォールバックする。
public struct Config: Equatable {
    /// nvim 起動時に追加で渡す環境変数（TOML の `[nvim.env]` テーブル）。
    public var nvimEnvironment: [String: String]

    /// クリップボード履歴を辿るポインタが揮発するまでの秒数（TOML の `[cycle]` テーブルの `timeout`）。
    public var cycleTimeout: TimeInterval

    public static let empty = Config(nvimEnvironment: [:], cycleTimeout: 10)

    public init(nvimEnvironment: [String: String] = [:], cycleTimeout: TimeInterval = 10) {
        self.nvimEnvironment = nvimEnvironment
        self.cycleTimeout = cycleTimeout
    }

    /// TOML テキストをパースして組み立てる。未知のテーブル・未知のキーはエラーにせず無視する
    /// （将来の設定項目追加で古いバイナリが壊れないようにするため）。
    public static func parse(_ text: String) throws -> Config {
        let tables = try TOMLParser.parse(text)
        let nvimEnvironment = tables["nvim.env"] ?? [:]

        // `timeout` の値が不正（数値に変換できない・0以下・非有限）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var cycleTimeout: TimeInterval = 10
        if let timeoutString = tables["cycle"]?["timeout"] {
            if let timeout = Double(timeoutString), timeout > 0, timeout.isFinite {
                cycleTimeout = timeout
            } else {
                NSLog("ClipHistory: Config.parse() invalid [cycle] timeout value: \(timeoutString), using default 10")
            }
        }

        return Config(nvimEnvironment: nvimEnvironment, cycleTimeout: cycleTimeout)
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
