import KeyboardShortcuts
import ServiceManagement
import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EditorSettingsView().tabItem { Label("Editor", systemImage: "textformat") }
            AccountSettings().tabItem { Label("Accounts", systemImage: "person.2.crop.square.stack") }
        }
        .frame(width: 520)
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
    @State private var confirmClear: String?
    @State private var addRequest: AddAccountRequest?

    var body: some View {
        Form {
            if app.accounts.isEmpty {
                Text("Not signed in.").foregroundStyle(.secondary)
            } else {
                if app.hasMultipleAccounts {
                    Section {
                        Picker("New snippets go to:", selection: Binding(
                            get: { app.defaultAccountID },
                            set: { app.defaultAccountID = $0 }
                        )) {
                            ForEach(app.accounts) { Text($0.info.displayName).tag($0.id) }
                        }
                        Text("Used for ⌘N in the merged view, the menu bar and the global hotkeys. Accounts never sync with each other; snippets only move when you choose Copy to or Move to.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(app.accounts) { account in
                    AccountSection(account: account, store: account.store, confirmClear: $confirmClear, addRequest: $addRequest)
                }
            }
            Section {
                Button("Add Account…") { addRequest = AddAccountRequest(reauth: nil) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
        .sheet(item: $addRequest) { request in
            SignInView(adding: true, reauth: request.reauth)
                .frame(width: 440)
                .padding(24)
        }
        .confirmationDialog("Sign out and delete the offline copy?", isPresented: Binding(
            get: { confirmClear != nil },
            set: { if !$0 { confirmClear = nil } }
        )) {
            Button("Sign Out and Clear Cache", role: .destructive) {
                if let id = confirmClear { app.signOut(id, clearCache: true) }
                confirmClear = nil
            }
        } message: {
            Text("Changes that haven't synced yet are lost.")
        }
    }
}

private struct AccountSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var account: Account
    @ObservedObject var store: SnippetStore
    @Binding var confirmClear: String?
    @Binding var addRequest: AddAccountRequest?

    var body: some View {
        Section {
            TextField("Name:", text: Binding(
                get: { account.info.name },
                set: { name in app.updateInfo(account.id) { $0.name = name } }
            ), prompt: Text(account.info.serverURL?.host ?? ""))
            Picker("Color:", selection: Binding(
                get: { account.info.color },
                set: { color in app.updateInfo(account.id) { $0.color = color } }
            )) {
                ForEach(AccountColor.allCases) { color in
                    Label {
                        Text(color.label)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(color.color)
                    }
                    .tag(color)
                }
            }
            LabeledContent("Server:", value: account.info.server)
            LabeledContent("Signed in as:", value: account.info.username)
            LabeledContent("Snippets:", value: "\(store.library.own.count) own, \(store.library.shared.count) shared")
            if let last = store.library.lastSync {
                LabeledContent("Last sync:", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if !store.outbox.isEmpty {
                LabeledContent("Waiting to sync:", value: "\(store.outbox.count) change(s)")
            }
            Toggle("Keep an offline copy on this Mac", isOn: Binding(
                get: { account.info.keepsOfflineCache },
                set: { keep in app.updateInfo(account.id) { $0.keepsOfflineCache = keep } }
            ))
            .help("Turn off if this server's snippets must not be stored on this Mac. They then load again each time the app starts.")
            HStack {
                if account.needsSignIn {
                    Button("Sign In Again…") { addRequest = AddAccountRequest(reauth: account.info) }
                }
                if app.hasMultipleAccounts {
                    Button { app.moveAccount(account.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .help("Move up")
                        .disabled(app.accounts.first?.id == account.id)
                    Button { app.moveAccount(account.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .help("Move down")
                        .disabled(app.accounts.last?.id == account.id)
                }
                Spacer()
                Button("Sign Out") { app.signOut(account.id) }
                Button("Sign Out and Clear Cache…", role: .destructive) { confirmClear = account.id }
            }
        } header: {
            HStack(spacing: 6) {
                Circle().fill(account.info.color.color).frame(width: 9, height: 9)
                Text(account.info.displayName)
                if account.needsSignIn {
                    Text("· needs sign-in").foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct AddAccountRequest: Identifiable {
    let id = UUID()
    let reauth: AccountInfo?
}
