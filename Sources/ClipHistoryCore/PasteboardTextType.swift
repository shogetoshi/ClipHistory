import Foundation

/// 履歴に取り込む唯一のテキスト UTI（設計書 13.4 によりリッチテキストは扱わない）。
/// `ClipboardMonitor`（取り込み時）・`HistoryStore`（読み出し時）・
/// `PickerPanelController`（書き戻し時）が共通で参照する。
public enum PasteboardTextType {
    public static let utf8PlainText = "public.utf8-plain-text"
}
