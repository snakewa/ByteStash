import KeyboardShortcuts
import ServiceManagement
import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EditorSettingsView().tabItem { Label("Editor", systemImage: "textformat") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("defaultLanguage") private var defaultLanguage = "plaintext"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Paster.autoPasteKey) private var autoPaste = false
    @State private var accessibilityGranted = Paster.isTrusted(prompt: false)

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Quick search:", name: .quickSearch)
            KeyboardShortcuts.Recorder("Save selected text:", name: .saveSelection)
            KeyboardShortcuts.Recorder("New snippet from clipboard:", name: .newFromClipboard)
            Toggle("Paste into the previous app after choosing a snippet", isOn: $autoPaste)
                .onChange(of: autoPaste) { _, on in
                    if on { accessibilityGranted = Paster.isTrusted(prompt: true) }
                }
            if !accessibilityGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Auto-paste and “Save selected text” need Accessibility access.")
                        .font(.caption)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.small)
                }
            }
            Toggle("Show in menu bar", isOn: $showMenuBarIcon)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Picker("Default language:", selection: $defaultLanguage) {
                ForEach(Languages.all, id: \.self) { Text(Languages.displayName(for: $0)).tag($0) }
            }
        }
        .onAppear { accessibilityGranted = Paster.isTrusted(prompt: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = Paster.isTrusted(prompt: false)
        }
    }
}

private struct EditorSettingsView: View {
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize: Double = 13
    @AppStorage(EditorSettings.wrapKey) private var wrapLines = false
    @AppStorage(EditorSettings.lineNumbersKey) private var lineNumbers = true
    @AppStorage(EditorSettings.lightThemeKey) private var lightTheme = EditorSettings.defaultLightTheme
    @AppStorage(EditorSettings.darkThemeKey) private var darkTheme = EditorSettings.defaultDarkTheme
    @State private var sample = "func greet(_ name: String) -> String {\n    // Say hello\n    return \"Hello, \\(name)!\"\n}\n"

    var body: some View {
        Form {
            Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...28)
            Toggle("Wrap long lines", isOn: $wrapLines)
            Toggle("Show line numbers", isOn: $lineNumbers)
            Picker("Light theme:", selection: $lightTheme) {
                ForEach(EditorSettings.availableThemes, id: \.self) { Text($0).tag($0) }
            }
            Picker("Dark theme:", selection: $darkTheme) {
                ForEach(EditorSettings.availableThemes, id: \.self) { Text($0).tag($0) }
            }
            CodeEditor(text: $sample, language: "swift", isEditable: false, fontSize: CGFloat(fontSize),
                       wrapLines: wrapLines, showLineNumbers: lineNumbers, lightTheme: lightTheme, darkTheme: darkTheme)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct AccountSettings: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            if let user = app.user, let server = app.serverURL {
                LabeledContent("Server:", value: server.absoluteString)
                LabeledContent("Signed in as:", value: user.username)
                if let store = app.store {
                    LabeledContent("Snippets:", value: "\(store.library.own.count) own, \(store.library.shared.count) shared")
                    if let last = store.library.lastSync {
                        LabeledContent("Last sync:", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if !store.outbox.isEmpty {
                        LabeledContent("Waiting to sync:", value: "\(store.outbox.count) change(s)")
                    }
                }
                HStack {
                    Button("Sign Out") { app.signOut(keepServer: true) }
                    Button("Sign Out and Clear Cache", role: .destructive) { app.signOut(keepServer: false) }
                }
            } else {
                Text("Not signed in.").foregroundStyle(.secondary)
            }
        }
    }
}
