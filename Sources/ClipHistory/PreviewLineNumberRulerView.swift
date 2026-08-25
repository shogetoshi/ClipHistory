import Cocoa

/// テキストプレビューの左側ガターに行番号を描画するルーラー（Issue 0016）。
/// 行番号を `NSTextView` の本文に混ぜず `NSRulerView` として描画することで、
/// 本文をドラッグ選択してコピーしても行番号が一切含まれないようにしている。
final class PreviewLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// 直近に描画した行数の桁数。桁数が変わらない限りは `ruleThickness` を更新しない。
    private var lastDigitCount = 0
    /// クリップビューの境界変化通知の購読トークン。
    private var boundsDidChangeObserver: NSObjectProtocol?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        updateWidth()

        // NSRulerView は縦スクロールで自動的に再描画されるとは限らないため、
        // クリップビューの境界変化を監視して明示的に再描画する。
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let boundsDidChangeObserver {
            NotificationCenter.default.removeObserver(boundsDidChangeObserver)
        }
    }

    /// 総行数の桁数からガター幅を計算し、変化があれば `ruleThickness` を更新する。
    func updateWidth() {
        guard let textView else { return }
        let text = textView.string as NSString
        var lineCount = 0
        if text.length > 0 {
            lineCount = 1
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { _, _, _, _ in
                lineCount += 1
            }
            // enumerateSubstrings は各行を1回ずつ列挙するため、最後に加算した分を戻す。
            lineCount -= 1
        }
        let digitCount = max(2, String(max(lineCount, 1)).count)
        guard digitCount != lastDigitCount else { return }
        lastDigitCount = digitCount
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: TerminalTheme.previewFont]).width
        ruleThickness = digitWidth * CGFloat(digitCount) + 12
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return
        }
        // ガターの背景と、本文との境目を示す縦線を描く。テキストが空でも
        // ガター自体は常に表示されるべきなので、この後の早期 return より前に描く。
        // drawHashMarksAndLabels(in:) に渡される rect はルーラーの bounds をはみ出す
        // ことがあり、macOS 14 以降は NSView.clipsToBounds の既定が false なので、
        // rect をそのまま塗ると本文の上まで塗りつぶしてしまう。そのため必ず bounds で
        // 切り取ってから塗る。境界線の位置も、部分再描画でずれないよう bounds を
        // 基準に計算する。
        TerminalTheme.contentBackground.setFill()
        rect.intersection(bounds).fill()
        let borderRect = NSRect(x: bounds.maxX - TerminalTheme.borderWidth, y: bounds.minY, width: TerminalTheme.borderWidth, height: bounds.height)
        TerminalTheme.border.setFill()
        borderRect.fill()

        let textStorage = textView.textStorage
        guard let textStorage, textStorage.length > 0 else { return }

        // 可視範囲のみ描画する。
        guard let visibleRect = scrollView?.contentView.bounds else { return }
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var actualGlyphRange = NSRange(location: 0, length: 0)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: &actualGlyphRange)

        let text = textStorage.string as NSString

        // 可視範囲の先頭が何行目かを、先頭からの改行数を数えて求める（1 始まり）。
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: visibleCharRange.location), options: .byLines) { _, _, _, _ in
            lineNumber += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: TerminalTheme.previewFont,
            .foregroundColor: TerminalTheme.secondaryForeground
        ]

        var glyphIndex = actualGlyphRange.location
        let maxGlyphIndex = NSMaxRange(actualGlyphRange)
        while glyphIndex < maxGlyphIndex {
            var lineFragmentRange = NSRange(location: 0, length: 0)
            let lineFragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineFragmentRange)

            // 論理行の先頭にあたる行フラグメントにだけ番号を描く（折り返しは無効化済みだが念のため）。
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            if lineRange.location == charIndex {
                let originY = lineFragmentRect.minY + textView.textContainerOrigin.y
                let converted = convert(NSPoint(x: 0, y: originY), from: textView)
                let numberString = String(lineNumber) as NSString
                let size = numberString.size(withAttributes: attributes)
                let drawRect = NSRect(
                    x: bounds.width - size.width - 6,
                    y: converted.y + (lineFragmentRect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                numberString.draw(in: drawRect, withAttributes: attributes)
                lineNumber += 1
            }

            glyphIndex = NSMaxRange(lineFragmentRange)
        }
    }
}
