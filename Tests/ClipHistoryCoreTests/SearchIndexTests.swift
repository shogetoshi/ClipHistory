import Testing
@testable import ClipHistoryCore

private func makeEntry(id: Int64, createdAt: Int64, text: String) -> IndexEntry {
    IndexEntry(id: id, createdAt: createdAt, searchKey: Normalizer.normalize(text))
}

@Suite("SearchIndex")
struct SearchIndexTests {
    @Test("AND条件: foo bar は両方を含む対象にのみ、順不同でマッチする")
    func andConditionMatchesBothTermsRegardlessOfOrder() {
        let index = SearchIndex()
        index.load([
            makeEntry(id: 1, createdAt: 1_000, text: "foo only"),
            makeEntry(id: 2, createdAt: 2_000, text: "bar only"),
            makeEntry(id: 3, createdAt: 3_000, text: "foo and bar together"),
            makeEntry(id: 4, createdAt: 4_000, text: "bar comes before foo here"),
            makeEntry(id: 5, createdAt: 5_000, text: "neither term appears"),
        ])

        let hits = Set(index.search(query: "foo bar", limit: 10))
        #expect(hits == Set([3, 4]))
    }

    @Test("正規化の一貫性: 全角・大文字で入力しても半角小文字の対象にマッチする")
    func normalizationConsistencyBetweenQueryAndStoredData() {
        let index = SearchIndex()
        index.load([
            makeEntry(id: 1, createdAt: 1_000, text: "Hello World"),
        ])

        // クエリを全角・大文字で入力しても、正規化済みの search_key にマッチすること
        let hits = index.search(query: "ＨＥＬＬＯ", limit: 10)
        #expect(hits == [1])
    }

    @Test("空クエリでは走査せずcreatedAt降順の先頭limit件が返る")
    func emptyQueryReturnsRecentByCreatedAtDescending() {
        let index = SearchIndex()
        index.load([
            makeEntry(id: 1, createdAt: 1_000, text: "aaa"),
            makeEntry(id: 2, createdAt: 2_000, text: "bbb"),
            makeEntry(id: 3, createdAt: 3_000, text: "ccc"),
        ])

        let hits = index.search(query: "", limit: 2)
        #expect(hits == [3, 2])
    }

    @Test("空クエリはcreatedAt同点の場合id降順で解決する")
    func emptyQueryTieBreaksByIDDescending() {
        let index = SearchIndex()
        index.load([
            makeEntry(id: 1, createdAt: 1_000, text: "aaa"),
            makeEntry(id: 2, createdAt: 1_000, text: "bbb"),
        ])

        let hits = index.search(query: "", limit: 10)
        #expect(hits == [2, 1])
    }

    @Test("スコア降順に並び、同点はcreatedAt降順→id降順で解決する")
    func scoreOrderingWithTieBreaks() {
        let index = SearchIndex()
        index.load([
            // "foo" が連続一致する方が、分散一致するものよりスコアが高いはず
            makeEntry(id: 1, createdAt: 1_000, text: "xx f xx o xx o xx"),
            makeEntry(id: 2, createdAt: 2_000, text: "foo appears consecutively"),
        ])

        let hits = index.search(query: "foo", limit: 10)
        #expect(hits == [2, 1])
    }

    @Test("逐次絞り込みの正当性: f→fo→fooの結果がfooを直接検索した結果と完全に一致する")
    func progressiveRefinementMatchesDirectSearch() {
        let entries = (0..<200).map { i -> IndexEntry in
            let text: String
            switch i % 4 {
            case 0: text = "foo bar baz \(i)"
            case 1: text = "food is great \(i)"
            case 2: text = "fox and hound \(i)"
            default: text = "completely unrelated text \(i)"
            }
            return makeEntry(id: Int64(i + 1), createdAt: Int64(i), text: text)
        }

        let progressive = SearchIndex()
        progressive.load(entries)
        _ = progressive.search(query: "f", limit: 1_000)
        _ = progressive.search(query: "fo", limit: 1_000)
        let progressiveResult = progressive.search(query: "foo", limit: 1_000)

        let direct = SearchIndex()
        direct.load(entries)
        let directResult = direct.search(query: "foo", limit: 1_000)

        #expect(progressiveResult == directResult)
    }

    @Test("逐次絞り込みの正当性: バックスペースで巻き戻した場合も直接検索と完全に一致する")
    func progressiveRefinementWithBackspaceMatchesDirectSearch() {
        let entries = (0..<200).map { i -> IndexEntry in
            let text: String
            switch i % 5 {
            case 0: text = "foo bar baz \(i)"
            case 1: text = "food is great \(i)"
            case 2: text = "bar none here \(i)"
            case 3: text = "barn door \(i)"
            default: text = "completely unrelated text \(i)"
            }
            return makeEntry(id: Int64(i + 1), createdAt: Int64(i), text: text)
        }

        let progressive = SearchIndex()
        progressive.load(entries)
        // f -> fo -> foo -> fo (バックスペース) -> foo (再入力) -> foo b (スペース+新ターム) -> foo ba -> foo bar
        _ = progressive.search(query: "f", limit: 1_000)
        _ = progressive.search(query: "fo", limit: 1_000)
        _ = progressive.search(query: "foo", limit: 1_000)
        _ = progressive.search(query: "fo", limit: 1_000)
        _ = progressive.search(query: "foo", limit: 1_000)
        _ = progressive.search(query: "foo b", limit: 1_000)
        _ = progressive.search(query: "foo ba", limit: 1_000)
        let progressiveResult = progressive.search(query: "foo bar", limit: 1_000)

        // まったく別の文字列を経由してから本命に戻すパターンも試す（スタックが空になり全件走査に
        // 戻る経路を通す）
        let progressiveViaUnrelated = SearchIndex()
        progressiveViaUnrelated.load(entries)
        _ = progressiveViaUnrelated.search(query: "foo", limit: 1_000)
        _ = progressiveViaUnrelated.search(query: "zzz-unrelated", limit: 1_000)
        _ = progressiveViaUnrelated.search(query: "foo b", limit: 1_000)
        let progressiveViaUnrelatedResult = progressiveViaUnrelated.search(query: "foo bar", limit: 1_000)

        let direct = SearchIndex()
        direct.load(entries)
        let directResult = direct.search(query: "foo bar", limit: 1_000)

        #expect(progressiveResult == directResult)
        #expect(progressiveViaUnrelatedResult == directResult)
    }

    @Test("append で追記したエントリも検索対象になり、DB再読み込みなしで反映される")
    func appendedEntryIsSearchable() {
        let index = SearchIndex()
        index.load([
            makeEntry(id: 1, createdAt: 1_000, text: "existing entry"),
        ])
        index.append(makeEntry(id: 2, createdAt: 2_000, text: "newly appended entry"))

        let hits = index.search(query: "appended", limit: 10)
        #expect(hits == [2])
    }

    @Test("remove で指定したidが検索結果から除去される")
    func removedEntryIsNoLongerSearchable() {
        let index = SearchIndex()
        index.load([
            makeEntry(id: 1, createdAt: 1_000, text: "keep me"),
            makeEntry(id: 2, createdAt: 2_000, text: "remove me"),
        ])
        index.remove(ids: [2])

        let hits = index.search(query: "me", limit: 10)
        #expect(hits == [1])
    }
}
