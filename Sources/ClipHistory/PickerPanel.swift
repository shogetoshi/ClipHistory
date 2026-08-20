import Cocoa

/// ホットキーで呼び出される検索パネル本体（設計書 7.1）。
///
/// `.nonactivatingPanel` を指定することで、パネルを前面表示してもアプリ全体を
/// アクティブ化しない（= 前面アプリを奪わない）挙動にできる。ただしこのままでは
/// パネルがキーウィンドウにならず検索フィールドが文字入力を受け取れないため、
/// `canBecomeKey` を明示的に `true` にオーバーライドし、表示側（`PickerPanelController`）で
/// `NSApp.activate()` → `makeKeyAndOrderFront()` の順に呼んでキーウィンドウ化する。
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = false
        // 他アプリがアクティブになった際に OS が自動でパネルを隠す挙動を無効化する。
        // フォーカスロスト時に閉じる制御は windowDidResignKey で明示的に行うため、
        // ここで自動非表示を許可すると二重に制御が走り挙動が読みにくくなる。
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true

        // 角丸・半透明の背景。凝ったデザインは不要なため NSVisualEffectView 一枚で軽く整える。
        let effectView = NSVisualEffectView(frame: contentRect)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        contentView = effectView
    }
}
