import Cocoa
import ClipHistoryCore

/// グローバルホットキー「⌘⌃V」で連続貼り付けを行う機能の中核（Issue 0022）。
///
/// 既存の「前後移動」機能（`ClipboardCycler`）はクリップボードの内容を1個前へ差し替える
/// だけで、貼り付けは利用者が自分で ⌘V する必要がある。本コントローラはこれに
/// `PasteSimulator` による貼り付けの実行を足し、押すたびに「貼り付け→クリップボードを
/// 1個前へ」を繰り返せるようにする。ポインタの揮発・HUD通知・自分の書き戻しを履歴に
/// 記録しない、といった挙動は `ClipboardCycler` にそのまま任せる。
final class ContinuousPasteController {
    /// 貼り付け実行後、`cycler.moveToPrevious()` を呼ぶまでの待ち時間。
    ///
    /// 貼り付け先のアプリが ⌘V を処理し終える前にクリップボードを書き換えてしまうと、
    /// 実際に貼り付けられる内容が意図した項目ではなく次の項目になってしまうため、
    /// 少し待ってからクリップボードを進める。
    private static let pasteSettleInterval: TimeInterval = 0.15

    private let cycler: ClipboardCycler
    private let pasteSimulator: PasteSimulator

    /// `pasteSettleInterval` の待機中かどうか。待機中に再度 `pasteAndCycle()` が呼ばれても
    /// クリップボードはまだ進んでいないため、同じ内容をもう一度貼り付けてしまう。
    /// これを防ぐため待機中の呼び出しは無視する。
    private var isCyclePending = false

    init(cycler: ClipboardCycler, pasteSimulator: PasteSimulator = PasteSimulator()) {
        self.cycler = cycler
        self.pasteSimulator = pasteSimulator
    }

    /// ホットキー（⌘⌃V）から呼ばれる。「貼り付け→クリップボードを1個前へ」を実行する。
    func pasteAndCycle() {
        guard !isCyclePending else { return }

        guard pasteSimulator.paste() else {
            // 貼り付けできなかった（権限が無い等）場合は、貼り付けていないのに内容だけが
            // 変わってしまうのを避けるため、クリップボードは進めない。
            return
        }

        isCyclePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteSettleInterval) { [weak self] in
            guard let self else { return }
            self.cycler.moveToPrevious()
            self.isCyclePending = false
        }
    }
}
