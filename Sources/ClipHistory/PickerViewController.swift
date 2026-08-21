import Cocoa
import ClipHistoryCore

/// 検索フィールドと結果一覧（`NSTableView`）の描画・キー操作の受け付けを担う（設計書 3.1 / 7.1）。
/// ビュー以外の責務は分けてある。一覧の状態と検索は `PickerViewModel`、プレビューの表示は
/// `PreviewPaneView` と `PreviewContentLoader`、nvim 編集モードは `NvimEditModeController`。
/// 絞り込みロジックは `ResultsProvider` の向こう側にあり、ここには持たない（設計書 13.2）。
final class PickerViewController: NSViewController {
    /// 確定時に選択項目を渡すコールバック。クリップボードへの書き戻しは呼び出し元が行う。
    var onCommit: ((HistoryItem) -> Void)?
    /// キャンセル（Esc・フォーカス喪失）時のコールバック
    var onCancel: (() -> Void)?
    /// nvim で編集した内容を確定したときに呼ぶコールバック。クリップボードへの書き戻しは呼び出し元の責務。
    var onCommitEditedText: ((String) -> Void)?

    /// 編集モード中は `PickerPanelController` 側でフォーカス喪失による自動クローズを止めるため、
    /// 外から読めるようにする。
    var isEditingInNvim: Bool { nvimEditController.isEditing }
    /// nvim 編集モードのライフサイクルを担う（Issue 0006 / 0007）。`previewPane` が
    /// `loadView()` を待たずに init 時点で生成済みのため lazy で保持できる。
    private lazy var nvimEditController = NvimEditModeController(container: previewPane)

    private let historyStore: HistoryStore
    private let previewContentLoader: PreviewContentLoader
    private let viewModel: PickerViewModel

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    // プレビューペイン（Issue 0002）。一覧の右側に選択中アイテムの本文を表示する。
    private let previewPane = PreviewPaneView()
    /// プレビューとして読み込む最大文字数。一覧より大きく取り、長文もある程度確認できるようにする。
    private static let previewMaxCharacters = 4000

    // 編集モードでのレイアウト差し替え用（Issue 0006）。通常時は previewPane を一覧の右45%に
    // 配置するが、nvim 編集中は全幅に広げる必要があるため、対象の制約をアクティブ/非アクティブ
    // 切り替えできるようストアドプロパティとして保持する。
    private var previewLeadingNormalConstraint: NSLayoutConstraint!
    private var previewWidthConstraint: NSLayoutConstraint!
    private var previewLeadingFullWidthConstraint: NSLayoutConstraint!

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("HistoryItemCell")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("HistoryItemColumn")

    init(resultsProvider: ResultsProvider, settings: Settings, historyStore: HistoryStore) {
        self.historyStore = historyStore
        self.previewContentLoader = PreviewContentLoader(historyStore: historyStore, maxCharacters: Self.previewMaxCharacters)
        self.viewModel = PickerViewModel(resultsProvider: resultsProvider, settings: settings)
        super.init(nibName: nil, bundle: nil)

        viewModel.onItemsChanged = { [weak self] in
            self?.applyItems()
        }

        nvimEditController.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            self.setEditingLayout(editing)
            if !editing {
                self.updatePreview()
                self.view.window?.makeFirstResponder(self.searchField)
            }
        }
        nvimEditController.onCommit = { [weak self] text in
            self?.onCommitEditedText?(text)
        }
        nvimEditController.onDiscard = { [weak self] in
            self?.onCancel?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        root.autoresizingMask = [.width, .height]
        // ⌘E / ⌘↩ / ⌘. を、検索フィールドやターミナルにフォーカスがある状態でも
        // 確実に受け取るため、ビュー階層の探索より先にここでハンドリングする（Issue 0006）。
        root.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }

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
        previewPane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewPane)

        // 一覧55% / プレビュー45%。中央に12ptの間隔を空け、比率は multiplier で表現する。
        // 編集モード（Issue 0006）では previewPane を全幅に広げるため、切り替え対象の2制約は
        // ストアドプロパティとして保持し、後から isActive を切り替えられるようにする。
        previewLeadingNormalConstraint = previewPane.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 12)
        previewWidthConstraint = previewPane.widthAnchor.constraint(equalTo: scrollView.widthAnchor, multiplier: 45.0 / 55.0)
        // 編集モード用の全幅レイアウト。初期状態では使わないため非アクティブのまま保持する。
        previewLeadingFullWidthConstraint = previewPane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16)

        // contentViewController を持つウィンドウは Auto Layout 上でウィンドウサイズ自体が
        // 変数になっており、「現在のサイズに留まろうとする」制約の優先度は
        // NSLayoutPriority.windowSizeStayPut（500）しかない。一方コンテンツ側の
        // content compression resistance は既定で750と高いため、長いテキストや大きな画像で
        // 固有サイズが大きくなるとウィンドウがそれに引きずられて拡大してしまう。
        // これを防ぐため、押し広げの起点となるビューの圧縮抵抗をwindowSizeStayPutより低い
        // .defaultLowに下げる。あわせて、内容が小さいときにウィンドウを縮める方向へ
        // 引っ張らないよう content hugging priority も.defaultLowに下げる（Issue 0009）。
        for view in [scrollView, previewPane] as [NSView] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
        }

        NSLayoutConstraint.activate([
            searchField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: searchField.topAnchor, constant: -12),

            previewPane.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            previewLeadingNormalConstraint,
            previewPane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            previewPane.bottomAnchor.constraint(equalTo: searchField.topAnchor, constant: -12),
            previewWidthConstraint
        ])

        view = root
    }

    /// パネル表示のたびに `PickerPanelController` から呼ばれる。検索語をクリアし、
    /// 最新の結果を再取得して最終行（最新のアイテム）を選択したうえで、検索フィールドへ入力フォーカスを移す。
    func willShow() {
        // パネルが何らかの理由で編集モードのまま再表示された場合に備えた保険（Issue 0006）。
        nvimEditController.finish(commit: false)
        searchField.stringValue = ""
        viewModel.cancelPendingReload()
        viewModel.reload(query: "")
        view.window?.makeFirstResponder(searchField)
    }

    /// 結果が入れ替わったときに一覧の表示・選択・プレビューを追従させる。
    private func applyItems() {
        tableView.reloadData()
        if viewModel.count > 0 {
            // 反転後は最終行が最新のアイテムになるため、最終行を選択する（Issue 0003）。
            let lastRow = viewModel.count - 1
            tableView.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(lastRow)
        }
        // selectRowIndexes は選択が実際に変わらない場合（例: 既に最終行が選択済み）に
        // tableViewSelectionDidChange を発火しないため、items が空になったケースなどで
        // プレビューが前の内容を残してしまわないよう、ここで明示的に更新する。
        updatePreview()
    }

    /// 選択中アイテムのプレビュー本文を更新する。
    private func updatePreview() {
        guard let item = viewModel.item(at: tableView.selectedRow) else {
            previewPane.show(.empty)
            return
        }
        previewPane.show(previewContentLoader.content(for: item))
    }

    private func moveSelection(by delta: Int) {
        guard viewModel.count > 0 else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? 0 : min(max(current + delta, 0), viewModel.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func commitSelection() {
        guard let item = viewModel.item(at: tableView.selectedRow) else { return }
        onCommit?(item)
    }

    @objc private func handleDoubleClick() {
        commitSelection()
    }

    /// Esc キーの押下はレスポンダチェーンを通じて `cancelOperation(_:)` として
    /// 送られてくるため、`NSViewController`（`NSResponder` のサブクラス）である
    /// ここで受けることで、検索フィールド・プレビューの `NSTextView` など
    /// フォーカスがどこにあってもパネルを閉じられるようにする（Issue 0009）。
    /// nvim 編集モード中は Esc をノーマルモード復帰等のため nvim 自身に使わせる必要が
    /// あるので、ここでは何もせずレスポンダチェーンより先で処理される nvim 側に委ねる。
    override func cancelOperation(_ sender: Any?) {
        guard !isEditingInNvim else { return }
        onCancel?()
    }

    /// ⌘系のキー等価を、ビュー階層の探索より先に横取りして処理する（Issue 0006）。
    /// `PanelBackgroundView.keyEquivalentHandler` から呼ばれる。
    /// 修飾キーが `.command` のみの押下だけを対象にする（⌘⇧E 等の意図しない組み合わせを
    /// 誤って拾わないため）。
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return false
        }

        switch event.charactersIgnoringModifiers {
        case "e":
            // 編集モードでなければ nvim 編集を開始する。編集モード中の ⌘E は
            // nvim へ素通ししても意味が無いため、握りつぶして何もしない。
            if !isEditingInNvim {
                beginNvimEdit()
            }
            return true
        case "\r":
            // Esc は nvim 側が（ノーマルモード復帰等に）使うため確定には使えない。
            // そのため確定は ⌘↩ に割り当てる。編集モードでなければ通常の確定（Enter）に譲る。
            guard isEditingInNvim else { return false }
            nvimEditController.finish(commit: true)
            return true
        case ".":
            // Esc が使えない都合上、破棄も ⌘. に割り当てる。
            guard isEditingInNvim else { return false }
            nvimEditController.finish(commit: false)
            return true
        default:
            return false
        }
    }

    /// 選択中の項目を本物の nvim で編集するモードへ入る（Issue 0006）。
    private func beginNvimEdit() {
        guard !isEditingInNvim else { return }

        guard let item = viewModel.item(at: tableView.selectedRow) else {
            NSSound.beep()
            return
        }

        // 画像アイテムはテキストとして編集できないため対象外とする。
        guard item.kind != .image else {
            NSSound.beep()
            return
        }

        let text: String
        do {
            guard let loaded = try historyStore.loadFullText(itemID: item.id) else {
                NSLog("ClipHistory: HistoryStore.loadFullText(itemID:) returned nil")
                NSSound.beep()
                return
            }
            text = loaded
        } catch {
            NSLog("ClipHistory: HistoryStore.loadFullText(itemID:) failed: \(error)")
            NSSound.beep()
            return
        }

        nvimEditController.begin(text: text)
    }

    /// 通常レイアウトと nvim 編集用の全幅レイアウトを切り替える（Issue 0006）。
    /// プレビュー幅45%（約300pt）では nvim の編集領域として狭すぎるため、編集中は
    /// 一覧を隠して previewPane を全幅に広げる。
    private func setEditingLayout(_ editing: Bool) {
        if editing {
            previewLeadingNormalConstraint.isActive = false
            previewWidthConstraint.isActive = false
            previewLeadingFullWidthConstraint.isActive = true
            scrollView.isHidden = true
        } else {
            previewLeadingFullWidthConstraint.isActive = false
            previewLeadingNormalConstraint.isActive = true
            previewWidthConstraint.isActive = true
            scrollView.isHidden = false
        }
        previewPane.setContentHidden(editing)
    }
}

extension PickerViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.count
    }
}

extension PickerViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let display = viewModel.rowDisplay(at: row) else { return nil }

        let cell: HistoryItemCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? HistoryItemCellView {
            cell = reused
        } else {
            cell = HistoryItemCellView()
            cell.identifier = Self.cellIdentifier
        }

        cell.configure(
            preview: display.preview,
            sourceAppName: display.sourceAppName,
            relativeTime: display.relativeTime
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
        viewModel.scheduleReload(query: searchField.stringValue)
    }

    /// 検索フィールドにフォーカスがある状態でも ↑↓ / Enter / Esc がテーブル側の操作として
    /// 効くよう、ここでハンドリングする（設計書 7.2）。
    /// ⌃P/⌃N は NSTextView 標準のキーバインディング（DefaultKeyBinding.dict）により
    /// 内部で moveUp:/moveDown: に変換されて渡ってくるため、矢印キーと同じ分岐で扱える。
    /// なお Esc（cancelOperation:）は検索フィールドにフォーカスがある場合はここで即座に
    /// 処理されるが、`PickerViewController.cancelOperation(_:)` のオーバーライドにより
    /// フォーカスがどこにあっても効くようになっている（Issue 0009）。
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
