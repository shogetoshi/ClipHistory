import Cocoa

/// 結果一覧の1行を描画するセル。プレビュー本文（最大2行）と、コピー元アプリ名・相対時刻を
/// まとめたサブタイトルの2段で構成する（設計書 7.1「行の表示」）。
///
/// `NSTableView` のセル再利用（`makeView(withIdentifier:owner:)`）で使い回されるため、
/// 内容は毎回 `configure()` で上書きするだけで、ビュー階層自体は初回生成時に一度だけ組み立てる。
final class HistoryItemCellView: NSTableCellView {
    private let previewLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    /// セル右側の余白。オーバーレイ表示される（＝レイアウトに幅を割かない）スクロールバーが
    /// 一時的に前面に出た際、本文の末尾に重なって読めなくなるのを避けるための空き（修正1）。
    private static let trailingInset: CGFloat = 12
    /// プレビューの表示領域の高さを固定値にする（修正3）。
    /// 13pt フォントの2行分がちょうど収まる高さで、これより長い内容は
    /// `maximumNumberOfLines` / `truncatesLastVisibleLine` により省略記号で切られる。
    private static let previewHeight: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2
        // 高さを固定した範囲に収まらない分を、行数途中でも省略記号付きで切る
        (previewLabel.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = true
        previewLabel.font = TerminalTheme.listFont
        previewLabel.textColor = TerminalTheme.foreground
        addSubview(previewLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.font = TerminalTheme.listSubtitleFont
        subtitleLabel.textColor = TerminalTheme.secondaryForeground
        addSubview(subtitleLabel)

        // サブタイトルを行の下端に固定する（修正3）。
        //
        // 以前は「上端→プレビュー→サブタイトル」の順に上から積む制約になっており、
        // プレビューが2行に伸びると行高（旧56pt）からサブタイトルがはみ出して消えてしまっていた
        // （プレビューの行数がサブタイトルの位置を決めてしまう構造が根本原因）。
        // 逆に「サブタイトルを bottomAnchor に固定し、プレビューは上端〜固定高さの範囲に収める」
        // 構造に組み替えることで、プレビューの内容量に関わらずサブタイトルの位置は常に一定になり、
        // 同じ崩れが再発しなくなる。プレビュー側は高さを明示的に固定し、収まらない分は
        // truncatesLastVisibleLine で省略記号にする（サブタイトル側へのはみ出しを起こさない）。
        NSLayoutConstraint.activate([
            previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            previewLabel.heightAnchor.constraint(equalToConstant: Self.previewHeight),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    func configure(preview: String, sourceAppName: String, relativeTime: String) {
        previewLabel.stringValue = preview.isEmpty ? "(空)" : preview
        subtitleLabel.stringValue = "\(sourceAppName) ・ \(relativeTime)"
    }
}
