import Foundation

/// Snippet アイテムの出どころ（ソース .md ファイルのパスと、見出し行の1始まり行番号）
public struct SnippetSourceLocation: Equatable {
    public let filePath: String
    public let lineNumber: Int

    public init(filePath: String, lineNumber: Int) {
        self.filePath = filePath
        self.lineNumber = lineNumber
    }
}

/// 設定ディレクトリ配下の `.md` ファイルを再帰的に走査し、Snippet アイテムの一覧を保持する。
///
/// Snippet 専用の行の型は新設せず `HistoryItem` を流用して変換する。理由は `ResultsProvider` /
/// `PickerViewModel` / `MarkedSelection` / セルまで型の波及を起こさないため
/// （Issue 0030 はクリップボード履歴との相互運用を考えないと明記している）。
public final class SnippetStore {
    private let directories: [String]

    private var loadedItems: [HistoryItem] = []
    private var loadedIndexEntries: [IndexEntry] = []
    private var snippetsByID: [Int64: SnippetItem] = [:]
    private var sourceLocationsByID: [Int64: SnippetSourceLocation] = [:]

    public init(directories: [String]) {
        self.directories = directories
    }

    /// 検索パネルに出す行（`SearchIndex` に載せる id と対応する）
    public var items: [HistoryItem] { loadedItems }

    /// `SearchIndex.load` に渡すエントリ
    public var indexEntries: [IndexEntry] { loadedIndexEntries }

    /// 設定ディレクトリを走査し直し、アイテムを作り直す
    public func reload() {
        var items: [HistoryItem] = []
        var indexEntries: [IndexEntry] = []
        var snippetsByID: [Int64: SnippetItem] = [:]
        var sourceLocationsByID: [Int64: SnippetSourceLocation] = [:]

        // 同じファイルが複数のディレクトリ指定から二重に見つかった場合、後から見つかった
        // ほうを読み飛ばすため、ここまでに読んだファイルパスを覚えておく。
        var seenPaths: Set<String> = []
        var nextID: Int64 = 1

        for directory in directories {
            let expandedPath = (directory as NSString).expandingTildeInPath
            let directoryURL = URL(fileURLWithPath: expandedPath, isDirectory: true)

            // 存在しないディレクトリを渡された場合、enumerator は nil または空列挙になる
            // （どちらの場合もこの for ループは何もせず次のディレクトリへ進む）。
            guard let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            var filePaths: [String] = []
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "md" {
                filePaths.append(fileURL.path)
            }
            // 実行ごとに結果の順序が変わらないよう、読む前に昇順ソートしておく。
            filePaths.sort()

            for path in filePaths {
                guard !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)

                // 1ファイルの読み込み失敗（権限・エンコーディング不正など）で機能全体が
                // 死なないよう、ログに残して読み飛ばす（design 13.3 と同じ方針）。
                guard let markdown = try? String(contentsOfFile: path, encoding: .utf8) else {
                    NSLog("ClipHistory: SnippetStore.reload() failed to read file at \(path)")
                    continue
                }

                let fileName = (path as NSString).lastPathComponent
                let baseName = (fileName as NSString).deletingPathExtension

                for snippetItem in SnippetParser.parse(markdown: markdown) {
                    let id = nextID
                    nextID += 1

                    // 「ファイル名（拡張子を除く）+ 半角スペース1つ + アイテムのタイトル」
                    let lineText = "\(baseName) \(snippetItem.title)"
                    let searchKey = Normalizer.normalize(lineText)

                    items.append(HistoryItem(
                        id: id,
                        // SearchIndex は createdAt 昇順（同値は id 昇順）を前提とするため
                        // （SearchIndex.swift のコメント参照）、id と同じ値を入れる。
                        // Snippet に時刻の概念は無い。
                        createdAt: id,
                        kind: .text,
                        previewText: lineText,
                        searchKey: searchKey,
                        // 以下は Snippet では使わないフィールド。
                        contentHash: "",
                        byteSize: 0,
                        sourceAppBundleID: nil,
                        sourceAppName: nil,
                        pinned: false
                    ))
                    indexEntries.append(IndexEntry(id: id, createdAt: id, searchKey: searchKey))
                    snippetsByID[id] = snippetItem
                    sourceLocationsByID[id] = SnippetSourceLocation(filePath: path, lineNumber: snippetItem.headingLineNumber)
                }
            }
        }

        loadedItems = items
        loadedIndexEntries = indexEntries
        self.snippetsByID = snippetsByID
        self.sourceLocationsByID = sourceLocationsByID
    }

    /// id に対応する Snippet の中身（プレビュー全文とコードブロック）
    public func snippet(id: Int64) -> SnippetItem? {
        snippetsByID[id]
    }

    /// id に対応する Snippet の出どころ（ソース .md ファイルのパスと見出し行番号）
    public func sourceLocation(id: Int64) -> SnippetSourceLocation? {
        sourceLocationsByID[id]
    }

    /// id 列に対応する行を、渡された順序を保って返す（`HistoryStore.fetchItems(ids:)` と同じ役割）
    public func items(ids: [Int64]) -> [HistoryItem] {
        let itemsByID = Dictionary(uniqueKeysWithValues: loadedItems.map { ($0.id, $0) })
        return ids.compactMap { itemsByID[$0] }
    }
}
