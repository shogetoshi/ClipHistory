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

        // 角丸背景は contentViewController のルートビュー（PanelBackgroundView）側で描く。
        // ここで contentView に背景ビューを設定しても contentViewController の代入時に
        // 丸ごと置き換えられてしまうため。
    }
}

/// パネルの不透明な角丸背景を描くビュー（`PickerViewController.loadView()` のルートビューとして使う）。
final class PanelBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
