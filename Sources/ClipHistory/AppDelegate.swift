import Cocoa
import ClipHistoryCore

/// アプリのライフサイクルを担う。多重起動チェック、メニューバー（`StatusItemController`）と
/// 各コンポーネント（`AppComponents`）の起動、設定ウィンドウの開閉、破壊的操作の確認、
/// ホットキー登録結果のメニューへの反映だけを行い、コンポーネントの組み立て自体は持たない。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var components: AppComponents?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 他の初期化より前に多重起動チェックを行う。詳細は checkForDuplicateInstance() 参照。
        if checkForDuplicateInstance() {
            return
        }
        // 見た目をターミナル風に統一するため、システムのライト/ダーク設定に関わらず
        // アプリ全体をダークに固定する（Issue 0012）。
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // ⌘C などの標準的な編集キーを有効にするため、画面に出ないメインメニューを登録する（不具合修正）。
        NSApp.mainMenu = MainMenu.make()
        setUpStatusItem()
        setUpComponents()
    }

    func applicationWillTerminate(_ notification: Notification) {
        components?.stop()
    }

    /// 同一バンドル識別子の他インスタンスが既に起動していないか確認し、多重起動なら即終了する。
    ///
    /// なぜ多重起動を弾くのか: Carbon の `RegisterEventHotKey` はシステム全体で排他であり、
    /// 2つ目のインスタンスが起動しているとホットキー登録が必ず失敗する。実際にこれが
    /// 「⌥⌘V を押してもパネルが出ない」不具合の根本原因だった（検証中の二重起動）。
    /// ここで多重起動を検出して何も初期化せずに終了しておけば、既存インスタンスから
    /// ホットキーを奪う（＝解除させてしまう）ことがなくなる。
    /// - Returns: 多重起動と判定し終了処理を行った場合は true（呼び出し元は以降の初期化を行わない）。
    private func checkForDuplicateInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            // `.app` バンドル外での実行（`swift run` 等）ではバンドル識別子が取得できない。
            // その場合はガードをスキップし、開発時のワークフローを壊さないようにする。
            return false
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard !others.isEmpty else {
            return false
        }
        NSLog("ClipHistory: another instance of \(bundleID) is already running (count: \(others.count)). Terminating this instance so it does not steal the global hot key.")
        NSApp.terminate(nil)
        return true
    }

    private func setUpStatusItem() {
        let controller = StatusItemController()
        controller.onOpenPicker = { [weak self] in self?.components?.togglePicker() }
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onClearAllHistory = { [weak self] in self?.clearAllHistory() }
        controller.onReregisterHotKey = { [weak self] in self?.registerHotKey() }
        controller.onQuit = { NSApp.terminate(nil) }
        statusItemController = controller
    }

    private func setUpComponents() {
        do {
            let built = try AppComponents(settings: Settings.shared)
            components = built
            built.start()
            registerHotKey()
        } catch {
            NSLog("ClipHistory: failed to initialize storage: \(error)")
        }
    }

    /// 設定ウィンドウを開く。既に開いていれば新規作成せず前面化するだけにする（指示）。
    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: Settings.shared) { [weak self] in
                // 監視間隔の変更だけは即座に反映する。ClipboardMonitorのタイマーを張り替える
                // （他の設定項目は次回の読み出し時に反映されればよい。指示）。
                self?.components?.restartClipboardMonitor()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// 「履歴を全消去」。誤操作防止のため `NSAlert` で確認する。
    ///
    /// これは起動処理中ではなくユーザーがメニューから明示的に選んだ操作なので、
    /// `registerHotKey` のときとは異なりメインスレッドを同期的にブロックする
    /// `runModal()` を使って構わない（指示）。
    private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "履歴をすべて削除しますか？"
        alert.informativeText = "保存されているクリップボード履歴とファイルがすべて削除されます。この操作は取り消せません。"
        alert.alertStyle = .warning
        // 誤ってEnterキーを押しただけで削除が実行されないよう、既定ボタン（1番目に追加した
        // もの）を「キャンセル」にする。削除ボタンには hasDestructiveAction を付け赤字表示にする。
        alert.addButton(withTitle: "キャンセル")
        let deleteButton = alert.addButton(withTitle: "履歴を削除")
        deleteButton.hasDestructiveAction = true

        guard alert.runModal() == .alertSecondButtonReturn else { return }

        do {
            try components?.clearAllHistory()
        } catch {
            NSLog("ClipHistory: failed to clear all history: \(error)")
        }
    }

    /// ホットキーの登録を試み、結果をメニューバーへ反映する。
    ///
    /// なぜ `NSAlert.runModal()` を使わないのか: 以前は登録失敗時に同期モーダルを表示していたが、
    /// `applicationDidFinishLaunching` の内側でモーダルを出すと、利用者がダイアログを閉じるまで
    /// 起動処理全体（`ClipboardMonitor` の起動を含む）がブロックされてしまう。しかも
    /// `LSUIElement` のアクセサリアプリではこのアラートが前面に出てこないため、利用者からは
    /// 「画面には何も見えないのに、ホットキーもクリップボード監視も完全に無反応」という
    /// 最悪の見え方になっていた（実際に起きた不具合）。
    /// また `UNUserNotificationCenter` は ad-hoc 署名のローカルアプリでは通知の認可が
    /// 下りない可能性があるため使わず、`NSLog` とメニューバーの状態表示のみで通知する。
    /// これによりメインスレッドを一切ブロックせず、失敗時も `ClipboardMonitor` は動き続ける。
    private func registerHotKey() {
        guard let components else { return }
        do {
            try components.registerHotKey()
            statusItemController?.showHotKeySuccess()
        } catch {
            // 登録失敗時（他アプリとの衝突・多重起動など）はメニューバーで通知する（設計書 12節）
            NSLog("ClipHistory: failed to register hot key: \(error)")
            statusItemController?.showHotKeyFailure(error)
        }
    }
}
