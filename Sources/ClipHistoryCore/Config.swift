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

    /// Snippet 機能が走査する対象ディレクトリ（TOML の `[snippet]` テーブルの `directories`）。
    /// 空（未設定）なら Snippet 機能は使わない。
    public var snippetDirectories: [String]

    /// TOML の [hotkey] テーブルから読み込んだホットキー設定。キーが無い、または値が不正な
    /// アクションは辞書に含めない（他の設定項目と異なり既定値へのフォールバックはしない。
    /// 設定が無ければそのホットキーは登録されず機能を呼び出せなくなる、design 10.2）。
    public var hotKeyBindings: [HotKeyAction: HotKeyConfig]

    /// TOML の [hotkey] テーブルの `edit_in_nvim` から読み込んだ、パネル内でnvim編集モードに
    /// 入るキー。`hotKeyBindings` とは異なりCarbonでグローバル登録されるものではなく、
    /// パネルにフォーカスがある時だけローカルに判定される（PickerViewController）。
    /// 他のホットキーと同様、値が無い・不正な場合は既定値へフォールバックせず nil のままにする
    /// （その場合この機能は呼び出せなくなる、design 10.2）。
    public var editInNvimHotKey: HotKeyConfig?

    /// TOML の [hotkey] テーブルの `edit_snippet_source` から読み込んだ、Snippet パネルで
    /// 選択中アイテムのソース .md ファイル本体を nvim で開くキー。`hotKeyBindings` とは異なり
    /// グローバル登録されず、パネルにフォーカスがある時だけローカルに判定される。
    /// 他のホットキーと同様、値が無い・不正な場合は既定値へフォールバックせず nil のままにする
    /// （その場合この機能は呼び出せなくなる、design 10.2）。
    public var editSnippetSourceHotKey: HotKeyConfig?

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
        inlineBlobThreshold: 64 * 1024,
        snippetDirectories: [],
        hotKeyBindings: [:],
        editInNvimHotKey: nil,
        editSnippetSourceHotKey: nil
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
        inlineBlobThreshold: Int = 64 * 1024,
        snippetDirectories: [String] = [],
        hotKeyBindings: [HotKeyAction: HotKeyConfig] = [:],
        editInNvimHotKey: HotKeyConfig? = nil,
        editSnippetSourceHotKey: HotKeyConfig? = nil
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
        self.snippetDirectories = snippetDirectories
        self.hotKeyBindings = hotKeyBindings
        self.editInNvimHotKey = editInNvimHotKey
        self.editSnippetSourceHotKey = editSnippetSourceHotKey
    }

    /// TOML テキストをパースして組み立てる。未知のテーブル・未知のキーはエラーにせず無視する
    /// （将来の設定項目追加で古いバイナリが壊れないようにするため）。
    public static func parse(_ text: String) throws -> Config {
        let document = try TOMLParser.parseDocument(text)
        let tables = document.tables
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

        // `directories` の値が不正（配列でない・空文字要素を含む）でも throw はしない。
        // 設定ファイルの些細な不備でアプリが起動不能になるのを避ける方針のため
        // （design 13.3、および `loadDefault()` と同じ方針）、警告を残して既定値を使う。
        var snippetDirectories: [String] = []
        if document.tables["snippet"]?["directories"] != nil {
            NSLog("ClipHistory: Config.parse() [snippet] directories must be an array, using default []")
        } else if let directoriesArray = document.arrays["snippet"]?["directories"] {
            let nonEmptyDirectories = directoriesArray.filter { !$0.isEmpty }
            if nonEmptyDirectories.count != directoriesArray.count {
                NSLog("ClipHistory: Config.parse() [snippet] directories contains empty elements, removed")
            }
            snippetDirectories = nonEmptyDirectories
        }

        // ホットキーは他の設定項目と異なり、値が無い・不正でも既定値へフォールバックしない。
        // 設定が無ければそのホットキーは登録されず機能を呼び出せなくなる（design 10.2）。
        var hotKeyBindings: [HotKeyAction: HotKeyConfig] = [:]
        let hotKeyTomlKeys: [(String, HotKeyAction)] = [
            ("toggle_panel", .togglePanel),
            ("cycle_previous", .cyclePrevious),
            ("cycle_next", .cycleNext),
            ("direct_vim_edit", .directVimEdit),
            ("paste_and_cycle_previous", .pasteAndCyclePrevious),
            ("toggle_snippet_panel", .toggleSnippetPanel),
        ]
        for (tomlKey, action) in hotKeyTomlKeys {
            if let value = tables["hotkey"]?[tomlKey] {
                if let binding = HotKeyBindingParser.parse(value) {
                    hotKeyBindings[action] = binding
                } else {
                    NSLog("ClipHistory: Config.parse() invalid [hotkey] \(tomlKey) value: \(value), hotkey disabled")
                }
            }
        }

        var editInNvimHotKey: HotKeyConfig?
        if let value = tables["hotkey"]?["edit_in_nvim"] {
            if let binding = HotKeyBindingParser.parse(value) {
                editInNvimHotKey = binding
            } else {
                NSLog("ClipHistory: Config.parse() invalid [hotkey] edit_in_nvim value: \(value), hotkey disabled")
            }
        }

        var editSnippetSourceHotKey: HotKeyConfig?
        if let value = tables["hotkey"]?["edit_snippet_source"] {
            if let binding = HotKeyBindingParser.parse(value) {
                editSnippetSourceHotKey = binding
            } else {
                NSLog("ClipHistory: Config.parse() invalid [hotkey] edit_snippet_source value: \(value), hotkey disabled")
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
            inlineBlobThreshold: inlineBlobThreshold,
            snippetDirectories: snippetDirectories,
            hotKeyBindings: hotKeyBindings,
            editInNvimHotKey: editInNvimHotKey,
            editSnippetSourceHotKey: editSnippetSourceHotKey
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
