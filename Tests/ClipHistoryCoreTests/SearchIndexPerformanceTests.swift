import Foundation
import Testing
@testable import ClipHistoryCore

@Suite("SearchIndex Performance")
struct SearchIndexPerformanceTests {
    /// 日本語・英数字を混在させた合成データで6万件のインデックスを構築し、
    /// `search` 1回あたりの実行時間を計測する（設計書6.5「想定処理時間: 数msオーダー」/
    /// 指揮官指示の性能ゲート: 16msを大きく超えないこと）。
    ///
    /// CI環境差やマシン負荷変動を考慮し、ここでの `#expect` はゲートそのものより
    /// 大きく緩めた閾値にとどめる。実測値は `print` で出力し、報告時にコンソール出力から
    /// ミリ秒値を確認する。
    @Test("6万件合成データでの検索性能")
    func sixtyThousandEntriesPerformance() {
        let entries = Self.makeSyntheticEntries(count: 60_000)

        // ヒット数が多いケース: 1文字クエリ。毎回フルスキャンのコストを測るため、
        // 逐次絞り込みキャッシュの影響を受けないよう新しい SearchIndex を都度使う。
        let manyHitsIndex = SearchIndex()
        manyHitsIndex.load(entries)
        let manyHitsMs = Self.measureMs { _ = manyHitsIndex.search(query: "e", limit: 200) }
        let manyHitsCount = manyHitsIndex.search(query: "e", limit: 60_000).count

        // ヒット数が少ないケース: 複数タームのAND条件で、存在しない語を含める。
        let fewHitsIndex = SearchIndex()
        fewHitsIndex.load(entries)
        let fewHitsMs = Self.measureMs { _ = fewHitsIndex.search(query: "zzqxvw wvktpq", limit: 200) }
        let fewHitsCount = fewHitsIndex.search(query: "zzqxvw wvktpq", limit: 60_000).count

        // ヒット数が中程度のケース: 実際に含まれる複合語。
        let midHitsIndex = SearchIndex()
        midHitsIndex.load(entries)
        let midHitsMs = Self.measureMs { _ = midHitsIndex.search(query: "history", limit: 200) }
        let midHitsCount = midHitsIndex.search(query: "history", limit: 60_000).count

        // 否定つき1文字クエリ: 特殊構文パス（毎回entries全件を走査）のコストを測る。
        let negatedIndex = SearchIndex()
        negatedIndex.load(entries)
        let negatedMs = Self.measureMs { _ = negatedIndex.search(query: "!e", limit: 200) }
        let negatedCount = negatedIndex.search(query: "!e", limit: 60_000).count

        print("""
        [SearchIndex performance] 60,000件
          多ヒット(1文字 'e'):            \(String(format: "%.2f", manyHitsMs)) ms (hits=\(manyHitsCount))
          少ヒット('zzqxvw wvktpq'):      \(String(format: "%.2f", fewHitsMs)) ms (hits=\(fewHitsCount))
          中ヒット('history'):            \(String(format: "%.2f", midHitsMs)) ms (hits=\(midHitsCount))
          否定(1文字 '!e'):               \(String(format: "%.2f", negatedMs)) ms (hits=\(negatedCount))
        """)

        // 性能ゲート（指揮官指示: 16ms）は「本アプリのリリースビルド」を基準にしたものであり、
        // `swift build -c release`（Makefile参照）に相当する。デバッグビルド（`swift test` の
        // 既定）はSwiftの最適化がほぼ無効化されるため、同じ処理でも1〜2桁遅くなる
        // （実測: リリースビルドで約10ms、デバッグビルドで約1000ms）。そのため閾値は
        // ビルド構成で切り替え、デバッグビルドでは「ハングしていないこと」の確認に留める。
        #if DEBUG
        let gateMs = 5_000.0
        #else
        // 実測（約2〜11ms）に対して十分な余裕を持たせつつ、性能ゲート16msを大きく
        // 超えるような重大な劣化は検知できる値にする。
        let gateMs = 50.0
        #endif
        #expect(manyHitsMs < gateMs)
        #expect(fewHitsMs < gateMs)
        #expect(midHitsMs < gateMs)
        #expect(negatedMs < gateMs)
    }

    private static func measureMs(_ block: () -> Void) -> Double {
        let start = DispatchTime.now()
        block()
        let end = DispatchTime.now()
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static let japaneseFragments = [
        "会議の議事録です", "明日までにご確認ください", "見積書を送付します", "ありがとうございます",
        "本日は晴天なり", "サンプルテキストです", "クリップボード履歴の実装", "検索インデックスの設計",
        "パフォーマンス計測結果", "設計書のレビューコメント", "顧客対応の記録", "定例ミーティングの議題",
    ]

    private static let englishFragments = [
        "the quick brown fox jumps", "hello world example", "swift package manager setup",
        "unit test coverage report", "performance benchmark result", "index entry structure",
        "clipboard history feature", "fuzzy matching algorithm", "error handling code path",
        "sample text data payload",
    ]

    /// 日本語・英数字を混在させた合成 `IndexEntry` を生成する。
    private static func makeSyntheticEntries(count: Int) -> [IndexEntry] {
        let pool = japaneseFragments + englishFragments
        var rng = SystemRandomNumberGenerator()
        var result: [IndexEntry] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let pickCount = Int.random(in: 1...3, using: &rng)
            var text = ""
            for _ in 0..<pickCount {
                text += pool.randomElement(using: &rng)! + " "
            }
            text += "id\(i)"
            let entry = IndexEntry(id: Int64(i + 1), createdAt: Int64(i), searchKey: Normalizer.normalize(text))
            result.append(entry)
        }
        return result
    }
}
