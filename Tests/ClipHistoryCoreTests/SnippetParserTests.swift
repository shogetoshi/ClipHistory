import Testing
@testable import ClipHistoryCore

@Suite("SnippetParser")
struct SnippetParserTests {
    @Test("git.mdの例が2件のアイテムに分かれ、2件目のtitle・codeBlock・fullTextが仕様どおりになる")
    func gitMarkdownExampleIsSplitIntoTwoItems() {
        let markdown = """
        ### branch rename master to main
        ```bash
        git branch -m master main
        ```

        ### rebase onto
        ```bash
        git rebase --onto <ここに> <ここから> <これを>
        ```

        ```
        o-o-o     develop (d1,d2,d3)
           \\o-o   feature (f1,f2)

        git rebase --onto d1 d2 feature

        o-o-o     develop (d1,d2,d3)
         \\o-o     feature (f1,f2)
        ```
        """

        let items = SnippetParser.parse(markdown: markdown)
        #expect(items.count == 2)

        let second = items[1]
        #expect(second.title == "rebase onto")
        #expect(second.codeBlock == "git rebase --onto <ここに> <ここから> <これを>")
        #expect(second.fullText.hasPrefix("### rebase onto"))
        #expect(second.fullText.contains("git rebase --onto <ここに> <ここから> <これを>"))
    }

    @Test("最初の###より前の内容が捨てられる")
    func contentBeforeFirstHeadingIsDiscarded() {
        let markdown = """
        # タイトル
        前置きの説明文

        ### item
        本文
        """

        let items = SnippetParser.parse(markdown: markdown)
        #expect(items.count == 1)
        #expect(items[0].title == "item")
        #expect(!items[0].fullText.contains("前置きの説明文"))
    }

    @Test("```が1つも無いアイテムのcodeBlockはnil")
    func itemWithoutCodeFenceHasNilCodeBlock() {
        let markdown = """
        ### item
        本文のみでコードブロックは無い
        """

        let items = SnippetParser.parse(markdown: markdown)
        #expect(items.count == 1)
        #expect(items[0].codeBlock == nil)
    }

    @Test("閉じフェンスが無い場合codeBlockはnil")
    func unclosedCodeFenceResultsInNilCodeBlock() {
        let markdown = """
        ### item
        ```bash
        git status
        """

        let items = SnippetParser.parse(markdown: markdown)
        #expect(items.count == 1)
        #expect(items[0].codeBlock == nil)
    }

    @Test("####の行も境界になる")
    func fourHashHeadingIsAlsoBoundary() {
        let markdown = """
        ### first
        本文1

        #### second
        本文2
        """

        let items = SnippetParser.parse(markdown: markdown)
        #expect(items.count == 2)
        #expect(items[0].title == "first")
        #expect(items[1].title == "second")
    }

    @Test("インデントされた###は境界にならない")
    func indentedHeadingIsNotBoundary() {
        let markdown = """
        ### first
        本文1
          ### インデントされた見出し
        本文2
        """

        let items = SnippetParser.parse(markdown: markdown)
        #expect(items.count == 1)
        #expect(items[0].fullText.contains("インデントされた見出し"))
    }

    @Test("###が1つも無い入力では空配列になる")
    func inputWithoutAnyHeadingReturnsEmptyArray() {
        let items = SnippetParser.parse(markdown: "ただのテキスト\nもう一行")
        #expect(items.isEmpty)
    }

    @Test("タイトルが空の見出しは結果に含まれない")
    func headingWithEmptyTitleIsExcluded() {
        let markdown = """
        ###
        本文

        ### item
        本文2
        """

        let items = SnippetParser.parse(markdown: markdown)
        #expect(items.count == 1)
        #expect(items[0].title == "item")
    }
}
