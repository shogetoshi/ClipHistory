import Testing
@testable import ClipHistoryCore

private func makeItem(id: Int64) -> HistoryItem {
    HistoryItem(
        id: id,
        createdAt: id,
        kind: .text,
        previewText: "item-\(id)",
        searchKey: "item-\(id)",
        contentHash: "hash-\(id)",
        byteSize: 0,
        sourceAppBundleID: nil,
        sourceAppName: nil,
        pinned: false
    )
}

@Suite("MarkedSelection")
struct MarkedSelectionTests {
    @Test("初期状態は空である")
    func initialStateIsEmpty() {
        let selection = MarkedSelection()
        #expect(selection.isEmpty)
        #expect(selection.count == 0)
        #expect(selection.items.isEmpty)
    }

    @Test("toggleで追加され、同じidを再度toggleすると取り除かれる")
    func toggleAddsAndRemoves() {
        var selection = MarkedSelection()
        let item = makeItem(id: 1)

        selection.toggle(item)
        #expect(selection.count == 1)
        #expect(selection.contains(itemID: 1))

        selection.toggle(item)
        #expect(selection.isEmpty)
        #expect(!selection.contains(itemID: 1))
    }

    @Test("印を付けた順序が保たれる")
    func orderIsPreserved() {
        var selection = MarkedSelection()
        selection.toggle(makeItem(id: 3))
        selection.toggle(makeItem(id: 1))
        selection.toggle(makeItem(id: 2))

        #expect(selection.items.map { $0.id } == [3, 1, 2])
    }

    @Test("途中の1件を取り除いても残りの順序が保たれる")
    func removingMiddleItemPreservesRemainingOrder() {
        var selection = MarkedSelection()
        selection.toggle(makeItem(id: 3))
        selection.toggle(makeItem(id: 1))
        selection.toggle(makeItem(id: 2))

        selection.toggle(makeItem(id: 1))

        #expect(selection.items.map { $0.id } == [3, 2])
    }

    @Test("contains(itemID:)が印の有無を正しく返す")
    func containsReflectsMarkedState() {
        var selection = MarkedSelection()
        selection.toggle(makeItem(id: 1))

        #expect(selection.contains(itemID: 1))
        #expect(!selection.contains(itemID: 2))
    }

    @Test("removeAllで空になる")
    func removeAllClearsSelection() {
        var selection = MarkedSelection()
        selection.toggle(makeItem(id: 1))
        selection.toggle(makeItem(id: 2))

        selection.removeAll()

        #expect(selection.isEmpty)
        #expect(selection.count == 0)
    }

    @Test("joinedTextが改行で結合する（0件・1件・複数件）")
    func joinedTextJoinsWithNewline() {
        #expect(MarkedSelection.joinedText([]) == "")
        #expect(MarkedSelection.joinedText(["a"]) == "a")
        #expect(MarkedSelection.joinedText(["a", "b", "c"]) == "a\nb\nc")
    }
}
