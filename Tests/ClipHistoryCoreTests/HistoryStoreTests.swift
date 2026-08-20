import Foundation
import Testing
@testable import ClipHistoryCore

/// テストごとに一時ディレクトリへ DB と blobs を作り、HistoryStore を組み立てるヘルパー。
private func makeHistoryStore(inlineBlobThreshold: Int = 64 * 1024) throws -> (store: HistoryStore, tempDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let dbPath = tempDir.appendingPathComponent("history.db").path
    let db = try Database(path: dbPath)
    try Migrations.migrate(db)

    let blobStore = try BlobStore(baseDirectory: tempDir.appendingPathComponent("blobs", isDirectory: true))
    let store = HistoryStore(db: db, blobStore: blobStore, inlineBlobThreshold: inlineBlobThreshold)
    return (store, tempDir)
}

/// purge / deleteAll のテスト用に、db・blobStore への直接アクセスも必要になるため
/// `makeHistoryStore` とは別に db・blobStore も返すヘルパーを用意する。
private func makeHistoryStoreWithHandles(
    inlineBlobThreshold: Int = 64 * 1024
) throws -> (store: HistoryStore, db: Database, blobStore: BlobStore, tempDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let dbPath = tempDir.appendingPathComponent("history.db").path
    let db = try Database(path: dbPath)
    try Migrations.migrate(db)

    let blobStore = try BlobStore(baseDirectory: tempDir.appendingPathComponent("blobs", isDirectory: true))
    let store = HistoryStore(db: db, blobStore: blobStore, inlineBlobThreshold: inlineBlobThreshold)
    return (store, db, blobStore, tempDir)
}

/// テストから直接 `pinned` を書き換えるためのヘルパー（HistoryStoreにはピン留めUI用の
/// 公開APIをまだ持たせていないため、DBを直接更新する）。
private func setPinned(_ db: Database, itemID: Int64, pinned: Bool) throws {
    let stmt = try db.prepare("UPDATE items SET pinned = ? WHERE id = ?;")
    try stmt.bind(1, Int64(pinned ? 1 : 0))
    try stmt.bind(2, itemID)
    _ = try stmt.step()
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

private func makeImageItem(uti: String, data: Data, createdAt: Int64) -> HistoryStore.NewItem {
    let previewText = "[Image] PNG 2×2"
    return HistoryStore.NewItem(
        createdAt: createdAt,
        kind: .image,
        previewText: previewText,
        searchKey: Normalizer.normalize(previewText),
        contentHash: sha256Hex(data),
        sourceAppBundleID: "com.example.app",
        sourceAppName: "ExampleApp",
        representations: [HistoryStore.NewRepresentation(uti: uti, data: data)]
    )
}

@Suite("HistoryStore")
struct HistoryStoreTests {
    @Test("挿入したレコードを最新順で取得でき、表現も取得できる")
    func insertAndFetchRecentAndRepresentations() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("first", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("second", createdAt: 2_000))

        let recent = try store.fetchRecent(limit: 10)
        #expect(recent.count == 2)
        // created_at DESC なので2番目に挿入したものが先頭
        #expect(recent[0].id == id2)
        #expect(recent[0].previewText == "second")
        #expect(recent[1].id == id1)
        #expect(recent[1].previewText == "first")

        let reps = try store.fetchRepresentations(itemID: id1)
        #expect(reps.count == 1)
        #expect(reps[0].uti == "public.utf8-plain-text")
        let data = try store.loadData(for: reps[0])
        #expect(String(data: data, encoding: .utf8) == "first")
    }

    @Test("同一内容を2回挿入すると別レコードになる")
    func duplicateContentCreatesSeparateRecords() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("same content", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("same content", createdAt: 2_000))

        #expect(id1 != id2)
        let recent = try store.fetchRecent(limit: 10)
        #expect(recent.count == 2)
        #expect(recent[0].contentHash == recent[1].contentHash)
    }

    @Test("検索インデックス用の軽量ロードができる")
    func loadIndexEntries() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try store.insert(makeTextItem("hello", createdAt: 1_000))
        _ = try store.insert(makeTextItem("world", createdAt: 2_000))

        let entries = try store.loadIndexEntries()
        #expect(entries.count == 2)
        #expect(entries.map(\.searchKey).contains("hello"))
        #expect(entries.map(\.searchKey).contains("world"))
    }

    @Test("latestContentHash: itemsが空ならnil、挿入後は最新のcontentHashが返る")
    func latestContentHash() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(try store.latestContentHash() == nil)

        _ = try store.insert(makeTextItem("first", createdAt: 1_000))
        _ = try store.insert(makeTextItem("second", createdAt: 2_000))

        #expect(try store.latestContentHash() == sha256Hex(Data("second".utf8)))
    }

    @Test("閾値超のデータは外部ファイルとして保存される")
    func largeDataIsStoredExternally() throws {
        let (store, tempDir) = try makeHistoryStore(inlineBlobThreshold: 16)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bigText = String(repeating: "a", count: 100)
        let id = try store.insert(makeTextItem(bigText, createdAt: 1_000))

        let reps = try store.fetchRepresentations(itemID: id)
        #expect(reps.count == 1)
        #expect(reps[0].inlineBlob == nil)
        #expect(reps[0].filePath != nil)

        let data = try store.loadData(for: reps[0])
        #expect(String(data: data, encoding: .utf8) == bigText)
    }

    @Test("purge: 上限を超えた分だけが古い順に削除され、新しい方が残ること")
    func purgeDeletesOnlyOverflowingOldRecords() throws {
        let (store, _, _, tempDir) = try makeHistoryStoreWithHandles()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id1 = try store.insert(makeTextItem("one", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("two", createdAt: 2_000))
        let id3 = try store.insert(makeTextItem("three", createdAt: 3_000))
        let id4 = try store.insert(makeTextItem("four", createdAt: 4_000))
        let id5 = try store.insert(makeTextItem("five", createdAt: 5_000))

        let deleted = try store.purge(maxItemCount: 3)

        // 削除された id が戻り値として正しく返ること（古い2件）
        #expect(Set(deleted) == Set([id1, id2]))

        // 新しい方（3件）が残ること
        let remaining = try store.fetchRecent(limit: 10)
        #expect(Set(remaining.map(\.id)) == Set([id3, id4, id5]))
    }

    @Test("purge: pinned=1のレコードは削除されず、件数カウントにも含まれないこと")
    func purgeExcludesPinnedRecordsFromDeletionAndCount() throws {
        let (store, db, _, tempDir) = try makeHistoryStoreWithHandles()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pinnedID = try store.insert(makeTextItem("pinned-oldest", createdAt: 1_000))
        try setPinned(db, itemID: pinnedID, pinned: true)

        let id2 = try store.insert(makeTextItem("two", createdAt: 2_000))
        let id3 = try store.insert(makeTextItem("three", createdAt: 3_000))
        let id4 = try store.insert(makeTextItem("four", createdAt: 4_000))

        // pinned=0 は [id2, id3, id4] の3件。maxItemCount=2 なので、最も古い id2 のみ削除対象。
        // pinned=1 の pinnedID は件数カウントにも含めないため、上限判定に影響しない。
        let deleted = try store.purge(maxItemCount: 2)

        #expect(deleted == [id2])

        let remaining = try store.fetchRecent(limit: 10)
        #expect(Set(remaining.map(\.id)) == Set([pinnedID, id3, id4]))
        #expect(remaining.first { $0.id == pinnedID }?.pinned == true)
    }

    @Test("deleteAll: items / representations / BLOBファイルがすべて消えること")
    func deleteAllRemovesEverything() throws {
        let (store, _, blobStore, tempDir) = try makeHistoryStoreWithHandles(inlineBlobThreshold: 16)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try store.insert(makeTextItem("small", createdAt: 1_000))
        let bigID = try store.insert(makeTextItem(String(repeating: "a", count: 100), createdAt: 2_000))

        let reps = try store.fetchRepresentations(itemID: bigID)
        let filePath = try #require(reps.first?.filePath)
        #expect(try blobStore.load(relativePath: filePath).isEmpty == false)

        try store.deleteAll()

        #expect(try store.fetchRecent(limit: 10).isEmpty)
        #expect(try store.referencedBlobPaths().isEmpty)
        #expect(throws: (any Error).self) {
            try blobStore.load(relativePath: filePath)
        }
    }

    @Test("referencedBlobPaths: file_pathが非NULLの表現のみを集合として返す")
    func referencedBlobPathsReturnsOnlyExternalFiles() throws {
        let (store, _, _, tempDir) = try makeHistoryStoreWithHandles(inlineBlobThreshold: 16)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // inline（16バイト以下）と外部ファイル（16バイト超）を混在させる
        _ = try store.insert(makeTextItem("small", createdAt: 1_000))
        let bigID = try store.insert(makeTextItem(String(repeating: "b", count: 100), createdAt: 2_000))

        let reps = try store.fetchRepresentations(itemID: bigID)
        let filePath = try #require(reps.first?.filePath)

        let paths = try store.referencedBlobPaths()
        #expect(paths == Set([filePath]))
    }

    @Test("BLOB GC安全性: 同一BLOBを共有する2レコードの片方だけを削除してもファイルは残ること")
    func sharedBlobSurvivesPartialDeletion() throws {
        let (store, _, blobStore, tempDir) = try makeHistoryStoreWithHandles(inlineBlobThreshold: 16)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 同一内容（同一ハッシュ）を2回コピーする。BlobStore.save はハッシュ名で保存するため、
        // 2つの item の representations は同じ file_path を共有する。
        let sharedText = String(repeating: "shared", count: 20)
        let id1 = try store.insert(makeTextItem(sharedText, createdAt: 1_000))
        let id2 = try store.insert(makeTextItem(sharedText, createdAt: 2_000))

        let path1 = try #require(try store.fetchRepresentations(itemID: id1).first?.filePath)
        let path2 = try #require(try store.fetchRepresentations(itemID: id2).first?.filePath)
        #expect(path1 == path2, "同一内容は同一ファイルを共有する前提")

        // id1 だけを削除する（もう片方の id2 はまだ file_path を参照している）
        _ = try store.purge(maxItemCount: 1)
        #expect(try store.fetchRecent(limit: 10).map(\.id) == [id2])

        // 参照が1件でも残っていればGCで消してはいけない
        let referenced = try store.referencedBlobPaths()
        #expect(referenced.contains(path1))
        let deletedCount = try blobStore.collectGarbage(referencedPaths: referenced)
        #expect(deletedCount == 0)
        #expect(try blobStore.load(relativePath: path1) == Data(sharedText.utf8))

        // 残った id2 もDBから削除すれば（purge自体はBLOBファイルには触れない）、
        // ようやく参照が0件になる。
        let deletedIDs2 = try store.purge(maxItemCount: 0)
        #expect(deletedIDs2 == [id2])
        #expect(try store.fetchRecent(limit: 10).isEmpty)

        let referencedAfter = try store.referencedBlobPaths()
        #expect(referencedAfter.isEmpty)
        let deletedAfterAll = try blobStore.collectGarbage(referencedPaths: referencedAfter)
        #expect(deletedAfterAll == 1)
        #expect(throws: (any Error).self) {
            try blobStore.load(relativePath: path1)
        }
    }

    @Test("loadPreviewText: 改行を含むテキストを改行込みで取得できる")
    func loadPreviewTextKeepsNewlines() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let text = "line1\nline2\nline3"
        let id = try store.insert(makeTextItem(text, createdAt: 1_000))

        let preview = try store.loadPreviewText(itemID: id, maxCharacters: 200)
        #expect(preview == text)
    }

    @Test("loadPreviewText: maxCharactersを超えるテキストは切り詰められる")
    func loadPreviewTextTruncatesToMaxCharacters() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let text = String(repeating: "a", count: 300)
        let id = try store.insert(makeTextItem(text, createdAt: 1_000))

        let preview = try store.loadPreviewText(itemID: id, maxCharacters: 100)
        #expect(preview == String(repeating: "a", count: 100))
    }

    @Test("loadPreviewText: 存在しないitemIDではnilが返る")
    func loadPreviewTextReturnsNilForMissingItem() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let preview = try store.loadPreviewText(itemID: 9_999, maxCharacters: 200)
        #expect(preview == nil)
    }

    @Test("loadPreviewImageData: 画像アイテムからutiとデータを取得できる")
    func loadPreviewImageDataReturnsImageRepresentation() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let id = try store.insert(makeImageItem(uti: "public.png", data: data, createdAt: 1_000))

        let result = try store.loadPreviewImageData(itemID: id)
        #expect(result?.uti == "public.png")
        #expect(result?.data == data)
    }

    @Test("loadPreviewImageData: テキストのみのアイテムではnilが返る")
    func loadPreviewImageDataReturnsNilForTextOnlyItem() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let id = try store.insert(makeTextItem("hello", createdAt: 1_000))

        let result = try store.loadPreviewImageData(itemID: id)
        #expect(result == nil)
    }

    @Test("loadPreviewImageData: 複数の画像表現がある場合はorderedUTIsの優先順で返る")
    func loadPreviewImageDataPrefersOrderedUTIs() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tiffData = Data([0x4D, 0x4D, 0x00, 0x2A])
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let previewText = "[Image] PNG 2×2"
        let item = HistoryStore.NewItem(
            createdAt: 1_000,
            kind: .image,
            previewText: previewText,
            searchKey: Normalizer.normalize(previewText),
            contentHash: sha256Hex(pngData),
            sourceAppBundleID: "com.example.app",
            sourceAppName: "ExampleApp",
            representations: [
                HistoryStore.NewRepresentation(uti: "public.tiff", data: tiffData),
                HistoryStore.NewRepresentation(uti: "public.png", data: pngData)
            ]
        )
        let id = try store.insert(item)

        let result = try store.loadPreviewImageData(itemID: id)
        #expect(result?.uti == "public.png")
        #expect(result?.data == pngData)
    }
}
