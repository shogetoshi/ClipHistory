import Cocoa

/// ⌃⌘P / ⌃⌘N でクリップボードへ入れた履歴を、フォーカスを奪わない HUD で数秒間通知する
/// （Issue 0015「クリップボードに入った内容はユーザに通知される」「通知は数秒で消える」）。
///
/// `UNUserNotificationCenter` を使わない理由: `AppDelegate.registerHotKey()` のコメントにある
/// とおり、ad-hoc 署名のローカルアプリでは通知の認可が下りない可能性があり、また
/// 「権限は一切不要」が本アプリの方針（設計書 9節）であるため、OS の通知機構には頼らず
/// 自前の HUD パネルを表示する。
///
/// フォーカスを奪わない実装にしている理由: 利用者はこの通知が出た直後、元のアプリで ⌘V する
/// 前提の機能である。通知パネルがキーウィンドウ・メインウィンドウになったりアプリを
/// アクティブ化したりすると、その ⌘V の宛先が変わってしまい機能が成立しなくなる。

/// クリップボード切り替え通知を表示する HUD パネル本体。
/// `PickerPanel` と異なり、キーウィンドウ化もアプリのアクティブ化も一切行わない。
final class CycleNotificationPanel: NSPanel {
    // フォーカスを奪わないため、キーウィンドウ・メインウィンドウに一切ならないようにする。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 他アプリのウィンドウより前に出す。
        level = .statusBar
        // 通知の下にあるアプリへのクリックを妨げないようにする。
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // フルスクリーン表示のアプリの上でも見えるようにする。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// クリップボード切り替え通知の表示制御を担う。
final class CycleNotificationController {
    /// HUD の表示時間（「数秒で消える」の実装）。
    private static let displayDuration: TimeInterval = 2.5
    private static let fadeOutDuration: TimeInterval = 0.2
    private static let panelSize = NSSize(width: 480, height: 44)
    /// 画面下端中央からの上方向オフセット。
    private static let bottomOffset: CGFloat = 120

    private let panel: CycleNotificationPanel
    private let offsetLabel: NSTextField
    private let contentLabel: NSTextField
    private var dismissTimer: Timer?

    init() {
        let contentRect = NSRect(origin: .zero, size: Self.panelSize)
        panel = CycleNotificationPanel(contentRect: contentRect)

        let backgroundView = PanelBackgroundView(frame: contentRect)

        offsetLabel = NSTextField(labelWithString: "")
        offsetLabel.font = TerminalTheme.listSubtitleFont
        offsetLabel.textColor = TerminalTheme.accent
        offsetLabel.isEditable = false
        offsetLabel.isBezeled = false
        offsetLabel.drawsBackground = false
        offsetLabel.isSelectable = false
        offsetLabel.translatesAutoresizingMaskIntoConstraints = false

        contentLabel = NSTextField(labelWithString: "")
        contentLabel.font = TerminalTheme.listFont
        contentLabel.textColor = TerminalTheme.foreground
        contentLabel.isEditable = false
        contentLabel.isBezeled = false
        contentLabel.drawsBackground = false
        contentLabel.isSelectable = false
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.maximumNumberOfLines = 1
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.addSubview(offsetLabel)
        backgroundView.addSubview(contentLabel)
        NSLayoutConstraint.activate([
            offsetLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            offsetLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),

            contentLabel.leadingAnchor.constraint(equalTo: offsetLabel.trailingAnchor, constant: 10),
            contentLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
            contentLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
        ])

        panel.contentView = backgroundView
    }

    deinit {
        dismissTimer?.invalidate()
    }

    /// クリップボードへ入れた履歴を通知する。
    /// - Parameters:
    ///   - offset: 何個前の履歴か（0 なら最新）。
    ///   - text: 内容ラベルにそのまま表示する文字列。複数行の畳み込みは呼び出し側で
    ///     済ませておくこと（このメソッドは1行に切り詰めない）。
    func show(offset: Int, text: String) {
        offsetLabel.stringValue = offset == 0 ? "最新" : "\(offset)個前"
        contentLabel.stringValue = text.isEmpty ? "（内容なし）" : text

        positionPanel()

        dismissTimer?.invalidate()
        panel.alphaValue = 1
        // makeKeyAndOrderFront や NSApp.activate はフォーカスを奪ってしまうため使わない。
        // 利用者はこの直後に元アプリで ⌘V する前提のため、フォーカスを一切動かさない。
        panel.orderFrontRegardless()

        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.displayDuration, repeats: false) { [weak self] _ in
            self?.fadeOutAndHide()
        }
    }

    /// HUD を即座に隠す。
    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.orderOut(nil)
    }

    private func fadeOutAndHide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    /// アクティブスクリーン（マウスカーソルのあるスクリーン。取れなければ `NSScreen.main`）の
    /// `visibleFrame` の下端中央から120pt上に配置する。画面に収まるよう幅をクランプする。
    private func positionPanel() {
        guard let screen = activeScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let width = min(Self.panelSize.width, visibleFrame.width)
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.minY + Self.bottomOffset
        let frame = NSRect(x: x, y: y, width: width, height: Self.panelSize.height)
        panel.setFrame(frame, display: false)
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
    }
}
