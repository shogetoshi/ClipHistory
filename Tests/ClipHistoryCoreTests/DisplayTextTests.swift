import Testing
@testable import ClipHistoryCore

@Suite("DisplayText")
struct DisplayTextTests {
    @Test("LF改行が半角スペース1個に畳まれる")
    func lineFeedIsCollapsedToSingleSpace() {
        let result = DisplayText.singleLine("[user]\nname = shogetoshi")
        #expect(result == "[user] name = shogetoshi")
    }

    @Test("CRLF改行が半角スペース1個に畳まれる")
    func crlfIsCollapsedToSingleSpace() {
        let result = DisplayText.singleLine("a\r\nb")
        #expect(result == "a b")
    }

    @Test("タブと連続する空白が1個の半角スペースに畳まれる")
    func tabsAndConsecutiveSpacesAreCollapsed() {
        let result = DisplayText.singleLine("a\t\t  b")
        #expect(result == "a b")
    }

    @Test("全角スペースも畳む対象に含める（行の見た目を揃えるため、半角スペースと区別しない）")
    func fullWidthSpaceIsCollapsedToo() {
        // 全角スペース単体でも半角スペース1個に変換される
        #expect(DisplayText.singleLine("a\u{3000}b") == "a b")
        // 半角・全角が混在して連続していても1個に畳まれる
        #expect(DisplayText.singleLine("a \u{3000} \u{3000}b") == "a b")
    }

    @Test("前後の空白がトリムされる")
    func leadingAndTrailingWhitespaceIsTrimmed() {
        let result = DisplayText.singleLine("  \n\t hello \t\n  ")
        #expect(result == "hello")
    }

    @Test("空文字は空文字のまま返る")
    func emptyStringRemainsEmpty() {
        #expect(DisplayText.singleLine("") == "")
    }

    @Test("空白のみの入力は空文字が返る")
    func whitespaceOnlyInputReturnsEmptyString() {
        #expect(DisplayText.singleLine("   \n\t\r\n  ") == "")
    }
}
