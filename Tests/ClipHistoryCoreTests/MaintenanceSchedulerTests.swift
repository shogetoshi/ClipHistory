import Foundation
import Testing
@testable import ClipHistoryCore

/// db・historyStore・blobStore一式を組み立てるヘルパー。`MaintenanceScheduler` は
/// これらすべてを束ねて動かすため、単体の `HistoryStore` だけでは検証できない。
private func makeEnvironment(
    inlineBlobThreshold: Int = 64 * 1024
) throws -> (db: Database, store: HistoryStore, blobStore: BlobStore, settings: Settings, tempDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let dbPath = tempDir.appendingPathComponent("history.db").path
    let db = try Database(path: dbPath)
    try Migrations.migrate(db)

    let blobStore = try BlobStore(baseDirectory: tempDir.appendingPathComponent("blobs", isDirectory: true))
    let store = HistoryStore(db: db, blobStore: blobStore, inlineBlobThreshold: inlineBlobThreshold)

    // テストごとに独立した UserDefaults スイートを使い、他のテスト・実アプリの設定と
    // 混ざらないようにする。
    let suiteName = "ClipHistoryTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = Settings(defaults: defaults)

    return (db, store, blobStore, settings, tempDir)
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

private func readLastVacuumAt(_ db: Database) throws -> Int64? {
    let stmt = try db.prepare("SELECT value FROM meta WHERE key = 'last_vacuum_at';")
    guard try stmt.step(), let value = stmt.columnText(0) else { return nil }
    return Int64(value)
}

@Suite("MaintenanceScheduler")
struct MaintenanceSchedulerTests {
    @Test("runMaintenanceがpurgeを実行し、削除idをonPurgeで通知する")
    func runMaintenancePurgesAndNotifies() throws {
        let (db, store, blobStore, settings, tempDir) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        settings.maxItemCount = 2
        let id1 = try store.insert(makeTextItem("one", createdAt: 1_000))
        let id2 = try store.insert(makeTextItem("two", createdAt: 2_000))
        let id3 = try store.insert(makeTextItem("three", createdAt: 3_000))
        let id4 = try store.insert(makeTextItem("four", createdAt: 4_000))

        let scheduler = MaintenanceScheduler(
            db: db, historyStore: store, blobStore: blobStore, settings: settings,
            now: { Date(timeIntervalSince1970: 0) }
        )
        var purgedIDs: [Int64] = []
        scheduler.onPurge = { purgedIDs.append(contentsOf: $0) }

        scheduler.runMaintenance()

        #expect(Set(purgedIDs) == Set([id1, id2]))
        let remaining = try store.fetchRecent(limit: 10)
        #expect(Set(remaining.map(\.id)) == Set([id3, id4]))
    }

    @Test("runMaintenanceが不要になったBLOBをGCする")
    func runMaintenanceCollectsGarbageBlobs() throws {
        let (db, store, blobStore, settings, tempDir) = try makeEnvironment(inlineBlobThreshold: 16)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        settings.maxItemCount = 1
        _ = try store.insert(makeTextItem(String(repeating: "old", count: 20), createdAt: 1_000))
        let keptID = try store.insert(makeTextItem(String(repeating: "new", count: 20), createdAt: 2_000))
        let keptRepresentation = try #require(try store.fetchRepresentations(itemID: keptID).first)
        let keptPath = try #require(keptRepresentation.filePath)
        let keptData = try store.loadData(for: keptRepresentation)

        let scheduler = MaintenanceScheduler(
            db: db, historyStore: store, blobStore: blobStore, settings: settings,
            now: { Date(timeIntervalSince1970: 0) }
        )
        scheduler.runMaintenance()

        // 古い方のitemがpurgeされ、そのBLOBはどこからも参照されなくなるためGCで消える。
        // 一方、残った方のitemが参照するBLOBは消えない。
        #expect(try blobStore.load(relativePath: keptPath) == keptData)
        let referenced = try store.referencedBlobPaths()
        #expect(referenced == Set([keptPath]))
    }

    @Test("VACUUM: last_vacuum_atが7日以内なら実行せず、7日以上前なら実行する")
    func vacuumRunsOnlyAfterSevenDays() throws {
        let (db, store, blobStore, settings, tempDir) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dayMillis: Int64 = 24 * 60 * 60 * 1000
        let t0 = Date(timeIntervalSince1970: 0)

        // 1回目: last_vacuum_atが未記録のため必ずVACUUMする
        let scheduler1 = MaintenanceScheduler(
            db: db, historyStore: store, blobStore: blobStore, settings: settings, now: { t0 }
        )
        scheduler1.runMaintenance()
        let firstRecordedAt = try #require(try readLastVacuumAt(db))
        #expect(firstRecordedAt == Int64(t0.timeIntervalSince1970 * 1000))

        // 2回目: 1日後（7日未満）。VACUUMは実行されず、記録時刻は変わらない。
        let tPlus1Day = Date(timeIntervalSince1970: 0).addingTimeInterval(TimeInterval(dayMillis / 1000))
        let scheduler2 = MaintenanceScheduler(
            db: db, historyStore: store, blobStore: blobStore, settings: settings, now: { tPlus1Day }
        )
        scheduler2.runMaintenance()
        let secondRecordedAt = try #require(try readLastVacuumAt(db))
        #expect(secondRecordedAt == firstRecordedAt, "7日未満はVACUUMを実行しないため記録時刻は変わらない")

        // 3回目: 8日後（7日以上）。VACUUMが実行され、記録時刻が更新される。
        let tPlus8Days = Date(timeIntervalSince1970: 0).addingTimeInterval(TimeInterval(dayMillis * 8 / 1000))
        let scheduler3 = MaintenanceScheduler(
            db: db, historyStore: store, blobStore: blobStore, settings: settings, now: { tPlus8Days }
        )
        scheduler3.runMaintenance()
        let thirdRecordedAt = try #require(try readLastVacuumAt(db))
        #expect(thirdRecordedAt == Int64(tPlus8Days.timeIntervalSince1970 * 1000))
        #expect(thirdRecordedAt != secondRecordedAt, "7日以上経過したのでVACUUMが実行され記録時刻が更新される")
    }
}
