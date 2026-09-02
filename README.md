# ClipHistory

macOS 用のクリップボード履歴アプリ。メニューバーに常駐し、グローバルホットキーで呼び出したパネルから
**fzf ライクな曖昧検索**で過去のコピーを探してクリップボードへ書き戻します。

貼り付け操作そのものは OS 標準の ⌘V に委ね、このアプリは
**「これから貼り付けるデータを選択する機能」** に責務を限定しています。

[![CI](https://github.com/shogetoshi/ClipHistory/actions/workflows/ci.yml/badge.svg)](https://github.com/shogetoshi/ClipHistory/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![license](https://img.shields.io/badge/license-MIT-blue)

## 特徴

- **fzf 方式の曖昧検索** — サブシーケンス一致 + 語頭 / 連続一致の加点によるスコア順表示。全件インメモリスキャンなので取りこぼしがない
- **ターミナル風の UI** — 等幅フォント・ダーク固定。検索欄は最下部、最新の履歴が最下行（fzf と同じレイアウト）
- **プレビュー** — 右ペインに行番号付き・折り返しなしで全文表示。コードや設定ファイルの桁位置が崩れない
- **nvim で編集してから貼り付け** — ⌘E で選択項目を本物の Neovim（パネル埋め込みのターミナル）で編集し、確定した内容をクリップボードへ書き戻す
- **パネルを開かない前後移動** — ⌃⌘P / ⌃⌘N でクリップボードを履歴の1個前 / 1個後へ差し替え、内容を HUD で通知
- **連続貼り付け** — ⌃⌘V で「貼り付け → 1個前へ」を繰り返す（この機能のみアクセシビリティ権限が必要）
- **複数選択** — Tab で印を付けた複数の履歴を、印を付けた順に改行で結合して1回で貼り付け
- **画像対応** — 画像のコピーも履歴に保存し、プレビュー表示・書き戻しができる
- **Snippet 機能** — クリップボード履歴とは別のホットキーで開く2つ目のピッカー。`config.toml` の `[snippet]` で指定したディレクトリ配下の Markdown（`### 見出し` ごとに1アイテム）を検索・プレビューし、最初のコードブロックだけを貼り付けられる。クリップボード履歴とは上下が逆で、検索欄が最上部・アイテムは上から下に並ぶ
- **プライバシー** — パスワードマネージャ由来のデータ（`org.nspasteboard.ConcealedType`）は自動でスキップ。履歴はローカルの SQLite のみに保存し、外部へ送信しない
- **軽量** — 履歴 10,000 件（設定で最大 100,000 件）を扱える。外部依存は [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1 件のみ

## 動作環境

| 項目 | 要件 |
| --- | --- |
| OS | macOS 13 (Ventura) 以降 |
| ビルド | Xcode Command Line Tools（Swift 6.0 以降） |
| Neovim | 任意。nvim 編集機能（⌘E / ⌃⌘⇧C）を使う場合のみ必要。`PATH` 上に `nvim` があれば自動で検出します |

Apple Developer Program の証明書は不要です（公証されたバイナリの配布は行っておらず、各自でビルドします）。

## インストール

### 1. 取得

```sh
git clone https://github.com/shogetoshi/ClipHistory.git ClipHistory
cd ClipHistory
```

### 2. 署名用の証明書を作る（推奨）

```sh
./scripts/setup-signing-cert.sh
```

自己署名のコード署名証明書 `ClipHistory Dev` をログインキーチェーンに作成します。
省略しても ad-hoc 署名でビルドできますが、その場合は**再ビルドのたびにアクセシビリティ権限の許可が失効**します
（ad-hoc 署名では署名要件がバイナリのハッシュに紐づくため）。連続貼り付け（⌃⌘V）を使うなら実行してください。

このスクリプトが失敗した場合は証明書が作られず、`make app` は ad-hoc 署名にフォールバックします（警告が出ます）。
その状態でアクセシビリティ権限を許可してしまうと下記「許可しても『設定を促される』ままの場合」の状態になるため、
先に証明書を作ってからビルドしてください。

### 3. ビルドして起動

```sh
make run     # .app を組み立てて署名し、起動する
```

`.build/ClipHistory.app` が生成され、起動するとメニューバーにアイコンが出ます。
`make app` はビルドのみ、`make build` は実行バイナリのみを作ります。

常用する場合は `.app` を `/Applications` へコピーし、
**システム設定 → 一般 → ログイン項目** に追加してログイン時に自動起動させると便利です
（開発中は `.build` 配下のまま `scripts/restart.sh` で再起動するのが手軽です）。

### 4. 権限（連続貼り付けを使う場合のみ）

⌃⌘V の連続貼り付けは ⌘V のキーイベントを合成するため、アクセシビリティ権限が必要です。
初回に ⌃⌘V を押すと macOS 標準の許可ダイアログが出るので、
**システム設定 → プライバシーとセキュリティ → アクセシビリティ** で ClipHistory を許可してください。

それ以外の機能（履歴の取り込み・検索・書き戻し・ホットキー・nvim 編集）は**権限なしで動作**します。
画面収録・フルディスクアクセスは使いません。

#### 許可しても「設定を促される」ままの場合

ad-hoc 署名でビルドしたアプリで一度権限を許可した後に手順2の証明書へ切り替えると、
macOS が記録している署名要件と実際のアプリが一致しなくなり、権限が無効になります。
このとき、**システム設定のスイッチを ON / OFF しても記録は更新されないため復旧しません**。
エントリごと削除して登録し直してください。

```sh
osascript -e 'quit app "ClipHistory"'
tccutil reset Accessibility local.cliphistory.app
```

そのうえで **システム設定 → プライバシーとセキュリティ → アクセシビリティ** を開き、
ClipHistory の行が残っていれば **「−」ボタンで削除**します（ON / OFF ではなく削除です）。
アプリを起動し直して ⌃⌘V を押すと、改めて許可ダイアログが出ます。

証明書で署名していれば、以降は再ビルドしても権限は維持されます。

## 使い方

### グローバルホットキー

ホットキーは `~/.config/cliphistory/config.toml` の `[hotkey]` で設定します。**設定を書かないとそのホットキーは一切使えません**（既定値へのフォールバックはありません）。以下は代表的な設定例と、その場合の動作です。

| `config.toml` の設定 | 動作 |
| --- | --- |
| `toggle_panel = "ctrl+command+c"` | 履歴パネルの表示 / 非表示（⌃⌘C） |
| `cycle_previous = "ctrl+command+p"` | パネルを開かず、クリップボードを履歴の1個前へ差し替える（⌃⌘P） |
| `cycle_next = "ctrl+command+n"` | パネルを開かず、クリップボードを履歴の1個後へ差し替える（⌃⌘N） |
| `paste_and_cycle_previous = "command+ctrl+v"` | 今の内容を貼り付け、クリップボードを1個前へ進める（連続貼り付け、⌘⌃V） |
| `direct_vim_edit = "command+ctrl+shift+c"` | パネルを開かず、今のクリップボードの内容を nvim で編集する（⌘⌃⇧C） |
| `toggle_snippet_panel = "ctrl+command+s"` | Snippet パネルの表示 / 非表示（クリップボード履歴とは別のホットキー） |

設定方法の詳細（キー名の一覧・書式）は下記「設定ファイル」を参照してください。

### パネル内のキー操作

| キー | 動作 |
| --- | --- |
| 文字入力 | 曖昧検索で絞り込み |
| ↑ / ↓ , ⌃P / ⌃N | 選択移動 |
| Enter | 確定（クリップボードへ書き戻して閉じる） |
| Esc | キャンセルして閉じる |
| Tab | 選択行に複数選択の印を付け / 外し、選択を1つ下（未来方向）へ移す |
| ⇧Tab | 同じく印をトグルし、選択を1つ上（過去方向）へ移す |
| ⌘E（`config.toml`の`[hotkey]`の`edit_in_nvim`で設定。既定は`"command+e"`） | 選択項目（印がある場合は結合後のテキスト）を nvim で編集 |
| `config.toml`の`[hotkey]`の`edit_snippet_source`で設定（例は`"command+shift+e"`） | Snippet パネルで、選択項目の元になった `.md` ファイル本体をその見出し行にカーソルを置いて nvim で開く。保存して終了してもクリップボードへは反映されない |
| ⌘↩ | nvim 編集を確定 |
| ⌘. | nvim 編集を破棄 |
| ⌃A / ⌃E / ⌃B / ⌃F / ⌃D / ⌃K / ⌃Y | 検索欄のカーソル移動・削除（macOS 標準のまま fzf と同じ操作感） |
| ⌃W / ⌃U | 検索欄で直前の単語 / 行頭までを削除 |
| ⌘C / ⌘A / ⌘X / ⌘V / ⌘Z | 標準の編集操作（プレビューで選択した本文のコピーなどに使う） |

印を付けた項目は**印を付けた順**に改行で結合されます。印はパネルを開くたびにリセットされます。
一覧とプレビューの境界はドラッグで動かせ、パネルの位置・大きさと分割比率は次回起動時に復元されます。

### メニューバー

履歴パネルを開く / 設定 / 履歴を全消去 / 終了。

## 設定

設定は2系統あります。全ての利用者向け設定値は `config.toml` に統一されており、設定画面
（メニューバー → 設定）は現在の値を確認するための読み取り専用表示です（Issue 0025）。

### 設定画面（`UserDefaults`）

メニューバー → 設定 では、`config.toml` の現在値とホットキーの現在値を確認できます（編集はできません）:

| 項目 | 既定値 | 説明 |
| --- | --- | --- |
| 保持件数上限 | 10,000 | 最大 100,000。超過分は古いものから削除（起動時 + 1時間ごと） |
| 監視間隔 | 0.3 秒 | クリップボードのポーリング間隔 |
| 保存する最大テキストサイズ | 5 MB | 超えるテキストは保存しない |
| 保存する最大画像サイズ | 20 MB | 超える画像は保存しない |
| 機密データをスキップ | 有効 | `org.nspasteboard.ConcealedType` 付きのデータを保存しない |
| 一覧の最大表示件数 | 200 | 検索結果の表示上限 |
| BLOB のインライン閾値 | 64 KB | これ以下は DB 内 BLOB、超過は外部ファイルへ |

### 設定ファイル（`~/.config/cliphistory/`）

手で書く設定は XDG 準拠のディレクトリに置きます（`$XDG_CONFIG_HOME` があればそちら）。
どのファイルも**無くて構いません**。不正な記述はログに警告を残し、既定値で起動します。
ただし `[hotkey]` だけは例外で、既定値へのフォールバックがありません（後述）。

```
~/.config/cliphistory/
  ├── config.toml     ← アプリ本体の設定（起動時に1回だけ読む）
  ├── init-pre.lua    ← 利用者の nvim 設定より「前」に走る Lua
  └── init.lua        ← 利用者の nvim 設定より「後」に走る Lua
```

```toml
# config.toml
[history]
max_item_count = 10000   # 履歴の保持件数上限

[monitor]
polling_interval = 0.3     # 監視間隔（秒）
max_text_bytes = 5242880   # これを超えるテキストは保存しない
max_image_bytes = 20971520 # これを超える画像は保存しない
skip_concealed = true      # 機密フラグ付きデータをスキップするか

[list]
result_limit = 200   # 一覧に表示する最大件数

[storage]
inline_blob_threshold = 65536   # この値以下は DB 内 BLOB、超過は外部ファイル

[cycle]
timeout = 10   # 前後移動のポインタが揮発するまでの秒数

[font]
size = 12      # 一覧・検索欄・プレビューのフォントサイズ（pt）

[nvim.env]
NVIM_CLIPHISTORY = "1"   # nvim 起動時に追加で渡す環境変数

[snippet]
directories = ["~/notes/snippets"]   # Snippet機能が走査するディレクトリ（再帰的に.mdを探す）

[hotkey]
toggle_panel = "ctrl+command+c"          # 履歴パネルの表示 / 非表示
cycle_previous = "ctrl+command+p"        # パネルを開かず1個前へ
cycle_next = "ctrl+command+n"            # パネルを開かず1個後へ
direct_vim_edit = "command+ctrl+shift+c" # パネルを開かず直接nvim編集
paste_and_cycle_previous = "command+ctrl+v" # 連続貼り付け
toggle_snippet_panel = "ctrl+command+s"      # Snippetパネルの表示 / 非表示
edit_in_nvim = "command+e"                  # パネル内でnvim編集を開始するキー
edit_snippet_source = "command+shift+e"      # Snippetのソース.mdをnvimで開くキー
```

`[hotkey]` の値は `"モディファイヤ+...+キー"` 形式の文字列です。モディファイヤは
`command`/`ctrl`/`option`/`shift`（重複不可、1つ以上必須）、キーは `a`-`z` / `0`-`9` /
`enter` / `space` / `escape`（すべて小文字）が使えます。**書かなかったアクションはホットキーとして
登録されず、そのショートカットキーは使えなくなります**（他の設定項目と異なり既定値へのフォールバックはありません）。
なお `edit_in_nvim`（Vim編集モードへ入るキー）と `edit_snippet_source`（Snippetソース編集モードへ
入るキー）の2項目だけは他の6項目と異なり、システム全体へグローバル登録されるものではなく、
ClipHistoryのパネルにフォーカスがある時だけ効くローカルなキー操作です。

`[nvim.env]` の値はシェル展開されないリテラルです。`PATH` の追加は `init-pre.lua` で
`vim.env.PATH = vim.env.PATH .. ":/opt/hoge/bin"` と書いてください。
`NVIM_APPNAME` を指定すると利用者の `~/.config/nvim/` が読まれなくなるため書かないでください。

詳細は [docs/design.md](docs/design.md) の 10 章を参照してください。

## データの保存場所

| パス | 内容 |
| --- | --- |
| `~/Library/Application Support/ClipHistory/history.db` | 履歴の SQLite データベース |
| `~/Library/Application Support/ClipHistory/blobs/` | 64 KB を超える表現の外部ファイル |
| `~/.config/cliphistory/` | 手書きの設定ファイル |

履歴は暗号化していません（単一利用者のローカル運用を前提としています）。
機密情報を消したい場合はメニューバー → 履歴を全消去 を使ってください。

### アンインストール

```sh
osascript -e 'quit app "ClipHistory"'
rm -rf ~/Library/Application\ Support/ClipHistory
defaults delete local.cliphistory.app
```

`.app` 本体（`/Applications` へコピーした場合はそこ、それ以外は `.build/`）と、
`~/.config/cliphistory/` を作っていれば併せて削除してください。

## 開発

```sh
make build   # swift build -c release
make test    # swift test（AppKit 非依存の純ロジックのみ）
make app     # .app バンドルの組み立てと署名
make run     # make app + 起動
make clean   # .build を削除

./scripts/restart.sh   # 既存プロセスを終了し、ビルドし直して起動する
```

- 設計の意図・決定事項・既知の制約は [docs/design.md](docs/design.md) に集約しています
- 個々の変更の背景は [docs/issues/](docs/issues/) にあります
- `.xcodeproj` は作らず、SwiftPM + `Makefile` で `.app` を組み立てる方式です
- テストは Swift Testing（`import Testing`）。パネル表示やキー操作といった対話的な挙動は自動検証しておらず、手動確認が必要な領域として残しています

### 構成

| ターゲット | 役割 |
| --- | --- |
| `ClipHistoryCore` | 設定・DB・BLOB 管理・履歴ストア・正規化・曖昧検索・クリップボード監視（非 UI ロジック） |
| `ClipHistory` | メニューバー常駐アプリ本体（AppKit / SwiftUI / SwiftTerm） |

## 現状の制約

- ホットキーの変更 UI（キー入力を記録するレコーダ）はありません。設定画面では読み取り専用表示で、変更は `config.toml` の `[hotkey]` を直接編集して行います
- リッチテキスト（RTF / HTML など書式付きテキスト）は保存しません。プレーンテキストと画像のみが対象です（理由は design.md 13.4）
- 画像は取り込み・プレビュー・書き戻しに対応していますが、検索対象は説明テキスト（例: `[Image] PNG 1920×1080`）のみです
- ファイル（Finder からのコピー）は未対応です
- nvim 編集モードでの日本語 IME は未検証です
- iCloud 同期はありません

## ライセンス

MIT License — 詳細は [LICENSE](LICENSE) を参照してください。

依存ライブラリ:

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — MIT License
