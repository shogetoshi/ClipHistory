import Foundation
import CoreGraphics

/// 呼び出しホットキーの設定値。キーコード・修飾キーは Carbon の定数体系（HotKeyManager が
/// 実装されるフェーズ2で `RegisterEventHotKey` にそのまま渡す想定）で保持する。
/// このフェーズでは値を保持するのみで、実際のホットキー登録は行わない。
public struct HotKeyConfig: Equatable {
    /// Carbon の仮想キーコード（既定値 9 は kVK_ANSI_V）
    public var keyCode: UInt32
    /// Carbon の修飾キーマスク（既定値 0x0900 は optionKey(0x0800) | cmdKey(0x0100)）
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// `UserDefaults` ベースの設定管理。設計書「10. 設定項目」の全キーを定義する。
/// このフェーズで実際に参照するのは `pollingInterval` / `maxTextBytes` /
/// `inlineBlobThreshold` / `skipConcealed` のみで、他のキーは後続フェーズのために
/// 既定値付きで先に定義しておく。
public final class Settings {
    public static let shared = Settings()

    private let defaults: UserDefaults

    private enum Key: String {
        case pollingInterval
        case maxItemCount
        case hotKeyKeyCode
        case hotKeyModifiers
        case maxTextBytes
        case maxImageBytes
        case resultLimit
        case inlineBlobThreshold
        case skipConcealed
        case panelFrame
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.pollingInterval.rawValue: 0.3,
            Key.maxItemCount.rawValue: 10_000,
            Key.hotKeyKeyCode.rawValue: 9,       // kVK_ANSI_V
            Key.hotKeyModifiers.rawValue: 0x0900, // optionKey | cmdKey
            Key.maxTextBytes.rawValue: 5 * 1024 * 1024,
            Key.maxImageBytes.rawValue: 20 * 1024 * 1024,
            Key.resultLimit.rawValue: 200,
            Key.inlineBlobThreshold.rawValue: 64 * 1024,
            Key.skipConcealed.rawValue: true
        ])
    }

    /// 監視間隔（秒）。既定 0.3
    public var pollingInterval: TimeInterval {
        get { defaults.double(forKey: Key.pollingInterval.rawValue) }
        set { defaults.set(newValue, forKey: Key.pollingInterval.rawValue) }
    }

    /// 履歴の保持件数上限（既定 10000、最大 100000）
    public var maxItemCount: Int {
        get { min(100_000, max(1, defaults.integer(forKey: Key.maxItemCount.rawValue))) }
        set { defaults.set(min(100_000, max(1, newValue)), forKey: Key.maxItemCount.rawValue) }
    }

    /// 呼び出しホットキー（既定 ⌥⌘V）
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

    /// これを超えるテキストは保存しない（既定 5MB）
    public var maxTextBytes: Int {
        get { defaults.integer(forKey: Key.maxTextBytes.rawValue) }
        set { defaults.set(newValue, forKey: Key.maxTextBytes.rawValue) }
    }

    /// これを超える画像は保存しない（既定 20MB）。テキストとは別の上限を持たせるのは、
    /// スクリーンショットなどの画像はテキストより桁が大きいため。
    public var maxImageBytes: Int {
        get { defaults.integer(forKey: Key.maxImageBytes.rawValue) }
        set { defaults.set(newValue, forKey: Key.maxImageBytes.rawValue) }
    }

    /// 一覧に表示する最大件数（既定 200）
    public var resultLimit: Int {
        get { defaults.integer(forKey: Key.resultLimit.rawValue) }
        set { defaults.set(newValue, forKey: Key.resultLimit.rawValue) }
    }

    /// この値以下は DB 内 BLOB、超過は外部ファイル（既定 64KB）
    public var inlineBlobThreshold: Int {
        get { defaults.integer(forKey: Key.inlineBlobThreshold.rawValue) }
        set { defaults.set(newValue, forKey: Key.inlineBlobThreshold.rawValue) }
    }

    /// 機密フラグ付きデータをスキップするか（既定 true）
    public var skipConcealed: Bool {
        get { defaults.bool(forKey: Key.skipConcealed.rawValue) }
        set { defaults.set(newValue, forKey: Key.skipConcealed.rawValue) }
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
