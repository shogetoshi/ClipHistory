import SwiftUI
import ClipHistoryCore

/// 設定画面のビューモデル。`Settings`（`UserDefaults` ベース）への読み書きを仲介する。
/// SwiftUI の双方向バインディングのため `ObservableObject` にしている。
///
/// 各 `@Published` プロパティの `didSet` で即座に `Settings` へ書き戻す（保存ボタンは設けない）。
/// `pollingInterval` のみ、変更のたびに `onPollingIntervalChanged` を呼び、
/// `ClipboardMonitor` のタイマー張り替えを `AppDelegate` 側に依頼する
/// （指示: 監視間隔だけは即座に反映、他の項目は次回の読み出し時に反映されればよい）。
final class SettingsViewModel: ObservableObject {
    // `SwiftUI.Settings`（Scene）と名前が衝突するため、明示的に `ClipHistoryCore.Settings` を指す。
    private let settings: ClipHistoryCore.Settings
    private let onPollingIntervalChanged: () -> Void

    @Published var maxItemCount: Int {
        // Settings.maxItemCount のセッターが 1〜100000 にクランプする
        didSet { settings.maxItemCount = maxItemCount }
    }
    @Published var pollingInterval: Double {
        didSet {
            settings.pollingInterval = pollingInterval
            onPollingIntervalChanged()
        }
    }
    @Published var maxTextBytes: Int {
        didSet { settings.maxTextBytes = maxTextBytes }
    }
    @Published var resultLimit: Int {
        didSet { settings.resultLimit = resultLimit }
    }
    @Published var skipConcealed: Bool {
        didSet { settings.skipConcealed = skipConcealed }
    }

    /// ホットキーは読み取り専用表示のみ（v1スコープ外のレコーダUIは実装しない）。
    let hotKeyDisplay: String

    init(settings: ClipHistoryCore.Settings, onPollingIntervalChanged: @escaping () -> Void) {
        self.settings = settings
        self.onPollingIntervalChanged = onPollingIntervalChanged
        // これらの代入は自身の初期化子内での設定のため didSet は呼ばれない
        // （Settingsへの書き戻し・onPollingIntervalChangedの誤発火は起きない）。
        self.maxItemCount = settings.maxItemCount
        self.pollingInterval = settings.pollingInterval
        self.maxTextBytes = settings.maxTextBytes
        self.resultLimit = settings.resultLimit
        self.skipConcealed = settings.skipConcealed
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

/// 設定画面の本体。凝ったデザインは不要という指示のため、`Form` による最小限の構成にする。
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("履歴") {
                Stepper(value: $viewModel.maxItemCount, in: ClipHistoryCore.Settings.maxItemCountRange, step: 100) {
                    labeledValue("保持件数上限", "\(viewModel.maxItemCount) 件")
                }
            }

            Section("監視") {
                labeledField("監視間隔（秒）", value: $viewModel.pollingInterval, range: 0.05...5.0)
                labeledField("保存する最大テキストサイズ（バイト）", value: $viewModel.maxTextBytes, range: 1_024...50_000_000)
                Toggle("機密データをスキップ", isOn: $viewModel.skipConcealed)
            }

            Section("一覧表示") {
                Stepper(value: $viewModel.resultLimit, in: 1...5_000, step: 10) {
                    labeledValue("一覧の最大表示件数", "\(viewModel.resultLimit) 件")
                }
            }

            Section("ホットキー") {
                labeledValue("呼び出しホットキー", viewModel.hotKeyDisplay)
                Text("この画面ではホットキーの変更はできません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func labeledField(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = range.clamp($0) }
            ), format: .number)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
    }

    private func labeledField(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = range.clamp($0) }
            ), format: .number)
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
        }
    }
}

private extension ClosedRange {
    /// 入力値を範囲内にクランプする（TextField への直接入力で不正な値にならないようにする）。
    func clamp(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
