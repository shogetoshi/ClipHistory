import Foundation

/// 一覧表示用にプレビュー本文を1行へ畳んで整形する（設計書 7.1「行の表示」）。
///
/// 複数行のコピー内容（例: `[user]\n\tname = shogetoshi`）を `preview_text` のまま
/// ラベルに流すと、改行の数だけ行内で場所を占め、一覧の行の高さが不揃いになる。
/// これを避けるため、**表示直前**にここで改行・タブ・連続空白を半角スペース1個へ畳む。
///
/// 重要: この整形は表示専用であり、DB の `preview_text` 自体は改変しない
/// （呼び出し側で都度この関数を通してから描画する）。
///
/// `Normalizer`（検索キー生成用、設計書 6.2）とは役割が異なるため流用しない。
/// - `Normalizer` は検索一致精度のための正規化（NFKC・小文字化・120文字切り詰めなど）
/// - `DisplayText` は見た目の行揃えのためだけの整形で、大文字小文字や文字の等価性には関与しない
public enum DisplayText {
    /// 改行（LF / CRLF / CR）・タブ・連続する空白文字を半角スペース1個へ畳み、前後の空白をトリムする。
    ///
    /// 全角スペース（U+3000）の扱い: **畳む対象に含める**。
    /// 目的は一覧行の見た目を揃えることであり、全角スペースを残すと半角スペースとの混在で
    /// 行ごとの余白の見え方がまちまちになる。検索用の `Normalizer` と異なり文字の意味的な
    /// 区別は不要なため、`Character.isWhitespace`（Unicode の空白判定。全角スペースを含む）で
    /// まとめて判定する。
    public static func singleLine(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var lastWasSpace = false
        for ch in input {
            if ch.isWhitespace {
                if !lastWasSpace {
                    result.append(" ")
                }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
