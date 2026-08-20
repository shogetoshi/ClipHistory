import Foundation

/// fzf ライクな1タームのサブシーケンス一致とスコアリングを行う（設計書 6.3）。
///
/// 呼び出し側は文字列をあらかじめ `[Unicode.Scalar]` に変換した配列で渡す。`String` の
/// `Character`（書記素クラスタ）単位の走査は判定コストが高いため避け、インデックス走査は
/// 変換済みのスカラ配列上で行う（設計書 6.1 のコメントのとおり）。
///
/// パフォーマンス上の理由から、DPスコアリングに使う一時配列（スクラッチ領域）をインスタンス内に
/// 保持して使い回す。1回の検索（`SearchIndex.search`）で数万件を走査するため、呼び出しのたびに
/// ヒープ確保するとオーバーヘッドが無視できなくなる。そのため `FuzzyMatcher` はクラス
/// （可変な内部状態を持つ）とし、`SearchIndex` がインデックスの生存期間中ずっと同じインスタンスを
/// 使い回す想定にする（このアプリの検索はメインスレッド同期実行に固定しているため、
/// 複数スレッドからの同時アクセスは発生しない）。
public final class FuzzyMatcher {

    // MARK: - スコア係数
    // 以下の値はいずれも「fzfが持つ相対的な優先順位」を再現するための経験的な重みであり、
    // 絶対値そのものに客観的な根拠はない。重要なのは各要素間の大小関係。

    /// 一致文字が直前の一致と連続しているときの加点（延長1文字ごと）。
    /// 「連続一致が最重要」という設計書6.3の要件を反映し、他のどの加点よりも大きくする。
    private let consecutiveBonus = 12

    /// 語頭（文字列先頭・区切り文字直後・キャメルケース境界直後）での一致に対する加点。
    /// 連続一致には劣るが、ギャップを挟んだだけの一致より明確に優先させたい値にする。
    private let boundaryBonus = 9

    /// 文字列先頭に近い位置での一致に与える加点の最大値（j=0で満額、末尾に向けて線形に減衰）。
    /// boundaryBonus より小さくし、「語頭一致」の優先度を「先頭に近いだけの一致」より上に保つ。
    private let positionBonusMax = 5

    /// ギャップ（一致文字間に不一致文字が挟まること）が生じたときの基礎減点。
    /// 1文字だけのギャップでも consecutiveBonus 1回分を確実に相殺できる大きさにし、
    /// 「連続一致 > 分散一致」の順序を必ず成立させる。
    private let gapStartPenalty = -6

    /// ギャップが1文字延びるごとの追加減点。ギャップが長引くほど不利にする。
    private let gapExtensionPenalty = -2

    /// 文字列全体が短いときの加点の最大値（「わずかに加点」なので他の要素より小さくする）。
    private let shortHaystackBonusMax = 3
    /// この文字数以下の場合に shortHaystackBonusMax を基準とした加点を与える閾値。
    private let shortHaystackThreshold = 20

    private static let negativeInfinity = Int.min / 2

    // DPスクラッチ領域。`Normalizer.maxLength`（120文字）まで育てば以降は再確保が発生しない。
    private var prevH: [Int] = []
    private var prevC: [Int] = []
    private var currH: [Int] = []
    private var currC: [Int] = []
    private var bonusAt: [Int] = []

    public init() {}

    /// needle が haystack にサブシーケンス一致するか判定し、一致すればスコアを返す。
    /// 一致しない場合は nil を即座に返す（設計書6.3「早期打ち切り」）。
    public func score(needle: [Unicode.Scalar], haystack: [Unicode.Scalar]) -> Int? {
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }
        let matches = needle.withUnsafeBufferPointer { nd in
            haystack.withUnsafeBufferPointer { hs in
                quickSubsequenceCheck(needle: nd, haystack: hs)
            }
        }
        guard matches else { return nil }
        return dpScore(needle: needle, haystack: haystack)
    }

    /// 本格的なDPスコアリングに入る前に、そもそもサブシーケンスとして成立するかどうかだけを
    /// 軽量に確認する（O(n)、配列確保なし）。成立しない場合はここで打ち切り、コストの高い
    /// DPスコアリングへは進まない。
    /// このチェックは検索対象**全件**に対して毎回走るため、境界チェックのオーバーヘッドを
    /// 避けるためにunsafeポインタ経由にしている（dpScoreと同じ理由）。
    private func quickSubsequenceCheck(
        needle: UnsafeBufferPointer<Unicode.Scalar>,
        haystack: UnsafeBufferPointer<Unicode.Scalar>
    ) -> Bool {
        var needleIndex = 0
        let needleCount = needle.count
        for scalar in haystack {
            if scalar == needle[needleIndex] {
                needleIndex += 1
                if needleIndex == needleCount { return true }
            }
        }
        return false
    }

    /// スクラッチ配列を必要な長さまで育てる。一度育てば（120文字が上限のため）以降は
    /// 再確保が発生しない。
    private func ensureCapacity(_ n: Int) {
        guard prevH.count < n else { return }
        prevH = [Int](repeating: 0, count: n)
        prevC = [Int](repeating: 0, count: n)
        currH = [Int](repeating: 0, count: n)
        currC = [Int](repeating: 0, count: n)
        bonusAt = [Int](repeating: 0, count: n)
    }

    /// 空白・記号ではない「単語文字」かどうか（区切り文字判定の基準に使う）。
    ///
    /// パフォーマンス上の理由から `Unicode.Scalar.properties`（Unicodeの一般カテゴリ表を
    /// 参照する）は使わない。60,000件規模の走査で1文字ごとに呼ばれるため、テーブル参照の
    /// コストが致命的に効いてくる（実測: properties版は6万件で1秒超、単純な値レンジ判定に
    /// 置き換えると数msに収まった）。ASCIIは直接の範囲比較で判定し、ASCII外（日本語の
    /// 漢字・かな等を含む）は「区切り文字として代表的なもの以外は単語文字とみなす」という
    /// 単純化されたヒューリスティックで代用する。
    private func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x80 {
            return (v >= 0x30 && v <= 0x39) // 0-9
                || (v >= 0x41 && v <= 0x5A) // A-Z
                || (v >= 0x61 && v <= 0x7A) // a-z
                || v == 0x5F // '_'
        }
        // ASCII外は、代表的な区切り記号（全角スペース・句読点・括弧類など）だけを
        // 非単語文字とみなし、それ以外（漢字・ひらがな・カタカナ等）は単語文字として扱う。
        switch v {
        case 0x3000, // 全角スペース
             0x3001, 0x3002, // 、。
             0xFF0C, 0xFF0E, // ，．
             0x300C, 0x300D, 0x300E, 0x300F, // 「」『』
             0xFF08, 0xFF09, // （）
             0x30FB: // ・
            return false
        default:
            return true
        }
    }

    /// ASCII の小文字アルファベットかどうか（キャメルケース境界判定の高速パス用）。
    private func isAsciiLower(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x61 && scalar.value <= 0x7A
    }

    /// ASCII の大文字アルファベットかどうか（キャメルケース境界判定の高速パス用）。
    private func isAsciiUpper(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x41 && scalar.value <= 0x5A
    }

    /// 位置 j での一致が「語頭」（文字列先頭・区切り文字直後・キャメルケース境界直後）かどうか。
    private func isBoundary(at j: Int, haystack: UnsafeBufferPointer<Unicode.Scalar>) -> Bool {
        if j == 0 { return true }
        let prev = haystack[j - 1]
        if !isWordScalar(prev) { return true }
        let curr = haystack[j]
        // キャメルケース境界: 直前がASCII小文字、現在がASCII大文字。
        // 注意: このアプリの実運用では search_key は Normalizer により保存前に小文字化済み
        // （設計書6.2）のため、実データではこの分岐はほぼ発火しない。FuzzyMatcher 自体は
        // 汎用のスコアラーとして仕様どおりキャメルケース境界を判定できるようにしておき、
        // 単体テストでは大文字小文字混在の文字列を直接渡してこのロジックを検証する。
        if isAsciiLower(prev) && isAsciiUpper(curr) { return true }
        return false
    }

    /// 文字列全体が短いときの、一致1回あたりに乗せる加点（合計スコアに1回だけ加算する）。
    private func lengthBonus(haystackCount: Int) -> Int {
        guard haystackCount <= shortHaystackThreshold else { return 0 }
        let remaining = shortHaystackThreshold - haystackCount
        return (shortHaystackBonusMax * remaining + shortHaystackThreshold / 2) / shortHaystackThreshold
    }

    /// DPで最適なアラインメントのスコアを求める。
    ///
    /// - `prevH[j]` / `currH[j]`: パターンの先頭 i+1 文字を haystack[0...j] にマッチさせ、
    ///   i番目の文字をちょうど j で一致させたときの最良スコア（1行分のみ保持し、
    ///   1パターン文字ずつ更新していく）。
    /// - `prevC[j]` / `currC[j]`: 同じアラインメントにおける、j で終わる連続一致の長さ。
    /// - `runningGap`: 「i-1番目までを j'' (<= j-2) のどこかで一致させ、j までギャップを
    ///   挟んで届いた場合の最良スコア」を j の走査に合わせて漸化的に維持する値。
    ///   これにより O(n^2 * m) の全探索を避け、O(n * m) で最適アラインメントを求められる
    ///   （fzf 自身が採用しているのと同じ考え方）。
    ///
    /// パフォーマンス上の理由から、内側のホットループは `UnsafeMutableBufferPointer` /
    /// `UnsafeBufferPointer` 経由で走らせる。`swift build -c release`（本アプリの
    /// リリースビルド、`Makefile` 参照）では配列の境界チェックが有効なままであり、
    /// 6万件規模の走査ではこのチェックのオーバーヘッドが支配的になる
    /// （実測: 素朴な `Array` 添字アクセスで6万件フルスキャンが約56ms、
    /// unsafeポインタ経由に置き換えると約7msまで縮んだ）。境界チェックを外す代わりに、
    /// このメソッド内で扱う添字はすべてループ変数 `j`（`0..<n`の範囲であることが
    /// ループ構造から自明）か、直前に `if j >= 1` / `if j >= 2` で範囲を確認した
    /// `j-1` / `j-2` のみであり、範囲外アクセスは発生しない。
    private func dpScore(needle: [Unicode.Scalar], haystack: [Unicode.Scalar]) -> Int? {
        let n = haystack.count
        let m = needle.count
        let negInf = Self.negativeInfinity
        ensureCapacity(n)

        return haystack.withUnsafeBufferPointer { hs in
            needle.withUnsafeBufferPointer { nd in
                prevH.withUnsafeMutableBufferPointer { prevHBuf in
                    prevC.withUnsafeMutableBufferPointer { prevCBuf in
                        currH.withUnsafeMutableBufferPointer { currHBuf in
                            currC.withUnsafeMutableBufferPointer { currCBuf in
                                bonusAt.withUnsafeMutableBufferPointer { bonusBuf in
                                    // 1文字一致したときの、位置・語頭に基づくボーナスを
                                    // 先に計算しておく（needle側の位置には依存しないため、
                                    // 全パターン行で使い回す）
                                    for j in 0..<n {
                                        let boundary = isBoundary(at: j, haystack: hs)
                                        let posBonus = (positionBonusMax * (n - j) + n / 2) / n
                                        bonusBuf[j] = (boundary ? boundaryBonus : 0) + posBonus
                                    }

                                    // ローカル変数としてポインタを持ち、行の切り替えは
                                    // （配列そのものではなく）このポインタ変数のswapで行う
                                    var prevHPtr = prevHBuf
                                    var prevCPtr = prevCBuf
                                    var currHPtr = currHBuf
                                    var currCPtr = currCBuf

                                    for j in 0..<n {
                                        prevHPtr[j] = negInf
                                        prevCPtr[j] = 0
                                    }

                                    for i in 0..<m {
                                        for j in 0..<n {
                                            currHPtr[j] = negInf
                                            currCPtr[j] = 0
                                        }

                                        var runningGap = negInf
                                        let needleChar = nd[i]

                                        for j in 0..<n {
                                            if i > 0 {
                                                // 既存の候補（j'' <= j-3 相当）をギャップ延長分だけ
                                                // 減点し、新たに条件を満たす j''=j-2 を取り込む
                                                if runningGap != negInf {
                                                    runningGap += gapExtensionPenalty
                                                }
                                                if j >= 2, prevHPtr[j - 2] != negInf {
                                                    let candidate = prevHPtr[j - 2] + gapStartPenalty
                                                    runningGap = max(runningGap, candidate)
                                                }
                                            }

                                            guard hs[j] == needleChar else { continue }

                                            let charBonus = bonusBuf[j]

                                            if i == 0 {
                                                currHPtr[j] = charBonus
                                                currCPtr[j] = 1
                                                continue
                                            }

                                            var best = negInf
                                            var bestConsecutive = 0

                                            // 選択肢1: 直前(i-1)の一致がちょうど j-1 にあり、連続して続ける
                                            if j >= 1, prevHPtr[j - 1] != negInf {
                                                let candidate = prevHPtr[j - 1] + charBonus + consecutiveBonus
                                                if candidate > best {
                                                    best = candidate
                                                    bestConsecutive = prevCPtr[j - 1] + 1
                                                }
                                            }

                                            // 選択肢2: ギャップを挟んで一致する
                                            // （runningGapに既にギャップ減点が織り込まれている）
                                            if runningGap != negInf {
                                                let candidate = runningGap + charBonus
                                                if candidate > best {
                                                    best = candidate
                                                    bestConsecutive = 1
                                                }
                                            }

                                            if best != negInf {
                                                currHPtr[j] = best
                                                currCPtr[j] = bestConsecutive
                                            }
                                        }

                                        swap(&prevHPtr, &currHPtr)
                                        swap(&prevCPtr, &currCPtr)
                                    }

                                    var best = negInf
                                    for j in 0..<n where prevHPtr[j] > best {
                                        best = prevHPtr[j]
                                    }
                                    guard best != negInf else { return nil }
                                    return best + lengthBonus(haystackCount: n)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
