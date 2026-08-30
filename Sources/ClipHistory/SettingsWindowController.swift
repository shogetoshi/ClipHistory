import Cocoa
import SwiftUI
import ClipHistoryCore

/// 設定画面のウィンドウ制御。SwiftUI で組んだ `SettingsView` を `NSHostingController` に
/// 載せた通常の `NSWindow`（パネルではない）で表示する。
///
/// このコントローラ自体は「開く」「前面化する」以上のことをしない。複数開かないようにする
/// 制御（既に開いていれば前面化するだけ）は呼び出し元（`AppDelegate`）が
/// インスタンスを使い回すことで実現する。
final class SettingsWindowController: NSWindowController {
    // `SwiftUI.Settings`（Scene）と名前が衝突するため、明示的に `ClipHistoryCore.Settings` を指す。
    init(settings: ClipHistoryCore.Settings) {
        let viewModel = SettingsViewModel(settings: settings)
        let hosting = NSHostingController(rootView: SettingsView(viewModel: viewModel))

        let window = NSWindow(contentViewController: hosting)
        window.title = "設定の確認"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // 閉じるボタンで実体を破棄せず隠すだけにする（次回「設定」選択時に同じウィンドウを
        // 前面化する運用のため）。
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
