import AppKit
import Foundation
import Testing
@testable import ClipHistoryCore

/// テストごとに一時ディレクトリへ DB と blobs を作り、HistoryStore を組み立てるヘルパー。
/// `HistoryStoreTests.swift` のヘルパーと同じ流儀。
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

/// テスト中に時刻を書き換えられるようにするための箱。`ClipboardCycler` の `now` に
/// クロージャとして注入する。
private final class MutableClock {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

private func pasteboardText(_ pasteboard: NSPasteboard) -> String? {
    pasteboard.string(forType: .string)
}

@Suite("ClipboardCycler")
struct ClipboardCyclerTests {
    @Test("moveToPreviousを繰り返すと1個前、2個前とクリップボードに書き戻され、末尾を超えると止まる")
    func moveToPreviousCyclesThroughHistoryAndStopsAtEnd() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipHistoryTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        _ = try store.insert(makeTextItem("C", createdAt: 1_000))
        _ = try store.insert(makeTextItem("B", createdAt: 2_000))
        _ = try store.insert(makeTextItem("A", createdAt: 3_000))

        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cycler = ClipboardCycler(historyStore: store, pasteboard: pasteboard, timeout: 10, now: { clock.current })

        var cycledOffsets: [Int] = []
        cycler.onCycled = { _, offset in cycledOffsets.append(offset) }

        cycler.moveToPrevious()
        #expect(pasteboardText(pasteboard) == "B")
        #expect(cycledOffsets == [1])

        cycler.moveToPrevious()
        #expect(pasteboardText(pasteboard) == "C")
        #expect(cycledOffsets == [1, 2])

        // 末尾（最も古い履歴）を超える移動は無視され、クリップボードもコールバックも変化しない
        cycler.moveToPrevious()
        #expect(pasteboardText(pasteboard) == "C")
        #expect(cycledOffsets == [1, 2])
    }

    @Test("moveToNextでより新しい方へ戻り、最新を超えると止まる")
    func moveToNextReturnsTowardNewestAndStopsAtStart() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipHistoryTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        _ = try store.insert(makeTextItem("C", createdAt: 1_000))
        _ = try store.insert(makeTextItem("B", createdAt: 2_000))
        _ = try store.insert(makeTextItem("A", createdAt: 3_000))

        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cycler = ClipboardCycler(historyStore: store, pasteboard: pasteboard, timeout: 10, now: { clock.current })

        var cycledOffsets: [Int] = []
        cycler.onCycled = { _, offset in cycledOffsets.append(offset) }

        cycler.moveToPrevious()
        cycler.moveToPrevious()
        #expect(pasteboardText(pasteboard) == "C")

        cycler.moveToNext()
        #expect(pasteboardText(pasteboard) == "B")
        #expect(cycledOffsets.last == 1)

        cycler.moveToNext()
        #expect(pasteboardText(pasteboard) == "A")
        #expect(cycledOffsets.last == 0)

        // 最新（オフセット0）を超えて新しい方へは進めない
        cycler.moveToNext()
        #expect(pasteboardText(pasteboard) == "A")
        #expect(cycledOffsets == [1, 2, 1, 0])
    }

    @Test("timeoutを超えて放置するとスナップショットが取り直され、オフセットが1から再開する")
    func snapshotIsRefreshedAfterTimeout() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipHistoryTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        _ = try store.insert(makeTextItem("C", createdAt: 1_000))
        _ = try store.insert(makeTextItem("B", createdAt: 2_000))
        _ = try store.insert(makeTextItem("A", createdAt: 3_000))

        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cycler = ClipboardCycler(historyStore: store, pasteboard: pasteboard, timeout: 10, now: { clock.current })

        var cycledOffsets: [Int] = []
        cycler.onCycled = { _, offset in cycledOffsets.append(offset) }

        cycler.moveToPrevious()
        cycler.moveToPrevious()
        #expect(cycledOffsets == [1, 2])
        #expect(pasteboardText(pasteboard) == "C")

        // timeout(10秒)を超えて時間を進める
        clock.advance(by: 11)

        cycler.moveToPrevious()
        // スナップショットが取り直され pointer=0 から始まるため、1個前 = B に戻る
        #expect(pasteboardText(pasteboard) == "B")
        #expect(cycledOffsets == [1, 2, 1])
    }

    @Test("timeout以内であれば継続してオフセットが増えていく")
    func continuesWithinTimeout() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipHistoryTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        _ = try store.insert(makeTextItem("C", createdAt: 1_000))
        _ = try store.insert(makeTextItem("B", createdAt: 2_000))
        _ = try store.insert(makeTextItem("A", createdAt: 3_000))

        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cycler = ClipboardCycler(historyStore: store, pasteboard: pasteboard, timeout: 10, now: { clock.current })

        var cycledOffsets: [Int] = []
        cycler.onCycled = { _, offset in cycledOffsets.append(offset) }

        cycler.moveToPrevious()
        clock.advance(by: 9)
        cycler.moveToPrevious()

        #expect(cycledOffsets == [1, 2])
        #expect(pasteboardText(pasteboard) == "C")
    }

    @Test("invalidate後のmoveToPreviousはオフセット1から再開する")
    func invalidateResetsToOffsetOne() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipHistoryTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        _ = try store.insert(makeTextItem("C", createdAt: 1_000))
        _ = try store.insert(makeTextItem("B", createdAt: 2_000))
        _ = try store.insert(makeTextItem("A", createdAt: 3_000))

        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cycler = ClipboardCycler(historyStore: store, pasteboard: pasteboard, timeout: 10, now: { clock.current })

        var cycledOffsets: [Int] = []
        cycler.onCycled = { _, offset in cycledOffsets.append(offset) }

        cycler.moveToPrevious()
        cycler.moveToPrevious()
        #expect(cycledOffsets == [1, 2])

        cycler.invalidate()

        cycler.moveToPrevious()
        #expect(pasteboardText(pasteboard) == "B")
        #expect(cycledOffsets == [1, 2, 1])
    }

    @Test("onDidWritePasteboardは書き戻し1回につき1回呼ばれる")
    func onDidWritePasteboardIsCalledOncePerWrite() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipHistoryTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        _ = try store.insert(makeTextItem("C", createdAt: 1_000))
        _ = try store.insert(makeTextItem("B", createdAt: 2_000))
        _ = try store.insert(makeTextItem("A", createdAt: 3_000))

        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cycler = ClipboardCycler(historyStore: store, pasteboard: pasteboard, timeout: 10, now: { clock.current })

        var writeCount = 0
        cycler.onDidWritePasteboard = { writeCount += 1 }

        cycler.moveToPrevious()
        #expect(writeCount == 1)

        cycler.moveToPrevious()
        #expect(writeCount == 2)

        // 範囲外への移動では書き込みは発生しない
        cycler.moveToPrevious()
        #expect(writeCount == 2)
    }

    @Test("履歴が0件のときmoveToPreviousを呼んでもクラッシュせず、onCycledも呼ばれない")
    func moveToPreviousWithEmptyHistoryDoesNothing() throws {
        let (store, tempDir) = try makeHistoryStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipHistoryTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let cycler = ClipboardCycler(historyStore: store, pasteboard: pasteboard, timeout: 10, now: { clock.current })

        var cycled = false
        cycler.onCycled = { _, _ in cycled = true }

        cycler.moveToPrevious()

        #expect(cycled == false)
    }
}
