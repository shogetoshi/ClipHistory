import Foundation

/// インメモリの検索インデックス本体。`HistoryStore.loadIndexEntries()` で取得した軽量な
/// エントリ配列を保持し、fzfライクな曖昧検索・逐次絞り込みを行う（設計書 6.1 / 6.4）。
///
/// スレッド方針について: 指揮官判断により、このフェーズでは検索をメインスレッド同期実行に
/// 固定する（バックグラウンド走査・キャンセルは行わない。理由は6万件のインメモリ走査が
/// 数msオーダーに収まる見込みであり、キャンセル制御を伴う非同期化はレースを生むリスクの割に
/// 得るものが小さいため）。そのため `SearchIndex` 自体も排他制御を持たない。
/// 呼び出しは常にメインスレッドから行うこと。
public final class SearchIndex {

    /// 走査用に保持する1件分のエントリ。`searchKey` は `[Unicode.Scalar]` へ変換済みで
    /// 保持し、検索のたびに `String` から変換し直すコストを避ける（設計書6.1）。
    private struct Entry {
        let id: Int64
        let createdAt: Int64
        let scalars: [Unicode.Scalar]
    }

    /// 逐次絞り込み用スタックの1段（設計書6.4）。`ids` は表示件数上限で切る前の
    /// 「ヒットした全件」であることに注意する（次段の絞り込みで候補集合として使うため）。
    private struct RefineFrame {
        let query: String
        let ids: [Int64]
    }

    /// createdAt 昇順（tie: id昇順）を保つ前提の全件配列。
    /// `HistoryStore.loadIndexEntries()` がこの順序で返す（設計書6.1）ことと、
    /// 新規追記が常に既存より新しい時刻であることの両方に依存している。
    private var entries: [Entry] = []

    /// id からエントリを O(1) で引くための索引。逐次絞り込みで候補集合を絞る際に使う。
    private var entryByID: [Int64: Entry] = [:]

    private var refineStack: [RefineFrame] = []

    private let matcher = FuzzyMatcher()

    public init() {}

    /// 全件を置き換える（起動時ロード用）。
    public func load(_ newEntries: [IndexEntry]) {
        entries = newEntries.map(Self.makeEntry)
        rebuildIndexByID()
        refineStack.removeAll()
    }

    /// 新規コピー1件を末尾に追記する（設計書6.1「新規コピー・選択確定時は配列末尾に追記するのみ。
    /// DB再読み込みは行わない」）。
    public func append(_ entry: IndexEntry) {
        let e = Self.makeEntry(entry)
        entries.append(e)
        entryByID[e.id] = e
        // 追記によって「候補集合＝これまでのヒット」という前提が崩れる
        // （新規エントリは過去のどの絞り込み結果にも含まれていない）ため、
        // 逐次絞り込みのキャッシュは破棄する。次回検索は全件走査からやり直す。
        refineStack.removeAll()
    }

    /// 指定した id 群をインデックスから除去する（将来のパージ機能向け）。
    public func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        for id in ids {
            entryByID.removeValue(forKey: id)
        }
        refineStack.removeAll()
    }

    /// クエリに対する検索結果を、マッチしたitem idのcreatedAt降順（同点はid降順）で返す。
    public func search(query: String, limit: Int) -> [Int64] {
        let normalizedQuery = Normalizer.normalize(query)
        let terms = tokenize(normalizedQuery)

        guard !terms.isEmpty else {
            // 空クエリは走査せず、createdAt 降順の先頭 limit 件を返す（設計書6.3）
            refineStack.removeAll()
            return recentIDs(limit: limit)
        }

        // 1. スタックを、新クエリの前方拡張になっている段まで巻き戻す（設計書6.4）
        while let top = refineStack.last, !normalizedQuery.hasPrefix(top.query) {
            refineStack.removeLast()
        }

        // 2. 巻き戻した結果、ちょうど同じクエリの段が残っていればそのままキャッシュを使う
        //    （例: バックスペースで一度戻ってから、たまたま同じ文字列を再入力した場合）
        if let top = refineStack.last, top.query == normalizedQuery {
            return Array(top.ids.prefix(limit))
        }

        // 3. 前方拡張なら直前のヒット集合だけを、そうでなければ全件を候補にする
        let candidates: [Entry]
        if let top = refineStack.last {
            candidates = top.ids.compactMap { entryByID[$0] }
        } else {
            candidates = entries
        }

        var scored: [(id: Int64, createdAt: Int64)] = []
        scored.reserveCapacity(candidates.count)

        for entry in candidates {
            if totalScore(entry: entry, terms: terms) != nil {
                scored.append((entry.id, entry.createdAt))
            }
        }

        // created_at 降順。同点は id 降順で解決（絞り込み中も一覧の並びは常に時刻順を保つ）
        scored.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id > rhs.id
        }

        let hitIDs = scored.map(\.id)
        refineStack.append(RefineFrame(query: normalizedQuery, ids: hitIDs))

        return Array(hitIDs.prefix(limit))
    }

    // MARK: - Private

    private static func makeEntry(_ indexEntry: IndexEntry) -> Entry {
        Entry(
            id: indexEntry.id,
            createdAt: indexEntry.createdAt,
            scalars: Array(indexEntry.searchKey.unicodeScalars)
        )
    }

    private func rebuildIndexByID() {
        entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    /// クエリをスペース区切りで分割する（設計書6.3「全ターム AND 条件」）。
    /// クエリは呼び出し前に `Normalizer.normalize` 済みのため、連続空白は既に1個に
    /// 圧縮されている。
    private func tokenize(_ normalizedQuery: String) -> [[Unicode.Scalar]] {
        normalizedQuery.split(separator: " ").map { Array($0.unicodeScalars) }
    }

    /// 全ターム AND のスコア合計。1タームでも不一致なら nil（AND条件、設計書6.3）。
    private func totalScore(entry: Entry, terms: [[Unicode.Scalar]]) -> Int? {
        var total = 0
        for term in terms {
            guard let s = matcher.score(needle: term, haystack: entry.scalars) else { return nil }
            total += s
        }
        return total
    }

    /// `entries` は createdAt 昇順（tie: id昇順）で保持されている前提のため、末尾から
    /// limit 件を取り出して逆順にするだけで「createdAt降順・同点はid降順」の先頭limit件になる。
    private func recentIDs(limit: Int) -> [Int64] {
        guard limit > 0, !entries.isEmpty else { return [] }
        let take = min(limit, entries.count)
        return entries.suffix(take).reversed().map(\.id)
    }
}
