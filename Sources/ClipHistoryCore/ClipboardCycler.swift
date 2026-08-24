import AppKit

/// グローバルホットキー（⌃⌘P / ⌃⌘N）でクリップボードに「N個前」の履歴を書き戻す
/// 循環機能の中核（Issue 0015）。
///
/// 設計判断:
/// - 「N個前」は**循環開始時に取ったスナップショットに対する添字**である。都度 `fetchRecent` し
///   直すと、自分の書き戻しや新規コピーで並びがずれて「2個前」が意図した項目を指さなくなるため。
/// - 自分の書き戻しは履歴に記録させない（`onDidWritePasteboard` の用途）。記録すると
///   キーを押した回数だけ履歴が汚れ、「N個前」の基準もずれるため。パネルからの確定
///   （設計書 3.2 手順4）とは意図的に扱いを分けている。
///
/// スレッド: すべてメインスレッドから呼ばれる前提（ホットキーのコールバックはメインRunLoop上で
/// 走る）。そのためロックは持たない。
public final class ClipboardCycler {
    /// スナップショットとして遡る履歴の上限件数。ホットキーを200回以上押す運用は
    /// 想定しないため、これ以上前へは辿らない。
    public static let defaultSnapshotLimit = 200

    private let historyStore: HistoryStore
    private let pasteboard: NSPasteboard
    private let timeout: TimeInterval
    private let snapshotLimit: Int
    private let now: () -> Date

    /// 循環を開始した時点の履歴一覧（`fetchRecent` の結果、最新順）。空配列 = 非アクティブ
    /// （ポインタ揮発済み）。
    private var snapshot: [HistoryItem] = []
    /// `snapshot` 内の現在位置。`0` = 最新（= 循環開始時点のクリップボード内容）、
    /// `1` = 1個前、`2` = 2個前 …。
    private var pointer: Int = 0
    /// 最後にこの機能が使われた時刻。
    private var lastUsedAt: Date?

    /// 書き戻しに成功したときに `(項目, オフセット)` で呼ぶ。オフセットは「N個前」の N
    /// （= `pointer`）。通知UIがこれを購読する。
    public var onCycled: ((HistoryItem, Int) -> Void)?
    /// クリップボードへ書き込んだ**直後**に呼ぶ。自前の書き込みを `ClipboardMonitor` に
    /// 新規コピーとして拾わせないため、呼び出し側で「既読」にするのに使う。
    public var onDidWritePasteboard: (() -> Void)?

    /// - Parameters:
    ///   - pasteboard: 書き戻し先。既定は `.general` だが、ユニットテストが利用者の実際の
    ///     クリップボードを壊さないよう注入可能にしている。
    ///   - now: 現在時刻の取得元。ユニットテストがタイムアウト判定を検証できるよう
    ///     注入可能にしている。
    public init(
        historyStore: HistoryStore,
        pasteboard: NSPasteboard = .general,
        timeout: TimeInterval,
        snapshotLimit: Int = ClipboardCycler.defaultSnapshotLimit,
        now: @escaping () -> Date = { Date() }
    ) {
        self.historyStore = historyStore
        self.pasteboard = pasteboard
        self.timeout = timeout
        self.snapshotLimit = snapshotLimit
        self.now = now
    }

    /// ⌃⌘P。より古い方へ1つ進む（`pointer` を +1）。
    public func moveToPrevious() {
        move(by: 1)
    }

    /// ⌃⌘N。より新しい方へ1つ戻る（`pointer` を -1）。
    public func moveToNext() {
        move(by: -1)
    }

    /// スナップショットとポインタを破棄する（外部からの新規コピー検知時に呼ばれる。
    /// スナップショットが陳腐化するため）。
    public func invalidate() {
        snapshot = []
        pointer = 0
        lastUsedAt = nil
    }

    /// `moveToPrevious` / `moveToNext` の共通処理。
    ///
    /// 「揮発」判定はここで**遅延評価**する（Timer は使わない）。ポインタの状態はこの機能
    /// 自身の操作からしか観測されないため、押されたときに期限切れを判定すれば
    /// 「10秒使わなければ揮発する」と等価であり、RunLoop に依存せずテストできる。
    private func move(by delta: Int) {
        let currentTime = now()
        if snapshot.isEmpty || (lastUsedAt.map { currentTime.timeIntervalSince($0) > timeout } ?? false) {
            do {
                snapshot = try historyStore.fetchRecent(limit: snapshotLimit)
            } catch {
                NSLog("ClipHistory: failed to fetch recent history for cycling: \(error)")
                return
            }
            pointer = 0
        }

        let target = pointer + delta
        guard target >= 0 && target < snapshot.count else {
            // 範囲外への移動は無視するが、利用者はこの機能を使っているため有効期限は延ばす。
            lastUsedAt = currentTime
            return
        }

        let item = snapshot[target]
        do {
            try writeToPasteboard(item)
        } catch {
            NSLog("ClipHistory: failed to write pasteboard while cycling: \(error)")
            return
        }

        pointer = target
        lastUsedAt = currentTime
        onCycled?(item, pointer)
    }

    /// 選択項目の全表現を `NSPasteboard` へ書き戻す。`PickerPanelController.writeToPasteboard(_:)`
    /// と同じ方式にする。
    private func writeToPasteboard(_ item: HistoryItem) throws {
        let representations = try historyStore.fetchRepresentations(itemID: item.id)
        pasteboard.clearContents()
        for representation in representations {
            let data = try historyStore.loadData(for: representation)
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(representation.uti))
        }
        onDidWritePasteboard?()
    }
}
