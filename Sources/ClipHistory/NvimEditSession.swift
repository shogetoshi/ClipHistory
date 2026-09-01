import Foundation
import ClipHistoryCore

/// nvim エラー型。
enum NvimEditSessionError: LocalizedError {
    case nvimNotFound

    var errorDescription: String? {
        switch self {
        case .nvimNotFound:
            return "nvim が見つかりません（ログインシェルの PATH を確認してください）"
        }
    }
}

/// プレビューを本物の nvim で編集するための1回分のセッション（Issue 0006）。
/// nvim を常駐させず、`⌘E` で編集を始めた項目1件だけオンデマンドに起動する
/// （`~/.config/nvim` が lazy.nvim + coc の重量級構成のため、常駐運用は
/// 選択の高速移動に追従できずちらつく懸念があるため）。
/// UI（SwiftTerm の `LocalProcessTerminalView`）には依存させず、一時ディレクトリの管理・
/// 起動コマンドの組み立て・編集結果の取り出し・後片付けのみをこのクラスの責務とする。
final class NvimEditSession {
    /// 解決済み nvim 絶対パスのキャッシュ。プロセス内で1回だけ解決すれば十分なため、
    /// セッションのたびにログインシェルを起動するコストを避ける。
    static private var cachedNvimPath: String?

    /// 一時セッションディレクトリ内の、編集対象テキストを書き出すファイル
    let sourceURL: URL
    /// nvim が `--listen` で待ち受ける UNIX ドメインソケット
    let socketURL: URL

    private let sessionDirectory: URL
    private let nvimPath: String
    /// nvim 起動時に追加で渡す環境変数（Issue 0011）。`export` のクォートにはリテラルの
    /// シングルクォートを使うため、シェル展開（`$PATH` 等）はされない。
    private let environment: [String: String]
    /// 利用者設定より前に読ませる、このアプリ専用の nvim 設定ファイルの絶対パス（Issue 0011）。
    /// `init` の時点で存在確認済みで、存在しなければ nil（起動コマンドに何も加えない）。
    private let nvimInitPrePath: String?
    /// 利用者設定より後に読ませる、このアプリ専用の nvim 設定ファイルの絶対パス（Issue 0011）。
    /// `init` の時点で存在確認済みで、存在しなければ nil（起動コマンドに何も加えない）。
    private let nvimInitPath: String?
    /// 読み戻し時、末尾改行の有無を元テキストに合わせるために保持する。
    private let sourceEndsWithNewline: Bool
    /// `init` でテキストを書き出した直後の `sourceURL` の更新日時。
    /// nvim が `:w` で保存したかどうかを、この日時からの変化で判定するために保持する。
    /// 取得できなかった場合は nil とし、その場合は「保存されていない」扱いにする。
    private let sourceModificationDate: Date?

    /// nvim の絶対パスを解決する。
    /// GUI アプリ（`.app` バンドル）としての起動時、プロセスの PATH には
    /// `/opt/homebrew/bin` 等が含まれず `nvim` が見つからないため、
    /// 必ずログインシェル（`/bin/zsh -l`）経由で `command -v nvim` を解決する。
    private static func resolveNvimPath() throws -> String {
        if let cached = cachedNvimPath {
            return cached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v nvim"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw NvimEditSessionError.nvimNotFound
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NvimEditSessionError.nvimNotFound
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            throw NvimEditSessionError.nvimNotFound
        }

        cachedNvimPath = path
        return path
    }

    /// シェルのシングルクォート内に安全に埋め込むためのエスケープ。
    /// このクラスが組み立てるパスは UUID とアプリ固定文字列のみで `'` を含まないが、
    /// 念のため通しておく。
    private static func shellSingleQuoteEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Lua の文字列リテラル（ダブルクォート）内に安全に埋め込むためのエスケープ。
    /// `--cmd` / `-c` に渡す前段・後段設定の読み込みには Ex コマンドの `luafile` ではなく
    /// Lua の `dofile` を使う。`luafile <パス>` は Ex コマンドの引数としてパスを渡すため
    /// 空白・`|`・`%`・`#` を含むパスでエスケープ規則が煩雑になるが、Lua の文字列リテラルなら
    /// `\` と `"` の2文字だけエスケープすれば済むため。
    /// 置換順は `\` → `"` の順で行うこと（逆にすると `"` のエスケープで入れた `\` が
    /// 再度エスケープされ、二重エスケープになってしまう）。
    private static func luaStringEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `--cmd` / `-c` にそのまま渡せる `lua dofile("<path>")` コマンド文字列を組み立てる。
    /// 呼び出し側でシェルのシングルクォートにくるむこと。
    private static func luaDofileCommand(_ path: String) -> String {
        "lua dofile(\"\(luaStringEscape(path))\")"
    }

    /// シェル変数名として妥当か（先頭が英字または `_`、以降は英数字または `_`）を判定する。
    private static func isValidShellVariableName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isASCII, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    init(
        text: String,
        environment: [String: String] = Config.shared.nvimEnvironment,
        nvimInitPreURL: URL? = AppPaths.nvimInitPreURL(),
        nvimInitURL: URL? = AppPaths.nvimInitURL()
    ) throws {
        // ディレクトリを作る前に nvim の絶対パスを解決しておく。
        // ここで見つからず throw した場合、ディレクトリを作らずに済むため後片付けが不要になる。
        self.nvimPath = try Self.resolveNvimPath()
        self.environment = environment
        // 存在しないファイルを nvim に渡すとエラーメッセージが出てしまうため、
        // ここで1回だけ存在確認し、無ければ以降 nil のまま扱う（起動コマンドに何も加えない）。
        self.nvimInitPrePath = nvimInitPreURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil
        }
        self.nvimInitPath = nvimInitURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil
        }

        // ディレクトリ名は短くする。UNIX ドメインソケットのパス長には104バイトの上限があり、
        // `temporaryDirectory` 配下に長い名前を作るとソケットパスがこれを超えかねないため。
        let directoryName = "ch-" + UUID().uuidString.prefix(8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)

        // クリップボードには認証情報が入りうるため、他ユーザーから読めないよう 0700 で作成する。
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.sessionDirectory = directory

        self.sourceURL = directory.appendingPathComponent("clip.txt")
        self.socketURL = directory.appendingPathComponent("s")

        self.sourceEndsWithNewline = text.hasSuffix("\n")
        try text.write(to: sourceURL, atomically: true, encoding: .utf8)
        self.sourceModificationDate = try? sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
    }

    /// `LocalProcessTerminalView.startProcess(executable:args:)` にそのまま渡す実行ファイル。
    var launchExecutable: String {
        "/bin/zsh"
    }

    /// `LocalProcessTerminalView.startProcess(executable:args:)` にそのまま渡す引数。
    /// ログインシェル（`-l`）経由で nvim を起動することで、ユーザーの環境変数
    /// （LSP サーバのパス等）も nvim に渡るようにする。
    var launchArguments: [String] {
        // 環境変数は `LocalProcessTerminalView.startProcess(environment:)` ではなく
        // ここでコマンド文字列に `export` を書く形で渡す。nvim はログインシェル経由で
        // 起動しており、シェルの起動ファイル（`.zshenv` / `.zprofile` 等）が同名の変数を
        // 上書きしうる。`-c` で渡すコマンドは起動ファイルの評価後に走るため、
        // ここで `export` すれば利用者の設定より確実に後勝ちになる。
        // キー名はシェル変数名として妥当なものだけを通し、出力順を安定させるためキーでソートする。
        let exports = environment.keys.sorted().compactMap { key -> String? in
            guard Self.isValidShellVariableName(key) else {
                NSLog("ClipHistory: 不正な環境変数名のため export をスキップします: \(key)")
                return nil
            }
            return "export \(key)=\(Self.shellSingleQuoteEscape(environment[key] ?? ""))"
        }

        var execParts = ["exec \(Self.shellSingleQuoteEscape(nvimPath))"]
        // 前段設定（`--cmd`）は `--listen` より前に置く。nvim のオプションであり、
        // 利用者の `~/.config/nvim/` より前に走るため、`vim.env.PATH` の追加のような
        // プラグイン・LSP の起動に間に合わせたい処理を置く場所になる。
        if let nvimInitPrePath {
            execParts.append("--cmd \(Self.shellSingleQuoteEscape(Self.luaDofileCommand(nvimInitPrePath)))")
        }
        execParts.append("--listen \(Self.shellSingleQuoteEscape(socketURL.path))")
        // 後段設定（`-c`）は `--listen` の後、`--` の前に置く。利用者設定を評価し
        // 編集対象ファイルを開いた後に走るため、オプション・キーマップの上書きに向く。
        if let nvimInitPath {
            execParts.append("-c \(Self.shellSingleQuoteEscape(Self.luaDofileCommand(nvimInitPath)))")
        }
        execParts.append("-- \(Self.shellSingleQuoteEscape(sourceURL.path))")

        var parts = exports.isEmpty ? [] : [exports.joined(separator: "; ")]
        parts.append(execParts.joined(separator: " "))

        return ["-l", "-c", parts.joined(separator: "; ")]
    }

    /// nvim が `:w` で保存して終了したかどうかを判定し、保存されていればその本文を返す。
    /// `sourceURL` の更新日時が `init` 時点から変化していれば「保存された」と判断する
    /// （nvim を終了しただけでは、この判定により「保存して終了」と「保存せず終了」を
    /// 区別できる）。保存されていないと判断した場合（更新日時が変化していない、
    /// `init` 時に日時を取得できなかった、ファイルが既に存在しない等）は nil を返す。
    func savedText() throws -> String? {
        guard let sourceModificationDate else {
            return nil
        }
        guard let currentModificationDate = try? sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else {
            return nil
        }
        guard currentModificationDate != sourceModificationDate else {
            return nil
        }

        let text = try String(contentsOf: sourceURL, encoding: .utf8)

        // nvim は保存時に行末へ必ず改行を付与するため、
        // 元テキストが改行で終わっていなければ末尾に付いた改行1個だけを取り除く。
        if !sourceEndsWithNewline, text.hasSuffix("\n") {
            return String(text.dropLast())
        }
        return text
    }

    /// nvim を終了させる。既に終了しているケースもあるため、失敗しても無視する。
    func requestQuit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nvimPath)
        process.arguments = ["--server", socketURL.path, "--remote-send", "<C-\\><C-N>:qa!<CR>"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // 既に nvim が終了している等のケースは無視する。
        }
    }

    /// 一時セッションディレクトリを丸ごと削除する。複数回呼ばれても安全（冪等）。
    func cleanUp() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }
}
