import Foundation

/// 一覧での複数選択（印付け）状態を保持する値型（Issue 0023）。
///
/// tabキーによる複数選択では、選択したアイテムを行番号ではなく `HistoryItem` そのもので
/// 覚える。検索の絞り込みによって一覧から一時的に消えても印が失われないようにするためで、
/// 行番号だけを保持すると絞り込み後の一覧に対して意味を持たなくなってしまう。
///
/// UI（AppKit）には依存させず、印の集合を管理する純粋なロジックのみをここに置く。
public struct MarkedSelection {
    /// 印を付けた順に並んだアイテム
    public private(set) var items: [HistoryItem] = []

    public init() {}

    /// 印が1件も付いていないか
    public var isEmpty: Bool {
        items.isEmpty
    }

    /// 印が付いているアイテムの件数
    public var count: Int {
        items.count
    }

    /// 指定した id のアイテムに印が付いているか
    public func contains(itemID: Int64) -> Bool {
        items.contains { $0.id == itemID }
    }

    /// 印の状態を切り替える。同じ id が既にあれば取り除き、無ければ末尾に追加する
    /// （末尾に追加することで「印を付けた順」を保つ）。
    public mutating func toggle(_ item: HistoryItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
        } else {
            items.append(item)
        }
    }

    /// 印を全て取り除く
    public mutating func removeAll() {
        items.removeAll()
    }

    /// 複数選択されたテキストを改行で結合する（Issue 0023）
    public static func joinedText(_ texts: [String]) -> String {
        texts.joined(separator: "\n")
    }
}
