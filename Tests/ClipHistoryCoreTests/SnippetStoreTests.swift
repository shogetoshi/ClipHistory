import Foundation
import Testing
@testable import ClipHistoryCore

@Suite("SnippetStore")
struct SnippetStoreTests {
    @Test("サブディレクトリ配下の.mdも再帰的に拾う")
    func picksUpMarkdownFilesInSubdirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let subDir = tempDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try "### top\n本文".write(to: tempDir.appendingPathComponent("top.md"), atomically: true, encoding: .utf8)
        try "### nested\n本文".write(to: subDir.appendingPathComponent("nested.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directories: [tempDir.path])
        store.reload()

        #expect(Set(store.items.map { $0.previewText ?? "" }) == Set(["top top", "nested nested"]))
    }

    @Test(".md以外のファイルは拾わない")
    func ignoresNonMarkdownFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "### item\n本文".write(to: tempDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "not a snippet".write(to: tempDir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directories: [tempDir.path])
        store.reload()

        #expect(store.items.count == 1)
        #expect(store.items[0].previewText == "note item")
    }

    @Test("行テキストがファイル名（拡張子なし）+ スペース + タイトルになる")
    func lineTextIsFileNamePlusTitle() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "### rebase onto\n本文".write(to: tempDir.appendingPathComponent("git.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directories: [tempDir.path])
        store.reload()

        #expect(store.items.count == 1)
        #expect(store.items[0].previewText == "git rebase onto")
        #expect(store.items[0].searchKey == Normalizer.normalize("git rebase onto"))
    }

    @Test("idが1始まりの連番でcreatedAtと一致する")
    func idsAreSequentialStartingAtOneAndMatchCreatedAt() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "### a\n本文a\n\n### b\n本文b".write(to: tempDir.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directories: [tempDir.path])
        store.reload()

        #expect(store.items.map(\.id) == [1, 2])
        for item in store.items {
            #expect(item.id == item.createdAt)
        }
    }

    @Test("snippet(id:)でfullTextとcodeBlockが引ける")
    func snippetLookupReturnsFullTextAndCodeBlock() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let markdown = """
        ### rebase onto
        ```bash
        git rebase --onto a b c
        ```
        """
        try markdown.write(to: tempDir.appendingPathComponent("git.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directories: [tempDir.path])
        store.reload()

        let id = store.items[0].id
        let snippet = store.snippet(id: id)
        #expect(snippet?.codeBlock == "git rebase --onto a b c")
        #expect(snippet?.fullText.hasPrefix("### rebase onto") == true)
    }

    @Test("items(ids:)が渡したidの順序を保つ")
    func itemsPreservesArgumentOrder() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "### a\n本文a\n\n### b\n本文b\n\n### c\n本文c".write(to: tempDir.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directories: [tempDir.path])
        store.reload()

        let reversedIDs = Array(store.items.map(\.id).reversed())
        let result = store.items(ids: reversedIDs)
        #expect(result.map(\.id) == reversedIDs)
    }

    @Test("reload()を呼ぶと、その間に追加された.mdが結果へ反映される")
    func reloadPicksUpNewlyAddedFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "### first\n本文".write(to: tempDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let store = SnippetStore(directories: [tempDir.path])
        store.reload()
        #expect(store.items.count == 1)

        try "### second\n本文".write(to: tempDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.items.count == 2)
    }

    @Test("存在しないディレクトリを指定してもクラッシュせず空になる")
    func nonexistentDirectoryResultsInEmptyItems() {
        let store = SnippetStore(directories: ["/nonexistent/\(UUID().uuidString)"])
        store.reload()

        #expect(store.items.isEmpty)
        #expect(store.indexEntries.isEmpty)
    }
}

@Suite("SnippetResultsProvider")
struct SnippetResultsProviderTests {
    @Test("reload()後に空クエリで全件、タイトルの部分文字列で絞り込める")
    func reloadThenSearchReturnsMatchingResults() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "### rebase onto\n本文1\n\n### branch rename\n本文2".write(
            to: tempDir.appendingPathComponent("git.md"),
            atomically: true,
            encoding: .utf8
        )

        let store = SnippetStore(directories: [tempDir.path])
        let provider = SnippetResultsProvider(store: store)
        provider.reload()

        let all = try provider.results(for: "", limit: 10)
        #expect(all.count == 2)

        let filtered = try provider.results(for: "rebase", limit: 10)
        #expect(filtered.count == 1)
        #expect(filtered[0].previewText == "git rebase onto")
    }
}
