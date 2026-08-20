import Foundation

public enum BlobStoreError: Error, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "blob not found: \(path)"
        }
    }
}

/// 64KB を超えるデータを実ファイルとして保存・読み出し・削除するストア。
/// 設計書 4.1 のとおり `blobs/<hash先頭2文字>/<hash>` に配置する。
/// 先頭2文字でサブディレクトリを分けるのは、単一ディレクトリに大量のファイルが
/// 集中して探索が遅くなるのを避けるため。
public final class BlobStore {
    private let baseDirectory: URL

    public init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// データを保存し、DB の `representations.file_path` に格納すべき相対パスを返す。
    /// 同一ハッシュのファイルが既に存在する場合は書き込みをスキップする（複数レコードが
    /// 同一内容を参照し得るため。パージ時の BLOB GC は参照カウントに基づいて行う）。
    @discardableResult
    public func save(_ data: Data) throws -> String {
        let hash = sha256Hex(data)
        let (relativePath, fileURL) = paths(forHash: hash)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
        }
        return relativePath
    }

    public func load(relativePath: String) throws -> Data {
        let fileURL = baseDirectory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BlobStoreError.notFound(relativePath)
        }
        return try Data(contentsOf: fileURL)
    }

    public func delete(relativePath: String) throws {
        let fileURL = baseDirectory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// `blobs` ディレクトリを走査し、`referencedPaths` に含まれないファイルを削除する。
    ///
    /// **重要**: 同一ハッシュのBLOBは複数レコードから共有され得る（`save` がハッシュ名で
    /// 保存するため、同一内容を複数の `representations` 行が同じファイルを指すことがある）。
    /// そのため「DB上のどのレコードからも参照されていない（＝参照0件の）ファイルだけ」を
    /// 削除対象とする。呼び出し元は `HistoryStore.referencedBlobPaths()` で
    /// **現在生きている全レコード分**の参照集合を渡すこと。ここを1件でも過小に渡すと、
    /// 生きている履歴のデータを誤って削除してしまう。
    ///
    /// 空になったサブディレクトリ（`<hash先頭2文字>/`）も削除する。
    /// - Returns: 削除したファイル数
    @discardableResult
    public func collectGarbage(referencedPaths: Set<String>) throws -> Int {
        let fm = FileManager.default
        var deletedCount = 0

        guard let subdirectories = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return 0
        }

        for subdirectory in subdirectories {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: subdirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let prefix = subdirectory.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(at: subdirectory, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in files {
                let relativePath = "\(prefix)/\(file.lastPathComponent)"
                // 参照が1件でも残っていれば削除しない（複数レコードによる共有を壊さないため）
                guard !referencedPaths.contains(relativePath) else { continue }
                try fm.removeItem(at: file)
                deletedCount += 1
            }

            // 全ファイルを消してディレクトリが空になった場合のみ、ディレクトリ自体も削除する
            if let remaining = try? fm.contentsOfDirectory(at: subdirectory, includingPropertiesForKeys: nil),
               remaining.isEmpty {
                try? fm.removeItem(at: subdirectory)
            }
        }

        return deletedCount
    }

    private func paths(forHash hash: String) -> (relativePath: String, fileURL: URL) {
        let prefix = String(hash.prefix(2))
        let relativePath = "\(prefix)/\(hash)"
        let fileURL = baseDirectory.appendingPathComponent(prefix).appendingPathComponent(hash)
        return (relativePath, fileURL)
    }
}
