import Foundation

/// パネルの結果一覧を提供するプロトコル。UI 側（`PickerViewController`）はこの型にのみ依存し、
/// 具体的な絞り込みロジックには依存しない。
///
/// 実装は `SearchResultsProvider`（`SearchIndex` による fzf ライクな絞り込み）。
/// UI をこのプロトコルにのみ依存させることで、絞り込みロジックを UI 無変更で差し替えられる。
public protocol ResultsProvider {
    /// クエリに対する結果をcreatedAt降順で返す
    func results(for query: String, limit: Int) throws -> [HistoryItem]
}

/// `SearchIndex` による fzf ライクな絞り込みで id 列を求め、
/// `HistoryStore.fetchItems(ids:)` で実データを取得する。
/// createdAt降順（id列の順序）は `fetchItems` 側で保持されるため、ここでは並べ替えを行わない。
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
