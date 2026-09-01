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

    @Test("クォート無しの整数値が文字列として取れる")
    func unquotedIntegerValueIsStoredAsString() throws {
        let result = try TOMLParser.parse("""
        [table]
        key = 123
        """)
        #expect(result["table"] == ["key": "123"])
    }

    @Test("クォート無しの負数・小数が文字列として取れる")
    func unquotedNegativeAndFloatValuesAreStoredAsString() throws {
        let result = try TOMLParser.parse("""
        [table]
        a = -3
        b = +0.5
        c = 2.75
        """)
        #expect(result["table"]?["a"] == "-3")
        #expect(result["table"]?["b"] == "+0.5")
        #expect(result["table"]?["c"] == "2.75")
    }

    @Test("数値の後ろに行コメントが付いていても読める")
    func numericValueWithTrailingCommentIsParsed() throws {
        let result = try TOMLParser.parse("""
        [table]
        timeout = 10  # 秒
        """)
        #expect(result["table"] == ["timeout": "10"])
    }

    @Test("未対応の値（大文字小文字が異なる真偽値）で throw する")
    func unsupportedBooleanValueThrows() {
        #expect(throws: (any Error).self) {
            try TOMLParser.parse("""
            [table]
            key = True
            """)
        }
        #expect(throws: (any Error).self) {
            try TOMLParser.parse("""
            [table]
            key = TRUE
            """)
        }
    }

    @Test("未対応の値（アンダースコア区切りの数値）で throw する")
    func unsupportedUnderscoreNumberValueThrows() {
        #expect(throws: (any Error).self) {
            try TOMLParser.parse("""
            [table]
            key = 1_000
            """)
        }
    }

    @Test("未対応の値（数値要素を含む配列）で throw する")
    func unsupportedArrayValueThrows() {
        #expect(throws: (any Error).self) {
            try TOMLParser.parse("""
            [table]
            key = [1, 2]
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

    @Test("クォート無しの true が文字列としてパースできる")
    func unquotedTrueValueIsStoredAsString() throws {
        let result = try TOMLParser.parse("""
        [table]
        key = true
        """)
        #expect(result["table"] == ["key": "true"])
    }

    @Test("クォート無しの false が文字列としてパースできる")
    func unquotedFalseValueIsStoredAsString() throws {
        let result = try TOMLParser.parse("""
        [table]
        key = false
        """)
        #expect(result["table"] == ["key": "false"])
    }

    @Test("複数要素の文字列配列が parseDocument の arrays に読み込まれる")
    func multipleElementStringArrayIsLoadedIntoArrays() throws {
        let result = try TOMLParser.parseDocument("""
        [table]
        dirs = ["a", "b", "c"]
        """)
        #expect(result.arrays["table"] == ["dirs": ["a", "b", "c"]])
    }

    @Test("空配列が空の配列として読み込まれる")
    func emptyArrayIsLoadedAsEmptyArray() throws {
        let result = try TOMLParser.parseDocument("""
        [table]
        dirs = []
        """)
        #expect(result.arrays["table"] == ["dirs": []])
    }

    @Test("末尾カンマと要素間の空白を許容する")
    func trailingCommaAndSpacesBetweenElementsAreAllowed() throws {
        let result = try TOMLParser.parseDocument("""
        [table]
        dirs = [ "a" , "b" , ]
        """)
        #expect(result.arrays["table"] == ["dirs": ["a", "b"]])
    }

    @Test("配列要素のエスケープが展開される")
    func escapeSequencesInArrayElementsAreExpanded() throws {
        let result = try TOMLParser.parseDocument("""
        [table]
        dirs = ["a\\nb", "a\\"b"]
        """)
        #expect(result.arrays["table"] == ["dirs": ["a\nb", "a\"b"]])
    }

    @Test("行コメントが配列でも正しく除去される")
    func lineCommentIsStrippedFromArrayValueToo() throws {
        let result = try TOMLParser.parseDocument("""
        [table]
        dirs = ["a"] # コメント
        """)
        #expect(result.arrays["table"] == ["dirs": ["a"]])
    }

    @Test("閉じ括弧が無い（複数行配列）場合は syntaxError を投げる")
    func unterminatedArrayThrowsSyntaxError() throws {
        let error = try #require(throws: TOMLParseError.self) {
            try TOMLParser.parseDocument("""
            [table]
            key = ["a"
            """)
        }
        guard case .syntaxError = error else {
            Issue.record("syntaxError であるべきところ \(error) が投げられた")
            return
        }
    }

    @Test("同一テーブル内で同じキーが文字列と配列で重複したら duplicateKey を投げる")
    func duplicateKeyAcrossStringAndArrayThrows() throws {
        let error = try #require(throws: TOMLParseError.self) {
            try TOMLParser.parseDocument("""
            [table]
            key = "a"
            key = ["b"]
            """)
        }
        guard case .duplicateKey = error else {
            Issue.record("duplicateKey であるべきところ \(error) が投げられた")
            return
        }
    }

    @Test("既存の parse は配列を含む設定でも文字列値だけを返す（配列キーは含まれない）")
    func parseReturnsOnlyStringValuesWhenArrayIsPresent() throws {
        let result = try TOMLParser.parse("""
        [table]
        str = "value"
        dirs = ["a", "b"]
        """)
        #expect(result["table"] == ["str": "value"])
    }
}
