import Testing
@testable import ClipHistoryCore

private func scalars(_ s: String) -> [Unicode.Scalar] {
    Array(s.unicodeScalars)
}

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test("サブシーケンス一致: abc は axxbxxc にマッチする")
    func subsequenceMatches() {
        let matcher = FuzzyMatcher()
        let score = matcher.score(needle: scalars("abc"), haystack: scalars("axxbxxc"))
        #expect(score != nil)
    }

    @Test("順序が崩れる acb は axxbxxc にマッチしない")
    func outOfOrderDoesNotMatch() {
        let matcher = FuzzyMatcher()
        let score = matcher.score(needle: scalars("acb"), haystack: scalars("axxbxxc"))
        #expect(score == nil)
    }

    @Test("needle が haystack より長い場合はマッチしない")
    func needleLongerThanHaystackDoesNotMatch() {
        let matcher = FuzzyMatcher()
        let score = matcher.score(needle: scalars("abcde"), haystack: scalars("abc"))
        #expect(score == nil)
    }

    @Test("空needleは常にスコア0でマッチする")
    func emptyNeedleAlwaysMatches() {
        let matcher = FuzzyMatcher()
        let score = matcher.score(needle: scalars(""), haystack: scalars("anything"))
        #expect(score == 0)
    }

    @Test("連続一致は分散一致よりスコアが高い")
    func consecutiveMatchScoresHigherThanScattered() {
        let matcher = FuzzyMatcher()
        // どちらも "abc" が haystack と同じ長さ・似た構造だが、一方は連続、他方は分散させる
        let consecutiveScore = matcher.score(needle: scalars("abc"), haystack: scalars("xxabcxxxxx"))!
        let scatteredScore = matcher.score(needle: scalars("abc"), haystack: scalars("xxaxxbxxxc"))!
        #expect(consecutiveScore > scatteredScore)
    }

    @Test("語頭一致は語中一致よりスコアが高い")
    func boundaryMatchScoresHigherThanMidWordMatch() {
        let matcher = FuzzyMatcher()
        // 同じ長さ・同じ位置(index 3)で一致させつつ、境界の有無だけを変える
        let atBoundaryScore = matcher.score(needle: scalars("ab"), haystack: scalars("xx-abyyyy"))!
        let midWordScore = matcher.score(needle: scalars("ab"), haystack: scalars("xxxabyyyy"))!
        #expect(atBoundaryScore > midWordScore)
    }

    @Test("文字列先頭に近い一致ほどスコアが高い（語頭一致であることは揃える）")
    func earlierPositionScoresHigherThanLaterPosition() {
        let matcher = FuzzyMatcher()
        // 'a' は両方とも直前が '-'（区切り文字）で語頭一致になるが、出現位置だけが異なる
        let earlyScore = matcher.score(needle: scalars("a"), haystack: scalars("-abbbbbbbbbb"))!
        let lateScore = matcher.score(needle: scalars("a"), haystack: scalars("bbbbbbbbbb-a"))!
        #expect(earlyScore > lateScore)
    }

    @Test("キャメルケース境界直後の一致は語中一致よりスコアが高い")
    func camelCaseBoundaryScoresHigherThanMidWord() {
        let matcher = FuzzyMatcher()
        // FuzzyMatcher自体は大文字小文字混在の入力も扱える汎用スコアラーとして実装しているため、
        // ここでは正規化前の（大文字小文字混在の）文字列を直接渡して検証する。
        // 実運用ではsearch_keyは常に小文字化済みのため、この分岐は実データ上はほぼ発火しない。
        // 長さ・一致位置(index 4)を揃え、境界の有無だけを変える:
        // "itemValue" は 'm'(小文字)→'V'(大文字) でキャメルケース境界になるが、
        // "ITEMVALUE" は 'M'(大文字)→'V'(大文字) のため境界にはならない。
        let camelBoundaryScore = matcher.score(needle: scalars("V"), haystack: scalars("itemValue"))!
        let midWordScore = matcher.score(needle: scalars("V"), haystack: scalars("ITEMVALUE"))!
        #expect(camelBoundaryScore > midWordScore)
    }

    @Test("文字列全体が短いとわずかに加点される")
    func shortHaystackScoresSlightlyHigher() {
        let matcher = FuzzyMatcher()
        let shortScore = matcher.score(needle: scalars("a"), haystack: scalars("-a"))!
        let longScore = matcher.score(needle: scalars("a"), haystack: scalars("-a" + String(repeating: "x", count: 100)))!
        #expect(shortScore > longScore)
    }

    @Test("日本語文字列でもサブシーケンス一致とスコアリングができる")
    func matchesJapaneseText() {
        let matcher = FuzzyMatcher()
        let score = matcher.score(needle: scalars("会議"), haystack: scalars("本日の会議の議事録"))
        #expect(score != nil)

        let noMatch = matcher.score(needle: scalars("会議"), haystack: scalars("議会に関する報告書"))
        #expect(noMatch == nil)
    }
}
