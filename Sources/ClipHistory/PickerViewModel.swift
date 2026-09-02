import Foundation
import ClipHistoryCore

/// 一覧の1行に表示する文字列一式。整形済みで、セル側はそのまま流し込むだけにする。
struct HistoryRowDisplay {
    let preview: String
    let sourceAppName: String
    let relativeTime: String
    /// tabキーによる複数選択で印が付いているか（Issue 0023）。
    let isMarked: Bool
}

/// 検索パネルの一覧が持つ状態（検索結果と、行の表示文字列）を担う。
/// ビューには一切触れず、`ResultsProvider` への問い合わせ・打鍵のデバウンス・
/// 表示用文字列の組み立てだけを行う。結果が入れ替わったことは `onItemsChanged` で通知する。
final class PickerViewModel {
    /// 結果が入れ替わったときに呼ばれる。ビュー側はここで `reloadData()` などを行う。
    var onItemsChanged: (() -> Void)?

    private let resultsProvider: ResultsProvider

    /// Snippet にはアプリ名も時刻も無いため副情報を出さない（Issue 0030）。
    private let showsItemMetadata: Bool

    /// 検索窓を上に、結果を上から下へ表示するレイアウトかどうか（Issue 0031、Snippet 用）。
    private let isTopDown: Bool

    private(set) var items: [HistoryItem] = []

    /// tabキーによる複数選択（印付け）の状態（Issue 0023）。検索の絞り込みが変わっても
    /// 印は保つ設計のため、`reload(query:)` では触れない。
    private var markedSelection = MarkedSelection()

    /// 打鍵ごとの reload 実行を抑えるデバウンス用タイマー（設計書6.5、40ms）。
    /// 検索自体はメインスレッド同期実行のままだが、これにより高速な連続入力時の
    /// 実行回数そのものを減らす（指揮官指示）。
    private var reloadDebounceTimer: Timer?
    private static let reloadDebounceInterval: TimeInterval = 0.04

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(resultsProvider: ResultsProvider, showsItemMetadata: Bool = true, isTopDown: Bool = false) {
        self.resultsProvider = resultsProvider
        self.showsItemMetadata = showsItemMetadata
        self.isTopDown = isTopDown
    }

    var count: Int { items.count }

    /// 指定行のアイテム。範囲外なら nil。
    func item(at row: Int) -> HistoryItem? {
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    /// 保留中のデバウンスを取り消す。
    func cancelPendingReload() {
        reloadDebounceTimer?.invalidate()
        reloadDebounceTimer = nil
    }

    /// 打鍵のたびに呼ばれる。直前のタイマーを破棄して再スケジュールすることで、
    /// 連続入力中は最後の1回だけが実際に `reload()` を実行する（設計書6.5、40msデバウンス）。
    func scheduleReload(query: String) {
        reloadDebounceTimer?.invalidate()
        reloadDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.reloadDebounceInterval, repeats: false) { [weak self] _ in
            self?.reload(query: query)
        }
    }

    /// 即座に結果を取り直す。
    func reload(query: String) {
        do {
            // resultLimit は起動時に読み込まれた config.toml の値（Config.shared）を使う
            // （設定はconfig.tomlに統一し、GUIからの変更はできない。Issue 0025）。
            // プロバイダは最新順（先頭が最上位）で返すが、履歴なので最新を下に置きたいため
            // ここで反転する（Issue 0003）。ただし isTopDown の場合（Snippet）は上から下へ
            // 表示するため、プロバイダが返した順のまま反転しない（Issue 0031）。
            let results = try resultsProvider.results(for: query, limit: Config.shared.resultLimit)
            items = isTopDown ? results : Array(results.reversed())
        } catch {
            items = []
            NSLog("ClipHistory: ResultsProvider.results(for:) failed: \(error)")
        }
        onItemsChanged?()
    }

    /// 指定行の表示文字列を組み立てる。
    func rowDisplay(at row: Int) -> HistoryRowDisplay? {
        guard let item = item(at: row) else { return nil }
        // Snippet にはアプリ名も時刻も無いため、showsItemMetadata が false の場合は
        // 副情報（アプリ名・相対時刻）を空文字にし、relativeFormatter による整形自体も行わない
        // （Issue 0030）。
        let sourceAppName: String
        let relativeTime: String
        if showsItemMetadata {
            sourceAppName = item.sourceAppName ?? "不明なアプリ"
            relativeTime = relativeFormatter.localizedString(
                for: Date(timeIntervalSince1970: Double(item.createdAt) / 1000),
                relativeTo: Date()
            )
        } else {
            sourceAppName = ""
            relativeTime = ""
        }
        // 一覧は表示専用の整形を通す（修正2）。DB の preview_text 自体は変更しない。
        // 複数行のコピー内容がそのまま描画されると改行の数だけ行内を占め、行の見た目が
        // 不揃いになるため、改行・タブ・連続空白を半角スペース1個へ畳んでから渡す。
        return HistoryRowDisplay(
            preview: DisplayText.singleLine(item.previewText ?? ""),
            sourceAppName: sourceAppName,
            relativeTime: relativeTime,
            isMarked: markedSelection.contains(itemID: item.id)
        )
    }

    /// 印を付けたアイテム（印を付けた順）（Issue 0023）。
    var markedItems: [HistoryItem] { markedSelection.items }

    /// 印が1件以上付いているか（Issue 0023）。
    var hasMarks: Bool { !markedSelection.isEmpty }

    /// 指定行のアイテムの印をトグルする（Issue 0023）。行が範囲外の場合は何もせず
    /// `false` を返す。画像アイテムにも印は付けられるが、結合はテキストのみを
    /// 対象とするため、本文を読めない画像は結合時に除外される。
    func toggleMark(at row: Int) -> Bool {
        guard let item = item(at: row) else { return false }
        markedSelection.toggle(item)
        return true
    }

    /// 印を全て取り除く（Issue 0023）。
    func clearMarks() {
        markedSelection.removeAll()
    }
}
