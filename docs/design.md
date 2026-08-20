# macOS クリップボード履歴アプリ 基本設計書

作成日: 2026-08-20

---

## 1. 目的

macOS 上でコピーしたデータの履歴を蓄積し、グローバルホットキーで呼び出したパネルから
fzf ライクな曖昧検索で目的の項目を探し、クリップボードへ書き戻すツール。

貼り付け操作そのものは OS 標準（⌘V）に委ね、本アプリは
**「これから貼り付けるデータを選択する機能」** に責務を限定する。

### 1.1 前提

- 利用者は 1 名（作成者本人）のみ
- 配布・公証（notarization）は不要。ad-hoc 署名でローカル運用
- 履歴の上限は件数基準。最大 60,000 件以上を扱えること

### 1.2 非スコープ

| 項目 | 理由 |
| --- | --- |
| ⌘V の自動合成（CGEvent によるキーイベント送出） | 責務外。アクセシビリティ権限も不要になる |
| iCloud / デバイス間同期 | 単一マシン利用のため |
| 画像・ファイルの検索 | 将来対応。ただしデータスキーマは今から多型対応にする |
| ひらがな / カタカナの相互一致 | 不要と判断 |
| 複雑な除外設定 UI | v1 は最小限（機密フラグの自動スキップのみ） |

---

## 2. 技術スタック

| 領域 | 選定 | 理由 |
| --- | --- | --- |
| 言語 | Swift | macOS ネイティブ API を直接利用できる |
| UI | AppKit（`NSPanel` + `NSTableView`） | 大量行の遅延描画に強く、枯れている。SwiftUI は設定画面など補助的に利用 |
| 常駐形態 | `LSUIElement = true`（メニューバー常駐、Dock 非表示） | 常駐ツールの標準的な形 |
| 永続化 | SQLite（`sqlite3` 直叩き、または GRDB.swift） | 単一ファイル・枯れている。BLOB を扱うため Core Data は回避 |
| 検索 | 自前実装（インメモリ全件スキャン） | fzf 方式の曖昧一致は SQL では表現できない |
| ホットキー | Carbon `RegisterEventHotKey` | **アクセシビリティ権限が不要**。`NSEvent` のグローバル監視は権限が必要なため採用しない |
| サンドボックス | 無効 | 自分用のため。有効化しても `NSPasteboard` 読み取りは可能だが、制約を避ける |

### 2.1 なぜ SQLite FTS5 を使わないか

当初は FTS5（`trigram` トークナイザ）による全文検索を検討したが、fzf の曖昧一致は
サブシーケンス一致（`abc` が `axxbxxc` にマッチする）であり、trigram による事前絞り込みでは
取りこぼしが発生する。fzf 自身がそうしているように**全件スキャン**する方が正確かつ十分高速。

結果として **SQLite の役割は永続化のみ**に限定され、構成がシンプルになる。

---

## 3. アーキテクチャ

### 3.1 コンポーネント一覧

| コンポーネント | 責務 |
| --- | --- |
| `AppDelegate` | 起動・常駐設定、各コンポーネントの組み立て |
| `ClipboardMonitor` | `NSPasteboard.changeCount` のポーリング、新規項目の検出と正規化 |
| `HistoryStore` | SQLite への読み書き、パージ、BLOB ファイル管理 |
| `SearchIndex` | インメモリ検索インデックスの保持と fzf ライクな絞り込み |
| `HotKeyManager` | グローバルホットキーの登録・解除、パネル表示のトリガ |
| `PickerPanelController` | 検索パネルの表示制御、フォーカス復帰、選択確定処理 |
| `PickerViewController` | 検索フィールドと結果一覧（`NSTableView`）の描画 |
| `Settings` | `UserDefaults` ベースの設定管理 |
| `MaintenanceScheduler` | 起動時＋定期のパージ・BLOB GC 実行 |

### 3.2 データフロー

**コピー検出時**

1. `ClipboardMonitor` が 0.3 秒間隔で `changeCount` を比較
2. 変化を検出したら型一覧を取得し、機密フラグ・除外条件を判定
3. 対象なら本文を取り出し、`HistoryStore` へ挿入
4. 挿入結果を `SearchIndex` に追記（DB 再読み込みはしない）

**呼び出し〜選択時**

1. ホットキー押下 → 直前の frontmost アプリを記録 → パネル表示
2. 打鍵ごと（30〜50ms デバウンス）に `SearchIndex` で絞り込み、上位 200 件を描画
3. Enter で確定 → 選択項目を `NSPasteboard` へ書き込み → パネルを閉じ、元アプリへフォーカス復帰
4. 書き込みにより `changeCount` が変化するため、`ClipboardMonitor` が通常フローで検出し
   **新規レコードとして最新に追加される**（特別な処理を作らずに要件を満たす）
5. 利用者は元アプリでそのまま ⌘V

---

## 4. データ設計

### 4.1 設計方針

`NSPasteboard` の 1 回のコピーは**複数の表現（UTI）を同時に保持する**。
忠実に復元するため、「1 コピー = 1 `items` レコード + N 個の `representations` レコード」とする。

サイズによって保存先を切り替える。

| データサイズ | 保存先 |
| --- | --- |
| 64 KB 以下 | `representations.inline_blob`（DB 内 BLOB） |
| 64 KB 超 | `~/Library/Application Support/<AppName>/blobs/<hash 先頭2文字>/<hash>` に実ファイル。DB はパスのみ保持 |

これにより DB の肥大を防ぎ、将来の画像・ファイル対応は `representations` に行を足すだけで済む。

### 4.2 スキーマ

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- 1 回のコピー = 1 レコード
CREATE TABLE items (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at           INTEGER NOT NULL,          -- Unix epoch (ミリ秒)
    kind                 TEXT    NOT NULL           -- 'text' | 'image' | 'file' | 'rtf'
                                 CHECK (kind IN ('text','image','file','rtf')),
    preview_text         TEXT,                      -- 一覧表示用。先頭 200 文字
    search_key           TEXT,                      -- 正規化済み検索キー。先頭 120 文字
    content_hash         TEXT    NOT NULL,          -- 主表現の SHA-256（hex）
    byte_size            INTEGER NOT NULL,          -- 全表現の合計バイト数
    source_app_bundle_id TEXT,
    source_app_name      TEXT,
    pinned               INTEGER NOT NULL DEFAULT 0 -- 0/1。パージ対象外にするフラグ
);

CREATE INDEX idx_items_created_at ON items (created_at DESC);
CREATE INDEX idx_items_hash       ON items (content_hash);
CREATE INDEX idx_items_pinned     ON items (pinned) WHERE pinned = 1;

-- 1 コピーが持つ各 UTI の実データ
CREATE TABLE representations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    uti         TEXT    NOT NULL,   -- 'public.utf8-plain-text', 'public.png' など
    inline_blob BLOB,               -- 64KB 以下のとき使用
    file_path   TEXT,               -- 64KB 超のとき使用（blobs ディレクトリからの相対パス）
    byte_size   INTEGER NOT NULL,
    UNIQUE (item_id, uti),
    CHECK ((inline_blob IS NOT NULL) <> (file_path IS NOT NULL))
);

CREATE INDEX idx_reps_item ON representations (item_id);

-- スキーマバージョン管理
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

### 4.3 容量見積り

テキスト平均 1 KB として 60,000 件で約 60 MB。SQLite にとって十分小さい。
インメモリ検索インデックスは 1 件あたり約 200〜600 バイト（`search_key` 120 文字 + メタ）で、
60,000 件で **12〜36 MB** 程度。

### 4.4 重複の扱い

同一内容のコピーも**別レコードとして保存する**（履歴の時系列を壊さない）。

将来的な圧縮のために `content_hash` にインデックスを張っておき、
「N 日より古いレコードは、同一ハッシュのうち最新 1 件のみ残す」バッチを後から追加できる形にする。

---

## 5. クリップボード監視

macOS にはクリップボード変更の通知 API が存在しないため、ポーリングで実装する。

| 項目 | 仕様 |
| --- | --- |
| 間隔 | 0.3 秒（`Timer`、`tolerance` を 0.1 秒に設定して省電力化） |
| 判定 | `NSPasteboard.general.changeCount` の変化を検出 |
| 負荷 | `changeCount` の取得は極めて軽量。実データ読み出しは変化時のみ |

### 5.1 スキップ条件

| 条件 | 判定方法 |
| --- | --- |
| 機密データ | 型に `org.nspasteboard.ConcealedType` が含まれる（パスワードマネージャが付与） |
| 一時データ | 型に `org.nspasteboard.TransientType` / `AutoGeneratedType` が含まれる |
| 空 | 本文が空、または空白文字のみ |
| 過大 | テキストが 5 MB を超える（設定可能） |
| 自アプリ由来の即時再検出 | 直近に自分が書き込んだ `changeCount` と一致する場合のみ抑制（※選択時の再登録は仕様なので抑制しない） |

### 5.2 取得情報

- 本文: `public.utf8-plain-text`（v1）
- コピー元アプリ: 検出時点の `NSWorkspace.shared.frontmostApplication`（近似値）
- `content_hash`: 主表現バイト列の SHA-256

---

## 6. 検索設計（fzf 方式）

### 6.1 インデックス

起動時に DB から下記だけをロードし、配列として保持する。

```
struct IndexEntry {
    let id: Int64
    let createdAt: Int64
    let searchKey: [UInt8] or [Unicode.Scalar]  // 正規化済み
}
```

新規コピー・選択確定時は配列末尾に追記するのみ。DB 再読み込みは行わない。

### 6.2 正規化

保存時（`search_key` 生成時）とクエリ入力時に**同一の正規化**を適用する。

1. NFKC 正規化（全角英数字・半角カナの統一）
2. Unicode 準拠の小文字化（大文字 / 小文字を区別しない）
3. 連続空白を 1 個に圧縮
4. 先頭 120 文字に切り詰め

※ ひらがな / カタカナの相互変換は行わない。

### 6.3 マッチングとスコアリング

- クエリを**スペース区切りで分割し、全ターム AND 条件**（fzf 準拠）
- 各タームは**サブシーケンス一致**（文字が順序通り現れれば、間に他の文字が挟まってよい）
- スコア加点 / 減点:

| 要素 | 効果 |
| --- | --- |
| 一致文字が連続している | 連続長に応じて加点（最重要） |
| 語頭（空白・記号・キャメルケース境界の直後）での一致 | 加点 |
| 文字列先頭に近い位置での一致 | 加点 |
| 一致文字間のギャップ | ギャップ長に応じて減点 |
| 文字列全体が短い | わずかに加点 |

- 総合スコアは全タームの合計。同点は `created_at` 降順で解決
- 上位 200 件のみを描画対象とする
- クエリが空の場合は単純に `created_at` 降順の先頭 200 件

### 6.4 逐次絞り込みの最適化

fzf と同じ手法を採る。

- `(クエリ文字列, ヒットした id 配列)` をスタックで保持
- 新しいクエリが直前クエリの**前方拡張**（例: `foo` → `foob`）なら、**前回のヒット集合内だけを再検索**
- バックスペースなどで前方拡張でなくなった場合は、スタックを巻き戻して該当地点から再開。該当なしなら全件スキャン

これにより連続入力時の走査対象が急速に縮小し、体感即時になる。

### 6.5 性能方針

| 項目 | 方針 |
| --- | --- |
| デバウンス | 30〜50 ms |
| 実行スレッド | バックグラウンドキューで走査し、結果のみメインスレッドへ。入力中のキャンセルに対応 |
| 早期打ち切り | サブシーケンス一致に失敗した時点で即座にスキップ |
| 想定処理時間 | 60,000 件の全件スキャンで数 ms オーダー |

---

## 7. UI 設計

### 7.1 呼び出しパネル

| 項目 | 仕様 |
| --- | --- |
| 種別 | `NSPanel`（`.nonactivatingPanel`、ボーダーレス、`level = .floating`） |
| 位置 | アクティブなスクリーンの中央上寄り。幅 720pt 程度 |
| 構成 | 上部に検索フィールド（`NSSearchField`）、下部に結果一覧（`NSTableView`） |
| 行の表示 | プレビュー本文（1〜2 行）、コピー元アプリ名、相対時刻 |
| 描画 | `NSTableView` のセル再利用による遅延描画。全件をメモリ展開しない |
| 本文の読み出し | 一覧は `preview_text` のみを使用。実データは選択確定時に `representations` から読む |

### 7.2 キー操作

| キー | 動作 |
| --- | --- |
| ホットキー（既定 ⌥⌘V） | パネルの表示 / 非表示トグル |
| ↑ / ↓ , ⌃P / ⌃N | 選択移動 |
| Enter | 確定（クリップボードへ書き戻してパネルを閉じる） |
| Esc | キャンセルして閉じる |
| フォーカス喪失 | 自動的に閉じる |

### 7.3 フォーカス制御

1. ホットキー受信時に `NSWorkspace.shared.frontmostApplication` を保持
2. `NSApp.activate(ignoringOtherApps: true)` でパネルをキーウィンドウにする（テキスト入力を確実に受けるため）
3. パネルを閉じる際、保持していたアプリを `activate()` で復帰させる
4. 利用者はそのまま ⌘V

### 7.4 メニューバー

最小限の項目のみ。優先度は低い。

- 履歴パネルを開く
- 設定
- 履歴を全消去
- 終了

---

## 8. 履歴上限とメンテナンス

| 項目 | 仕様 |
| --- | --- |
| 上限 | 件数基準。既定 10,000 件、設定で最大 100,000 件まで |
| 対象外 | `pinned = 1` のレコード |
| 実行タイミング | 起動時、および 1 時間ごと（挿入ごとには実行しない） |

### 8.1 パージ処理

1. `pinned = 0` を `created_at DESC` で並べ、上限件数の位置の `created_at` をカットオフとして取得
2. カットオフより古い `pinned = 0` のレコードを削除（`representations` は `ON DELETE CASCADE`）
3. **BLOB GC**: `blobs` ディレクトリを走査し、`representations.file_path` から参照されていないファイルを削除
   （同一ハッシュを複数レコードが共有し得るため、参照が 0 になったものだけを対象とする）
4. インメモリ検索インデックスから削除済み id を除去
5. 定期的に `VACUUM`（起動時、かつ前回から一定期間経過時のみ）

---

## 9. セキュリティ / プライバシー

- 権限は**一切不要**（アクセシビリティ・画面収録・フルディスクアクセスのいずれも使わない）
- DB とヘルパーファイルは `~/Library/Application Support/<AppName>/` 配下（ユーザー権限のみで読める）
- パスワードマネージャ由来のデータは `org.nspasteboard.ConcealedType` により自動スキップ
- 履歴の暗号化は v1 では行わない（単一利用者のローカル運用のため）
- 「履歴を全消去」を必ず提供する

---

## 10. 設定項目（`UserDefaults`）

| キー | 既定値 | 説明 |
| --- | --- | --- |
| `pollingInterval` | 0.3 | 監視間隔（秒） |
| `maxItemCount` | 10000 | 履歴の保持件数上限（最大 100000） |
| `hotKey` | ⌥⌘V | 呼び出しホットキー |
| `maxTextBytes` | 5 MB | これを超えるテキストは保存しない |
| `resultLimit` | 200 | 一覧に表示する最大件数 |
| `inlineBlobThreshold` | 64 KB | この値以下は DB 内 BLOB、超過は外部ファイル |
| `skipConcealed` | true | 機密フラグ付きデータをスキップ |

---

## 11. 実装フェーズ

| フェーズ | 内容 | 完了条件 |
| --- | --- | --- |
| 0 | プロジェクト雛形、`LSUIElement` 設定、メニューバー常駐 | メニューバーに常駐し終了できる |
| 1 | `ClipboardMonitor` + `HistoryStore`（テキストのみ） | コピーが DB に蓄積される |
| 2 | `HotKeyManager` + パネル表示 + 最新順一覧 + 選択で書き戻し | ホットキーで選び、⌘V で貼れる |
| 3 | `SearchIndex`（fzf ライク検索、逐次絞り込み） | 60,000 件でも入力が引っかからない |
| 4 | パージ / BLOB GC / 設定画面 | 上限を超えても DB が肥大しない |
| 5（将来） | 画像・ファイル対応、ピン留め UI、古い重複の圧縮 | — |

v1 のスコープはフェーズ 0〜4。データスキーマのみ最初から多型対応としておく。

---

## 12. 想定リスクと対応

| リスク | 対応 |
| --- | --- |
| ポーリングによる常時 CPU 消費 | `changeCount` 参照は極めて軽量。`Timer.tolerance` で省電力化。実データ読み出しは変化時のみ |
| 巨大テキストのコピーでメモリを消費 | `maxTextBytes` で上限を設け、超過分は保存しない |
| `RegisterEventHotKey` が Carbon 由来（非推奨扱い） | 現行 macOS で動作継続中。権限不要という利点が大きいため採用。将来問題化すれば `CGEventTap`（権限必要）へ切替 |
| ホットキーが他アプリと衝突 | 設定で変更可能にする。登録失敗時は通知する |
| インメモリインデックスと DB の不整合 | 追記・削除を `HistoryStore` 経由に一本化。異常時は起動時の全ロードで回復 |
| 検索が入力に追従できない | バックグラウンド走査＋キャンセル、逐次絞り込み、上位 200 件のみ描画で担保 |
| コピー元アプリの誤判定 | frontmost アプリは近似値。表示は参考情報と割り切る |
