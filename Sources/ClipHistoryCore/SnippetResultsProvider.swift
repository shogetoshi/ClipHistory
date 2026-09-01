import Foundation

/// Snippet 用の `ResultsProvider` 実装。クリップボード履歴用の `SearchIndex` とは別に、
/// Snippet 専用の `SearchIndex` を1つ持つ。
public final class SnippetResultsProvider: ResultsProvider {
    private let store: SnippetStore
    private let searchIndex = SearchIndex()

    public init(store: SnippetStore) {
        self.store = store
    }

    /// パネルを開くたびに呼ばれる。ファイルを走査し直して検索インデックスを作り直す。
    /// `.md` は外部エディタで編集されるため、開くたびに読み直さないと変更が反映されないため。
    public func reload() {
        store.reload()
        searchIndex.load(store.indexEntries)
    }

    public func results(for query: String, limit: Int) throws -> [HistoryItem] {
        let ids = searchIndex.search(query: query, limit: limit)
        return store.items(ids: ids)
    }
}
