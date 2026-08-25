import Cocoa

/// 一覧とプレビューの間の12ptの間隔に重ねて配置し、ドラッグで境界の位置を
/// 変更できるようにするためのビュー（Issue 0018）。見た目は描画せず、
/// カーソルの切り替えとドラッグ検知のみを担う。
final class PreviewDividerHandleView: NSView {
    /// ドラッグ中、直前のイベントからの水平方向の移動量（pt、右方向が正）を都度通知する。
    var onDrag: ((CGFloat) -> Void)?
    /// ドラッグ終了時に呼ばれる（値の永続化に使う）。
    var onDragEnded: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
