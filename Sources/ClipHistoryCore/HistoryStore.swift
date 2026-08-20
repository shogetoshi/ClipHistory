import Foundation

/// `items.kind` の取り得る値。v1 のこのフェーズで実際に生成するのは `.text` のみだが、
/// スキーマ・API は設計書のとおり多型対応の形にしておく。
public enum ItemKind: String {
    case text
    case image
    case file
    case rtf
}

/// 1件の履歴（= 1回のコピー）
public struct HistoryItem: Equatable {
    public let id: Int64
    public let createdAt: Int64
    public let kind: ItemKind
    public let previewText: String?
    public let searchKey: String?
    public let contentHash: String
    public let byteSize: Int64
    public let sourceAppBundleID: String?
    public let sourceAppName: String?
    public let pinned: Bool
}

/// 1件の表現（UTIごとの実データ）。データそのものは `inlineBlob` か `filePath` のどちらか一方に入る。
public struct Representation: Equatable {
    public let id: Int64
    public let itemID: Int64
    public let uti: String
    public let inlineBlob: Data?
    public let filePath: String?
    public let byteSize: Int64
}

/// `SearchIndex` を組み立てるための軽量ロード結果
public struct IndexEntry: Equatable {
    public let id: Int64
    public let createdAt: Int64
    public let searchKey: String
}

/// items + representations への挿入・読み出しを担う。
/// BLOB の実体保存先の判断（inline か外部ファイルか）は `inlineBlobThreshold` を基準にここで行い、
/// 外部ファイルの実際の保存・読み出しは `BlobStore` に委譲する。
public final class HistoryStore {
    /// 新規に挿入する表現データ（UTI + 生バイト列）
    public struct NewRepresentation {
        public let uti: String
        public let data: Data

        public init(uti: String, data: Data) {
            self.uti = uti
            self.data = data
        }
    }

    /// 新規に挿入する項目
    public struct NewItem {
        public let createdAt: Int64
        public let kind: ItemKind
        public let previewText: String?
        public let searchKey: String?
        public let contentHash: String
        public let sourceAppBundleID: String?
        public let sourceAppName: String?
        public let representations: [NewRepresentation]

        public init(
            createdAt: Int64,
            kind: ItemKind,
            previewText: String?,
            searchKey: String?,
            contentHash: String,
            sourceAppBundleID: String?,
            sourceAppName: String?,
            representations: [NewRepresentation]
        ) {
            self.createdAt = createdAt
            self.kind = kind
            self.previewText = previewText
            self.searchKey = searchKey
            self.contentHash = contentHash
            self.sourceAppBundleID = sourceAppBundleID
            self.sourceAppName = sourceAppName
            self.representations = representations
        }
    }

    private let db: Database
    private let blobStore: BlobStore
    private let inlineBlobThreshold: Int

    public init(db: Database, blobStore: BlobStore, inlineBlobThreshold: Int) {
        self.db = db
        self.blobStore = blobStore
        self.inlineBlobThreshold = inlineBlobThreshold
    }

    /// items + representations を1トランザクションで挿入する。
    /// 同一内容のコピーであっても常に新規レコードとして追加する（設計書 4.4、重複を圧縮しない）。
    @discardableResult
    public func insert(_ item: NewItem) throws -> Int64 {
        let totalByteSize = item.representations.reduce(Int64(0)) { $0 + Int64($1.data.count) }

        try db.exec("BEGIN;")
        do {
            let itemStmt = try db.prepare("""
            INSERT INTO items
                (created_at, kind, preview_text, search_key, content_hash, byte_size,
                 source_app_bundle_id, source_app_name, pinned)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0);
            """)
            try itemStmt.bind(1, item.createdAt)
            try itemStmt.bind(2, item.kind.rawValue)
            try bindOptionalText(itemStmt, 3, item.previewText)
            try bindOptionalText(itemStmt, 4, item.searchKey)
            try itemStmt.bind(5, item.contentHash)
            try itemStmt.bind(6, totalByteSize)
            try bindOptionalText(itemStmt, 7, item.sourceAppBundleID)
            try bindOptionalText(itemStmt, 8, item.sourceAppName)
            _ = try itemStmt.step()

            let itemID = db.lastInsertRowID

            for rep in item.representations {
                // 64KB 以下は DB 内 BLOB、超過は外部ファイルへ（設計書 4.1）
                let repStmt = try db.prepare("""
                INSERT INTO representations (item_id, uti, inline_blob, file_path, byte_size)
                VALUES (?, ?, ?, ?, ?);
                """)
                try repStmt.bind(1, itemID)
                try repStmt.bind(2, rep.uti)
                if rep.data.count <= inlineBlobThreshold {
                    try repStmt.bind(3, rep.data)
                    try repStmt.bindNull(4)
                } else {
                    let relativePath = try blobStore.save(rep.data)
                    try repStmt.bindNull(3)
                    try repStmt.bind(4, relativePath)
                }
                try repStmt.bind(5, Int64(rep.data.count))
                _ = try repStmt.step()
            }

            try db.exec("COMMIT;")
            return itemID
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    /// 最新順（created_at DESC）で items を取得する
    public func fetchRecent(limit: Int, offset: Int = 0) throws -> [HistoryItem] {
        let stmt = try db.prepare("""
        SELECT id, created_at, kind, preview_text, search_key, content_hash, byte_size,
               source_app_bundle_id, source_app_name, pinned
        FROM items
        -- 同一ミリ秒のコピーが複数あり得るため id をタイブレーカにする（順序の安定＋ページング漏れ防止）
        ORDER BY created_at DESC, id DESC
        LIMIT ? OFFSET ?;
        """)
        try stmt.bind(1, Int64(limit))
        try stmt.bind(2, Int64(offset))

        var results: [HistoryItem] = []
        while try stmt.step() {
            results.append(try makeHistoryItem(from: stmt))
        }
        return results
    }

    /// 指定した item に紐づく全表現を取得する
    public func fetchRepresentations(itemID: Int64) throws -> [Representation] {
        let stmt = try db.prepare("""
        SELECT id, item_id, uti, inline_blob, file_path, byte_size
        FROM representations
        WHERE item_id = ?;
        """)
        try stmt.bind(1, itemID)

        var results: [Representation] = []
        while try stmt.step() {
            results.append(Representation(
                id: stmt.columnInt64(0),
                itemID: stmt.columnInt64(1),
                uti: stmt.columnText(2) ?? "",
                inlineBlob: stmt.columnBlob(3),
                filePath: stmt.columnText(4),
                byteSize: stmt.columnInt64(5)
            ))
        }
        return results
    }

    /// 表現の実データを読み出す（inline ならそのまま、外部ファイルなら BlobStore 経由）
    public func loadData(for representation: Representation) throws -> Data {
        if let inline = representation.inlineBlob {
            return inline
        }
        guard let path = representation.filePath else {
            return Data()
        }
        return try blobStore.load(relativePath: path)
    }

    /// 指定した id 群の items を取得する。`SearchIndex.search()` が返した id 列を実データに
    /// 解決するために使う（`SearchResultsProvider` の責務）。
    ///
    /// SQL の `IN` で一括取得したうえで、戻り値は **引数の id の順序を保って** 並べ替える。
    /// `IN` 句は一致順を保証しないため（設計書には明記されていないが、検索スコア順の並びを
    /// 崩さないために必須の処理）。存在しない id は結果から単純に取り除く。
    public func fetchItems(ids: [Int64]) throws -> [HistoryItem] {
        guard !ids.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let stmt = try db.prepare("""
        SELECT id, created_at, kind, preview_text, search_key, content_hash, byte_size,
               source_app_bundle_id, source_app_name, pinned
        FROM items
        WHERE id IN (\(placeholders));
        """)
        for (offset, id) in ids.enumerated() {
            try stmt.bind(Int32(offset + 1), id)
        }

        var itemsByID: [Int64: HistoryItem] = [:]
        while try stmt.step() {
            let item = try makeHistoryItem(from: stmt)
            itemsByID[item.id] = item
        }

        return ids.compactMap { itemsByID[$0] }
    }

    /// 上限件数を超えた古い履歴を削除する（設計書 8.1 手順1〜2）。
    ///
    /// `pinned = 1` のレコードは削除対象外であり、かつ「上限件数」のカウントにも含めない
    /// （ピン留めした項目をいくら増やしても、通常の履歴が圧迫されて早く消えることがないように
    /// するため）。`pinned = 0` を `created_at DESC, id DESC` で並べ、`maxItemCount` 件目より
    /// 後ろ（＝古い側）を削除する。`id DESC` を第二キーにするのは `fetchRecent` と同じ理由で、
    /// 同一ミリ秒の複数レコードでも順序を安定させるため。
    ///
    /// - Returns: 削除した item id の配列（呼び出し元が `SearchIndex.remove(ids:)` に渡す）。
    ///   削除対象がなければ空配列を返す。
    @discardableResult
    public func purge(maxItemCount: Int) throws -> [Int64] {
        // OFFSET maxItemCount により「上限件数より後ろ（古い側）」の id だけを一括取得できる。
        // LIMIT -1 は「上限なし」を意味する SQLite の慣用句。
        let selectStmt = try db.prepare("""
        SELECT id FROM items
        WHERE pinned = 0
        ORDER BY created_at DESC, id DESC
        LIMIT -1 OFFSET ?;
        """)
        try selectStmt.bind(1, Int64(maxItemCount))

        var toDelete: [Int64] = []
        while try selectStmt.step() {
            toDelete.append(selectStmt.columnInt64(0))
        }
        guard !toDelete.isEmpty else { return [] }

        try db.exec("BEGIN;")
        do {
            // SQLiteのバインド変数上限（環境によっては999程度）を超えないよう、
            // 一定件数ごとに分割してDELETEする。representations は
            // items.id への ON DELETE CASCADE により自動的に削除される。
            for chunk in toDelete.chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let deleteStmt = try db.prepare("DELETE FROM items WHERE id IN (\(placeholders));")
                for (offset, id) in chunk.enumerated() {
                    try deleteStmt.bind(Int32(offset + 1), id)
                }
                _ = try deleteStmt.step()
            }
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
        return toDelete
    }

    /// 全 items / representations を削除し、対応する BLOB ファイルも削除する
    /// （メニューの「履歴を全消去」用）。
    public func deleteAll() throws {
        // DBの行を消してしまう前に、削除すべきBLOBファイルのパスを控えておく。
        let paths = try referencedBlobPaths()

        try db.exec("BEGIN;")
        do {
            try db.exec("DELETE FROM representations;")
            try db.exec("DELETE FROM items;")
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }

        // DB削除後にBLOB実体を削除する。1件の削除失敗（既に手動で消されていた等）で
        // 全消去操作全体を失敗させないよう、個々のエラーは握りつぶして続行する。
        for path in paths {
            try? blobStore.delete(relativePath: path)
        }
    }

    /// `representations.file_path` が非NULLの値の集合を返す（BLOB GC用）。
    ///
    /// 同一ハッシュのBLOBは複数レコードから共有され得るため（`BlobStore.save` がハッシュ名で
    /// 保存するため）、ここでは「参照されているパスの集合」のみを返し、実際にどのファイルを
    /// 消してよいかの判断（参照0件のみ削除）は `BlobStore.collectGarbage` 側に委ねる。
    public func referencedBlobPaths() throws -> Set<String> {
        let stmt = try db.prepare("SELECT file_path FROM representations WHERE file_path IS NOT NULL;")
        var paths: Set<String> = []
        while try stmt.step() {
            if let path = stmt.columnText(0) {
                paths.insert(path)
            }
        }
        return paths
    }

    /// `SearchIndex` 構築用の軽量ロード（id / created_at / search_key のみ）
    public func loadIndexEntries() throws -> [IndexEntry] {
        let stmt = try db.prepare("""
        SELECT id, created_at, search_key
        FROM items
        ORDER BY created_at ASC, id ASC;
        """)

        var results: [IndexEntry] = []
        while try stmt.step() {
            results.append(IndexEntry(
                id: stmt.columnInt64(0),
                createdAt: stmt.columnInt64(1),
                searchKey: stmt.columnText(2) ?? ""
            ))
        }
        return results
    }

    private func bindOptionalText(_ stmt: Statement, _ index: Int32, _ value: String?) throws {
        if let value {
            try stmt.bind(index, value)
        } else {
            try stmt.bindNull(index)
        }
    }

    private func makeHistoryItem(from stmt: Statement) throws -> HistoryItem {
        HistoryItem(
            id: stmt.columnInt64(0),
            createdAt: stmt.columnInt64(1),
            kind: ItemKind(rawValue: stmt.columnText(2) ?? "text") ?? .text,
            previewText: stmt.columnText(3),
            searchKey: stmt.columnText(4),
            contentHash: stmt.columnText(5) ?? "",
            byteSize: stmt.columnInt64(6),
            sourceAppBundleID: stmt.columnText(7),
            sourceAppName: stmt.columnText(8),
            pinned: stmt.columnInt64(9) != 0
        )
    }
}

private extension Array {
    /// 指定件数ごとに分割する。`purge` のDELETE文をSQLiteのバインド変数上限に
    /// 収まる大きさへ分割実行するために使う。
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
