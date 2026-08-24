import Cocoa
import ClipHistoryCore

/// アプリを構成するコンポーネントの生成と結線をまとめる（合成ルート）。
/// メニューバーUI・設定ウィンドウといった見た目の責務は持たず、`AppDelegate` から使われる。
final class AppComponents {
    private let settings: Settings
    // db / blobStore は生成後 HistoryStore と MaintenanceScheduler に渡すだけだが、
    // 合成ルートが組み立てた実体を一覧できるようにここでも保持する。
    private let db: Database
    private let blobStore: BlobStore
    private let historyStore: HistoryStore
    private let searchIndex: SearchIndex
    private let clipboardMonitor: ClipboardMonitor
    private let maintenanceScheduler: MaintenanceScheduler
    private let pickerPanelController: PickerPanelController
    private let hotKeyManager: HotKeyManager

    /// DB・BlobStore・HistoryStore・SearchIndex・ClipboardMonitor・MaintenanceScheduler・
    /// パネル・ホットキーを組み立てる。DB を開けない等、初期化に失敗した場合は throw する。
    init(settings: Settings) throws {
        self.settings = settings

        let dbURL = try AppPaths.databaseURL()
        let db = try Database(path: dbURL.path)
        try Migrations.migrate(db)
        self.db = db

        let blobsURL = try AppPaths.blobsDirectory()
        let blobStore = try BlobStore(baseDirectory: blobsURL)
        self.blobStore = blobStore

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
        self.searchIndex = index

        let monitor = ClipboardMonitor(settings: settings, historyStore: historyStore)
        monitor.onInsert = { [weak index] entry in
            index?.append(entry)
        }
        self.clipboardMonitor = monitor

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
        self.maintenanceScheduler = scheduler

        let resultsProvider = SearchResultsProvider(searchIndex: index, historyStore: historyStore)
        let controller = PickerPanelController(
            historyStore: historyStore,
            resultsProvider: resultsProvider,
            settings: settings
        )
        self.pickerPanelController = controller

        self.hotKeyManager = HotKeyManager { [weak controller] action in
            switch action {
            case .togglePanel:
                controller?.toggle()
            case .cyclePrevious, .cycleNext:
                break
            }
        }
    }

    /// クリップボード監視とメンテナンスを開始する。
    func start() {
        clipboardMonitor.start()
        maintenanceScheduler.start()
    }

    /// 終了時に監視・ホットキー・メンテナンスを止める。
    func stop() {
        clipboardMonitor.stop()
        hotKeyManager.unregister()
        maintenanceScheduler.stop()
    }

    /// ホットキーの登録を試みる。失敗した場合は throw し、利用者への通知は呼び出し元に委ねる。
    func registerHotKey() throws {
        try hotKeyManager.register([
            .togglePanel: settings.hotKey,
            .cyclePrevious: .cyclePrevious,
            .cycleNext: .cycleNext
        ])
    }

    /// 検索パネルの表示/非表示をトグルする。
    func togglePicker() {
        pickerPanelController.toggle()
    }

    /// 監視間隔の変更を反映するため、クリップボード監視のタイマーを張り替える。
    /// 監視間隔の変更だけは即座に反映する（他の設定項目は次回の読み出し時に
    /// 反映されればよい。指示）。
    func restartClipboardMonitor() {
        clipboardMonitor.stop()
        clipboardMonitor.start()
    }

    /// 履歴・BLOB・検索インデックスをすべて消す（メニューの「履歴を全消去」用）。
    func clearAllHistory() throws {
        // DB・BLOB・SearchIndex の3つすべてをクリアする（どれか1つでも残すと不整合になる）。
        try historyStore.deleteAll()
        searchIndex.load([])
    }
}
