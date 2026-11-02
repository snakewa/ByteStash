import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Global quick-search hotkey. ⌥⌘Space by default (⌘Space is Spotlight, ⌃Space switches input sources).
    static let quickSearch = Self("quickSearch", default: .init(.space, modifiers: [.option, .command]))
    /// Global "new snippet from clipboard" hotkey; unset by default.
    static let newFromClipboard = Self("newFromClipboard")
    /// Global "save the selected text as a snippet" hotkey. ⇧⌥⌘C by default.
    static let saveSelection = Self("saveSelection", default: .init(.c, modifiers: [.shift, .option, .command]))
}

/// Spotlight-style floating panel: appears over any app, takes keyboard focus without
/// bringing the main window forward, and hides when it loses focus.
final class QuickSearchPanel: NSPanel {
    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear

        let host = NSHostingView(rootView: rootView.ignoresSafeArea())
        host.sizingOptions = [.preferredContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class QuickSearchController {
    private let state: AppState
    private lazy var panel = QuickSearchPanel(
        rootView: QuickSearchView(dismiss: { [weak self] in self?.hide() })
            .environmentObject(state)
    )

    init(state: AppState) {
        self.state = state
        KeyboardShortcuts.onKeyUp(for: .quickSearch) { [weak self] in self?.toggle() }
        KeyboardShortcuts.onKeyUp(for: .newFromClipboard) { [weak self] in self?.newFromClipboard() }
        KeyboardShortcuts.onKeyUp(for: .saveSelection) { [weak self] in
            Task { @MainActor in await self?.saveSelection() }
        }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        guard state.phase == .signedIn else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Upper third of the screen under the mouse, like Spotlight.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 4 - size.height / 2))
        }
        NotificationCenter.default.post(name: .quickSearchWillShow, object: nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }

    /// Saves the text selected in the frontmost app as a new snippet and opens it for editing.
    func saveSelection() async {
        guard state.store != nil else { return }
        let source = NSWorkspace.shared.frontmostApplication
        guard let text = await Paster.captureSelection() else {
            NSSound.beep()
            return
        }
        createSnippet(from: text, sourceApp: source?.localizedName)
    }

    /// Saves the clipboard text as a new snippet and opens it for editing.
    func newFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        createSnippet(from: text, sourceApp: nil)
    }

    private func createSnippet(from text: String, sourceApp: String?) {
        guard let store = state.store else { return }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Clipboard"
        var draft = Snippet.newDraft(id: Fragment.newLocalID())
        draft.title = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
        draft.fragments[0].code = text
        draft.fragments[0].language = UserDefaults.standard.string(forKey: "defaultLanguage") ?? "plaintext"
        if let sourceApp { draft.description = "Saved from \(sourceApp)" }
        let created = store.create(from: draft)
        state.selection = .all
        state.reveal(created.id)
    }
}

extension Notification.Name {
    static let quickSearchWillShow = Notification.Name("ByteStashQuickSearchWillShow")
}
