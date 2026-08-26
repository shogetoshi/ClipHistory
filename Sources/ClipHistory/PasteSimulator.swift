import Cocoa
import Carbon.HIToolbox
import ApplicationServices

/// ⌘V のキーイベントを合成し、今フォーカスがあるアプリに貼り付けを実行させる（Issue 0022）。
///
/// `ContinuousPasteController` から「貼り付け→クリップボードを1個前へ」の1手目として使われる。
/// キーイベントの合成にはアクセシビリティ権限が必要なため、権限が無い場合は
/// `AXIsProcessTrustedWithOptions` で（非ブロッキングな）許可誘導ダイアログを出すに留め、
/// `NSAlert` 等の同期モーダルは使わない（設計書 13.3 で禁止されている）。
final class PasteSimulator {
    /// ⌘V を合成して送出する。
    ///
    /// - Returns: イベントの生成・送出まで行えたら `true`。アクセシビリティ権限が無い、
    ///   または `CGEventSource` / `CGEvent` の生成に失敗した場合は `false`。
    @discardableResult
    func paste() -> Bool {
        guard AXIsProcessTrusted() else {
            let options: [String: Bool] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            NSSound.beep()
            NSLog("ClipHistory: accessibility permission is required to simulate paste")
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("ClipHistory: failed to create CGEventSource for paste simulation")
            return false
        }

        // ⌘⌃V のホットキー押下中は物理的に ⌃ / ⌘ が押されたままなので、合成イベント送出直後の
        // 抑止期間中は実キーボードのイベントを混ぜないようにする（Issue 0022）。
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            NSLog("ClipHistory: failed to create CGEvent for paste simulation")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // HID レイヤへの注入ではなく、現在のログインセッションのイベントストリームへ注入する（Issue 0022）。
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        return true
    }
}
