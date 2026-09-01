import Cocoa
import ClipHistoryCore

/// グローバルホットキー（⌘⌃⇧C）でパネルを開かずに直接 nvim 編集モードを起動する
/// 「直接Vimモード」の中核（Issue 0020）。
///
/// 今 `NSPasteboard.general` に入っているプレーンテキストを、検索パネルの nvim 編集モード
/// （`NvimEditModeController`、設計書 7.5）と同じ実装でそのまま編集できるようにする。
/// 一覧・検索は一切表示しないため、`PickerPanelController` とは独立した最小限のウィンドウを
/// 自前で持つ。
final class DirectVimEditController: NSObject {
    private static let panelSize = NSSize(width: 720, height: 420)
    /// ウィンドウが内容に引きずられて縮小・拡大しすぎないための下限（`PickerPanelController` と同じ値）。
    private static let panelMinSize = NSSize(width: 480, height: 320)

    private let panel: DirectVimEditPanel
    private let backgroundView: PanelBackgroundView
    /// ターミナルを載せるコンテナ。`backgroundView` の各辺から16pt内側に配置し、
    /// 周囲の余白を背景ドラッグ（`isMovableByWindowBackground`）によるウィンドウ移動に使えるようにする
    /// （通常パネルの `PickerViewController.loadView()` の nvim 編集モード時のレイアウトと同じ16ptに揃えている、Issue 0021）。
    private let terminalContainer = NSView()
    private let nvimEditController: NvimEditModeController
    private let settings: Settings

    /// ホットキー押下時点の frontmost アプリ。編集終了時にここへフォーカスを戻す
    /// （`PickerPanelController` 7.3 と同じ方針）。
    private var previousFrontmostApp: NSRunningApplication?

    init(settings: Settings) {
        self.settings = settings
        let contentRect = NSRect(origin: .zero, size: Self.panelSize)
        panel = DirectVimEditPanel(contentRect: contentRect)

        let background = PanelBackgroundView(frame: contentRect)
        backgroundView = background
        panel.contentView = background

        background.addSubview(terminalContainer)
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            terminalContainer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            terminalContainer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            terminalContainer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16)
        ])

        nvimEditController = NvimEditModeController(container: terminalContainer)
        super.init()

        panel.contentMinSize = Self.panelMinSize
        panel.delegate = self

        nvimEditController.onEditingChanged = { [weak self] editing in
            guard let self, !editing else { return }
            // isEditing が false になるのは finish(commit:) / nvim 終了のいずれかの経路
            // （NvimEditModeController.tearDown() 内）であり、このウィンドウの唯一の状態は
            // 「編集中」なので、編集が終わったらウィンドウを閉じてフォーカスを戻してよい。
            self.hideAndRestoreFocus()
        }
        nvimEditController.onCommit = { [weak self] text in
            self?.writeToPasteboard(text)
        }
    }

    /// ホットキー（⌘⌃⇧C）から呼ばれる。既に編集中なら何もしない。
    /// クリップボードにプレーンテキストが無い場合（画像のみ等）はビープのみで何もしない
    /// （設計書 7.5 の nvim 編集対象がテキストに限られるのと同じ方針）。
    func begin() {
        guard !nvimEditController.isEditing else { return }

        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }

        previousFrontmostApp = NSWorkspace.shared.frontmostApplication

        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        nvimEditController.begin(text: text)
    }

    private func hideAndRestoreFocus() {
        panel.orderOut(nil)
        previousFrontmostApp?.activate()
        previousFrontmostApp = nil
    }

    /// nvim で編集した内容を `NSPasteboard` へ書き戻す。`PickerPanelController.commitEditedText(_:)`
    /// と同じくプレーンテキスト1表現のみを書き戻す（設計書 7.5「なぜテキスト1表現だけ書き戻すか」）。
    private func writeToPasteboard(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            NSLog("ClipHistory: failed to write pasteboard: could not encode edited text as UTF-8")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(PasteboardTextType.utf8PlainText))
    }

    /// 保存済みの位置・大きさがあればそれを復元し、なければアクティブなスクリーン（マウスカーソルが
    /// あるスクリーン）の中央上寄りに配置する。検索パネルから直接Vimモードに入った場合と
    /// 同じウィンドウになるよう、`settings.panelFrame` を `PickerPanelController` と共有する
    /// （Issue 0021）。いずれの場合もアクティブスクリーンの visibleFrame に収まるようクランプする。
    private func positionPanel() {
        guard let screen = activeScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let frame: NSRect
        if let savedFrame = settings.panelFrame {
            frame = NSRect(origin: savedFrame.origin, size: savedFrame.size)
        } else {
            let size = Self.panelSize
            let x = visibleFrame.midX - size.width / 2
            // 「中央上寄り」: 画面上端から visibleFrame 高さの25%の位置にパネル上端がくるようにする
            let y = visibleFrame.maxY - visibleFrame.height * 0.25 - size.height
            frame = NSRect(x: x, y: max(y, visibleFrame.minY), width: size.width, height: size.height)
        }
        // アクティブスクリーンごとに visibleFrame は変わるため、表示のたびに上限を更新する。
        panel.contentMaxSize = visibleFrame.size
        panel.setFrame(clamped(frame, to: visibleFrame), display: false)
    }

    /// 矩形を `screenFrame` に収まるようクランプする（`PickerPanelController.clamped(_:to:)` と同じロジック）。
    /// まず幅・高さを画面以下に切り詰め、そのうえで原点を画面内側に収まる範囲へ移動させる。
    private func clamped(_ rect: NSRect, to screenFrame: NSRect) -> NSRect {
        let width = min(rect.width, screenFrame.width)
        let height = min(rect.height, screenFrame.height)
        let x = min(max(rect.minX, screenFrame.minX), screenFrame.maxX - width)
        let y = min(max(rect.minY, screenFrame.minY), screenFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
    }
}

extension DirectVimEditController: NSWindowDelegate {
    /// 利用者がパネルを移動したら位置を保存する（Issue 0021）。
    /// `panel.isVisible` を見るのは、`positionPanel()` 自身の `setFrame` や非表示中の
    /// フレーム変更で誤って保存してしまわないようにするため。
    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible else { return }
        settings.panelFrame = panel.frame
    }

    /// 利用者がパネルをリサイズしたら大きさを保存する（Issue 0021）。
    /// `panel.isVisible` を見る理由は `windowDidMove(_:)` と同様である。
    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible else { return }
        settings.panelFrame = panel.frame
    }
}

/// 直接Vim編集モード用の最小限のパネル（Issue 0020）。
/// `PickerPanel` 同様、`.nonactivatingPanel` のままではキーウィンドウにならず nvim が
/// 文字入力を受け取れないため `canBecomeKey` を `true` にオーバーライドする。
final class DirectVimEditPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // ボーダーレスでも .resizable を付けることでウィンドウ端のドラッグによる
            // リサイズが可能になる（Issue 0021）。
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        // 背景（マウスイベントを消費しないビュー上）のドラッグでパネルを移動できるようにする（Issue 0021）。
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
