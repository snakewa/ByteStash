import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Rendered Markdown, drawn by the same kind of renderer as the web app: a bundled page
/// (Resources/MarkdownPreview) with GitHub-flavoured Markdown, GitHub alerts, highlighted code
/// and Mermaid diagrams with zoom, copy, SVG/PNG download and full screen.
struct MarkdownPreview: NSViewRepresentable {
    let text: String
    /// Lets the toolbar export the rendered page as an image.
    var controller: MarkdownPreviewController?

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: MarkdownPreviewPage.messageHandler)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        // Leave file drops to the app instead of letting the web view open them.
        webView.unregisterDraggedTypes()
        context.coordinator.webView = webView

        if let url = MarkdownPreviewPage.indexURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller?.webView = webView
        context.coordinator.update(text: text, dark: colorScheme == .dark)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownPreviewPage.messageHandler)
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var loaded = false
        private var pending: (text: String, dark: Bool)?
        private var shown: (text: String, dark: Bool)?

        func update(text: String, dark: Bool) {
            pending = (text, dark)
            flush()
        }

        private func flush() {
            guard loaded, let webView, let pending else { return }
            if let shown, shown == pending { return }
            shown = pending
            webView.evaluateJavaScript(MarkdownPreviewPage.renderScript(text: pending.text, dark: pending.dark)) { _, error in
                if let error { NSLog("Markdown preview render failed: \(error.localizedDescription)") }
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            shown = nil // a fresh page (also after "Reload" in the context menu)
            flush()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            switch MarkdownPreviewPage.policy(for: url, isLinkClick: navigationAction.navigationType == .linkActivated) {
            case .allow:
                return .allow
            case .openExternally:
                NSWorkspace.shared.open(url)
                return .cancel
            case .block:
                return .cancel
            }
        }

        // MARK: Messages from the page

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "copy":
                if let text = body["text"] as? String { Clipboard.copy(text) }
            case "save":
                let name = body["name"] as? String ?? "diagram"
                if let text = body["text"] as? String {
                    PreviewFiles.save(Data(text.utf8), suggestedName: name, window: webView?.window)
                } else if let base64 = body["base64"] as? String, let data = Data(base64Encoded: base64) {
                    PreviewFiles.save(data, suggestedName: name, window: webView?.window)
                }
            case "snapshot":
                guard let webView, let rect = body["rect"] as? [String: Double] else { return }
                let name = body["name"] as? String ?? "diagram.png"
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(x: rect["x"] ?? 0, y: rect["y"] ?? 0, width: rect["width"] ?? 0, height: rect["height"] ?? 0)
                webView.takeSnapshot(with: configuration) { image, _ in
                    guard let image, let data = image.pngData else { return NSSound.beep() }
                    PreviewFiles.save(data, suggestedName: name, window: webView.window)
                }
            default:
                NSSound.beep()
            }
        }
    }
}

/// Exports the whole rendered preview as a PNG (or PDF, if the file is named .pdf).
@MainActor
final class MarkdownPreviewController: ObservableObject {
    weak var webView: WKWebView?

    var canExport: Bool { webView != nil }

    func exportImage(suggestedName: String) {
        guard let webView else { return NSSound.beep() }
        webView.evaluateJavaScript("ByteStash.prepareExport(true); undefined") { _, _ in
            // No rect: the PDF covers the page's full scroll height, not just what's visible.
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                webView.evaluateJavaScript("ByteStash.prepareExport(false); undefined")
                guard case .success(let pdf) = result else { return NSSound.beep() }
                var background = NSColor.textBackgroundColor.cgColor
                webView.effectiveAppearance.performAsCurrentDrawingAppearance {
                    background = NSColor.textBackgroundColor.cgColor
                }
                PreviewFiles.saveImage(pdf: pdf, background: background, suggestedName: suggestedName, window: webView.window)
            }
        }
    }
}

/// The bundled page and the rules for talking to it. Kept free of UI so it can be unit tested.
enum MarkdownPreviewPage {
    static let messageHandler = "bytestash"

    static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownPreview")
    }

    /// The JavaScript that renders `text`; the text is passed as a JSON string literal.
    static func renderScript(text: String, dark: Bool) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return "ByteStash.render(\(array)[0], {dark: \(dark)}); undefined"
    }

    enum Policy: Equatable { case allow, openExternally, block }

    /// The page itself (and its #anchors) loads in place; clicked web/mail links open in the
    /// default app; anything else (other files, drops, script redirects) is blocked.
    static func policy(for url: URL, isLinkClick: Bool) -> Policy {
        if url.isFileURL, let index = indexURL, url.standardizedFileURL.path == index.standardizedFileURL.path {
            return .allow
        }
        if url.scheme == "about" { return .allow }
        if isLinkClick, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return .openExternally
        }
        return .block
    }
}

@MainActor
enum PreviewFiles {
    static func save(_ data: Data, suggestedName: String, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: (suggestedName as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        present(panel, window: window) { url in
            do { try data.write(to: url, options: .atomic) } catch { NSSound.beep() }
        }
    }

    static func saveImage(pdf: Data, background: CGColor, suggestedName: String, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitized(suggestedName) + ".png"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png, .pdf]
        panel.message = "Save as PNG, or name the file .pdf for a PDF."
        present(panel, window: window) { url in
            let data = url.pathExtension.lowercased() == "pdf" ? pdf : PreviewImage.png(fromPDF: pdf, background: background)
            guard let data else { return NSSound.beep() }
            do { try data.write(to: url, options: .atomic) } catch { NSSound.beep() }
        }
    }

    nonisolated static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Snippet" : cleaned
    }

    private static func present(_ panel: NSSavePanel, window: NSWindow?, then save: @escaping (URL) -> Void) {
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { save(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            save(url)
        }
    }
}

enum PreviewImage {
    /// Draws the first page of a PDF into a PNG on a solid background, at `scale` (2× for
    /// Retina) but never wider or taller than `maxPixels`.
    static func png(fromPDF data: Data, background: CGColor, scale: CGFloat = 2, maxPixels: CGFloat = 16_000) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let factor = min(scale, maxPixels / box.width, maxPixels / box.height)
        let width = Int((box.width * factor).rounded()), height = Int((box.height * factor).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: factor, y: factor)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// WKUserContentController keeps its handlers alive; this keeps it from owning the coordinator.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
