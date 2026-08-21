import Cocoa

/// メニューバー常駐アイコンとそのメニューを担う（設計書 7.4）。
/// 各項目が選ばれたことをコールバックで通知するだけで、実際の処理は持たない。
/// 設計書 7.4 の4項目（履歴パネルを開く / 設定 / 履歴を全消去 / 終了）に加え、
/// ホットキー登録失敗時のみ表示する状態通知・再登録項目（不具合修正）を持つ。
final class StatusItemController: NSObject {
    var onOpenPicker: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onClearAllHistory: (() -> Void)?
    var onReregisterHotKey: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    // ホットキー登録失敗時に表示する状態通知用メニュー項目（不具合修正）。
    // 通常時は非表示にしておき、失敗時のみ `isHidden = false` にして出す。
    private let hotKeyErrorMenuItem: NSMenuItem
    private let reregisterHotKeyMenuItem: NSMenuItem

    private static let normalStatusTitle = "📋"
    private static let hotKeyFailedStatusTitle = "⚠️"

    override init() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = Self.normalStatusTitle
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "履歴パネルを開く", action: #selector(openPicker), keyEquivalent: ""))

        // 選択不可（isEnabled = false）のエラー内容表示項目。通常時は isHidden = true。
        let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)
        hotKeyErrorMenuItem = errorItem

        let reregisterItem = NSMenuItem(
            title: "ホットキーを再登録",
            action: #selector(reregisterHotKey),
            keyEquivalent: ""
        )
        reregisterItem.isHidden = true
        menu.addItem(reregisterItem)
        reregisterHotKeyMenuItem = reregisterItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "設定", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "履歴を全消去", action: #selector(clearAllHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))

        statusItem = item

        super.init()

        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
    }

    @objc private func openPicker() {
        onOpenPicker?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func clearAllHistory() {
        onClearAllHistory?()
    }

    @objc private func reregisterHotKey() {
        onReregisterHotKey?()
    }

    @objc private func quit() {
        onQuit?()
    }

    /// ホットキー登録失敗を示す状態（⚠️アイコン + エラーメニュー項目 + 再登録項目）に切り替える。
    func showHotKeyFailure(_ error: Error) {
        statusItem.button?.title = Self.hotKeyFailedStatusTitle
        hotKeyErrorMenuItem.title = "ホットキー登録失敗: \(error)"
        hotKeyErrorMenuItem.isHidden = false
        reregisterHotKeyMenuItem.isHidden = false
    }

    /// 登録成功時（初回成功時・再登録成功時とも）に通常状態へ戻す。
    func showHotKeySuccess() {
        statusItem.button?.title = Self.normalStatusTitle
        hotKeyErrorMenuItem.isHidden = true
        reregisterHotKeyMenuItem.isHidden = true
    }
}
