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

    @Test("containsSpecialSyntaxは特殊構文の有無を判定する")
    func containsSpecialSyntaxDetectsAnchorsAndNegation() {
        #expect(!QueryParser.containsSpecialSyntax(QueryParser.parse("foo bar")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("^foo")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("foo$")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("!foo")))
        #expect(QueryParser.containsSpecialSyntax(QueryParser.parse("foo !bar")))
    }
}
