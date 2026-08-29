import Foundation

/// 設定ファイル（`~/.config/cliphistory/config.toml`）の内容を保持する（Issue 0011）。
/// 設定ファイルが無くてもこれまでどおり動くよう、読み込み失敗時は空の設定にフォールバックする。
public struct Config: Equatable {
    /// nvim 起動時に追加で渡す環境変数（TOML の `[nvim.env]` テーブル）。
    public var nvimEnvironment: [String: String]

    /// クリップボード履歴を辿るポインタが揮発するまでの秒数（TOML の `[cycle]` テーブルの `timeout`）。
    public var cycleTimeout: TimeInterval

    /// 一覧・プレビューなど各所のフォントサイズの基準値（pt）（TOML の `[font]` テーブルの `size`）。
    public var fontSize: Double

    /// クリップボード履歴として保持する件数の上限（TOML の `[history]` テーブルの `max_item_count`）。
    public var maxItemCount: Int

    /// クリップボードを監視する間隔（秒）（TOML の `[monitor]` テーブルの `polling_interval`）。
    public var pollingInterval: TimeInterval

    /// 保存するテキストの最大バイト数（TOML の `[monitor]` テーブルの `max_text_bytes`）。
    public var maxTextBytes: Int

    /// 保存する画像の最大バイト数（TOML の `[monitor]` テーブルの `max_image_bytes`）。
    public var maxImageBytes: Int

    /// 機密データ（コンシールドフラグ付き）をスキップするか（TOML の `[monitor]` テーブルの `skip_concealed`）。
    public var skipConcealed: Bool

    /// 一覧の最大表示件数（TOML の `[list]` テーブルの `result_limit`）。
    public var resultLimit: Int

    /// BLOB をインラインで保存するサイズの閾値（バイト）（TOML の `[storage]` テーブルの `inline_blob_threshold`）。
    public var inlineBlobThreshold: Int

    public static let empty = Config(
        nvimEnvironment: [:],
        cycleTimeout: 10,
        fontSize: 12,
        maxItemCount: 10_000,
        pollingInterval: 0.3,
        maxTextBytes: 5 * 1024 * 1024,
        maxImageBytes: 20 * 1024 * 1024,
        skipConcealed: true,
        resultLimit: 200,
        inlineBlobThreshold: 64 * 1024
    )

    public init(
        nvimEnvironment: [String: String] = [:],
        cycleTimeout: TimeInterval = 10,
        fontSize: Double = 12,
        maxItemCount: Int = 10_000,
        pollingInterval: TimeInterval = 0.3,
        maxTextBytes: Int = 5 * 1024 * 1024,
        maxImageBytes: Int = 20 * 1024 * 1024,
        skipConcealed: Bool = true,
        resultLimit: Int = 200,
        inlineBlobThreshold: Int = 64 * 1024
    ) {
        self.nvimEnvironment = nvimEnvironment
        self.cycleTimeout = cycleTimeout
        self.fontSize = fontSize
        self.maxItemCount = maxItemCount
        self.pollingInterval = pollingInterval
        self.maxTextBytes = maxTextBytes
        self.maxImageBytes = maxImageBytes
        self.skipConcealed = skipConcealed
        self.resultLimit = resultLimit
        self.inlineBlobThreshold = inlineBlobThreshold
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

        // `size` の値が不正（数値に変換できない・0以下・非有限）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var fontSize: Double = 12
        if let fontSizeString = tables["font"]?["size"] {
            if let size = Double(fontSizeString), size > 0, size.isFinite {
                fontSize = size
            } else {
                NSLog("ClipHistory: Config.parse() invalid [font] size value: \(fontSizeString), using default 12")
            }
        }

        // `max_item_count` の値が不正（Int に変換できない・範囲外）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var maxItemCount = 10_000
        if let maxItemCountString = tables["history"]?["max_item_count"] {
            if let value = Int(maxItemCountString), (1...100_000).contains(value) {
                maxItemCount = value
            } else {
                NSLog("ClipHistory: Config.parse() invalid [history] max_item_count value: \(maxItemCountString), using default 10000")
            }
        }

        // `polling_interval` の値が不正（数値に変換できない・0以下・非有限）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var pollingInterval: TimeInterval = 0.3
        if let pollingIntervalString = tables["monitor"]?["polling_interval"] {
            if let value = Double(pollingIntervalString), value > 0, value.isFinite {
                pollingInterval = value
            } else {
                NSLog("ClipHistory: Config.parse() invalid [monitor] polling_interval value: \(pollingIntervalString), using default 0.3")
            }
        }

        // `max_text_bytes` の値が不正（Int に変換できない・1未満）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var maxTextBytes = 5 * 1024 * 1024
        if let maxTextBytesString = tables["monitor"]?["max_text_bytes"] {
            if let value = Int(maxTextBytesString), value >= 1 {
                maxTextBytes = value
            } else {
                NSLog("ClipHistory: Config.parse() invalid [monitor] max_text_bytes value: \(maxTextBytesString), using default 5242880")
            }
        }

        // `max_image_bytes` の値が不正（Int に変換できない・1未満）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var maxImageBytes = 20 * 1024 * 1024
        if let maxImageBytesString = tables["monitor"]?["max_image_bytes"] {
            if let value = Int(maxImageBytesString), value >= 1 {
                maxImageBytes = value
            } else {
                NSLog("ClipHistory: Config.parse() invalid [monitor] max_image_bytes value: \(maxImageBytesString), using default 20971520")
            }
        }

        // `skip_concealed` の値が不正（"true"/"false" 以外）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var skipConcealed = true
        if let skipConcealedString = tables["monitor"]?["skip_concealed"] {
            if let value = Bool(skipConcealedString) {
                skipConcealed = value
            } else {
                NSLog("ClipHistory: Config.parse() invalid [monitor] skip_concealed value: \(skipConcealedString), using default true")
            }
        }

        // `result_limit` の値が不正（Int に変換できない・1未満）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var resultLimit = 200
        if let resultLimitString = tables["list"]?["result_limit"] {
            if let value = Int(resultLimitString), value >= 1 {
                resultLimit = value
            } else {
                NSLog("ClipHistory: Config.parse() invalid [list] result_limit value: \(resultLimitString), using default 200")
            }
        }

        // `inline_blob_threshold` の値が不正（Int に変換できない・0未満）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var inlineBlobThreshold = 64 * 1024
        if let inlineBlobThresholdString = tables["storage"]?["inline_blob_threshold"] {
            if let value = Int(inlineBlobThresholdString), value >= 0 {
                inlineBlobThreshold = value
            } else {
                NSLog("ClipHistory: Config.parse() invalid [storage] inline_blob_threshold value: \(inlineBlobThresholdString), using default 65536")
            }
        }

        return Config(
            nvimEnvironment: nvimEnvironment,
            cycleTimeout: cycleTimeout,
            fontSize: fontSize,
            maxItemCount: maxItemCount,
            pollingInterval: pollingInterval,
            maxTextBytes: maxTextBytes,
            maxImageBytes: maxImageBytes,
            skipConcealed: skipConcealed,
            resultLimit: resultLimit,
            inlineBlobThreshold: inlineBlobThreshold
        )
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
