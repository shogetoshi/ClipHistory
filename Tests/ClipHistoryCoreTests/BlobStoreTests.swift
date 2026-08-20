import Foundation
import Testing
@testable import ClipHistoryCore

@Suite("BlobStore")
struct BlobStoreTests {
    @Test("閾値超データの保存・読み出し・削除ができる")
    func saveLoadDelete() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blobStore = try BlobStore(baseDirectory: tempDir)

        let data = Data(String(repeating: "x", count: 100_000).utf8) // 64KB超のダミーデータ
        let relativePath = try blobStore.save(data)

        // <hash先頭2文字>/<hash> の形式で配置されていること
        let hash = sha256Hex(data)
        #expect(relativePath == "\(hash.prefix(2))/\(hash)")
        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(relativePath).path))

        let loaded = try blobStore.load(relativePath: relativePath)
        #expect(loaded == data)

        try blobStore.delete(relativePath: relativePath)
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(relativePath).path))
    }

    @Test("同一内容を複数回保存してもファイルは共有される")
    func savingSameContentTwiceSharesFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blobStore = try BlobStore(baseDirectory: tempDir)
        let data = Data(String(repeating: "y", count: 100_000).utf8)

        let path1 = try blobStore.save(data)
        let path2 = try blobStore.save(data)
        #expect(path1 == path2)
    }

    @Test("collectGarbage: 参照されているファイルは削除されず、参照が消えたファイルだけが削除される")
    func collectGarbageDeletesOnlyUnreferencedFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blobStore = try BlobStore(baseDirectory: tempDir)
        let referencedData = Data(String(repeating: "r", count: 100_000).utf8)
        let orphanData = Data(String(repeating: "o", count: 100_000).utf8)

        let referencedPath = try blobStore.save(referencedData)
        let orphanPath = try blobStore.save(orphanData)

        let deletedCount = try blobStore.collectGarbage(referencedPaths: [referencedPath])

        #expect(deletedCount == 1)
        // 参照されているファイルは残る
        #expect(try blobStore.load(relativePath: referencedPath) == referencedData)
        // 参照が消えたファイルは削除される
        #expect(throws: (any Error).self) {
            try blobStore.load(relativePath: orphanPath)
        }
    }

    @Test("collectGarbage: 同一ハッシュを共有するファイルは、参照が1件でも残っていれば削除されない")
    func collectGarbageKeepsSharedFileWhileAnyReferenceRemains() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blobStore = try BlobStore(baseDirectory: tempDir)
        let sharedData = Data(String(repeating: "s", count: 100_000).utf8)
        // 2レコード相当が同一内容を保存する（BlobStore.save はハッシュ名で保存するため同じファイルになる）
        let path1 = try blobStore.save(sharedData)
        let path2 = try blobStore.save(sharedData)
        #expect(path1 == path2)

        // 1件のレコードがまだこのパスを参照している状態を模す
        let deletedWhileReferenced = try blobStore.collectGarbage(referencedPaths: [path1])
        #expect(deletedWhileReferenced == 0)
        #expect(try blobStore.load(relativePath: path1) == sharedData)

        // 参照が0件になって初めて削除される
        let deletedAfterNoReference = try blobStore.collectGarbage(referencedPaths: [])
        #expect(deletedAfterNoReference == 1)
        #expect(throws: (any Error).self) {
            try blobStore.load(relativePath: path1)
        }
    }

    @Test("collectGarbage: 空になったサブディレクトリも削除される")
    func collectGarbageRemovesEmptySubdirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blobStore = try BlobStore(baseDirectory: tempDir)
        let data = Data(String(repeating: "e", count: 100_000).utf8)
        let path = try blobStore.save(data)
        let subdirectory = tempDir.appendingPathComponent(String(path.split(separator: "/").first!))

        _ = try blobStore.collectGarbage(referencedPaths: [])

        #expect(!FileManager.default.fileExists(atPath: subdirectory.path))
    }
}
