import Foundation
import Testing
@testable import ClipHistoryCore

/// テストごとに一時ディレクトリへ DB と blobs を作り、HistoryStore を組み立てるヘルパー。
/// HistoryStoreTests.swift のヘルパーと同内容だが、テストファイル間で private ヘルパーは
/// 共有できないためここに複製する。
private func makeHistoryStore() throws -> (store: HistoryStore, tempDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let dbPath = tempDir.appendingPathComponent("history.db").path
    let db = try Database(path: dbPath)
    try Migrations.migrate(db)

    let blobStore = try BlobStore(baseDirectory: tempDir.appendingPathComponent("blobs", isDirectory: true))
    let store = HistoryStore(db: db, blobStore: blobStore, inlineBlobThreshold: 64 * 1024)
    return (store, tempDir)
}

private func makeTextItem(_ text: String, createdAt: Int64) -> HistoryStore.NewItem {
    let data = Data(text.utf8)
    return HistoryStore.NewItem(
        createdAt: createdAt,
        kind: .text,
        previewText: String(text.prefix(200)),
        searchKey: Normalizer.normalize(text),
        contentHash: sha256Hex(data),
        sourceAppBundleID: "com.example.app",
        sourceAppName: "ExampleApp",
        representations: [HistoryStore.NewRepresentation(uti: "public.utf8-plain-text", data: data)]
    )
}

@Suite("RecentResultsProvider")
struct ResultsProviderTests {
    @Test("fetchRecent の結果をそのまま最新順で返す")
    func returnsRecentResults() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("first", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("second", createdAt: 2_000))
        let id3 = try store.insert(makeTextItem("third", createdAt: 3_000))

        let provider: ResultsProvider = RecentResultsProvider(historyStore: store)
        let results = try provider.results(for: "", limit: 10)

        #expect(results.count == 3)
        #expect(results.map(\.id) == [id3, id2, id1])
    }

    @Test("フェーズ2ではクエリを無視して常に最新順を返す")
    func ignoresQuery() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("apple", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("banana", createdAt: 2_000))

        let provider = RecentResultsProvider(historyStore: store)
        let resultsForQuery = try provider.results(for: "zzz-does-not-match-anything", limit: 10)
        let resultsForEmpty = try provider.results(for: "", limit: 10)

        // query の値によらず同じ結果（最新順の全件）を返す
        #expect(resultsForQuery.map(\.id) == [id2, id1])
        #expect(resultsForEmpty.map(\.id) == [id2, id1])
    }

    @Test("limit を超えない件数だけ返す")
    func respectsLimit() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for index in 0..<5 {
            _ = try store.insert(makeTextItem("item-\(index)", createdAt: Int64(index) * 1_000))
        }

        let provider = RecentResultsProvider(historyStore: store)
        let results = try provider.results(for: "", limit: 2)
        #expect(results.count == 2)
    }
}
