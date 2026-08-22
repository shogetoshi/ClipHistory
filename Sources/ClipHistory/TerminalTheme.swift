import Cocoa

/// アプリ全体をターミナル風のダーク配色に統一するための、色と等幅フォントの定義（Issue 0012）。
/// 見た目のみを担い、レイアウトや挙動は持たない。
/// ダークモード固定のため、`NSColor` は動的色ではなく固定の RGB 値で定義する。
enum TerminalTheme {
    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// パネル全体の下地。
    static let background = color(0x16181A)
    /// 一覧・プレビューなど内容領域の下地。
    static let contentBackground = color(0x0F1113)
    /// パネルの外枠・プレビュー枠。
    static let border = color(0x2C3134)
    /// 本文の文字色。
    static let foreground = color(0xD6DBE0)
    /// コピー元アプリ名・相対時刻など補助情報の文字色。
    static let secondaryForeground = color(0x7A8288)
    /// プロンプト記号・キャレットなどの強調色（ターミナルの緑）。
    static let accent = color(0x5FD07A)
    /// 一覧の選択行の背景。
    static let selectionBackground = color(0x24402C)

    /// 一覧の本文用フォント。
    static var listFont: NSFont {
        .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    /// 一覧の補助情報用フォント。
    static var listSubtitleFont: NSFont {
        .monospacedSystemFont(ofSize: 10, weight: .regular)
    }

    /// 検索フィールド用フォント。
    static var searchFont: NSFont {
        .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    /// プレビュー本文・nvim ターミナル用フォント。
    static var previewFont: NSFont {
        .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    /// パネルの角丸半径。
    static let cornerRadius: CGFloat = 10
    /// 枠線の太さ。
    static let borderWidth: CGFloat = 1
}
