import Cocoa
import SwiftTerm

/// nvim 編集モードのライフサイクル（セッションの生成・破棄、ターミナルビューの搭載・撤去、
/// nvim プロセス終了の検知）を担う（Issue 0006 / 0007）。
/// 一覧・プレビュー・検索フィールドの状態は持たず、ターミナルを載せるコンテナビューだけを
/// ホスト（`PickerViewController`）から借りる。レイアウトの切り替えとフォーカスの戻し先は
/// ホストの責務なので `onEditingChanged` で通知するに留める。
final class NvimEditModeController: NSObject {
    /// 編集モードの開始・終了のたびに呼ばれる。ホストはレイアウト切り替えなどをここで行う。
    /// `true` はターミナル搭載直後（nvim 起動前）、`false` は後片付け完了後に呼ばれる。
    var onEditingChanged: ((Bool) -> Void)?
    /// 編集内容を確定したときに呼ぶ。クリップボードへの書き戻しは呼び出し元の責務。
    var onCommit: ((String) -> Void)?
    /// nvim を保存せずに終了したときに呼ぶ。
    var onDiscard: (() -> Void)?

    private(set) var isEditing = false

    private let container: NSView
    private var session: NvimEditSession?
    /// nvim 編集用のターミナルビュー。セッションごとに生成・破棄し、使い回さない。
    /// 前回の描画内容やプロセス状態（スクロールバック・カーソル位置・終了済みプロセスの残骸等）を
    /// 持ち越さないため。
    private var terminalView: LocalProcessTerminalView?

    init(container: NSView) {
        self.container = container
        super.init()
    }

    /// 選択中の項目を本物の nvim で編集するモードへ入る（Issue 0006）。
    /// - Parameter text: 編集対象のテキスト。
    /// - Returns: 編集モードへ入れた場合は `true`。既に編集中、または nvim セッションの
    ///   生成に失敗した場合は `false`。
    @discardableResult
    func begin(text: String) -> Bool {
        guard !isEditing else { return false }

        let session: NvimEditSession
        do {
            session = try NvimEditSession(text: text)
        } catch {
            NSLog("ClipHistory: NvimEditSession(text:) failed: \(error)")
            NSSound.beep()
            return false
        }
        self.session = session

        let terminal = LocalProcessTerminalView(frame: container.bounds)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.configureNativeColors()
        // プレビューと同じ等幅フォント・下地に揃える（Issue 0012）。
        terminal.font = TerminalTheme.previewFont
        terminal.nativeBackgroundColor = TerminalTheme.contentBackground
        terminal.nativeForegroundColor = TerminalTheme.foreground
        terminal.caretColor = TerminalTheme.accent
        terminal.processDelegate = self
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -1),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1)
        ])
        terminalView = terminal

        isEditing = true
        onEditingChanged?(true)

        terminal.startProcess(executable: session.launchExecutable, args: session.launchArguments)
        // 以降の全キー入力を nvim（ターミナルビュー）に流す。
        container.window?.makeFirstResponder(terminal)
        return true
    }

    /// nvim 編集モードを、確定せずに終了する（Issue 0006）。
    /// パネルが何らかの理由で編集モードのまま再表示された場合の保険として使う。
    func finish() {
        guard isEditing else { return }
        tearDown()
    }

    /// nvim 編集モードの後片付けを行う（Issue 0007）。
    /// nvim セッションの終了・破棄、ターミナルビューの取り外し、レイアウトの復元をまとめる。
    /// `finish()` と `processTerminated(source:exitCode:)` の双方から共通で呼ばれる。
    private func tearDown() {
        session?.requestQuit()
        session?.cleanUp()
        session = nil

        terminalView?.removeFromSuperview()
        terminalView = nil

        isEditing = false
        onEditingChanged?(false)
    }
}

extension NvimEditModeController: LocalProcessTerminalViewDelegate {
    /// ユーザーが nvim 内で `:q` した場合の経路。SwiftTerm から呼ばれるスレッドが
    /// 保証されないため、後片付け（メインスレッド専用の AppKit 操作を含む）は
    /// `DispatchQueue.main.async` 経由でメインスレッドに乗せて行う。
    /// nvim を終了したらパネルを閉じる。保存されていればクリップボードへ書き戻し、
    /// 保存されていなければ何もしない（Issue 0007）。
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.handleNvimTermination()
        }
    }

    // プロトコル要求のための空実装。パネル内埋め込みでウィンドウタイトルや
    // カレントディレクトリ表示、サイズ変更通知を使う予定はない。
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

private extension NvimEditModeController {
    /// nvim プロセスの終了を受けて編集モードを終える（Issue 0007）。
    /// nvim を終了したらパネルを閉じる。保存されていればクリップボードへ書き戻し、
    /// 保存されていなければ何もしない。
    func handleNvimTermination() {
        guard isEditing else { return }

        var savedText: String?
        do {
            savedText = try session?.savedText()
        } catch {
            NSLog("ClipHistory: NvimEditSession.savedText() failed: \(error)")
            savedText = nil
        }

        tearDown()

        if let savedText {
            onCommit?(savedText)
        } else {
            onDiscard?()
        }
    }
}
