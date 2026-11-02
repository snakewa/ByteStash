import AppKit
import ApplicationServices

/// Sends keystrokes to the frontmost app for auto-paste and "save selection". Both need
/// the Accessibility permission (System Settings → Privacy & Security → Accessibility).
enum Paster {
    static let autoPasteKey = "pasteAfterCopy"

    static var autoPasteEnabled: Bool { UserDefaults.standard.bool(forKey: autoPasteKey) }

    /// Whether we may post keystrokes; with `prompt`, macOS shows its permission dialog.
    @discardableResult
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Copies `text`, then pastes it into `target` (or whatever app is frontmost) when
    /// auto-paste is on and permitted. Returns true when it pasted.
    @MainActor
    @discardableResult
    static func copyAndMaybePaste(_ text: String, into target: NSRunningApplication? = nil) -> Bool {
        Clipboard.copy(text)
        guard autoPasteEnabled, isTrusted(prompt: true) else { return false }
        if let target, target != NSRunningApplication.current {
            target.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sendKey(9 /* v */)
        }
        return true
    }

    /// Copies the selection of the frontmost app and hands back the text, restoring the
    /// previous clipboard afterwards. Nil when nothing was selected or not permitted.
    @MainActor
    static func captureSelection() async -> String? {
        guard isTrusted(prompt: true) else { return nil }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount
        // Let the hotkey's own modifier keys come up before sending ⌘C.
        try? await Task.sleep(nanoseconds: 150_000_000)
        sendKey(8 /* c */)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let captured = pasteboard.string(forType: .string)
        if let previous {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
        guard let captured, !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return captured
    }

    /// Posts ⌘ + the given virtual key code.
    private static func sendKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
