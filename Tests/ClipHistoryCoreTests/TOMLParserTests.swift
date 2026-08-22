import Testing
@testable import ClipHistoryCore

@Suite("TOMLParser")
struct TOMLParserTests {
    @Test("テーブルヘッダとキー・値がパースできる")
    func tableHeaderAndKeyValueAreParsed() throws {
        let result = try TOMLParser.parse("""
        [table]
        key = "value"
        """)
        #expect(result["table"] == ["key": "value"])
    }

    @Test("ドット区切りのテーブルヘッダがそのままキーになる")
    func dotSeparatedTableHeaderBecomesJoinedKey() throws {
        let result = try TOMLParser.parse("""
        [nvim.env]
        FOO = "bar"
        """)
        #expect(result["nvim.env"] == ["FOO": "bar"])
    }

    @Test("コメントと空行が無視される")
    func commentsAndEmptyLinesAreIgnored() throws {
        let result = try TOMLParser.parse("""
        # comment

        [table]
        # another comment
        key = "value"

        """)
        #expect(result["table"] == ["key": "value"])
    }

    @Test("文字列リテラル内の # がコメント扱いされない")
    func hashInsideStringLiteralIsNotTreatedAsComment() throws {
        let result = try TOMLParser.parse("""
        [table]
        key = "va#lue"
        """)
        #expect(result["table"] == ["key": "va#lue"])
    }

    @Test("エスケープシーケンスが展開される")
    func escapeSequencesAreExpanded() throws {
        let result = try TOMLParser.parse("""
        [table]
        a = "line1\\nline2"
        b = "quote\\"here"
        c = "\\u3042"
        """)
        #expect(result["table"]?["a"] == "line1\nline2")
        #expect(result["table"]?["b"] == "quote\"here")
        #expect(result["table"]?["c"] == "あ")
    }

    @Test("未対応の値（数値）で throw する")
    func unsupportedNumericValueThrows() {
        #expect(throws: (any Error).self) {
            try TOMLParser.parse("""
            [table]
            key = 123
            """)
        }
    }

    @Test("未対応の値（配列）で throw する")
    func unsupportedArrayValueThrows() {
        #expect(throws: (any Error).self) {
            try TOMLParser.parse("""
            [table]
            key = ["a", "b"]
            """)
        }
    }

    @Test("重複キーで throw する")
    func duplicateKeyThrows() {
        #expect(throws: (any Error).self) {
            try TOMLParser.parse("""
            [table]
            key = "a"
            key = "b"
            """)
        }
    }

    @Test("ルートテーブル（ヘッダなし）のキーが空文字列に入る")
    func rootTableKeyIsStoredUnderEmptyString() throws {
        let result = try TOMLParser.parse("""
        key = "value"
        """)
        #expect(result[""] == ["key": "value"])
    }
}
