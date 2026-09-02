import Cocoa
import ClipHistoryCore

/// Snippet 用の実装（Issue 0030）。
final class SnippetContentSource: PickerContentSource {
    private let store: SnippetStore

    init(store: SnippetStore) {
        self.store = store
    }

    /// プレビューにはアイテム全文（`###` の行を含む）を出す。
    func previewContent(for item: HistoryItem) -> PreviewContent {
        guard let fullText = store.snippet(id: item.id)?.fullText else {
            return .empty
        }
        return .text(fullText)
    }

    /// nvim 編集・複数選択の結合対象は「最初の ``` の中身」。空文字の場合も貼る内容が
    /// 無いのと同じであるため nil として扱う。
    func editableText(for item: HistoryItem) -> String? {
        guard let codeBlock = store.snippet(id: item.id)?.codeBlock, !codeBlock.isEmpty else {
            return nil
        }
        return codeBlock
    }

    /// クリップボードに入るのはアイテム内で最初の ``` の開閉の中身だけ（Issue 0030）。
    /// ``` のブロックを持たないアイテムの場合はクリップボードを一切触らずに false を返す。
    func writeToPasteboard(_ item: HistoryItem) -> Bool {
        guard let text = editableText(for: item) else {
            return false
        }
        guard let data = text.data(using: .utf8) else {
            NSLog("ClipHistory: failed to write pasteboard: could not encode snippet text as UTF-8")
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(PasteboardTextType.utf8PlainText))
        return true
    }

    /// アイテムを切り出した .md ファイル本体のパスと、その `###` 見出し行の行番号（Issue 0032）。
    func sourceLocation(for item: HistoryItem) -> SnippetSourceLocation? {
        store.sourceLocation(id: item.id)
    }
}
