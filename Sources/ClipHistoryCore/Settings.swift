import Foundation
import CoreGraphics

/// 呼び出しホットキーの設定値。キーコード・修飾キーは Carbon の定数体系（HotKeyManager が
/// 実装されるフェーズ2で `RegisterEventHotKey` にそのまま渡す想定）で保持する。
/// このフェーズでは値を保持するのみで、実際のホットキー登録は行わない。
public struct HotKeyConfig: Equatable {
    /// Carbon の仮想キーコード（既定値 8 は kVK_ANSI_C）
    public var keyCode: UInt32
    /// Carbon の修飾キーマスク（既定値 0x1100 は controlKey(0x1000) | cmdKey(0x0100)）
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 1個前へ（⌃⌘P）。Issue 0015 で固定値とした（設定変更は将来）。
    public static let cyclePrevious = HotKeyConfig(keyCode: 35, modifiers: 0x1100)
    /// 1個後へ（⌃⌘N）。Issue 0015 で固定値とした（設定変更は将来）。
    public static let cycleNext = HotKeyConfig(keyCode: 45, modifiers: 0x1100)
    /// 直接Vim編集モードへ入る（⌘⌃⇧C）。Issue 0020 で固定値とした（設定変更は将来）。
    public static let directVimEdit = HotKeyConfig(keyCode: 8, modifiers: 0x1300)
    /// 連続貼り付け（⌘⌃V）。Issue 0022 で固定値とした（設定変更は将来）。
    public static let pasteAndCyclePrevious = HotKeyConfig(keyCode: 9, modifiers: 0x1100)
}

/// `UserDefaults` ベースの設定管理。利用者が指定する値はすべて `config.toml`（`Config`）に
/// 統一されており（Issue 0025）、ここに残るのはアプリが自動的に書き戻す状態
/// （ホットキー・パネル位置・プレビュー幅比率）のみである。
public final class Settings {
    public static let shared = Settings()

    /// 一覧とプレビューの幅比率として許容する範囲（Issue 0018）。
    public static let previewWidthRatioRange: ClosedRange<Double> = 0.3...3.0

    private let defaults: UserDefaults

    private enum Key: String {
        case hotKeyKeyCode
        case hotKeyModifiers
        case panelFrame
        case previewWidthRatio
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hotKeyKeyCode.rawValue: 8,       // kVK_ANSI_C
            Key.hotKeyModifiers.rawValue: 0x1100, // controlKey | cmdKey
            Key.previewWidthRatio.rawValue: 1.0
        ])
    }

    /// 一覧とプレビューの幅比率（プレビュー幅 ÷ 一覧幅）。ドラッグでの境界移動を反映して保存する（Issue 0018）。
    /// 既定は1.0（一覧:プレビュー=50:50）。
    public var previewWidthRatio: Double {
        get { Self.clampPreviewWidthRatio(defaults.double(forKey: Key.previewWidthRatio.rawValue)) }
        set { defaults.set(Self.clampPreviewWidthRatio(newValue), forKey: Key.previewWidthRatio.rawValue) }
    }

    private static func clampPreviewWidthRatio(_ value: Double) -> Double {
        min(previewWidthRatioRange.upperBound, max(previewWidthRatioRange.lowerBound, value))
    }

    /// 呼び出しホットキー（既定 ⌃⌘C）
    public var hotKey: HotKeyConfig {
        get {
            HotKeyConfig(
                keyCode: UInt32(defaults.integer(forKey: Key.hotKeyKeyCode.rawValue)),
                modifiers: UInt32(defaults.integer(forKey: Key.hotKeyModifiers.rawValue))
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyKeyCode.rawValue)
            defaults.set(Int(newValue.modifiers), forKey: Key.hotKeyModifiers.rawValue)
        }
    }

    /// 検索パネルの位置・大きさ（Issue 0009）。未保存・不正値なら nil を返し、
    /// 呼び出し側で既定配置を使わせる。既定値を登録しないのもそのためである。
    public var panelFrame: CGRect? {
        get {
            guard let values = defaults.array(forKey: Key.panelFrame.rawValue) as? [Double],
                  values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        set {
            guard let rect = newValue else {
                defaults.removeObject(forKey: Key.panelFrame.rawValue)
                return
            }
            defaults.set(
                [Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height)],
                forKey: Key.panelFrame.rawValue
            )
        }
    }
}
