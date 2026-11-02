import MarkdownUI
import SwiftUI

/// Rendered Markdown with syntax-highlighted fenced code blocks.
struct MarkdownPreview: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTheme(.gitHub)
                .markdownCodeSyntaxHighlighter(HighlightrCodeHighlighter(dark: colorScheme == .dark))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Bridges MarkdownUI's code blocks to the app's Highlightr-based highlighter.
struct HighlightrCodeHighlighter: CodeSyntaxHighlighter {
    let dark: Bool

    func highlightCode(_ code: String, language: String?) -> Text {
        MainActor.assumeIsolated {
            Text(SyntaxHighlighter.highlight(code, language: language.map(Languages.canonical), dark: dark, fontSize: 12))
        }
    }
}
