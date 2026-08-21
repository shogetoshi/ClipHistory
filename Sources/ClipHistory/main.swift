import Cocoa

// press-and-hold（既定 ON）が有効だと、`interpretKeyEvents` 経由で処理される修飾なし
// キーのキーリピートが抑止され、埋め込んだ nvim で `l` 長押しによる連続移動ができない
// （Issue 0008）。登録ドメイン（`register(defaults:)`）はグローバルドメインより後に
// 参照されるため、利用者がグローバルに `ApplePressAndHoldEnabled` を設定していると効かない。
// アプリドメインへの `set` ならグローバルより優先されるため、こちらを使う
// （`defaults write <bundle-id> ApplePressAndHoldEnabled -bool false` と同じ効果を、
// 利用者にコマンドを叩かせずアプリ自身で行う）。
// 副作用として、このアプリ内では検索フィールドでもアクセント候補のポップアップが出なく
// なるが、クリップボード検索欄では候補入力の価値が薄いため許容する。
UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")

// LSUIElement は .app バンドルの Info.plist で設定するが、`swift run` 実行時など
// バンドル化されていない場合にも Dock アイコンを出さないよう、ここでも明示しておく。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
