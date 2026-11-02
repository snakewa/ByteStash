import AppKit
import Highlightr
import SwiftUI

/// Highlights code into SwiftUI `AttributedString`s for previews (grid cards, Markdown code
/// blocks). One shared Highlightr (a JavaScriptCore context) is used on the main actor, and
/// results are cached.
@MainActor
enum SyntaxHighlighter {
    private static let highlightr = Highlightr()
    private static var currentTheme: String?
    private static var cache: [String: AttributedString] = [:]

    static func highlight(_ code: String, language: String?, dark: Bool, fontSize: CGFloat = 12) -> AttributedString {
        let theme = themeName(dark: dark)
        let name = language.flatMap { Languages.highlightName(for: $0) }
        let key = "\(theme)|\(fontSize)|\(name ?? "-")|\(code.hashValue)|\(code.count)"
        if let cached = cache[key] { return cached }

        var result = AttributedString(code)
        result.font = .system(size: fontSize, design: .monospaced)
        guard let highlightr, let name, highlightr.supportedLanguages().contains(name) else {
            return remember(result, key)
        }
        applyTheme(dark: dark)
        highlightr.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        guard let attributed = highlightr.highlight(code, as: name, fastRender: true) else {
            return remember(result, key)
        }

        // Map AppKit attributes onto SwiftUI ones so Text renders the colours.
        result = AttributedString()
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            var run = AttributedString((attributed.string as NSString).substring(with: range))
            run.font = .system(size: fontSize, design: .monospaced)
            if let color = attributes[.foregroundColor] as? NSColor {
                run.foregroundColor = Color(nsColor: color)
            }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                var swiftFont = Font.system(size: fontSize, design: .monospaced)
                if traits.contains(.bold) { swiftFont = swiftFont.bold() }
                if traits.contains(.italic) { swiftFont = swiftFont.italic() }
                run.font = swiftFont
            }
            result.append(run)
        }
        return remember(result, key)
    }

    /// The theme's background colour, so previews match the editor.
    static func background(dark: Bool) -> Color {
        applyTheme(dark: dark)
        if let color = highlightr?.theme.themeBackgroundColor {
            return Color(nsColor: color)
        }
        return Color(nsColor: .textBackgroundColor)
    }

    private static func themeName(dark: Bool) -> String {
        dark
            ? (UserDefaults.standard.string(forKey: EditorSettings.darkThemeKey) ?? EditorSettings.defaultDarkTheme)
            : (UserDefaults.standard.string(forKey: EditorSettings.lightThemeKey) ?? EditorSettings.defaultLightTheme)
    }

    private static func applyTheme(dark: Bool) {
        let theme = themeName(dark: dark)
        guard let highlightr, currentTheme != theme else { return }
        if !highlightr.setTheme(to: theme) {
            highlightr.setTheme(to: dark ? EditorSettings.defaultDarkTheme : EditorSettings.defaultLightTheme)
        }
        currentTheme = theme
    }

    private static func remember(_ value: AttributedString, _ key: String) -> AttributedString {
        if cache.count > 500 { cache.removeAll() }
        cache[key] = value
        return value
    }
}
