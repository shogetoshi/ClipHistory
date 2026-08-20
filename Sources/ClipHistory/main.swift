import Cocoa

// LSUIElement は .app バンドルの Info.plist で設定するが、`swift run` 実行時など
// バンドル化されていない場合にも Dock アイコンを出さないよう、ここでも明示しておく。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
