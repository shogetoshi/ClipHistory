import Foundation

/// 1ターム分の解釈結果。
public struct QueryTerm: Equatable {
    public enum MatchKind: Equatable {
        case fuzzy      // サブシーケンス一致（既定）
        case prefix     // 先頭一致（^foo）
        case suffix     // 末尾一致（foo$）
        case exact      // 完全一致（^foo$）
    }

    public let kind: MatchKind
    public let isNegated: Bool
    public let body: [Unicode.Scalar]   // 記号を取り除いた本体

    public init(kind: MatchKind, isNegated: Bool, body: [Unicode.Scalar]) {
        self.kind = kind
        self.isNegated = isNegated
        self.body = body
    }

    /// `haystack` の `startingAt` から `body.count` 分を、配列を新規に作らず要素ごとに
    /// 比較する（60,000件を毎回走査するため `Array(prefix/suffix(...))` のヒープ確保を避ける）。
    /// `SearchIndex` の性能最適化されたループから直接呼べるよう internal にしている。
    static func scalarsEqual(_ haystack: [Unicode.Scalar], startingAt start: Int, to body: [Unicode.Scalar]) -> Bool {
        guard start >= 0, start + body.count <= haystack.count else { return false }
        for i in 0..<body.count where haystack[start + i] != body[i] {
            return false
        }
        return true
    }
}

/// fzf のクエリ構文のうち `^`（先頭一致）・`$`（末尾一致）・`!`（否定）だけを解釈するパーサ。
public enum QueryParser {

    /// 正規化済みクエリ（`Normalizer.normalize` 済み）を解釈し、タームの配列を返す。
    public static func parse(_ normalizedQuery: String) -> [QueryTerm] {
        var terms: [QueryTerm] = []
        for rawTerm in normalizedQuery.split(separator: " ") {
            var scalars = Array(rawTerm.unicodeScalars)

            var isNegated = false
            if scalars.first == "!" {
                isNegated = true
                scalars.removeFirst()
            }

            var isPrefix = false
            if scalars.first == "^" {
                isPrefix = true
                scalars.removeFirst()
            }

            var isSuffix = false
            if scalars.last == "$" {
                isSuffix = true
                scalars.removeLast()
            }

            guard !scalars.isEmpty else { continue }

            let kind: QueryTerm.MatchKind
            switch (isPrefix, isSuffix) {
            case (true, true): kind = .exact
            case (true, false): kind = .prefix
            case (false, true): kind = .suffix
            case (false, false): kind = .fuzzy
            }

            terms.append(QueryTerm(kind: kind, isNegated: isNegated, body: scalars))
        }
        return terms
    }

    /// 逐次絞り込み（クエリの前方拡張時に前回ヒット集合だけを再走査する最適化）は
    /// 「クエリを伸ばすとヒット集合が必ず縮む」ことを前提にしている。否定タームでは
    /// `!a` → `!ab` のようにヒット集合が広がるため前提が崩れる。また末尾一致も
    /// `ab$` → `ab$x` のように意味が変わって部分集合にならない。そのため、
    /// これらを含むクエリでは呼び出し側がキャッシュを迂回して全件走査する。
    public static func containsSpecialSyntax(_ terms: [QueryTerm]) -> Bool {
        terms.contains { $0.kind != .fuzzy || $0.isNegated }
    }
}
