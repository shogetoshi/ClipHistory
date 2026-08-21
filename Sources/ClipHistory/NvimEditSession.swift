import Foundation

/// nvim エラー型。
enum NvimEditSessionError: LocalizedError {
    case nvimNotFound
    case readBackFailed(String)

    var errorDescription: String? {
        switch self {
        case .nvimNotFound:
            return "nvim が見つかりません（ログインシェルの PATH を確認してください）"
        case .readBackFailed(let detail):
            return "nvim から編集内容を読み戻せませんでした: \(detail)"
        }
    }
}

/// プレビューを本物の nvim で編集するための1回分のセッション（Issue 0006）。
/// nvim を常駐させず、`⌘E` で編集を始めた項目1件だけオンデマンドに起動する
/// （`~/.config/nvim` が lazy.nvim + coc の重量級構成のため、常駐運用は
/// 選択の高速移動に追従できずちらつく懸念があるため）。
/// 編集内容の取り出しには msgpack-RPC の自前実装は不要で、`nvim --server --remote-expr`
/// により nvim 自身を RPC クライアントとして使う（Issue 0006 検討メモ）。
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
    /// 編集結果の書き出し先（`writefile` の出力先）
    let outputURL: URL

    private let sessionDirectory: URL
    private let nvimPath: String
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

    /// VimScript の文字列リテラル（シングルクォート）内に安全に埋め込むためのエスケープ。
    private static func vimScriptSingleQuoteEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    init(text: String) throws {
        // ディレクトリを作る前に nvim の絶対パスを解決しておく。
        // ここで見つからず throw した場合、ディレクトリを作らずに済むため後片付けが不要になる。
        self.nvimPath = try Self.resolveNvimPath()

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
        self.outputURL = directory.appendingPathComponent("out.txt")

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
        let command = "exec \(Self.shellSingleQuoteEscape(nvimPath))" +
            " --listen \(Self.shellSingleQuoteEscape(socketURL.path))" +
            " -- \(Self.shellSingleQuoteEscape(sourceURL.path))"
        return ["-l", "-c", command]
    }

    /// nvim 側の編集内容を取り出す。
    func readEditedText() throws -> String {
        try? FileManager.default.removeItem(at: outputURL)

        // `getline` ではなく `getbufline(bufnr(...))` を使う。nvim 側でユーザーが
        // 別バッファを開いたり分割ウィンドウで移動したりしていても、対象バッファ
        // （`sourceURL` を開いたバッファ）の内容を確実に取得できるようにするため。
        let expr = "writefile(getbufline(bufnr('\(Self.vimScriptSingleQuoteEscape(sourceURL.path))'),1,'$')," +
            " '\(Self.vimScriptSingleQuoteEscape(outputURL.path))')"

        var lastFailureDetail = "不明なエラー"
        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: nvimPath)
            process.arguments = ["--server", socketURL.path, "--remote-expr", expr]

            let stderrPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                lastFailureDetail = error.localizedDescription
                if attempt < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                continue
            }
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                lastFailureDetail = ""
                break
            }

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lastFailureDetail = errText.isEmpty
                ? "終了コード \(process.terminationStatus)"
                : errText

            if attempt < maxAttempts {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NvimEditSessionError.readBackFailed(lastFailureDetail)
        }

        let text = try String(contentsOf: outputURL, encoding: .utf8)
        // 読み取り直後に削除する（クリップボードの内容を一時ファイルに長く残さないため）。
        try? FileManager.default.removeItem(at: outputURL)

        // `writefile` は各行末に必ず改行を付与するため、元テキストが改行で終わっていなければ
        // 末尾に付いた改行1個だけを取り除いて、元の見た目に合わせる。
        if !sourceEndsWithNewline, text.hasSuffix("\n") {
            return String(text.dropLast())
        }
        return text
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

        // `readEditedText()` と同様、nvim は保存時に行末へ必ず改行を付与するため、
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
