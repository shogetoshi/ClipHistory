import Cocoa
import ClipHistoryCore

/// 検索フィールドと結果一覧（`NSTableView`）の描画を担う（設計書 3.1 / 7.1）。
/// 実データの取得は `ResultsProvider` にのみ依存し、フィルタリングロジックはここに持たない
/// （フェーズ3の `SearchIndex` に差し替えるための継ぎ目）。
final class PickerViewController: NSViewController {
    /// 確定時に選択項目を渡すコールバック。クリップボードへの書き戻しは呼び出し元が行う。
    var onCommit: ((HistoryItem) -> Void)?
    /// キャンセル（Esc・フォーカス喪失）時のコールバック
    var onCancel: (() -> Void)?

    private let resultsProvider: ResultsProvider
    private let settings: Settings
    private let historyStore: HistoryStore

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    // プレビューペイン（Issue 0002）。一覧の右側に選択中アイテムの本文を表示する。
    private let previewBox = NSBox()
    private let previewScrollView = NSScrollView()
    private let previewTextView = NSTextView()
    /// プレビューとして読み込む最大文字数。一覧より大きく取り、長文もある程度確認できるようにする。
    private static let previewMaxCharacters = 4000

    private var items: [HistoryItem] = []
    /// 打鍵ごとの `reload()` 実行を抑えるデバウンス用タイマー（設計書6.5、40ms）。
    /// 検索自体はメインスレッド同期実行のままだが、これにより高速な連続入力時の
    /// 実行回数そのものを減らす（指揮官指示）。
    private var reloadDebounceTimer: Timer?
    private static let reloadDebounceInterval: TimeInterval = 0.04
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("HistoryItemCell")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("HistoryItemColumn")

    init(resultsProvider: ResultsProvider, settings: Settings, historyStore: HistoryStore) {
        self.resultsProvider = resultsProvider
        self.settings = settings
        self.historyStore = historyStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        root.autoresizingMask = [.width, .height]

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.placeholderString = "検索"
        root.addSubview(searchField)

        // 列幅をパネル幅に追従させる（修正1）。
        // 以前は column.width を 680 に固定していたため、パネルの実幅と食い違い、
        // 長いテキストが右端で省略記号なしに切れたりスクロールバーの下に潜り込んだりしていた。
        // resizingMask を .autoresizingMask にし、tableView 側を uniform 方式にすることで、
        // NSScrollView の可視幅が変わるたびに列幅が追従するようにする。
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        column.minWidth = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        // 単一列のテーブルなので列を常にテーブル幅いっぱいに合わせる
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // フルウィズス表示にし、列の内側インセットによる余計な余白・切れを避ける
        tableView.style = .fullWidth
        // プレビュー2行＋サブタイトル1行が収まる高さ（修正3でセル内制約を組み替えた際に微調整）
        tableView.rowHeight = 58
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.selectionHighlightStyle = .regular

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        // プレビューは一覧の右側に並べる（Issue 0002）。上下分割にすると、ただでさえ
        // 高さの限られたパネル内で一覧の可視行数が半分になってしまい選択操作がしづらくなるため、
        // 横方向に並べて一覧の縦の見え方はそのまま保つ。
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewTextView.textContainerInset = NSSize(width: 4, height: 4)
        // 等幅フォントにする。コピーしたコードや設定ファイルなどを崩さず、
        // インデントや桁位置が意図通りに見えるようにするため。
        previewTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.autoresizingMask = [.width]
        previewTextView.textContainer?.widthTracksTextView = true
        previewTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView.documentView = previewTextView
        previewScrollView.hasVerticalScroller = true
        previewScrollView.drawsBackground = false
        previewScrollView.autohidesScrollers = true

        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.boxType = .custom
        previewBox.fillColor = .textBackgroundColor
        previewBox.borderColor = .separatorColor
        previewBox.cornerRadius = 6
        previewBox.titlePosition = .noTitle
        previewBox.addSubview(previewScrollView)
        root.addSubview(previewBox)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            // 一覧55% / プレビュー45%。中央に12ptの間隔を空け、比率は multiplier で表現する。
            previewBox.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            previewBox.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 12),
            previewBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            previewBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            previewBox.widthAnchor.constraint(equalTo: scrollView.widthAnchor, multiplier: 45.0 / 55.0),

            previewScrollView.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 1),
            previewScrollView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 1),
            previewScrollView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -1),
            previewScrollView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -1)
        ])

        view = root
    }

    /// パネル表示のたびに `PickerPanelController` から呼ばれる。検索語をクリアし、
    /// 最新の結果を再取得して先頭行を選択したうえで、検索フィールドへ入力フォーカスを移す。
    func willShow() {
        searchField.stringValue = ""
        reloadDebounceTimer?.invalidate()
        reloadDebounceTimer = nil
        reload()
        view.window?.makeFirstResponder(searchField)
    }

    /// 打鍵のたびに呼ばれる。直前のタイマーを破棄して再スケジュールすることで、
    /// 連続入力中は最後の1回だけが実際に `reload()` を実行する（設計書6.5、40msデバウンス）。
    private func scheduleReload() {
        reloadDebounceTimer?.invalidate()
        reloadDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.reloadDebounceInterval, repeats: false) { [weak self] _ in
            self?.reload()
        }
    }

    private func reload() {
        let query = searchField.stringValue
        do {
            // resultLimit は毎回 Settings から読み直す（設定画面での変更が次回の読み出しで
            // 反映されるようにするため。フェーズ4指示）。
            items = try resultsProvider.results(for: query, limit: settings.resultLimit)
        } catch {
            items = []
            NSLog("ClipHistory: ResultsProvider.results(for:) failed: \(error)")
        }
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        // selectRowIndexes は選択が実際に変わらない場合（例: 既に0行目が選択済み）に
        // tableViewSelectionDidChange を発火しないため、items が空になったケースなどで
        // プレビューが前の内容を残してしまわないよう、ここで明示的に更新する。
        updatePreview()
    }

    /// 選択中アイテムのプレビュー本文を更新する。
    /// 一覧側の `previewText` は表示用に改行・連続空白を畳んで1行・200文字程度に短縮した値だが、
    /// プレビューでは改行を含む実データをそのまま見せたいため、ここでは一覧用の値を使わず
    /// `historyStore.loadPreviewText` で `public.utf8-plain-text` の実データを読み直す。
    private func updatePreview() {
        let row = tableView.selectedRow
        guard !items.isEmpty, row >= 0, row < items.count else {
            previewTextView.string = ""
            return
        }
        let item = items[row]
        let text: String
        do {
            if let loaded = try historyStore.loadPreviewText(itemID: item.id, maxCharacters: Self.previewMaxCharacters) {
                text = loaded
            } else {
                // テキスト表現が無い（将来の画像などを想定）場合は、一覧と同じ情報を出す
                text = item.previewText ?? ""
            }
        } catch {
            text = ""
            NSLog("ClipHistory: HistoryStore.loadPreviewText(itemID:) failed: \(error)")
        }
        previewTextView.string = text
        previewTextView.scrollToBeginningOfDocument(nil)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? 0 : min(max(current + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        onCommit?(items[row])
    }

    @objc private func handleDoubleClick() {
        commitSelection()
    }
}

extension PickerViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

extension PickerViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]

        let cell: HistoryItemCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? HistoryItemCellView {
            cell = reused
        } else {
            cell = HistoryItemCellView()
            cell.identifier = Self.cellIdentifier
        }

        let relativeTime = relativeFormatter.localizedString(
            for: Date(timeIntervalSince1970: Double(item.createdAt) / 1000),
            relativeTo: Date()
        )
        // 一覧は表示専用の整形を通す（修正2）。DB の preview_text 自体は変更しない。
        // 複数行のコピー内容がそのまま描画されると改行の数だけ行内を占め、行の見た目が
        // 不揃いになるため、改行・タブ・連続空白を半角スペース1個へ畳んでから渡す。
        cell.configure(
            preview: DisplayText.singleLine(item.previewText ?? ""),
            sourceAppName: item.sourceAppName ?? "不明なアプリ",
            relativeTime: relativeTime
        )
        return cell
    }

    /// 選択行が変わるたびにプレビューを更新する（Issue 0002）。
    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }
}

extension PickerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleReload()
    }

    /// 検索フィールドにフォーカスがある状態でも ↑↓ / Enter / Esc がテーブル側の操作として
    /// 効くよう、ここでハンドリングする（設計書 7.2）。
    /// ⌃P/⌃N は NSTextView 標準のキーバインディング（DefaultKeyBinding.dict）により
    /// 内部で moveUp:/moveDown: に変換されて渡ってくるため、矢印キーと同じ分岐で扱える。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
