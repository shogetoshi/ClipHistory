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
    /// 複数選択（Issue 0023）を改行結合した内容を確定したときに呼ぶコールバック。
    /// クリップボードへの書き戻しは呼び出し元の責務。
    var onCommitJoinedText: ((String) -> Void)?

    /// 編集モード中は `PickerPanelController` 側でフォーカス喪失による自動クローズを止めるため、
    /// 外から読めるようにする。
    var isEditingInNvim: Bool { nvimEditController.isEditing }
    /// nvim 編集モードのライフサイクルを担う（Issue 0006 / 0007）。`previewPane` が
    /// `loadView()` を待たずに init 時点で生成済みのため lazy で保持できる。
    private lazy var nvimEditController = NvimEditModeController(container: previewPane)

    private let historyStore: HistoryStore
    private let previewContentLoader: PreviewContentLoader
    private let viewModel: PickerViewModel
    private let settings: Settings

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    // プレビューペイン（Issue 0002）。一覧の右側に選択中アイテムの本文を表示する。
    private let previewPane = PreviewPaneView()
    // 一覧とプレビューの境界をドラッグでリサイズできるようにするハンドル（Issue 0018）。
    private let previewDividerHandle = PreviewDividerHandleView()
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
        self.viewModel = PickerViewModel(resultsProvider: resultsProvider)
        self.settings = settings
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
        // 検索欄をターミナルのプロンプト行のような見た目にする（Issue 0012）。
        // 入力の受け付け・デリゲート経由のキー操作は変えず、フォントと配色だけを差し替える。
        searchField.font = TerminalTheme.searchFont
        searchField.textColor = TerminalTheme.foreground
        searchField.focusRingType = .none
        (searchField.cell as? NSSearchFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: "検索",
            attributes: [
                .foregroundColor: TerminalTheme.secondaryForeground,
                .font: TerminalTheme.searchFont
            ]
        )
        searchField.bezelStyle = .squareBezel
        searchField.drawsBackground = true
        searchField.backgroundColor = TerminalTheme.contentBackground
        // 左端の虫眼鏡は、ターミナルのプロンプト記号に見えるよう chevron に差し替える。
        // このアイコンは検索メニュー（searchMenuTemplate）を設定していないため装飾でしかなく、
        // 差し替えても操作できることは変わらない。
        if let searchButton = (searchField.cell as? NSSearchFieldCell)?.searchButtonCell,
           let prompt = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            let tinted = prompt.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [TerminalTheme.accent]))
            )
            searchButton.image = tinted
            searchButton.alternateImage = tinted
        }
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
        // 行間の区切り線を出さず、ターミナルの出力のように行が連続して見えるようにする（Issue 0012）。
        tableView.gridStyleMask = []
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
        // 一覧の下地をターミナル風の暗い色にする（Issue 0012）。
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TerminalTheme.contentBackground
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        // プレビューは一覧の右側に並べる（Issue 0002）。上下分割にすると、ただでさえ
        // 高さの限られたパネル内で一覧の可視行数が半分になってしまい選択操作がしづらくなるため、
        // 横方向に並べて一覧の縦の見え方はそのまま保つ。
        previewPane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewPane)

        // 一覧とプレビューの間の12ptの間隔に重ねて配置し、ドラッグで境界を移動できるようにする（Issue 0018）。
        previewDividerHandle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewDividerHandle)

        // 一覧55% / プレビュー45%。中央に12ptの間隔を空け、比率は multiplier で表現する。
        // 編集モード（Issue 0006）では previewPane を全幅に広げるため、切り替え対象の2制約は
        // ストアドプロパティとして保持し、後から isActive を切り替えられるようにする。
        previewLeadingNormalConstraint = previewPane.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 12)
        previewWidthConstraint = previewPane.widthAnchor.constraint(equalTo: scrollView.widthAnchor, multiplier: CGFloat(settings.previewWidthRatio))
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
            previewWidthConstraint,

            previewDividerHandle.topAnchor.constraint(equalTo: scrollView.topAnchor),
            previewDividerHandle.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            previewDividerHandle.centerXAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 6),
            previewDividerHandle.widthAnchor.constraint(equalToConstant: 16)
        ])

        previewDividerHandle.onDrag = { [weak self] deltaX in
            self?.handleDividerDrag(deltaX: deltaX)
        }
        previewDividerHandle.onDragEnded = { [weak self] in
            self?.persistPreviewWidthRatio()
        }

        view = root
    }

    /// パネル表示のたびに `PickerPanelController` から呼ばれる。検索語をクリアし、
    /// 最新の結果を再取得して最終行（最新のアイテム）を選択したうえで、検索フィールドへ入力フォーカスを移す。
    func willShow() {
        // パネルが何らかの理由で編集モードのまま再表示された場合に備えた保険（Issue 0006）。
        nvimEditController.finish(commit: false)
        searchField.stringValue = ""
        // パネルを開くたびに印はリセットする（Issue 0023）。
        viewModel.clearMarks()
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
    /// 印（Issue 0023）が1件以上ある場合は、選択行ではなく結合後のテキストを表示する。
    private func updatePreview() {
        if viewModel.hasMarks {
            let joined = joinedMarkedText()
            let truncated = String(joined.prefix(Self.previewMaxCharacters))
            previewPane.show(.text(truncated))
            return
        }
        guard let item = viewModel.item(at: tableView.selectedRow) else {
            previewPane.show(.empty)
            return
        }
        previewPane.show(previewContentLoader.content(for: item))
    }

    /// 印を付けたアイテム（Issue 0023）の本文を順に読み込み、改行で結合して返す。
    /// 本文が読めなかったアイテムは結合対象から除外する。
    private func joinedMarkedText() -> String {
        var texts: [String] = []
        for item in viewModel.markedItems {
            do {
                guard let loaded = try historyStore.loadFullText(itemID: item.id) else {
                    continue
                }
                texts.append(loaded)
            } catch {
                NSLog("ClipHistory: HistoryStore.loadFullText(itemID:) failed: \(error)")
            }
        }
        return MarkedSelection.joinedText(texts)
    }

    private func moveSelection(by delta: Int) {
        guard viewModel.count > 0 else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? 0 : min(max(current + delta, 0), viewModel.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// 選択中の行に複数選択の印を付け（トグル）、選択を `delta` 行ぶん移す（Issue 0023）。
    /// 印を付ける対象は移動前の選択行である。連打で連続して印を付けられるようにするため、
    /// 印付けと移動をひとまとめにしている。
    private func markSelectedRow(movingBy delta: Int) {
        let targetRow = tableView.selectedRow
        if viewModel.toggleMark(at: targetRow) {
            tableView.reloadData(forRowIndexes: IndexSet(integer: targetRow), columnIndexes: IndexSet(integer: 0))
            moveSelection(by: delta)
            updatePreview()
        } else {
            NSSound.beep()
        }
    }

    private func commitSelection() {
        // 印（Issue 0023）が1件以上あれば、結合後の内容を確定として渡す。
        if viewModel.hasMarks {
            onCommitJoinedText?(joinedMarkedText())
            return
        }
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
    /// 修飾キーが `.control` のみの押下は、fzfライクな検索欄編集用の
    /// `handleControlKeyEquivalent(_:)`（Issue 0014）に振り分ける。
    /// 修飾キーが `.command` のみの押下だけを従来どおりここで処理する（⌘⇧E 等の意図しない
    /// 組み合わせを誤って拾わないため）。
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Issue 0014: ⌃W / ⌃U（fzfライクな検索欄編集）は専用のハンドラに委ねる。
        if modifiers == .control {
            return handleControlKeyEquivalent(event)
        }

        guard modifiers == .command else {
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

    /// 検索欄に対する ⌃W（直前の単語を削除）/ ⌃U（カーソル位置から行頭まで削除）を
    /// fzfライクな操作感として実装する（Issue 0014）。
    /// ⌃A / ⌃E / ⌃B / ⌃F / ⌃D / ⌃H / ⌃K / ⌃Y / ⌃P / ⌃N は macOS 標準のキーバインドが
    /// そのまま fzf と同じ動作になるため、ここでは扱わない。
    private func handleControlKeyEquivalent(_ event: NSEvent) -> Bool {
        // nvim 編集モード中はキーを nvim 側に渡す必要があるため何もしない。
        guard !isEditingInNvim else { return false }

        // 検索フィールドが編集中（フィールドエディタがファーストレスポンダ）でなければ対象外とする。
        // performKeyEquivalent はフォーカス位置に関係なくビュー階層全体に配られるため。
        guard let textView = view.window?.firstResponder as? NSTextView,
              searchField.currentEditor() === textView else {
            return false
        }

        switch event.charactersIgnoringModifiers {
        case "w":
            deleteWordBackward(in: textView)
            return true
        case "u":
            deleteToLineStart(in: textView)
            return true
        default:
            return false
        }
    }

    /// ⌃W: カーソル直前の単語（空白区切り）を削除する（fzf/readline の unix-word-rubout 相当）。
    /// 選択範囲がある場合はその選択範囲を削除するだけでよい。
    private func deleteWordBackward(in textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        let deleteRange: NSRange
        if selectedRange.length > 0 {
            deleteRange = selectedRange
        } else {
            let text = textView.string as NSString
            var location = selectedRange.location
            // カーソル直前の連続する空白を読み飛ばす。
            while location > 0, CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: location - 1)) ?? Unicode.Scalar(0)) {
                location -= 1
            }
            let end = location
            // さらに空白が現れるまで（＝単語の先頭まで）削除範囲を広げる。
            while location > 0, !CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: location - 1)) ?? Unicode.Scalar(0)) {
                location -= 1
            }
            deleteRange = NSRange(location: location, length: end - location)
        }
        replaceText(in: textView, range: deleteRange, with: "")
    }

    /// ⌃U: カーソル位置から行頭までを削除する（fzf/readline の unix-line-discard 相当）。
    /// 選択範囲がある場合はその選択範囲を削除するだけでよい。
    private func deleteToLineStart(in textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        let deleteRange = selectedRange.length > 0
            ? selectedRange
            : NSRange(location: 0, length: selectedRange.location)
        replaceText(in: textView, range: deleteRange, with: "")
    }

    /// 取り消し（⌘Z）や `controlTextDidChange` の通知が壊れないよう、フィールドエディタの
    /// テキスト編集APIを通じて置換する（`searchField.stringValue` の直接書き換えは避ける）。
    private func replaceText(in textView: NSTextView, range: NSRange, with replacement: String) {
        textView.insertText(replacement, replacementRange: range)
    }

    /// 選択中の項目を本物の nvim で編集するモードへ入る（Issue 0006）。
    private func beginNvimEdit() {
        guard !isEditingInNvim else { return }

        // 印（Issue 0023）が1件以上ある場合は、選択行ではなく結合後のテキストを編集対象にする
        // （プレビュー・Enter での確定と同じ扱い）。
        if viewModel.hasMarks {
            let joined = joinedMarkedText()
            guard !joined.isEmpty else {
                NSSound.beep()
                return
            }
            nvimEditController.begin(text: joined)
            return
        }

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

    /// previewWidthConstraint を指定した比率で作り直し、有効/無効状態を保ったまま差し替える。
    /// NSLayoutConstraint の multiplier は生成後に変更できないため、ドラッグ操作のたびに
    /// 制約オブジェクトごと作り直す必要がある（Issue 0018）。
    private func rebuildPreviewWidthConstraint(ratio: CGFloat) {
        let wasActive = previewWidthConstraint.isActive
        previewWidthConstraint.isActive = false
        previewWidthConstraint = previewPane.widthAnchor.constraint(equalTo: scrollView.widthAnchor, multiplier: ratio)
        previewWidthConstraint.isActive = wasActive
    }

    /// 一覧・プレビュー双方に確保する最小幅（Issue 0018）。列の最小幅（120行目付近の
    /// column.minWidth = 200）と揃え、極端に狭いペインにならないようにする。
    private static let minPaneWidth: CGFloat = 200

    /// ドラッグハンドルの移動量を、一覧とプレビューの幅比率へ反映する（Issue 0018）。
    /// 一覧幅 + 12pt(間隔) + プレビュー幅 の合計は変わらないため、その合計を保ったまま
    /// 一覧幅を最小幅でクランプし、プレビュー幅を「合計 - 間隔 - 一覧幅」として再計算する。
    private func handleDividerDrag(deltaX: CGFloat) {
        let totalContentWidth = scrollView.frame.width + 12 + previewPane.frame.width
        guard totalContentWidth > 12 + Self.minPaneWidth * 2 else { return }

        let proposedListWidth = scrollView.frame.width + deltaX
        let maxListWidth = totalContentWidth - 12 - Self.minPaneWidth
        let newListWidth = min(max(proposedListWidth, Self.minPaneWidth), maxListWidth)
        let newPreviewWidth = totalContentWidth - 12 - newListWidth

        rebuildPreviewWidthConstraint(ratio: newPreviewWidth / newListWidth)
        view.layoutSubtreeIfNeeded()
    }

    /// ドラッグ終了時に、その時点の実測幅から比率を計算して保存する（Issue 0018）。
    private func persistPreviewWidthRatio() {
        guard scrollView.frame.width > 0 else { return }
        settings.previewWidthRatio = Double(previewPane.frame.width / scrollView.frame.width)
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
        previewDividerHandle.isHidden = editing
        searchField.isHidden = editing
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
            relativeTime: display.relativeTime,
            isMarked: display.isMarked
        )
        return cell
    }

    /// 選択行の塗りをターミナル風にするため、独自の行ビューを使う（Issue 0012）。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TerminalTableRowView()
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
        case #selector(NSResponder.insertTab(_:)):
            // 検索フィールドにフォーカスがある状態で tab が来るため、Enter や ↑↓ と同じ経路で
            // ここで受け、選択行への印付け（Issue 0023）に使う。標準のフォーカス移動（次の
            // キービューへの遷移）を起こさないよう、常に true を返す。
            // 印を付けたら1つ下（未来方向）へ選択を移し、tab の連打で連続して印を付けられるようにする。
            markSelectedRow(movingBy: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            // Shift-Tab は insertBacktab(_:) として渡ってくる。Tab と同じく印を付けるが、
            // 選択は1つ上（過去方向）へ移す。一覧は最新が最下行のため、直近の履歴を続けて
            // 選ぶときはこちらを使うことになる。標準の逆方向のフォーカス移動を起こさないよう
            // 常に true を返す。
            markSelectedRow(movingBy: -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// 一覧の選択行をターミナル風の暗い緑で塗るための行ビュー（Issue 0012）。
/// システム標準の選択色（青系のアクセントカラー）はターミナルの見た目と合わないため、
/// `drawSelection(in:)` を差し替えて自前で塗る。選択の判定・移動そのものは
/// `NSTableView` に任せたままで、描画だけを変えている。
final class TerminalTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        TerminalTheme.selectionBackground.setFill()
        dirtyRect.fill()
    }
}
