import AppKit
import Highlightr
import SwiftUI

enum EditorSettings {
    static let fontSizeKey = "editorFontSize"
    static let wrapKey = "editorWrapLines"
    static let lightThemeKey = "editorLightTheme"
    static let darkThemeKey = "editorDarkTheme"
    static let lineNumbersKey = "editorLineNumbers"

    static let defaultLightTheme = "xcode"
    static let defaultDarkTheme = "atom-one-dark"

    static var availableThemes: [String] = {
        (Highlightr()?.availableThemes() ?? [defaultLightTheme, defaultDarkTheme]).sorted()
    }()
}

/// A syntax-highlighted code view (TextKit 1 + Highlightr) with line numbers.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: String
    var isEditable: Bool = true
    var fontSize: CGFloat = 13
    var wrapLines: Bool = false
    var showLineNumbers: Bool = true
    var lightTheme: String = EditorSettings.defaultLightTheme
    var darkTheme: String = EditorSettings.defaultDarkTheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = CodeAttributedString()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in coordinator?.applyTheme() }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // macOS 14 stopped clipping views to their bounds by default; without this the ruler
        // and text view can paint over the SwiftUI header above the editor.
        scrollView.clipsToBounds = true
        scrollView.contentView.clipsToBounds = true
        textView.clipsToBounds = true
        scrollView.documentView = textView

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true

        context.coordinator.textView = textView
        context.coordinator.storage = storage
        context.coordinator.ruler = ruler
        context.coordinator.scrollView = scrollView

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        context.coordinator.configure(force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView, let storage = context.coordinator.storage else { return }
        if textView.string != text {
            let selection = textView.selectedRanges
            context.coordinator.isUpdating = true
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            context.coordinator.isUpdating = false
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
        }
        context.coordinator.configure(force: false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        weak var scrollView: NSScrollView?
        var storage: CodeAttributedString?
        var ruler: LineNumberRuler?
        var isUpdating = false

        private var appliedLanguage: String?
        private var appliedTheme: String?
        private var appliedFontSize: CGFloat = 0
        private var appliedWrap: Bool?

        init(_ parent: CodeEditor) { self.parent = parent }

        func configure(force: Bool) {
            guard let textView, let storage, let scrollView else { return }
            textView.isEditable = parent.isEditable
            textView.isSelectable = true

            let language = Languages.highlightName(for: parent.language)
            let supported = language.flatMap { name in storage.highlightr.supportedLanguages().contains(name) ? name : nil }
            if force || appliedLanguage != supported {
                appliedLanguage = supported
                storage.language = supported
            }

            if force || appliedFontSize != parent.fontSize {
                appliedFontSize = parent.fontSize
                appliedTheme = nil
            }
            applyTheme()

            if force || appliedWrap != parent.wrapLines {
                appliedWrap = parent.wrapLines
                let container = textView.textContainer
                if parent.wrapLines {
                    container?.widthTracksTextView = true
                    container?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                    textView.isHorizontallyResizable = false
                    textView.frame.size.width = scrollView.contentSize.width
                    scrollView.hasHorizontalScroller = false
                } else {
                    container?.widthTracksTextView = false
                    container?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    textView.isHorizontallyResizable = true
                    scrollView.hasHorizontalScroller = true
                }
            }
            scrollView.rulersVisible = parent.showLineNumbers
        }

        func applyTheme() {
            guard let textView, let storage else { return }
            let dark = textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let name = dark ? parent.darkTheme : parent.lightTheme
            guard appliedTheme != name else { return }
            appliedTheme = name
            if !storage.highlightr.setTheme(to: name) {
                _ = storage.highlightr.setTheme(to: dark ? EditorSettings.defaultDarkTheme : EditorSettings.defaultLightTheme)
            }
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            storage.highlightr.theme.setCodeFont(font)
            let background = storage.highlightr.theme.themeBackgroundColor ?? NSColor.textBackgroundColor
            textView.backgroundColor = background
            textView.drawsBackground = true
            textView.font = font
            textView.insertionPointColor = dark ? .white : .black
            textView.typingAttributes = [.font: font, .foregroundColor: dark ? NSColor.white : NSColor.black]
            ruler?.backgroundColor = background
            ruler?.font = NSFont.monospacedDigitSystemFont(ofSize: max(parent.fontSize - 2, 9), weight: .regular)
            // Re-run highlighting with the new theme.
            let language = storage.language
            storage.language = language
            ruler?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            parent.text = textView.string
            ruler?.needsDisplay = true
        }
    }
}

final class CodeTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// Tab indents with spaces matching the line's existing indentation style.
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    /// Keep the indentation of the current line on return.
    override func insertNewline(_ sender: Any?) {
        let nsString = string as NSString
        let lineRange = nsString.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = nsString.substring(with: lineRange)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// Draws line numbers beside a TextKit 1 text view.
final class LineNumberRuler: NSRulerView {
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { needsDisplay = true } }
    var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func refresh() { needsDisplay = true }

    override var isFlipped: Bool { true }

    /// Draw everything ourselves: NSRulerView's own drawing adds a baseline and marker area,
    /// and its dirty rect can reach outside the ruler.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        drawHashMarksAndLabels(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()

        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible character.
        var lineNumber = 1
        var index = 0
        while index < charRange.location {
            let lineEnd = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            if lineEnd > charRange.location { break }
            index = lineEnd
            lineNumber += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let inset = textView.textContainerInset.height
        let offset = convert(NSPoint.zero, from: textView).y
        var maxWidth: CGFloat = 0

        index = charRange.location
        repeat {
            let lineRange = string.length == 0 ? NSRange(location: 0, length: 0) : string.lineRange(for: NSRange(location: index, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: max(lineRange.length, 0)), actualCharacterRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: min(glyphs.location, max(layoutManager.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            if string.length == 0 { lineRect = NSRect(x: 0, y: 0, width: 0, height: font.boundingRectForFont.height) }
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            maxWidth = max(maxWidth, size.width)
            let y = lineRect.minY + inset + offset + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attributes)
            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        } while index < NSMaxRange(charRange)

        // Trailing empty line after a final newline.
        if string.length > 0, string.hasSuffix("\n"), NSMaxRange(charRange) >= string.length {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: extra.minY + inset + offset + (extra.height - size.height) / 2), withAttributes: attributes)
            }
        }

        let needed = max(36, maxWidth + 14)
        if abs(needed - ruleThickness) > 1 { ruleThickness = needed }
    }
}
