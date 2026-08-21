import Cocoa
import ClipHistoryCore

/// プレビューペインに表示する内容。テキストと画像は排他で、選択が無い場合は `.empty`。
enum PreviewContent {
    case text(String)
    case image(NSImage)
    case empty
}

/// 選択中アイテムのプレビュー内容を `HistoryStore` から解決する。
/// 表示側（`PreviewPaneView`）とデータ取得を分けるための層で、ビューには一切触れない。
///
/// 一覧側の `previewText` は表示用に改行・連続空白を畳んで1行・200文字程度に短縮した値だが、
/// プレビューでは改行を含む実データをそのまま見せたいため、ここでは一覧用の値を使わず
/// `historyStore.loadPreviewText` で `public.utf8-plain-text` の実データを読み直す。
struct PreviewContentLoader {
    private let historyStore: HistoryStore
    /// プレビューとして読み込む最大文字数。一覧より大きく取り、長文もある程度確認できるようにする。
    private let maxCharacters: Int

    init(historyStore: HistoryStore, maxCharacters: Int) {
        self.historyStore = historyStore
        self.maxCharacters = maxCharacters
    }

    func content(for item: HistoryItem) -> PreviewContent {
        // 画像アイテムの場合は画像を優先して表示する。取得・生成に失敗した場合は
        // テキストプレビューにフォールバックする（Issue 0004）。
        if item.kind == .image {
            do {
                if let loaded = try historyStore.loadPreviewImageData(itemID: item.id), let image = NSImage(data: loaded.data) {
                    return .image(image)
                }
            } catch {
                NSLog("ClipHistory: HistoryStore.loadPreviewImageData(itemID:) failed: \(error)")
            }
        }

        let text: String
        do {
            if let loaded = try historyStore.loadPreviewText(itemID: item.id, maxCharacters: maxCharacters) {
                text = loaded
            } else {
                // テキスト表現が無い（将来の画像などを想定）場合は、一覧と同じ情報を出す
                text = item.previewText ?? ""
            }
        } catch {
            text = ""
            NSLog("ClipHistory: HistoryStore.loadPreviewText(itemID:) failed: \(error)")
        }
        return .text(text)
    }
}
