import Testing
@testable import ClipHistoryCore

private func scalars(_ s: String) -> [Unicode.Scalar] {
    Array(s.unicodeScalars)
}

@Suite("QueryParser")
struct QueryParserTests {
    @Test("記号なしのクエリはfuzzyかつ非否定のタームに分解される")
    func plainQueryBecomesFuzzyTerms() {
        let terms = QueryParser.parse("foo bar")
        #expect(terms.count == 2)
        #expect(terms[0] == QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("foo")))
        #expect(terms[1] == QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("bar")))
    }

    @Test("^fooはprefix、foo$はsuffix、^foo$はexactになる")
    func anchorSyntaxDeterminesKind() {
        let terms = QueryParser.parse("^foo foo$ ^foo$")
        #expect(terms.count == 3)
        #expect(terms[0] == QueryTerm(kind: .prefix, isNegated: false, body: scalars("foo")))
        #expect(terms[1] == QueryTerm(kind: .suffix, isNegated: false, body: scalars("foo")))
        #expect(terms[2] == QueryTerm(kind: .exact, isNegated: false, body: scalars("foo")))
    }

    @Test("!fooは否定、!^fooは否定かつprefixになる")
    func negationSyntaxSetsIsNegated() {
        let terms = QueryParser.parse("!foo !^foo")
        #expect(terms.count == 2)
        #expect(terms[0] == QueryTerm(kind: .fuzzy, isNegated: true, body: scalars("foo")))
        #expect(terms[1] == QueryTerm(kind: .prefix, isNegated: true, body: scalars("foo")))
    }

    @Test("本体が空になるタームは無視される")
    func emptyBodyTermsAreIgnored() {
        let terms = QueryParser.parse("! ^ ^$ foo")
        #expect(terms.count == 1)
        #expect(terms[0] == QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("foo")))
    }

    @Test("中間に現れる記号は本体の一部として扱われる")
    func symbolsInTheMiddleAreTreatedAsPartOfBody() {
        let terms = QueryParser.parse("a^b a$b a!b")
        #expect(terms.count == 3)
        #expect(terms[0] == QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("a^b")))
        #expect(terms[1] == QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("a$b")))
        #expect(terms[2] == QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("a!b")))
    }

    @Test("matchesはprefix/suffix/exact/fuzzyそれぞれで期待通りの真偽を返す")
    func matchesReturnsExpectedResultPerKind() {
        let matcher = FuzzyMatcher()
        let haystack = scalars("hello world")

        let prefixTerm = QueryTerm(kind: .prefix, isNegated: false, body: scalars("hello"))
        #expect(prefixTerm.matches(haystack, matcher: matcher))
        let prefixMismatch = QueryTerm(kind: .prefix, isNegated: false, body: scalars("world"))
        #expect(!prefixMismatch.matches(haystack, matcher: matcher))

        let suffixTerm = QueryTerm(kind: .suffix, isNegated: false, body: scalars("world"))
        #expect(suffixTerm.matches(haystack, matcher: matcher))
        let suffixMismatch = QueryTerm(kind: .suffix, isNegated: false, body: scalars("hello"))
        #expect(!suffixMismatch.matches(haystack, matcher: matcher))

        let exactTerm = QueryTerm(kind: .exact, isNegated: false, body: scalars("hello world"))
        #expect(exactTerm.matches(haystack, matcher: matcher))
        let exactMismatch = QueryTerm(kind: .exact, isNegated: false, body: scalars("hello"))
        #expect(!exactMismatch.matches(haystack, matcher: matcher))

        let fuzzyTerm = QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("hlo"))
        #expect(fuzzyTerm.matches(haystack, matcher: matcher))
        let fuzzyMismatch = QueryTerm(kind: .fuzzy, isNegated: false, body: scalars("xyz"))
        #expect(!fuzzyMismatch.matches(haystack, matcher: matcher))
    }

    @Test("否定タームはmatchesの真偽が反転する")
    func negatedTermInvertsMatchesResult() {
        let matcher = FuzzyMatcher()
        let haystack = scalars("hello world")

        let negatedFuzzyMatch = QueryTerm(kind: .fuzzy, isNegated: true, body: scalars("hlo"))
        #expect(!negatedFuzzyMatch.matches(haystack, matcher: matcher))

        let negatedFuzzyMismatch = QueryTerm(kind: .fuzzy, isNegated: true, body: scalars("xyz"))
        #expect(negatedFuzzyMismatch.matches(haystack, matcher: matcher))

        let negatedPrefixMatch = QueryTerm(kind: .prefix, isNegated: true, body: scalars("hello"))
        #expect(!negatedPrefixMatch.matches(haystack, matcher: matcher))

        let negatedPrefixMismatch = QueryTerm(kind: .prefix, isNegated: true, body: scalars("world"))
        #expect(negatedPrefixMismatch.matches(haystack, matcher: matcher))
    }

    @Test("containsSpecialSyntaxは特殊構文の有無を判定する")
    func containsSpecialSyntaxDetectsAnchorsAndNegation() {
        #expect(!QueryParser.containsSpecialSyntax(QueryParser.parse("foo bar")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("^foo")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("foo$")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("!foo")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("foo !bar")))
    }
}
