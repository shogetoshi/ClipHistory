import Cocoa

/// 選択中アイテムの内容を表示するプレビューペイン（Issue 0002 / 0004）。
/// テキストと画像を同じ領域に重ねて配置し、排他的に切り替える。
/// nvim 編集モード（Issue 0006）では、このビュー自身をコンテナとして
/// `NvimEditModeController` がターミナルビューを載せる。
/// 配色はターミナル風に揃えている（Issue 0012）。
final class PreviewPaneView: NSBox {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()

    init() {
        super.init(frame: .zero)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // 文字色・選択色・キャレット色をターミナル風に揃える（Issue 0012）。
        textView.textColor = TerminalTheme.foreground
        textView.insertionPointColor = TerminalTheme.accent
        textView.selectedTextAttributes = [
            .backgroundColor: TerminalTheme.selectionBackground,
            .foregroundColor: TerminalTheme.foreground
        ]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        // 等幅フォントにする。コピーしたコードや設定ファイルなどを崩さず、
        // インデントや桁位置が意図通りに見えるようにするため。
        textView.font = TerminalTheme.previewFont
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        // プレビューの下地をターミナル風の暗い色にする（Issue 0012）。
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TerminalTheme.contentBackground
        scrollView.autohidesScrollers = true

        boxType = .custom
        fillColor = TerminalTheme.contentBackground
        borderColor = TerminalTheme.border
        borderWidth = TerminalTheme.borderWidth
        cornerRadius = 6
        titlePosition = .noTitle
        addSubview(scrollView)

        // 画像プレビュー（Issue 0004）。テキスト側の scrollView と同じ領域に重ねて配置し、
        // 表示時はテキスト側を隠すことで排他的に切り替える。
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isHidden = true
        addSubview(imageView)

        // ウィンドウが内容に引きずられて拡大しないよう圧縮抵抗と content hugging を
        // 下げる（Issue 0009）。詳細は `PickerViewController.loadView()` のコメントを参照。
        for view in [scrollView, textView, imageView] as [NSView] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// プレビュー内容を反映する。
    func show(_ content: PreviewContent) {
        switch content {
        case .image(let image):
            imageView.image = image
            imageView.isHidden = false
            scrollView.isHidden = true
        case .text(let text):
            textView.string = text
            textView.scrollToBeginningOfDocument(nil)
            imageView.image = nil
            imageView.isHidden = true
            scrollView.isHidden = false
        case .empty:
            textView.string = ""
            imageView.image = nil
            imageView.isHidden = true
            scrollView.isHidden = false
        }
    }

    /// 編集中はテキスト・画像どちらのプレビューも隠し、ターミナルのみを表示する。
    func setContentHidden(_ hidden: Bool) {
        scrollView.isHidden = hidden
        imageView.isHidden = hidden
    }
}
