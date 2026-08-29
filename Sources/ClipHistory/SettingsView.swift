import SwiftUI
import ClipHistoryCore

/// 設定画面のビューモデル。`Settings`（`UserDefaults` ベース）と `Config`（`config.toml`）から
/// 現在値を読み取って保持するだけの読み取り専用モデル（Issue 0025）。
final class SettingsViewModel: ObservableObject {
    let maxItemCount: Int
    let pollingInterval: TimeInterval
    let maxTextBytes: Int
    let maxImageBytes: Int
    let skipConcealed: Bool
    let resultLimit: Int
    let inlineBlobThreshold: Int

    /// ホットキーは読み取り専用表示のみ（v1スコープ外のレコーダUIは実装しない）。
    let hotKeyDisplay: String

    init(settings: ClipHistoryCore.Settings) {
        self.maxItemCount = Config.shared.maxItemCount
        self.pollingInterval = Config.shared.pollingInterval
        self.maxTextBytes = Config.shared.maxTextBytes
        self.maxImageBytes = Config.shared.maxImageBytes
        self.skipConcealed = Config.shared.skipConcealed
        self.resultLimit = Config.shared.resultLimit
        self.inlineBlobThreshold = Config.shared.inlineBlobThreshold
        self.hotKeyDisplay = Self.hotKeyDisplayString(settings.hotKey)
    }

    /// Carbon の修飾キーマスク・仮想キーコードから表示用文字列を組み立てる。
    /// 表示専用の簡易マッピングであり、主要なANSIキーのみ対応する（未知のコードは番号表示）。
    private static func hotKeyDisplayString(_ config: ClipHistoryCore.HotKeyConfig) -> String {
        let controlKey: UInt32 = 0x1000
        let optionKey: UInt32 = 0x0800
        let shiftKey: UInt32 = 0x0200
        let cmdKey: UInt32 = 0x0100

        var symbols = ""
        if config.modifiers & controlKey != 0 { symbols += "\u{2303}" } // ⌃
        if config.modifiers & optionKey != 0 { symbols += "\u{2325}" } // ⌥
        if config.modifiers & shiftKey != 0 { symbols += "\u{21E7}" } // ⇧
        if config.modifiers & cmdKey != 0 { symbols += "\u{2318}" } // ⌘
        symbols += keySymbol(config.keyCode)
        return symbols
    }

    private static func keySymbol(_ keyCode: UInt32) -> String {
        // Carbon の仮想キーコード（ANSI配列）のうち、主要なものだけを表示用にマッピングする。
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space"
        ]
        return map[keyCode] ?? "code:\(keyCode)"
    }
}

/// 設定画面の本体。設定は `config.toml` に統一されており、この画面はあくまで現在の設定値を
/// 確認するための読み取り専用画面である（Issue 0025）。`Form` による最小限の構成にする。
/// フォントだけはアプリの他の画面に合わせて等幅にする（Issue 0012）。
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("履歴") {
                labeledValue("保持件数上限", "\(viewModel.maxItemCount) 件")
            }

            Section("監視") {
                labeledValue("監視間隔（秒）", "\(viewModel.pollingInterval) 秒")
                labeledValue("保存する最大テキストサイズ（バイト）", "\(viewModel.maxTextBytes) バイト")
                labeledValue("保存する最大画像サイズ（バイト）", "\(viewModel.maxImageBytes) バイト")
                labeledValue("機密データをスキップ", viewModel.skipConcealed ? "有効" : "無効")
            }

            Section("一覧表示") {
                labeledValue("一覧の最大表示件数", "\(viewModel.resultLimit) 件")
            }

            Section("保存") {
                labeledValue("BLOBのインライン閾値（バイト）", "\(viewModel.inlineBlobThreshold) バイト")
            }

            Section("ホットキー") {
                labeledValue("呼び出しホットキー", viewModel.hotKeyDisplay)
                Text("この画面ではホットキーの変更はできません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // アプリの他の画面（一覧・検索欄・プレビュー）と同じく等幅フォントに揃える（Issue 0012）。
        .monospaced()
        .frame(width: 420, height: 420)
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
