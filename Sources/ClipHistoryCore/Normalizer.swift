import Foundation

/// 検索キー（`search_key`）の正規化。保存時とクエリ入力時で必ず同一の手順を適用する（設計書 6.2）。
///
/// 手順:
/// 1. NFKC 正規化（全角英数字・半角カナを標準形に統一）
/// 2. Unicode 準拠の小文字化
/// 3. 連続空白を1個に圧縮
/// 4. 先頭120文字に切り詰め
///
/// ひらがな/カタカナの相互変換は行わない（NFKC はそもそもこの変換を行わないため、
/// 追加の処理をしないことでこの非スコープを自然に満たす）。
public enum Normalizer {
    public static let maxLength = 120

    public static func normalize(_ input: String) -> String {
        let nfkc = input.precomposedStringWithCompatibilityMapping
        let lowered = nfkc.lowercased()
        let collapsed = collapseWhitespace(lowered)
        return String(collapsed.prefix(maxLength))
    }

    private static func collapseWhitespace(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
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
        return result
    }
}
