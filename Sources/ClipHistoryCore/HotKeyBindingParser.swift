import Foundation

/// 設定ファイルの `"ctrl+command+c"` のような文字列表現を `HotKeyConfig` に変換する。
public enum HotKeyBindingParser {
    private static let modifierValues: [String: UInt32] = [
        "command": 0x0100,
        "ctrl": 0x1000,
        "option": 0x0800,
        "shift": 0x0200,
    ]

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "enter": 36, "space": 49, "escape": 53,
    ]

    public static func parse(_ text: String) -> HotKeyConfig? {
        let tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 2, let keyToken = tokens.last else { return nil }
        let modifierTokens = tokens.dropLast()
        guard let keyCode = keyCodes[keyToken] else { return nil }

        var modifiers: UInt32 = 0
        var seen = Set<String>()
        for token in modifierTokens {
            guard let value = modifierValues[token], seen.insert(token).inserted else { return nil }
            modifiers |= value
        }

        return HotKeyConfig(keyCode: keyCode, modifiers: modifiers)
    }
}
