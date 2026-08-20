import Foundation
import Testing
@testable import ClipHistoryCore

/// テストごとに一時ディレクトリへ DB と blobs を作り、HistoryStore を組み立てるヘルパー。
/// 他テストファイルの同名ヘルパーと同内容だが、テストファイル間で private ヘルパーは
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

@Suite("SearchResultsProvider")
struct SearchResultsProviderTests {
    @Test("SearchIndexで絞り込んだ結果をHistoryStoreから取得し、スコア順を保って返す")
    func returnsFilteredResultsInScoreOrder() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let idApple = try store.insert(makeTextItem("apple pie recipe", createdAt: 1_000))
        let idBanana = try store.insert(makeTextItem("banana bread recipe", createdAt: 2_000))
        _ = try store.insert(makeTextItem("completely unrelated", createdAt: 3_000))

        let index = SearchIndex()
        index.load(try store.loadIndexEntries())

        let provider: ResultsProvider = SearchResultsProvider(searchIndex: index, historyStore: store)
        let results = try provider.results(for: "recipe", limit: 10)

        #expect(Set(results.map(\.id)) == Set([idApple, idBanana]))
    }

    @Test("クエリなしなら最新順で全件返る")
    func emptyQueryReturnsRecent() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("first", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("second", createdAt: 2_000))

        let index = SearchIndex()
        index.load(try store.loadIndexEntries())

        let provider = SearchResultsProvider(searchIndex: index, historyStore: store)
        let results = try provider.results(for: "", limit: 10)

        #expect(results.map(\.id) == [id2, id1])
    }
}

@Suite("HistoryStore.fetchItems")
struct HistoryStoreFetchItemsTests {
    @Test("引数のid順を保持して返す")
    func preservesArgumentOrder() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("first", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("second", createdAt: 2_000))
        let id3 = try store.insert(makeTextItem("third", createdAt: 3_000))

        // DBの挿入順・created_at順とは異なる、あえて入り乱れた順序で問い合わせる
        let results = try store.fetchItems(ids: [id3, id1, id2])
        #expect(results.map(\.id) == [id3, id1, id2])
    }

    @Test("存在しないidは結果から取り除かれる")
    func skipsMissingIDs() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("first", createdAt: 1_000))

        let results = try store.fetchItems(ids: [id1, 999_999])
        #expect(results.map(\.id) == [id1])
    }

    @Test("空配列を渡すと空配列が返る")
    func emptyIDsReturnsEmpty() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let results = try store.fetchItems(ids: [])
        #expect(results.isEmpty)
    }
}
