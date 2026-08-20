import Testing
@testable import ClipHistoryCore

@Suite("Normalizer")
struct NormalizerTests {
    @Test("全角英数字が半角に統一される")
    func fullWidthAlnumIsConvertedToHalfWidth() {
        let result = Normalizer.normalize("Ａ１ｂ２")
        #expect(result == "a1b2")
    }

    @Test("大文字が小文字化される")
    func uppercaseIsLowered() {
        let result = Normalizer.normalize("HELLO World")
        #expect(result == "hello world")
    }

    @Test("連続する空白が1個に圧縮される")
    func consecutiveWhitespaceIsCollapsed() {
        let result = Normalizer.normalize("a   b\t\nc")
        #expect(result == "a b c")
    }

    @Test("先頭120文字に切り詰められる")
    func truncatedToFirst120Characters() {
        let input = String(repeating: "x", count: 130)
        let result = Normalizer.normalize(input)
        #expect(result.count == 120)
        #expect(result == String(repeating: "x", count: 120))
    }

    @Test("ひらがな・カタカナは相互変換されない")
    func kanaIsNotConverted() {
        #expect(Normalizer.normalize("ひらがな") == "ひらがな")
        #expect(Normalizer.normalize("カタカナ") == "カタカナ")
        // ひらがな・カタカナ間で一致してしまわないこと（相互変換されていないことの確認）
        #expect(Normalizer.normalize("あいう") != Normalizer.normalize("アイウ"))
    }
}
