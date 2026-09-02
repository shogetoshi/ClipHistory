import Foundation

/// Markdown 1ファイルから切り出した Snippet アイテム1件。
public struct SnippetItem: Equatable {
    /// `###` 行から記号と前後の空白を除いたタイトル
    public let title: String
    /// `###` 行を含むアイテム全体のテキスト（プレビューに出す）
    public let fullText: String
    /// アイテム内で最初に現れる ``` の開閉の中身。無ければ nil（クリップボードに入れる値）
    public let codeBlock: String?
    /// `###` 見出し行の1始まりの行番号
    public let headingLineNumber: Int
}

/// Snippet 用 Markdown ファイルを、`###` 区切りのアイテム列にパースする。
/// ファイル走査やUIとは無関係に、渡された文字列1件分の変換のみを担当する。
public enum SnippetParser {
    /// 見出し行の判定は Issue の字面どおり「行頭が `###`」であることのみを見る。
    /// そのため `####` 以降の見出しも境界として扱う（`##` 未満は境界にしない）。
    public static func parse(markdown: String) -> [SnippetItem] {
        var items: [SnippetItem] = []

        // 改行コードは `\n` 前提（TOMLParser と同様の方針）。
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // 最初の `###` 行の位置を境界として区切っていく。それより前の内容（ファイル冒頭の
        // `# タイトル` など）は境界に含まれないため自然に捨てられる。
        var boundaries: [Int] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("###") {
            boundaries.append(index)
        }

        for (i, start) in boundaries.enumerated() {
            let end = i + 1 < boundaries.count ? boundaries[i + 1] : lines.count
            let itemLines = lines[start..<end]

            let title = itemLines[start]
                .drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespaces)
            if title.isEmpty {
                continue
            }

            let fullText = itemLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            items.append(
                SnippetItem(
                    title: title,
                    fullText: fullText,
                    codeBlock: extractFirstCodeBlock(itemLines: Array(itemLines)),
                    headingLineNumber: start + 1
                )
            )
        }

        return items
    }

    /// アイテム内で最初に現れる ``` の開閉ペアの中身を取り出す。
    /// 開始フェンス・終了フェンスの行そのものは含めない。ペアが揃わない場合は nil。
    private static func extractFirstCodeBlock(itemLines: [String]) -> String? {
        guard let openIndex = itemLines.firstIndex(where: { $0.hasPrefix("```") }) else {
            return nil
        }
        guard let closeOffset = itemLines[(openIndex + 1)...].firstIndex(where: { $0.hasPrefix("```") }) else {
            return nil
        }

        let bodyLines = itemLines[(openIndex + 1)..<closeOffset]
        return bodyLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
