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

/// 登録可能なグローバルホットキーの種類。`rawValue` は Carbon の `EventHotKeyID.id` に
/// そのまま使う（Issue 0015 で複数ホットキー対応するため導入）。
public enum HotKeyAction: UInt32 {
    /// 検索パネルの表示トグル
    case togglePanel = 1
    /// 1個前へ
    case cyclePrevious = 2
    /// 1個後へ
    case cycleNext = 3
}

/// グローバルホットキーの登録・解除を担う。
///
/// `NSEvent.addGlobalMonitorForEvents` はアクセシビリティ権限を要求するため採用しない
/// （設計書 2節・12節）。代わりに Carbon の `RegisterEventHotKey` / `InstallEventHandler` を使う。
/// Carbon 由来で非推奨扱いだが、権限不要という利点が大きく現行 macOS でも動作継続している。
/// Issue 0015 で `togglePanel` に加え `cyclePrevious` / `cycleNext` を同時に登録できるようにした。
public final class HotKeyManager {
    /// ホットキー発火時に呼ばれるコールバック。発火した `HotKeyAction` を受け取る。
    fileprivate let onHotKey: (HotKeyAction) -> Void

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]

    // アプリ内でユニークであればよい4文字コード（"ClHk" = ClipHistory Hotkey）。
    private static let signature: FourCharCode = {
        var result: FourCharCode = 0
        for scalar in "ClHk".unicodeScalars {
            result = (result << 8) + FourCharCode(scalar.value)
        }
        return result
    }()

    public init(onHotKey: @escaping (HotKeyAction) -> Void) {
        self.onHotKey = onHotKey
    }

    deinit {
        // 呼び出し元が unregister() を呼び忘れても、グローバルホットキーが登録されたまま
        // 残ってしまわないよう deinit でも確実に解除する。
        unregister()
    }

    /// 指定した設定でホットキー群を登録する。既に登録済みなら一旦解除してから登録し直す。
    /// 他アプリとの衝突などで失敗した場合は、それまでに登録できたホットキーとイベントハンドラを
    /// すべてロールバックした上で `HotKeyError` を投げる。
    public func register(_ bindings: [HotKeyAction: HotKeyConfig]) throws {
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

        // 辞書の列挙順は不定なので、失敗時のエラーが毎回変わらないよう rawValue 昇順で登録する。
        let orderedBindings = bindings.sorted { $0.key.rawValue < $1.key.rawValue }
        for (action, config) in orderedBindings {
            var hotKeyRefLocal: EventHotKeyRef?
            let registerStatus = RegisterEventHotKey(
                config.keyCode,
                config.modifiers,
                EventHotKeyID(signature: Self.signature, id: action.rawValue),
                GetApplicationEventTarget(),
                0,
                &hotKeyRefLocal
            )
            guard registerStatus == noErr else {
                // どれか1つでも登録に失敗したら、それまでに登録できたホットキーと
                // イベントハンドラをすべてロールバックする。
                unregister()
                throw HotKeyError.registrationFailed(registerStatus)
            }
            hotKeyRefs[action] = hotKeyRefLocal
        }
    }

    /// 登録済みの全ホットキーとイベントハンドラを解除する。未登録状態で呼んでも安全（二重解除可）。
    public func unregister() {
        for (_, hotKeyRef) in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// 発火した id に対応する `HotKeyAction` があればコールバックを呼び `true` を返す。
    /// 未知の id の場合は何もせず `false` を返す。
    @discardableResult
    fileprivate func fireHotKey(id: UInt32) -> Bool {
        guard let action = HotKeyAction(rawValue: id) else { return false }
        onHotKey(action)
        return true
    }
}

/// Carbon イベントハンドラの実体。C 関数ポインタとして渡す都合上、キャプチャを持たない
/// トップレベル関数にする必要がある。`userData` には登録時に渡した `HotKeyManager` の
/// unretained ポインタが入っており、ここから対象インスタンスを復元してコールバックを呼ぶ。
/// どのホットキーが発火したかは `kEventParamDirectObject` から `EventHotKeyID` を取得して判別する。
private func carbonHotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    guard manager.fireHotKey(id: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }
    return noErr
}
