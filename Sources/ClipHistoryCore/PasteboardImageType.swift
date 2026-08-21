import Foundation

/// 履歴に取り込む画像の UTI。優先順位の高い順に並べる（同じコピーが複数表現を持つ場合、
/// 先に見つかったものだけを保存する）。`ClipboardMonitor`（取り込み時）と `HistoryStore`
/// （プレビュー用の読み出し時）の双方がこの定義を参照する。
public enum PasteboardImageType {
    public static let orderedUTIs: [String] = ["public.png", "public.jpeg", "public.tiff"]
}
