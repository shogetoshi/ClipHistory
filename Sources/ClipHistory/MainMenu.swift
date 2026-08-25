import Cocoa

/// アプリのメインメニュー（`NSApp.mainMenu`）を組み立てる。
///
/// なぜこれが必要なのか: このアプリは `LSUIElement` のアクセサリアプリであり、
/// メニューバーに自前の項目を出さない。しかし AppKit では ⌘C・⌘V などの標準的な
/// 編集キーは `NSTextView` 自身が実装しているのではなく、「編集メニューの項目に
/// 付いたキー等価（key equivalent）」を通じて初めて `copy:` 等のアクションへ変換される。
/// メインメニューが存在しないと、プレビューでテキストを選択して ⌘C を押しても
/// 何も起こらない（不具合の原因）。
///
/// そのため、画面には表示されないメインメニューを1つだけ登録し、標準の編集アクションの
/// キー等価を有効にする。`NSApp.setActivationPolicy(.accessory)` によりメニューバーの
/// 見た目自体は変わらない。
///
/// 各項目には `target` を設定しない。これによりアクションはファーストレスポンダ
/// （プレビューの `NSTextView` や検索欄のフィールドエディタなど）へ responder chain
/// 経由で届く。項目の有効・無効判定も responder 側の `validateUserInterfaceItem` に委ねられる。
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")

        editMenu.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())

        editMenu.addItem(NSMenuItem(title: "切り取り", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))

        editMenu.addItem(NSMenuItem.separator())

        editMenu.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }
}
