import Foundation

/// 起動時＋定期的なメンテナンス（パージ・BLOB GC・VACUUM）を実行する（設計書 8節）。
/// **挿入ごとには実行しない**。`AppDelegate` がこれを組み立てて起動し、`onPurge` を
/// `SearchIndex.remove(ids:)` に接続することで、DBから消えた履歴がインメモリ検索
/// インデックスからも確実に除去されるようにする。
public final class MaintenanceScheduler {
    /// 1時間ごとに実行する（設計書8節「実行タイミング」）。
    public static let defaultInterval: TimeInterval = 60 * 60

    /// VACUUM は前回実行から7日以上経過している場合のみ行う（設計書 8.1 手順5）。
    public static let vacuumIntervalMillis: Int64 = 7 * 24 * 60 * 60 * 1000

    private static let lastVacuumAtKey = "last_vacuum_at"

    private let db: Database
    private let historyStore: HistoryStore
    private let blobStore: BlobStore
    private let settings: Settings
    private let interval: TimeInterval
    /// 現在時刻の取得元。テストで任意の時刻を注入できるよう `Date()` を直接呼ばない設計にする
    /// （指揮官指示。VACUUMの7日判定を時刻注入でテストするため）。
    private let now: () -> Date

    private var timer: Timer?

    /// パージで削除された item id を通知する。`AppDelegate` はこれを
    /// `SearchIndex.remove(ids:)` に接続し、インメモリ検索インデックスとDBの整合を保つ。
    public var onPurge: (([Int64]) -> Void)?

    public init(
        db: Database,
        historyStore: HistoryStore,
        blobStore: BlobStore,
        settings: Settings,
        interval: TimeInterval = MaintenanceScheduler.defaultInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.db = db
        self.historyStore = historyStore
        self.blobStore = blobStore
        self.settings = settings
        self.interval = interval
        self.now = now
    }

    /// 起動時に即座に1回実行し、以降 `interval`（既定1時間）ごとに実行するタイマーを開始する。
    public func start() {
        runMaintenance()

        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.runMaintenance()
        }
        // 挿入監視用の Timer と同様、tolerance を設けて OS のタイマーコアレッシングを許可し
        // 省電力化する。1時間間隔なので多少ずれても実用上問題ない。
        newTimer.tolerance = interval * 0.1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// パージ → BLOB GC → 必要なら VACUUM、の順で実行する。
    /// タイマー経由に限らずテストからも直接呼べるよう public にしておく。
    public func runMaintenance() {
        do {
            let deletedIDs = try historyStore.purge(maxItemCount: settings.maxItemCount)
            if !deletedIDs.isEmpty {
                onPurge?(deletedIDs)
            }

            // パージ後の「生きている参照」を数え直してからGCする。パージ直後に実行することで、
            // 削除されたレコードが指していたBLOBのうち他から参照されなくなったものを回収できる。
            let referenced = try historyStore.referencedBlobPaths()
            _ = try blobStore.collectGarbage(referencedPaths: referenced)

            try vacuumIfNeeded()
        } catch {
            NSLog("ClipHistory: maintenance failed: \(error)")
        }
    }

    /// VACUUM はDB全体を作り直す重い処理であり、毎回（1時間ごと）実行すると無駄なCPU/IOを
    /// 消費する。そのため `meta.last_vacuum_at` に前回実行時刻を記録し、7日以上経過している
    /// 場合のみ実行する（設計書 8.1 手順5）。
    private func vacuumIfNeeded() throws {
        let currentMillis = Int64(now().timeIntervalSince1970 * 1000)
        if let lastVacuumAt = try readLastVacuumAt(),
           currentMillis - lastVacuumAt < Self.vacuumIntervalMillis {
            return
        }
        try db.exec("VACUUM;")
        try writeLastVacuumAt(currentMillis)
    }

    private func readLastVacuumAt() throws -> Int64? {
        let stmt = try db.prepare("SELECT value FROM meta WHERE key = ?;")
        try stmt.bind(1, Self.lastVacuumAtKey)
        guard try stmt.step(), let value = stmt.columnText(0) else { return nil }
        return Int64(value)
    }

    private func writeLastVacuumAt(_ millis: Int64) throws {
        let stmt = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);")
        try stmt.bind(1, Self.lastVacuumAtKey)
        try stmt.bind(2, String(millis))
        _ = try stmt.step()
    }
}
