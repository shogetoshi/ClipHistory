import Carbon.HIToolbox
import Foundation

/// ホットキー登録に関するエラー。呼び出し元（AppDelegate）へそのまま伝播させ、
/// 通知（NSAlert / NSLog）を出す判断はここでは行わない。
public enum HotKeyError: Error, CustomStringConvertible {
    case eventHandlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)

    public var description: String {
        switch self {
        case .eventHandlerInstallFailed(let status):
            return "InstallEventHandler failed (status: \(status))"
        case .registrationFailed(let status):
            // 他アプリが同じキー組み合わせを既に登録している場合、RegisterEventHotKey は
            // エラーを返す（設計書 12節「ホットキーが他アプリと衝突」）。
            return "RegisterEventHotKey failed (status: \(status)). 他アプリと衝突している可能性があります。"
        }
    }
}

/// グローバルホットキーの登録・解除を担う。
///
/// `NSEvent.addGlobalMonitorForEvents` はアクセシビリティ権限を要求するため採用しない
/// （設計書 2節・12節）。代わりに Carbon の `RegisterEventHotKey` / `InstallEventHandler` を使う。
/// Carbon 由来で非推奨扱いだが、権限不要という利点が大きく現行 macOS でも動作継続している。
public final class HotKeyManager {
    /// ホットキー発火時に呼ばれるコールバック。
    fileprivate let onHotKey: () -> Void

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    // アプリ内でユニークであればよい4文字コード（"ClHk" = ClipHistory Hotkey）。
    private static let signature: FourCharCode = {
        var result: FourCharCode = 0
        for scalar in "ClHk".unicodeScalars {
            result = (result << 8) + FourCharCode(scalar.value)
        }
        return result
    }()
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    public init(onHotKey: @escaping () -> Void) {
        self.onHotKey = onHotKey
    }

    deinit {
        // 呼び出し元が unregister() を呼び忘れても、グローバルホットキーが登録されたまま
        // 残ってしまわないよう deinit でも確実に解除する。
        unregister()
    }

    /// 指定した設定でホットキーを登録する。既に登録済みなら一旦解除してから登録し直す。
    /// 他アプリとの衝突などで失敗した場合は `HotKeyError` を投げる。
    public func register(_ config: HotKeyConfig) throws {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Carbon のイベントハンドラは C 関数ポインタを要求し、キャプチャを持つ
        // Swift クロージャは渡せない。そのため self は userData 経由で受け渡し、
        // ハンドラ本体はファイル下部の非キャプチャなトップレベル関数として実装する。
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyEventHandler,
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
        guard installStatus == noErr else {
            throw HotKeyError.eventHandlerInstallFailed(installStatus)
        }
        eventHandlerRef = handlerRef

        var hotKeyRefLocal: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRefLocal
        )
        guard registerStatus == noErr else {
            // ハンドラだけが残らないよう、登録失敗時は必ずロールバックする
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            eventHandlerRef = nil
            throw HotKeyError.registrationFailed(registerStatus)
        }
        hotKeyRef = hotKeyRefLocal
    }

    /// 登録済みのホットキーとイベントハンドラを解除する。未登録状態で呼んでも安全（二重解除可）。
    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func fireHotKey() {
        onHotKey()
    }
}

/// Carbon イベントハンドラの実体。C 関数ポインタとして渡す都合上、キャプチャを持たない
/// トップレベル関数にする必要がある。`userData` には登録時に渡した `HotKeyManager` の
/// unretained ポインタが入っており、ここから対象インスタンスを復元してコールバックを呼ぶ。
private func carbonHotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.fireHotKey()
    return noErr
}
