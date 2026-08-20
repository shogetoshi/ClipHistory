import Cocoa
import ClipHistoryCore

/// 検索パネルの表示制御、フォーカス復帰、選択確定時のクリップボード書き戻しを担う
/// （設計書 3.1 `PickerPanelController` / 7.3 フォーカス制御）。
final class PickerPanelController: NSObject {
    private let panel: PickerPanel
    private let pickerViewController: PickerViewController
    private let historyStore: HistoryStore

    private static let panelSize = NSSize(width: 720, height: 420)

    /// ホットキー押下時点の frontmost アプリ。パネルを閉じる際にここへフォーカスを戻す
    /// （設計書 7.3 手順1・3）。
    private var previousFrontmostApp: NSRunningApplication?

    init(historyStore: HistoryStore, resultsProvider: ResultsProvider, settings: Settings) {
        self.historyStore = historyStore
        let contentRect = NSRect(origin: .zero, size: Self.panelSize)
        panel = PickerPanel(contentRect: contentRect)
        pickerViewController = PickerViewController(resultsProvider: resultsProvider, settings: settings, historyStore: historyStore)
        super.init()

        panel.contentViewController = pickerViewController
        panel.delegate = self

        pickerViewController.onCommit = { [weak self] item in
            self?.commit(item)
        }
        pickerViewController.onCancel = { [weak self] in
            self?.hide(restoringFocus: true)
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

    private func commit(_ item: HistoryItem) {
        do {
            try writeToPasteboard(item)
        } catch {
            NSLog("ClipHistory: failed to write pasteboard: \(error)")
        }
        panel.orderOut(nil)
        restoreFocus()
    }

    /// 保持していた元アプリを復帰させる（設計書 7.3 手順3）。復帰後、利用者はそのまま ⌘V する。
    private func restoreFocus() {
        previousFrontmostApp?.activate()
        previousFrontmostApp = nil
    }

    /// 選択項目の全表現を `NSPasteboard` へ書き戻す。v1 はテキストのみ扱うが、
    /// representations を回して書く汎用実装にしておく（将来の画像・ファイル対応の継ぎ目）。
    ///
    /// 書き戻しにより `changeCount` が変化するため、`ClipboardMonitor` が通常の変更検知として
    /// 拾い、新規レコードとして履歴の最新に追加される。これは仕様であり、意図的に
    /// `markOwnWrite()` は呼ばない（設計書 3.2 手順4）。
    private func writeToPasteboard(_ item: HistoryItem) throws {
        let representations = try historyStore.fetchRepresentations(itemID: item.id)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        for representation in representations {
            let data = try historyStore.loadData(for: representation)
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(representation.uti))
        }
    }

    /// アクティブなスクリーン（マウスカーソルがあるスクリーン）の中央上寄りに配置する（設計書 7.1）。
    private func positionPanel() {
        guard let screen = activeScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let size = Self.panelSize
        let x = visibleFrame.midX - size.width / 2
        // 「中央上寄り」: 画面上端から visibleFrame 高さの25%の位置にパネル上端がくるようにする
        let y = visibleFrame.maxY - visibleFrame.height * 0.25 - size.height
        panel.setFrame(
            NSRect(x: x, y: max(y, visibleFrame.minY), width: size.width, height: size.height),
            display: false
        )
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
        hide(restoringFocus: false)
    }
}
