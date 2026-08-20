import Foundation

/// パネルの結果一覧を提供するプロトコル。UI 側（`PickerViewController`）はこの型にのみ依存し、
/// 具体的な絞り込みロジックには依存しない。
///
/// フェーズ2では `RecentResultsProvider`（最新順のみ）を実装し、フェーズ3で fzf ライクな
/// `SearchIndex` ベースの実装に差し替える継ぎ目とする。
public protocol ResultsProvider {
    /// クエリに対する結果を最新/スコア順で返す
    func results(for query: String, limit: Int) throws -> [HistoryItem]
}

/// フェーズ2の実装。query は無視し、常に最新順の履歴を返す。
/// 検索フィールドへの入力自体は可能だが、絞り込みは行わない
/// （フィルタリングロジックの実装はフェーズ3の `SearchIndex` の責務）。
public final class RecentResultsProvider: ResultsProvider {
    private let historyStore: HistoryStore

    public init(historyStore: HistoryStore) {
        self.historyStore = historyStore
    }

    public func results(for query: String, limit: Int) throws -> [HistoryItem] {
        try historyStore.fetchRecent(limit: limit)
    }
}

/// フェーズ3の実装。`SearchIndex` による fzf ライクな絞り込みで id 列を求め、
/// `HistoryStore.fetchItems(ids:)` で実データを取得する。
/// スコア順（id列の順序）は `fetchItems` 側で保持されるため、ここでは並べ替えを行わない。
public final class SearchResultsProvider: ResultsProvider {
    private let searchIndex: SearchIndex
    private let historyStore: HistoryStore

    public init(searchIndex: SearchIndex, historyStore: HistoryStore) {
        self.searchIndex = searchIndex
        self.historyStore = historyStore
    }

    public func results(for query: String, limit: Int) throws -> [HistoryItem] {
        let ids = searchIndex.search(query: query, limit: limit)
        return try historyStore.fetchItems(ids: ids)
    }
}
