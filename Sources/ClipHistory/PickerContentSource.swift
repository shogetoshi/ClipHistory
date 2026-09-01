import Cocoa
import ClipHistoryCore

/// ピッカーで選択中のアイテムについて、「プレビューに出す内容」「nvim編集・複数選択結合の対象本文」
/// 「確定時のクリップボードへの書き戻し」を解決する。
/// 一覧の並び（`ResultsProvider`）と同様、UI をこのプロトコルにのみ依存させることで、
/// クリップボード履歴と Snippet（Issue 0030）で同じピッカーを使い回せるようにする。
protocol PickerContentSource {
    func previewContent(for item: HistoryItem) -> PreviewContent
    /// nvim 編集・複数選択の結合に使う本文。取得できなければ nil
    func editableText(for item: HistoryItem) -> String?
    /// 確定時に `NSPasteboard` へ書き戻す。書き戻す内容が無ければ false を返す
    func writeToPasteboard(_ item: HistoryItem) -> Bool
}

/// クリップボード履歴用の実装。
final class HistoryContentSource: PickerContentSource {
    private let historyStore: HistoryStore
    private let previewContentLoader: PreviewContentLoader

    init(historyStore: HistoryStore, previewMaxCharacters: Int) {
        self.historyStore = historyStore
        self.previewContentLoader = PreviewContentLoader(historyStore: historyStore, maxCharacters: previewMaxCharacters)
    }

    func previewContent(for item: HistoryItem) -> PreviewContent {
        previewContentLoader.content(for: item)
    }

    func editableText(for item: HistoryItem) -> String? {
        do {
            return try historyStore.loadFullText(itemID: item.id)
        } catch {
            NSLog("ClipHistory: HistoryStore.loadFullText(itemID:) failed: \(error)")
            return nil
        }
    }

    /// 選択項目の全表現を `NSPasteboard` へ書き戻す。v1 はテキストのみ扱うが、
    /// representations を回して書く汎用実装にしておく（将来の画像・ファイル対応の継ぎ目）。
    ///
    /// 書き戻しにより `changeCount` が変化するため、`ClipboardMonitor` が通常の変更検知として
    /// 拾い、新規レコードとして履歴の最新に追加される。これは仕様であり、意図的に
    /// 書き戻しは抑制しない（設計書 3.2 手順4）。
    func writeToPasteboard(_ item: HistoryItem) -> Bool {
        do {
            let representations = try historyStore.fetchRepresentations(itemID: item.id)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            for representation in representations {
                let data = try historyStore.loadData(for: representation)
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(representation.uti))
            }
        } catch {
            NSLog("ClipHistory: failed to write pasteboard: \(error)")
        }
        return true
    }
}
