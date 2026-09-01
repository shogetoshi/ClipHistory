import Cocoa
import ClipHistoryCore

/// 検索パネルの表示制御、フォーカス復帰、選択確定時のクリップボード書き戻しを担う
/// （設計書 3.1 `PickerPanelController` / 7.3 フォーカス制御）。
final class PickerPanelController: NSObject {
    private let panel: PickerPanel
    private let pickerViewController: PickerViewController
    private let contentSource: PickerContentSource
    private let settings: Settings

    private static let panelSize = NSSize(width: 720, height: 420)
    /// ウィンドウが内容（長いテキストや大きな画像）に引きずられて縮小・拡大しすぎないための下限（Issue 0009）。
    private static let panelMinSize = NSSize(width: 480, height: 320)

    /// ホットキー押下時点の frontmost アプリ。パネルを閉じる際にここへフォーカスを戻す
    /// （設計書 7.3 手順1・3）。
    private var previousFrontmostApp: NSRunningApplication?

    /// パネル表示直前に呼ばれる。Snippet は `.md` を外部エディタで編集されるため、
    /// 開くたびに読み直す必要がある（Issue 0030）。クリップボード履歴側は設定しないため、
    /// 従来どおり何も起こらない。
    var onWillShow: (() -> Void)?

    init(contentSource: PickerContentSource, resultsProvider: ResultsProvider, settings: Settings, showsItemMetadata: Bool = true) {
        self.contentSource = contentSource
        self.settings = settings
        let contentRect = NSRect(origin: .zero, size: Self.panelSize)
        panel = PickerPanel(contentRect: contentRect)
        pickerViewController = PickerViewController(resultsProvider: resultsProvider, settings: settings, contentSource: contentSource, showsItemMetadata: showsItemMetadata)
        super.init()

        panel.contentViewController = pickerViewController
        // contentViewController を持つウィンドウは内容の fitting size から contentMinSize が
        // 自動決定されることがあるため、保険として明示しておく（Issue 0009）。
        panel.contentMinSize = Self.panelMinSize
        panel.delegate = self

        pickerViewController.onCommit = { [weak self] item in
            self?.commit(item)
        }
        pickerViewController.onCancel = { [weak self] in
            self?.hide(restoringFocus: true)
        }
        pickerViewController.onCommitEditedText = { [weak self] text in
            self?.commitPlainText(text)
        }
        pickerViewController.onCommitJoinedText = { [weak self] text in
            self?.commitPlainText(text)
        }
    }

    /// ホットキーから呼ばれる表示/非表示のトグル（設計書 7.2）。
    func toggle() {
        if panel.isVisible {
            hide(restoringFocus: true)
        } else {
            show()
        }
    }

    private func show() {
        // ホットキー受信時点の frontmost アプリを保持しておく（設計書 7.3 手順1）
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication

        onWillShow?()

        positionPanel()
        pickerViewController.willShow()

        // nonactivatingPanel はそのままではキーウィンドウにならず検索フィールドが
        // 文字入力を受け取れないため、明示的にアプリをアクティブ化してからキーウィンドウ化する
        // （設計書 7.3 手順2）。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// パネルを閉じる。
    ///
    /// `restoringFocus` は「Esc・ホットキー再押下・確定」といった**明示的な閉じ操作**のときだけ
    /// true にする。ユーザーが他アプリをクリックして閉じた場合（`windowDidResignKey`）に
    /// 元アプリを activate してしまうと、ユーザーが今クリックしたアプリからフォーカスを
    /// 奪い返してしまうため、その経路では復帰させない。
    ///
    /// 既に非表示なら何もしない。commit()/hide() 自身の orderOut() が
    /// windowDidResignKey を誘発してもここで弾かれるため、処理が二重に走ることはない。
    private func hide(restoringFocus: Bool) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoringFocus {
            restoreFocus()
        } else {
            previousFrontmostApp = nil
        }
    }

    /// 書き戻す内容が無い場合はビープするだけで、クリップボードもパネルも変えない。
    /// Snippet で ``` のブロックを持たないアイテムを選んだ場合がこれにあたる（Issue 0030）。
    /// クリップボード履歴の項目は常に書き戻せるため、この経路には入らない。
    private func commit(_ item: HistoryItem) {
        guard contentSource.writeToPasteboard(item) else {
            NSSound.beep()
            return
        }
        panel.orderOut(nil)
        restoreFocus()
    }

    /// nvim で編集したテキスト（Issue 0006）と、複数選択を改行結合したテキスト（Issue 0023）を
    /// `public.utf8-plain-text` の1表現だけで `NSPasteboard` へ書き戻す。
    ///
    /// 元項目が RTF などの他表現を持っていても、プレーンテキストとして編集・結合した時点で
    /// 他表現は内容と整合しなくなるため、`public.utf8-plain-text` の1表現だけを書き戻す。
    /// `commit(_:)` と同様、書き戻しは抑制せず、`ClipboardMonitor` に
    /// 通常の変更検知として拾われ履歴の最新に追加されるのは意図どおりである。
    private func commitPlainText(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            NSLog("ClipHistory: failed to write pasteboard: could not encode edited text as UTF-8")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(PasteboardTextType.utf8PlainText))
        panel.orderOut(nil)
        restoreFocus()
    }

    /// 保持していた元アプリを復帰させる（設計書 7.3 手順3）。復帰後、利用者はそのまま ⌘V する。
    private func restoreFocus() {
        previousFrontmostApp?.activate()
        previousFrontmostApp = nil
    }

    /// 保存済みの位置・大きさがあればそれを復元し、なければアクティブなスクリーン（マウスカーソルが
    /// あるスクリーン）の中央上寄りに配置する（設計書 7.1、Issue 0009）。いずれの場合も
    /// アクティブスクリーンの visibleFrame に収まるようクランプする。
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
        // アクティブスクリーンごとに visibleFrame は変わるため、表示のたびに上限を更新する（Issue 0009）。
        panel.contentMaxSize = visibleFrame.size
        panel.setFrame(clamped(frame, to: visibleFrame), display: false)
    }

    /// 矩形を `screenFrame` に収まるようクランプする（Issue 0009）。
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

extension PickerPanelController: NSWindowDelegate {
    /// パネルがフォーカスを失ったら自動的に閉じる（設計書 7.2）。
    /// この経路ではユーザーが自分で別アプリへフォーカスを移しているため、元アプリへの復帰は行わない。
    func windowDidResignKey(_ notification: Notification) {
        // nvim 編集モード中に閉じると編集内容が失われるため、この経路では閉じない（Issue 0006）。
        // 編集の終了は nvim 自身の終了（:wq / :q 等）によってのみ起こる。
        guard !pickerViewController.isEditingInNvim else { return }
        hide(restoringFocus: false)
    }

    /// 利用者がパネルを移動したら位置を保存する（Issue 0009）。
    /// `panel.isVisible` を見るのは、`positionPanel()` 自身の `setFrame` や非表示中の
    /// フレーム変更で誤って保存してしまわないようにするため。
    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible else { return }
        settings.panelFrame = panel.frame
    }

    /// 利用者がパネルをリサイズしたら大きさを保存する（Issue 0009）。
    /// `panel.isVisible` を見る理由は `windowDidMove(_:)` と同様である。
    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible else { return }
        settings.panelFrame = panel.frame
    }
}
