import Testing
@testable import ClipHistoryCore

@Suite("HotKeyBindingParser")
struct HotKeyBindingParserTests {
    @Test("ctrl+command+c が期待する keyCode/modifiers になる")
    func ctrlCommandCIsParsed() {
        let result = HotKeyBindingParser.parse("ctrl+command+c")
        #expect(result == HotKeyConfig(keyCode: 8, modifiers: 0x1100))
    }

    @Test("enter/space/escape が使える")
    func enterSpaceEscapeAreParsed() {
        #expect(HotKeyBindingParser.parse("command+enter") == HotKeyConfig(keyCode: 36, modifiers: 0x0100))
        #expect(HotKeyBindingParser.parse("command+space") == HotKeyConfig(keyCode: 49, modifiers: 0x0100))
        #expect(HotKeyBindingParser.parse("command+escape") == HotKeyConfig(keyCode: 53, modifiers: 0x0100))
    }

    @Test("モディファイヤの順序が違っても同じ結果になる")
    func modifierOrderDoesNotMatter() {
        #expect(HotKeyBindingParser.parse("command+ctrl+c") == HotKeyBindingParser.parse("ctrl+command+c"))
    }

    @Test("モディファイヤが1つも無い場合は nil")
    func noModifierReturnsNil() {
        #expect(HotKeyBindingParser.parse("c") == nil)
    }

    @Test("未知のモディファイヤは nil")
    func unknownModifierReturnsNil() {
        #expect(HotKeyBindingParser.parse("cmd+c") == nil)
        #expect(HotKeyBindingParser.parse("alt+c") == nil)
    }

    @Test("未知のキーは nil")
    func unknownKeyReturnsNil() {
        #expect(HotKeyBindingParser.parse("ctrl+command+f1") == nil)
    }

    @Test("空文字列は nil")
    func emptyStringReturnsNil() {
        #expect(HotKeyBindingParser.parse("") == nil)
    }

    @Test("同じモディファイヤの重複は nil")
    func duplicateModifierReturnsNil() {
        #expect(HotKeyBindingParser.parse("ctrl+ctrl+c") == nil)
    }
}
