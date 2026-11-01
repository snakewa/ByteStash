# ByteStash for Mac

A native macOS client for ByteStash, in the spirit of SnippetsLab: three-pane library,
syntax-highlighted editor, a Spotlight-style quick search on a global hotkey, a menu bar
icon, and an offline cache that syncs when the server is reachable.

[中文說明](#中文)

## Install

Download `ByteStash-macOS.zip` from the latest **macOS app** workflow run (Actions tab) or
from a `macos-v*` release, unzip, and move `ByteStash.app` to Applications. The build is not
notarized, so the first time right-click the app and choose **Open** (or run
`xattr -dr com.apple.quarantine /Applications/ByteStash.app`).

Requires macOS 14 Sonoma or later. Universal (Apple silicon and Intel).

## Features

- **Sign in** with username and password, with your server's SSO/OIDC (Google, Authentik,
  Keycloak, ...), or without accounts when the server runs with `DISABLE_ACCOUNTS=true`.
  The token is kept in the Keychain.
- **Library sidebar**: All, Pinned, Favorites, Untagged, Shared with Me, Public, every tag
  and language with counts, and the Recycle Bin.
- **Editor**: title, description, tags, multiple files per snippet, language per file
  (guessed from the file name), syntax highlighting (highlight.js themes, separate light and
  dark theme), line numbers, auto-indent, find bar (⌘F inside the editor). Changes save
  automatically.
- **Search** in the list: words match title, description, tags, file names and code;
  `#tag` and `lang:python` narrow the results.
- **Quick search** (⌥⌘Space anywhere, configurable): type, ↑↓ to pick, ↩ copies the
  code, ⇥ switches between files, ⌘↩ opens the snippet in the main window.
- **New snippet from clipboard** global hotkey (set it in Settings).
- **Menu bar**: quick search, new from clipboard, and one-click copy of pinned and
  favorite snippets.
- **Offline**: everything is cached on disk. Edits made offline are queued and sent in
  order when the server is back; the sidebar footer shows pending changes.
- Pin, favorite, duplicate, private/public, share links (with expiry and sign-in
  requirement), open in browser, recycle bin with restore.

Sharing with groups and people is shown (who owns it, read-only, locked) but is still
managed in the web app.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌥⌘Space | Quick search (global) |
| ⌘N | New snippet |
| ⌘K | Quick search |
| ⌘R | Sync now |
| ⌥⌘C | Copy the selected snippet's code |
| ⇧⌘C | Copy the current file |
| ⌘D | Favorite |
| ⇧⌘P | Pin |
| ⌘1 to ⌘4 | All, Favorites, Shared, Recycle Bin |
| Delete | Move the selected snippet to the Recycle Bin |

## SSO / OIDC

The app opens `<server>/api/auth/oidc/auth?client=desktop` in a system sign-in sheet. The
server then redirects to `bytestash://auth/callback?token=...` instead of the web app. This
needs a server that includes that change (this fork, from the PR that added the app). No
extra redirect URI has to be registered with the identity provider: it still calls the
server's normal `/api/auth/oidc/callback`.

## Build from source

```sh
brew install xcodegen
cd macos
xcodegen generate
open ByteStash.xcodeproj
```

Requires Xcode 16. Dependencies (Swift packages): KeyboardShortcuts, Highlightr.

```
ByteStash/
  App/          entry point, menus, menu bar, AppState (account + session)
  API/          REST client and models
  Auth/         Keychain, OIDC web sign-in
  Store/        SnippetStore (cache, sync, outbox), search and filters
  Editor/       syntax-highlighted code view, language table
  Views/        sidebar, list, detail, sign-in, settings
  QuickSearch/  global hotkey panel
ByteStashTests/ model, search, outbox and language tests
```

---

## 中文

原生 macOS ByteStash 用戶端，操作方式參考 SnippetsLab。

- **安裝**：到 GitHub Actions 的 **macOS app** 工作流程下載 `ByteStash-macOS.zip`，解壓後把
  `ByteStash.app` 放到「應用程式」。沒有經過公證，第一次請按右鍵選「打開」。需要 macOS 14 以上。
- **登入**：帳號密碼、伺服器的 SSO/OIDC（例如 Google），或伺服器關閉帳號時直接進入。
- **三欄介面**：側欄（全部、置頂、最愛、未分類、共享給我、公開、各標籤和語言、回收桶）、清單、編輯器。
- **編輯器**：語法高亮、行號、多檔案、依檔名自動判斷語言、自動儲存。
- **搜尋**：標題、說明、標籤、檔名和程式碼全文；`#標籤`、`lang:python` 可縮小範圍。
- **快速搜尋**：任何地方按 ⌥⌘Space，↩ 複製程式碼，⌘↩ 在主視窗開啟。
- **選單列**：快速搜尋、用剪貼簿新增、一鍵複製置頂和最愛片段。
- **離線**：所有片段都快取在本機，離線時的修改會排隊，連線後依序同步。
