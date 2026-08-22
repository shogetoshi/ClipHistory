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
| 画像・ファイルの内容による検索 | 画像の取り込み・プレビュー・書き戻しは対応済み（Issue 0004）。検索対象は説明テキスト（例: `"[Image] PNG 1920×1080"`。日本語入力に切り替えずに検索できるよう英字にしている）のみで、画像の内容そのものによる検索は非スコープのまま。ファイルは未対応のまま |
| リッチテキスト（書式付きテキスト） | 取り込み・保存・書き戻しの対象はプレーンテキストと画像のみとする。書式付き表現（RTF / HTML / RTFD / webarchive / PDF / アプリ固有型）は保存しない。理由は 13.4 |
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
| `AppDelegate` | アプリのライフサイクル、多重起動チェック、設定ウィンドウ、破壊的操作の確認 |
| `AppComponents` | 各コンポーネントの生成と結線（合成ルート） |
| `StatusItemController` | メニューバーアイコンとメニュー項目。選択をコールバックで通知するのみ |
| `ClipboardMonitor` | `NSPasteboard.changeCount` のポーリング、新規項目の検出と正規化 |
| `HistoryStore` | SQLite への読み書き、パージ、BLOB ファイル管理 |
| `SearchIndex` | インメモリ検索インデックスの保持と fzf ライクな絞り込み |
| `HotKeyManager` | グローバルホットキーの登録・解除、パネル表示のトリガ |
| `PickerPanelController` | 検索パネルの表示制御、フォーカス復帰、選択確定処理 |
| `PickerViewController` | 検索フィールドと結果一覧（`NSTableView`）の描画とキー操作の受け付け |
| `PickerViewModel` | 一覧の状態（検索結果・デバウンス・行の表示文字列の組み立て） |
| `PreviewPaneView` | プレビューペインの描画（テキストと画像の排他表示） |
| `PreviewContentLoader` | プレビュー内容を `HistoryStore` から解決する |
| `NvimEditModeController` | nvim 編集モードのライフサイクル |
| `Settings` | `UserDefaults` ベースの設定管理 |
| `Config` | TOML 設定ファイルの読み込み（`TOMLParser` を使う） |
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

`kind` の CHECK 制約は `'file'` / `'rtf'` も許可しているが、**実際に生成されるのは `'text'` と `'image'` のみ**である
（13.4）。将来スキーマ変更なしに拡張できる余地として残しているだけで、該当するレコードは存在しない。
Swift 側の `ItemKind` は Issue 0010 のリファクタリングで `.text` / `.image` のみに絞った。
DB の CHECK 制約はマイグレーションが不要な上位互換なのでそのまま残している。

### 4.3 容量見積り

テキスト平均 1 KB として 60,000 件で約 60 MB。SQLite にとって十分小さい。
インメモリ検索インデックスは 1 件あたり約 200〜600 バイト（`search_key` 120 文字 + メタ）で、
60,000 件で **12〜36 MB** 程度。

### 4.4 重複の扱い

**直前（最新 1 件）と同一内容のコピーは登録しない**。同じ内容が連続して履歴に並ぶのを避けるためで、
判定は `ClipboardMonitor` が新規登録の直前に `HistoryStore.latestContentHash()` と比較して行う。

一方、**離れた位置での重複は別レコードとして保存する**（履歴の時系列を壊さない）。
比較対象を直前 1 件に限るのはこのためであり、過去データ全体の重複を掃除することはしない。

判定用のハッシュはメモリにキャッシュせず、毎回 DB へ問い合わせる。再起動後や「履歴を全消去」後に
古い状態が残って登録が誤って抑制されるのを避けるためで、コピー操作 1 回あたり
`idx_items_created_at` を使う 1 クエリだけなのでコストは無視できる。

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
| 過大 | テキストが `maxTextBytes`（既定 5 MB）を超える、または画像が `maxImageBytes`（既定 20 MB）を超える（いずれも設定可能） |
| 直前と同一内容 | 主表現の SHA-256 が最新 1 件の `content_hash` と一致（設計書 4.4） |

### 5.2 取得情報

- 本文（テキスト優先）: まず `public.utf8-plain-text` を確認し、取得できて空白のみでなければテキストとして保存する。テキストが使えない場合に限り、画像 UTI（`PasteboardImageType.orderedUTIs`: `public.png` → `public.jpeg` → `public.tiff` の優先順）を順に確認し、最初に非空データが取れた1表現のみを画像として保存する。リッチテキストのコピーはテキストと画像表現を同時に持つことがあるため、テキスト優先とすることで従来通りテキストとして扱う（この方針を最終決定とした根拠は 13.4）
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
| デバウンス | 40 ms |
| 実行スレッド | **メインスレッド同期実行**（下記の実測により非同期化は不要と判断） |
| 早期打ち切り | サブシーケンス一致に失敗した時点で即座にスキップ |
| 実測処理時間 | 60,000 件・リリースビルドで、1文字クエリ（約37,000件ヒット）**約10ms**／複合語 約6ms／不一致 約2ms |

実測にあたり2点の最適化が必須だった（いずれも性能ゲート16msを大幅超過したため）。

- 語頭・キャメルケース境界の判定に `Unicode.Scalar.properties`（Unicode一般カテゴリ表の参照）を使うと同条件で**約1.4秒**。整数範囲比較による自前ヒューリスティックに置換
- DP のホットループを `Array` 添字（境界チェック付き）で回すと約56ms。`UnsafeBufferPointer` / `UnsafeMutableBufferPointer` 経由に置換

---

## 7. UI 設計

### 7.1 呼び出しパネル

| 項目 | 仕様 |
| --- | --- |
| 種別 | `NSPanel`（`.nonactivatingPanel`、ボーダーレス、`level = .floating`。`styleMask` に `.resizable` を追加し、`isMovableByWindowBackground = true` としてマウスでの移動・リサイズに対応する） |
| 位置・大きさ | `UserDefaults`（`panelFrame`）に保存した位置・大きさがあれば復元し、無ければ既定配置（アクティブなスクリーンの中央上寄り、720×420pt 程度）を使う。いずれもアクティブなスクリーンの `visibleFrame` に収まるようクランプしてから適用する |
| サイズの安定 | 一覧・プレビュー各ビューの content compression resistance / content hugging を `.defaultLow` に下げ、内容の固有サイズによる拡大を抑止する。保険として `contentMinSize`（480×320）と `contentMaxSize`（アクティブなスクリーンの `visibleFrame` に追従）も設定する |
| 構成 | 下部に検索フィールド（`NSSearchField`）。上部は左右分割し、左に結果一覧（`NSTableView`、55%）、右にプレビューペイン（45%）を配置する。中央の間隔は 12pt。比率は `NSLayoutConstraint` の multiplier で表現し、`NSSplitView` は使わない |
| 並び順 | 一覧は最新（検索時は関連度が最上位のもの）を最下行に表示する。`ResultsProvider` は最新順（先頭が最上位）で返すため、`PickerViewModel` 側で反転して保持する。結果の再読み込み時の既定選択は最終行とし、その行までスクロールする |
| 行の表示 | プレビュー本文（1〜2 行）、コピー元アプリ名、相対時刻 |
| プレビュー | 読み取り専用の `NSTextView`（`NSScrollView` 内、`NSBox` で枠を描く）。フォントは等幅。一覧行が改行・連続空白を半角スペース1個に畳んだ1行表示（`DisplayText.singleLine`）なのに対し、プレビューは改行をそのまま描画する |
| 描画 | `NSTableView` のセル再利用による遅延描画。全件をメモリ展開しない |
| 背景 | 不透明（`windowBackgroundColor`）の角丸ビューで描く。半透明にはしない。`contentViewController` の代入で `contentView` が置き換わるため、背景はパネルではなくルートビュー側（`PanelBackgroundView`）が描く |
| 本文の読み出し | 一覧は `preview_text` のみを使用。プレビューと選択確定時は `representations` から読む。プレビューは `HistoryStore.loadPreviewText(itemID:maxCharacters:)` で `public.utf8-plain-text` の実データを上限 4,000 文字まで読み直す（`preview_text` は一覧用に先頭 200 文字で打ち切っているためプレビューの用途を満たせない）。テキスト表現が無い場合は `preview_text` をフォールバック表示する。選択項目が `kind == .image` の場合は、`HistoryStore.loadPreviewImageData(itemID:)`（`PasteboardImageType.orderedUTIs` の優先順で1件を選び、切り詰めずに実データ全体を返す）で読み出した画像をプレビュー表示する |

**左右分割にした理由**

パネルの高さが限られており、上下に分割すると結果一覧の可視行数が半減し選択操作がしづらくなる。そのため左右分割とし、一覧の可視行数を確保した。

**検索窓を下に、最新を最下行にした理由**

履歴は新しいものほど参照頻度が高い。検索窓を下端に置き、その直上に最新（＝最有力候補）を並べることで、視線と指の移動距離が最小になる（`fzf` の既定レイアウトと同じ考え方）。

**一覧とプレビューの役割の違い**

一覧行は改行・連続空白を半角スペース1個に畳んで1行で表示し、多数の候補を一目で見比べられるようにする。プレビューは改行をそのまま描画し、コピーしたコードや設定ファイルのインデント・桁位置を崩さない。

**更新契機**

プレビューは `NSTableViewDelegate.tableViewSelectionDidChange`、および結果の再読み込み後に更新する。`selectRowIndexes` は選択が実際に変わらない場合に通知を発火しないため、再読み込み後は明示的に更新する。

**画像対応との関係**

プレビューは `previewBox` 内に `NSImageView` を `NSScrollView`（テキスト）と同じ領域へ重ねて配置し、選択項目が `kind == .image` のときは画像、それ以外はテキストを表示する排他切り替えとした。画像データの読み出しは `HistoryStore.loadPreviewImageData(itemID:)` を使い、取得・生成に失敗した場合はテキストプレビュー（`loadPreviewText` → なければ `preview_text`）へフォールバックする。一覧行の表示（`HistoryItemCellView`）はテキストのままで、行にサムネイルは出さない。

**内容の長さでウィンドウが変わらないようにした理由**

`contentViewController` を持つウィンドウでは、ウィンドウサイズ自体が Auto Layout 上の変数として扱われ、「現在のサイズに留まろうとする」制約の優先度は `NSLayoutPriority.windowSizeStayPut`（500）しかない。一方コンテンツ側の content compression resistance は既定 750 と高いため、長いテキストや大きな画像で内容の固有サイズが大きくなるとウィンドウが押し広げられてしまう。そのため一覧・プレビュー各ビューの content compression resistance と content hugging をいずれも `.defaultLow`（250）へ下げ、押し広げの起点を断った。

### 7.2 キー操作

| キー | 動作 |
| --- | --- |
| ホットキー（既定 ⌥⌘V） | パネルの表示 / 非表示トグル |
| ↑ / ↓ , ⌃P / ⌃N | 選択移動 |
| Enter | 確定（クリップボードへ書き戻してパネルを閉じる） |
| Esc | キャンセルして閉じる。フォーカスの位置に関わらず効く（`PickerViewController` が `cancelOperation(_:)` をレスポンダチェーンで受ける） |
| ⌘E | 選択中のテキスト項目を nvim で編集（7.5） |
| ⌘↩ | nvim 編集の確定（編集モード中のみ） |
| ⌘. | nvim 編集の破棄（編集モード中のみ） |
| フォーカス喪失 | 自動的に閉じる（nvim 編集モード中は閉じない） |

nvim 編集モード中は Esc を含む全キーを nvim へ流すため、脱出は nvim が受け取らない ⌘系に割り当てる。
⌘系のキー等価は `PanelBackgroundView.performKeyEquivalent(with:)` でビュー階層の探索より先に
横取りし、検索フィールド／ターミナルのどちらにフォーカスがあっても確実に受け取る。

### 7.3 フォーカス制御

1. ホットキー受信時に `NSWorkspace.shared.frontmostApplication` を保持
2. `NSApp.activate(ignoringOtherApps: true)` でパネルをキーウィンドウにする（テキスト入力を確実に受けるため）
3. パネルを閉じる際、保持していたアプリを `activate()` で復帰させる
4. 利用者はそのまま ⌘V

**フォーカス復帰を行う経路の限定**（重要）

復帰させるのは「Esc」「確定（Enter）」「ホットキー再押下」という**明示的な閉じ操作**のときだけとする。
利用者が他アプリをクリックして閉じた場合（`windowDidResignKey`）に復帰処理を走らせると、
利用者が今クリックしたアプリからフォーカスを奪い返してしまうため、この経路では復帰させない。

### 7.4 メニューバー

最小限の項目のみ。優先度は低い。

- 履歴パネルを開く
- 設定
- 履歴を全消去
- 終了

### 7.5 プレビューの nvim 編集

`⌘E` で、選択中のテキスト項目を**本物の nvim**（利用者の `~/.config/nvim` がそのまま読まれる）で
編集し、その結果をクリップボードへ書き戻せる。操作をエミュレートした Vim 風モードではない。

| 項目 | 仕様 |
| --- | --- |
| 描画 | `previewBox` の3層目として SwiftTerm の `LocalProcessTerminalView` を重ね、PTY 上で nvim を起動する（既存の `previewScrollView` / `previewImageView` の排他切り替えの延長）。別ウィンドウのターミナルは開かない |
| 起動契機 | **オンデマンド**。ブラウズ中は `previewTextView` のままとし、`⌘E` を押した項目だけターミナル層を前面に出す |
| 起動方法 | `/bin/zsh -l -c "exec <nvim絶対パス> --listen <sock> -- <一時ファイル>"`。nvim の絶対パスは初回に `/bin/zsh -l -c "command -v nvim"` で解決してプロセス内にキャッシュする。設定ファイル（10.2）があれば `export` / `--cmd` / `-c` が加わる |
| 編集対象 | `HistoryStore.loadFullText(itemID:)` で読んだ本文全体。`kind == .image` の項目は対象外 |
| レイアウト | 編集モード中は一覧を隠し、`previewBox` を全幅へ拡張する |
| 取り出し | `nvim --server <sock> --remote-expr 'writefile(getbufline(bufnr(<src>),1,"$"), <out>)'` を `Process` で叩く |
| 書き戻し | `public.utf8-plain-text` の**1表現のみ** |
| 終了時の挙動 | 利用者が nvim を終了したらパネルも閉じる。`:wq` など**保存して終了**した場合はその本文をクリップボードへ書き戻し、`:q` など**保存せず終了**した場合は何もしない |
| キーリピート | 起動時に `ApplePressAndHoldEnabled` をアプリのドメインで `false` にし、キー長押しのリピートがターミナルビューへ届くようにする |

**なぜ常時 nvim にしないか**

一覧を ⌃N/⌃P で流し見する体感を落とさないため。現状の `NSTextView.string` 代入は 1ms 未満だが、
nvim は lazy.nvim + coc の構成では起動に 200ms〜1秒かかる。常駐させて `edit!` でバッファを
差し替える方式でも `BufRead` 系 autocmd（filetype 判定 → treesitter → LSP attach）が毎回走り、
選択の高速移動に追従できない。オンデマンドにすることで起動コストを「編集する1項目・1回だけ」に限定した。

**なぜ msgpack-RPC を自前実装しないか**

nvim 自身が RPC クライアント（`--server` + `--remote-expr` / `--remote-send`）になれるため、
`Process` で叩くだけで編集中バッファの内容を取り出せる。`--embed` + 自前グリッド描画（VimR /
Neovide 方式）は工数が数週間規模になるため採らない。

**なぜ `getline` ではなく `getbufline(bufnr(...))` か**

nvim 側で利用者が別バッファを開いたり分割ウィンドウへ移動したりしていても、編集対象バッファの
内容を確実に取れるようにするため。**未保存でもバッファの内容が取れる**ため `:w` は不要。

**なぜテキスト1表現だけ書き戻すか**

元項目が RTF + プレーンテキストを持っていても、プレーンテキストを編集した時点で他表現は
編集内容と整合しなくなるため。`commit(_:)` の全表現書き戻しとはここが異なる。

**編集モード中の自動クローズ抑止**

`windowDidResignKey` による自動クローズを編集モード中は無効化する。無効化しないと、nvim が
外部プロセス（LSP サーバ等）を起こしたタイミングなどでパネルが閉じ、編集内容が失われる。
編集の終了は `⌘↩` / `⌘.`、および利用者が nvim を終了した場合（`processTerminated`）に限る。

**nvim を終了したときの挙動**

`processTerminated` の経路では、編集モードを抜けて履歴一覧へ戻るのではなく**パネルごと閉じる**。
nvim を終了する操作は利用者にとって「この項目の編集を終える」ことと同義であり、そこで一覧に
戻されると、⌘V するために改めて Esc を押す手間が生じるため。

保存の有無は**一時ファイルの更新日時の変化**で判定する（`NvimEditSession.savedText()`）。
更新日時が起動時から変わっていれば nvim が `:w` でファイルを書いたということなので、その内容を
クリップボードへ書き戻す。変わっていなければ何もせず閉じる。`⌘↩` の `--remote-expr` による
バッファ読み出しと違い、こちらは nvim が既に終了しており RPC で問い合わせる相手がいないため、
ディスク上のファイルを見る方式を採る。

**キー長押しのリピート**

macOS の press-and-hold（`ApplePressAndHoldEnabled`、既定 ON）が有効だと、`interpretKeyEvents`
経由で処理される**修飾なしキー**のキーリピートが抑止される。SwiftTerm の `TerminalView.keyDown`
は修飾なしキーを `interpretKeyEvents` に渡すため、nvim で `l` を長押ししても連続移動しなかった
（Issue 0008）。`⌃` 付きのキーは `interpretKeyEvents` を通らず直接送出されるためリピートが
効いていた。症状が「Vim の通常キーだけ効かない」形で現れたのはこのためである。press-and-hold は
プロセス単位でしか切り替えられないため、`main.swift` で `NSApplication` の生成前に
`UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")` を呼ぶ。登録ドメイン
（`register(defaults:)`）はグローバルドメインより後に参照されるため、利用者がグローバルに
設定していると効かない。アプリドメインならグローバルより優先される。副作用として、このアプリ内
では検索フィールドでもアクセント候補のポップアップが出なくなる。クリップボード検索欄では候補
入力の価値が薄いため許容する。

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
- nvim 編集（7.5）で使う一時ファイルは、パーミッション 0700 のセッションディレクトリに置き、
  読み取り直後に削除する。クリップボードには認証情報が入りうるため（`skipConcealed` と同じ理由）
- 履歴の暗号化は v1 では行わない（単一利用者のローカル運用のため）
- 「履歴を全消去」を必ず提供する

---

## 10. 設定項目

設定は2系統ある。アプリ自身が書き換える値は `UserDefaults`（10.1）に、利用者が手で書く値は
`~/.config/cliphistory/` 配下のファイル（10.2）に置く。

### 10.1 `UserDefaults`

| キー | 既定値 | 説明 |
| --- | --- | --- |
| `pollingInterval` | 0.3 | 監視間隔（秒） |
| `maxItemCount` | 10000 | 履歴の保持件数上限（最大 100000） |
| `hotKey` | ⌥⌘V | 呼び出しホットキー |
| `maxTextBytes` | 5 MB | これを超えるテキストは保存しない |
| `maxImageBytes` | 20 MB | これを超える画像は保存しない |
| `resultLimit` | 200 | 一覧に表示する最大件数 |
| `inlineBlobThreshold` | 64 KB | この値以下は DB 内 BLOB、超過は外部ファイル |
| `skipConcealed` | true | 機密フラグ付きデータをスキップ |
| `panelFrame` | なし | パネルの位置・大きさ。移動・リサイズ時に保存し、次回表示時に復元する。未保存時は既定配置を使う |

### 10.2 設定ファイル

利用者が手で編集する設定は `~/.config/cliphistory/` に置く（Issue 0011）。`UserDefaults` と分けたのは、
設定画面から書き換える値（10.1）と違い、こちらは**アプリが書き戻さない読み取り専用**の値であり、
エディタで直接開いて差分を追える形が望ましいため。

| 項目 | 仕様 |
| --- | --- |
| 場所 | `$XDG_CONFIG_HOME/cliphistory/`。`XDG_CONFIG_HOME` が未設定・空・相対パスの場合は XDG 仕様どおり `~/.config/cliphistory/` にフォールバックする |
| 不在時 | 何も置かなくても従来どおり動く。3つとも無ければ nvim の起動コマンドはこの機能を入れる前と完全に同一 |
| 不正時 | `NSLog` に行番号付きのエラーを残し、既定値で起動する。起動は止めない（13.3 と同じ方針） |
| 未知の項目 | エラーにせず無視する。将来項目を追加したとき、古いバイナリが新しい設定ファイルで壊れないようにするため |

置けるファイルは3つで、いずれも**有無だけで決まる**。

```
~/.config/cliphistory/
  ├── config.toml     ← アプリ本体の設定。プロセス起動時に1回だけ読む
  ├── init-pre.lua    ← 利用者の nvim 設定より「前」に走る
  └── init.lua        ← 利用者の nvim 設定より「後」に走る
```

| ファイル | nvim へ渡る形 | 走る位置 | 向いている用途 |
| --- | --- | --- | --- |
| `config.toml` の `[nvim.env]` | 起動コマンド先頭の `export` | nvim 起動前 | nvim が Lua を走らせる前に読む値（`XDG_*` 系など） |
| `init-pre.lua` | `--cmd 'lua dofile(...)'` | 利用者設定の**前** | `vim.env.PATH` の追加など、プラグイン・LSP の起動に間に合わせたい処理 |
| `init.lua` | `-c 'lua dofile(...)'` | 利用者設定の**後**（編集対象を開いた後） | オプション・キーマップの上書き |

`~/.config/nvim/` は3つとも読まれる前提を崩さない。このアプリ専用の設定を利用者の nvim 設定へ
書き込ませないことがこの節の目的である。

```toml
# config.toml
[nvim.env]
NVIM_CLIPHISTORY = "1"
```

```lua
-- init-pre.lua : このアプリから起動した nvim にだけ PATH を足す
vim.env.PATH = vim.env.PATH .. ":/opt/hoge/bin"
```

```lua
-- init.lua : クリップボード1件を編集する用途に寄せる
vim.opt.wrap = true
vim.opt.number = false
vim.keymap.set("n", "q", "<Cmd>qa<CR>")
```

`config.toml` はプロセス起動時に1回だけ読むため、変更の反映にはアプリの再起動が必要。`.lua` の2つは
セッションごとに有無を判定するため、置いた直後から効く。

**`[nvim.env]` に書いてはならない2つ**

| キー | 何が起きるか |
| --- | --- |
| `NVIM_APPNAME` | nvim が設定を読むディレクトリ自体が `$XDG_CONFIG_HOME/<値>/` へ切り替わる（既定値は `nvim`）。指定すると `~/.config/nvim/` が読まれず、利用者の nvim 設定が丸ごと外れる |
| `PATH` | 値はリテラルとして渡すため `PATH = "$PATH:/opt/hoge/bin"` と書いても展開されず、PATH が文字列 `$PATH:/opt/hoge/bin` に壊れる。PATH の追加は `init-pre.lua` で `vim.env.PATH` を使う |

どちらも実装中に実際に踏んだ。`[nvim.env]` の値は `export KEY='VALUE'` とシングルクォートで囲む、
つまり**リテラルとして渡す**のが仕様であり、シェル展開はしない。展開を許すには `export KEY="VALUE"` に
変える必要があるが、それだと `$(...)` やバックティックのコマンド置換まで通ってしまう。安全性を保つには
「`$NAME` と `${NAME}` 以外は拒否」といった検証を抱えることになり、記法が複雑になる。前段設定があれば
`vim.env.PATH = vim.env.PATH .. ":/opt/hoge/bin"` と Lua で書けてシェルのクォートが一切絡まないため、
この複雑さを持ち込まない。

結果として `[nvim.env]` の出番は狭い。任意の環境変数は `vim.env.FOO` で書けるため、残る用途は nvim が
Lua を走らせる前に読む値に限られる。新しく何か渡すなら前段設定に書く方がよい。

**なぜ環境変数だけでは足りず `.lua` を置けるようにしたか**

`[nvim.env]` で目印を渡せても、それを読む分岐は利用者の `~/.config/nvim/init.lua` に書くしかない。
「このアプリからの呼び出しにだけ効く設定」がそこに入るのは nvim 本来の領域を侵すことになり避けたい。
nvim 側の既存の仕組みで済ませられないかも検討したが、いずれも成立しなかった。`NVIM_APPNAME` は
設定ディレクトリを**差し替える**変数なので `~/.config/nvim/` が読まれなくなる。`$XDG_CONFIG_DIRS/nvim` は
素の nvim では `runtimepath` に入るものの、lazy.nvim が `runtimepath` を作り直すため実環境では消えることを
実測で確認した。結局、起動コマンドを組み立てている本アプリ側で読ませるのが確実である。

**なぜ前段と後段の2段か**

役割が違い、片方では両方の用途を満たせないため。`-c`（後段）は利用者設定を評価し編集対象ファイルを
開いた後に走るのでオプション・キーマップの上書きが確実に効く。一方 PATH の追加はこれでは間に合わない。
PATH は lazy.nvim や coc が**起動時に実行ファイルを探すのに使う値**であり、`-c` の時点でその処理は
終わっている。`--cmd` が利用者設定より前に走ることは実測で確認した（前段で `wrap` を立てても、後から
利用者設定が `nowrap` に戻すため最終値が `0` になる）。

**なぜ `luafile` ではなく `dofile` か**

`luafile <パス>` はパスを Ex コマンドの引数として渡すため、空白・`|`・`%`・`#` などを含むパスで
エスケープ規則が煩雑になる。Lua の文字列リテラルへ入れれば `\` と `"` の2文字をエスケープするだけで済む。

**なぜ TOML ライブラリを追加しないか**

外部依存は SwiftTerm 1件のみという方針（13.1）を維持するため、`TOMLParser` として最小サブセット
（行コメント・`[table]` / `[a.b]` のテーブルヘッダ・`key = "基本文字列"`）だけを自前実装した。
設定項目は文字列から文字列への写像しかなく、数値・真偽値・配列・インラインテーブルを解釈する必要がない。
未対応の構文は行番号付きでエラーにするため、将来足りなくなったときに黙って誤読するのではなく気づける。

---

## 11. 実装フェーズ

| フェーズ | 内容 | 完了条件 |
| --- | --- | --- |
| 0 | プロジェクト雛形、`LSUIElement` 設定、メニューバー常駐 | メニューバーに常駐し終了できる |
| 1 | `ClipboardMonitor` + `HistoryStore`（テキストのみ） | コピーが DB に蓄積される |
| 2 | `HotKeyManager` + パネル表示 + 最新順一覧 + 選択で書き戻し | ホットキーで選び、⌘V で貼れる |
| 3 | `SearchIndex`（fzf ライク検索、逐次絞り込み） | 60,000 件でも入力が引っかからない |
| 4 | パージ / BLOB GC / 設定画面 | 上限を超えても DB が肥大しない |
| 5 | 画像対応（完了）。ファイル対応・ピン留め UI・古い重複の圧縮は将来 | 画像をコピーすると取り込み・プレビュー・書き戻しができる |

v1 のスコープはフェーズ 0〜4。データスキーマのみ最初から多型対応としておく。画像対応は Issue 0004 でフェーズ 5 として追加実装した。

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
| 多重起動によるホットキー登録失敗 | Carbon のホットキーはシステム全体で排他。起動直後に同一バンドル識別子の他インスタンスを検出し、何も初期化せず即終了する |
| 起動処理中の同期モーダルによる全体停止 | 下記「13. 実装中に確定した決定事項」参照 |

---

## 13. 実装中に確定した決定事項と既知の制約

### 13.1 ビルド・依存

| 項目 | 決定 |
| --- | --- |
| ビルド方式 | SwiftPM の実行可能ターゲット + `Makefile` で `.app` バンドルを組み立て、ad-hoc 署名。`.xcodeproj` は作らない |
| 外部依存 | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 のみ。他は `SQLite3` / AppKit / SwiftUI / Carbon / CryptoKit などOS同梱。当初は「ゼロ」を方針としていたが、プレビューを本物の nvim で編集する要件（7.5）は PTY を張ったターミナルエミュレータ無しには満たせず、自前実装は工数が見合わないため Issue 0006 でこの1件だけ受け入れた |
| 言語モード | `swift-tools-version:6.0` + `swiftLanguageMode(.v5)`（strict concurrency は使わない） |
| 最低OS | macOS 13 (Ventura) |
| テスト | Swift Testing（`import Testing`）。対象はAppKit非依存の純ロジック |

### 13.2 UI と検索の分離

UI（`PickerViewController`）は `ResultsProvider` プロトコルにのみ依存させる。

```swift
public protocol ResultsProvider {
    func results(for query: String, limit: Int) throws -> [HistoryItem]
}
```

この継ぎ目のおかげで、開発中は最新順のみを返す実装から `SearchResultsProvider`（`SearchIndex` による
fzf 検索）へ UI 無変更で差し替えられた。

役目を終えた最新順の実装（`RecentResultsProvider`）は Issue 0010 で削除し、現在の実装は
`SearchResultsProvider` の1つのみ。プロトコルは絞り込みロジックを UI から切り離す境界として残している。

Issue 0010 では `PickerViewController` をさらに分割した。一覧の状態は `PickerViewModel`、プレビューは
`PreviewPaneView`（描画）と `PreviewContentLoader`（内容の解決）、nvim 編集モードは
`NvimEditModeController` が担い、`PickerViewController` にはビューの組み立てとキー操作の受け付けだけが
残る。同様に `AppDelegate` からもメニューバーUI（`StatusItemController`）と各コンポーネントの生成・
結線（`AppComponents`）を分離した。これらはいずれも責務の分割のみで、画面の見え方・キー操作・
保存されるデータに変更はない。

### 13.3 起動処理では同期モーダルを使わない

**実際に事故が起きたため、明確に禁止事項とする。**

ホットキー登録失敗時に `NSAlert.runModal()` を起動処理内で呼ぶと、メインスレッドが停止し、
ホットキーだけでなく `ClipboardMonitor` のポーリングまで止まる。さらに `LSUIElement` の
アクセサリアプリではこのアラートが前面化しないため、**画面には何も見えないまま完全に無反応**という
最悪の症状になる。

代替として、失敗時はステータスアイコンを `⚠️` に変え、選択不可のエラー内容表示項目と
「ホットキーを再登録」項目をメニューに出す（すべて非ブロッキング）。
利用者操作起点のモーダル（「履歴を全消去」の確認など）は問題ないため許容する。

### 13.4 リッチテキストを扱わない

**決定**: 取り込み・保存・書き戻しの対象は `public.utf8-plain-text` と画像 UTI
（`PasteboardImageType.orderedUTIs`）のみとする。`public.rtf` / `public.html` /
`com.apple.flat-rtfd` / `com.apple.webarchive` / `com.adobe.pdf` およびアプリ固有型は保存しない。

判断にあたり、Word から装飾付きテキスト5行＋画像1枚をコピーした実データを計測した。

| 表現 | サイズ | 内容 |
| --- | --- | --- |
| `public.utf8-plain-text` | 71 B | 書式・画像なし |
| `com.apple.flat-rtfd` | 59 KB | 書式 ＋ PNG 42,872 B を添付として内包。自己完結 |
| `com.adobe.pdf` | 60 KB | レイアウト込み |
| `com.microsoft.Embed-Source` | 59 KB | Word 内部形式のスナップショット |
| `public.html` | 100 KB | フォント名が原文どおり。画像は `data:` URI で埋め込み |
| `com.apple.webarchive` | 100 KB | HTML ＋ 参照リソース一式 |
| `public.rtf` | 219 KB | フォント定義 122 個、`themedata` / `latentstyles` 等を含む |
| その他 9 表現（Word 固有型ほか） | 計 約 0.6 KB | うち 1 件は 0 バイト（後述） |
| **合計 16 表現** | **約 600 KB** | |

見送りの理由。

1. **容量**。1 コピーで約 600 KB。履歴上限 60,000 件では現実的な規模にならない。テキストのみなら
   同条件で約 60 MB（4.3）であり、3 桁の差がある。本アプリは件数基準で 60,000 件以上を扱うことを
   前提にしている（1.1）ため、ここは譲れない
2. **貼り付け先が受け取れるとは限らない**。同一のコピーを貼り付けて比較したところ、Notion と Obsidian は
   どちらも `public.html` を読んでいるのに結果が異なった。Notion は画像が落ち、フォントサイズと
   フォント名も失われた（Notion のインライン注釈モデルにこれらの概念が無いため）。Obsidian は
   `data:` URI を Markdown 本文へ文字列としてそのまま書き写した。保存側が何を持っていても、
   再現性は貼り付け先の実装に支配される
3. **完全な復元は原理的に不可能**。高再現度の経路は参照方式であることが多い。Word は
   `com.microsoft.ole.source.<pid>.<アドレス>` という **0 バイトの型**を載せており、これはデータでは
   なく実行中の Word プロセスへのハンドルである。履歴経由で後から書き戻す時点では必ず失効している
   ため、Word → Word であっても自己完結表現へのフォールバックになり、段落番号の連番・相互参照・
   コメントなど文書スコープの文脈は失われる
4. **目的との整合**。本アプリの責務は「これから貼り付けるデータを選択する機能」（1章）であり、
   書式の忠実な保存は主目的ではない

**維持する挙動**: 取り込みは従来どおりテキスト優先（5.2）。リッチテキストのコピーは
プレーンテキスト表現のみを保存する。テキスト表現が使えない場合に限り画像として取り込む。
利用者から見れば Word からのコピーもプレーンテキストとして履歴に入る。

**この決定により不要になった設計課題**: 書き戻し時の表現の優先順序（`fetchRepresentations` に
`ORDER BY` が無く挿入順依存である点を含む）、遅延提供型の実体化、0 バイト表現の除外判定、
複数 `NSPasteboardItem`（Finder での複数ファイルコピー等）に対応するスキーマ拡張、
RTF / HTML のプレビュー描画。いずれもリッチテキスト対応に伴ってのみ発生する課題であり、
本決定によって検討対象から外れる。

### 13.5 既知の制約

| 制約 | 内容 |
| --- | --- |
| キャメルケース境界の加点が実データで発火しない | `search_key` は保存時に小文字化されるため、実運用データでは大文字小文字の情報が失われる。`FuzzyMatcher` は汎用スコアラーとして境界加点を実装しているが、実際に効くのは区切り記号による語頭一致のみ。順位付けへの影響は限定的と判断し許容 |
| 語頭判定のUnicode網羅性 | 性能上の理由でUnicode一般カテゴリを参照せず、ASCII範囲比較＋日本語の代表的な区切り記号のみを非単語文字として扱う。他言語の句読点は語頭として認識されない |
| ホットキーの変更UI | 設定画面ではホットキーを読み取り専用表示とし、キー入力を記録するレコーダUIはv1のスコープ外 |
| nvim 編集モードの日本語 IME | `.nonactivatingPanel` 上の SwiftTerm で日本語 IME が期待どおり動くかは未検証。動かない場合でも英数の編集は成立するため、v1 では制約として残す |
| GUI操作の自動検証 | パネル表示・キー操作・書き戻しといった対話的挙動は、ターミナルにアクセシビリティ権限がないため自動検証できない。合成キー送出は利用者のフォーカスを奪うため行わない。**手動確認が必要な領域として残る** |
