import Cocoa
import ClipHistoryCore

/// 起動・常駐設定、各コンポーネントの組み立てを行う。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var clipboardMonitor: ClipboardMonitor?
    private var hotKeyManager: HotKeyManager?
    private var pickerPanelController: PickerPanelController?
    private var searchIndex: SearchIndex?
    private var historyStore: HistoryStore?
    private var maintenanceScheduler: MaintenanceScheduler?
    private var settingsWindowController: SettingsWindowController?

    // ホットキー登録失敗時に表示する状態通知用メニュー項目（不具合修正）。
    // 通常時は非表示にしておき、失敗時のみ `isHidden = false` にして出す。
    private var hotKeyErrorMenuItem: NSMenuItem?
    private var reregisterHotKeyMenuItem: NSMenuItem?

    private static let normalStatusTitle = "📋"
    private static let hotKeyFailedStatusTitle = "⚠️"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 他の初期化より前に多重起動チェックを行う。詳細は checkForDuplicateInstance() 参照。
        if checkForDuplicateInstance() {
            return
        }
        setUpStatusItem()
        setUpCore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        hotKeyManager?.unregister()
        maintenanceScheduler?.stop()
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

    /// メニューバー常駐アイコン。設計書 7.4 の4項目（履歴パネルを開く / 設定 / 履歴を全消去 / 終了）
    /// に加え、ホットキー登録失敗時のみ表示する状態通知・再登録項目（不具合修正）を持つ。
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = Self.normalStatusTitle
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "履歴パネルを開く", action: #selector(openPicker), keyEquivalent: ""))

        // 選択不可（isEnabled = false）のエラー内容表示項目。通常時は isHidden = true。
        let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)
        hotKeyErrorMenuItem = errorItem

        let reregisterItem = NSMenuItem(
            title: "ホットキーを再登録",
            action: #selector(reregisterHotKey),
            keyEquivalent: ""
        )
        reregisterItem.isHidden = true
        menu.addItem(reregisterItem)
        reregisterHotKeyMenuItem = reregisterItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "設定", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "履歴を全消去", action: #selector(clearAllHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu

        statusItem = item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openPicker() {
        pickerPanelController?.toggle()
    }

    /// 設定ウィンドウを開く。既に開いていれば新規作成せず前面化するだけにする（指示）。
    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: Settings.shared) { [weak self] in
                // 監視間隔の変更だけは即座に反映する。ClipboardMonitorのタイマーを張り替える
                // （他の設定項目は次回の読み出し時に反映されればよい。指示）。
                self?.clipboardMonitor?.stop()
                self?.clipboardMonitor?.start()
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
    @objc private func clearAllHistory() {
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

        guard let historyStore else { return }
        do {
            // DB・BLOB・SearchIndex の3つすべてをクリアする（どれか1つでも残すと不整合になる）。
            try historyStore.deleteAll()
            searchIndex?.load([])
        } catch {
            NSLog("ClipHistory: failed to clear all history: \(error)")
        }
    }

    /// DB・BlobStore・HistoryStore を組み立て、ClipboardMonitor を起動したうえで
    /// ホットキー・パネルまわり（フェーズ2）を組み立てる。
    private func setUpCore() {
        do {
            let dbURL = try AppPaths.databaseURL()
            let db = try Database(path: dbURL.path)
            try Migrations.migrate(db)

            let blobsURL = try AppPaths.blobsDirectory()
            let blobStore = try BlobStore(baseDirectory: blobsURL)

            let settings = Settings.shared
            let historyStore = HistoryStore(
                db: db,
                blobStore: blobStore,
                inlineBlobThreshold: settings.inlineBlobThreshold
            )
            self.historyStore = historyStore

            // 起動時にDBから検索インデックスを構築する（設計書6.1）。以降、新規コピーは
            // DB再読み込みなしで `SearchIndex.append` により追記するのみとする。
            let index = SearchIndex()
            index.load(try historyStore.loadIndexEntries())
            searchIndex = index

            let monitor = ClipboardMonitor(settings: settings, historyStore: historyStore)
            monitor.onInsert = { [weak index] entry in
                index?.append(entry)
            }
            monitor.start()
            clipboardMonitor = monitor

            // 起動時＋1時間ごとにパージ・BLOB GC・（必要なら）VACUUMを実行する（設計書8節）。
            // 挿入ごとには実行しない。
            let scheduler = MaintenanceScheduler(
                db: db,
                historyStore: historyStore,
                blobStore: blobStore,
                settings: settings
            )
            scheduler.onPurge = { [weak index] deletedIDs in
                // パージでDBから消えたidを検索インデックスからも除去し、不整合を防ぐ。
                index?.remove(ids: Set(deletedIDs))
            }
            scheduler.start()
            maintenanceScheduler = scheduler

            setUpPicker(historyStore: historyStore, settings: settings, searchIndex: index)
        } catch {
            NSLog("ClipHistory: failed to initialize storage: \(error)")
        }
    }

    /// `PickerPanelController` を組み立て、既定ホットキー（既定 ⌥⌘V。設計書 10節）で
    /// トグルできるようにする。
    private func setUpPicker(historyStore: HistoryStore, settings: Settings, searchIndex: SearchIndex) {
        let resultsProvider = SearchResultsProvider(searchIndex: searchIndex, historyStore: historyStore)
        let controller = PickerPanelController(
            historyStore: historyStore,
            resultsProvider: resultsProvider,
            settings: settings
        )
        pickerPanelController = controller

        let manager = HotKeyManager { [weak controller] in
            controller?.toggle()
        }
        hotKeyManager = manager

        registerHotKey(manager, settings: settings)
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
    private func registerHotKey(_ manager: HotKeyManager, settings: Settings) {
        do {
            try manager.register(settings.hotKey)
            applyHotKeyRegistrationSucceeded()
        } catch {
            // 登録失敗時（他アプリとの衝突・多重起動など）はメニューバーで通知する（設計書 12節）
            NSLog("ClipHistory: failed to register hot key: \(error)")
            applyHotKeyRegistrationFailed(error)
        }
    }

    /// ステータスメニューの「ホットキーを再登録」項目から呼ばれる。
    @objc private func reregisterHotKey() {
        guard let manager = hotKeyManager else { return }
        registerHotKey(manager, settings: Settings.shared)
    }

    /// 登録失敗を示す状態（⚠️アイコン + エラーメニュー項目 + 再登録項目）に切り替える。
    private func applyHotKeyRegistrationFailed(_ error: Error) {
        statusItem?.button?.title = Self.hotKeyFailedStatusTitle
        hotKeyErrorMenuItem?.title = "ホットキー登録失敗: \(error)"
        hotKeyErrorMenuItem?.isHidden = false
        reregisterHotKeyMenuItem?.isHidden = false
    }

    /// 登録成功時（初回成功時・再登録成功時とも）に通常状態へ戻す。
    private func applyHotKeyRegistrationSucceeded() {
        statusItem?.button?.title = Self.normalStatusTitle
        hotKeyErrorMenuItem?.isHidden = true
        reregisterHotKeyMenuItem?.isHidden = true
    }
}
