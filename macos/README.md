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
- **List or grid** (⌥⌘1 / ⌥⌘2): the grid shows cards with highlighted code previews.
- **Markdown**: Markdown files open in a rendered preview that matches the web app:
  GitHub-flavoured Markdown (tables, task lists, line breaks kept), `> [!NOTE]` style
  alerts, highlighted code blocks, and **Mermaid diagrams** with zoom (buttons, ⌘-scroll or
  pinch, drag to pan), copy code, SVG/PNG download and full screen. The camera button exports
  the whole preview as PNG (or PDF). Switch to Source to edit (⌥⌘P).
- **Search** in the list: words match title, description, tags, file names and code;
  `#tag` and `lang:python` narrow the results.
- **Quick search** (⌥⌘Space anywhere, configurable): type, ↑↓ to pick, ↩ copies the
  code, ⇥ switches between files, ⌘↩ opens the snippet in the main window.
- **Save selected text** (⇧⌥⌘C anywhere): copies the selection in the current app and
  saves it as a new snippet. **New snippet from clipboard** hotkey too (set it in Settings).
- **Menu bar popover**: search box, Recent, Pinned & Favorites and Recently Edited
  snippets; click or ↩ to copy.
- **Auto-paste** (Settings → General): choosing a snippet in quick search or the menu bar
  pastes it straight into the app you were using. Auto-paste and Save selected text need
  Accessibility access (System Settings → Privacy & Security → Accessibility).
- **Offline**: everything is cached on disk. Edits made offline are queued and sent in
  order when the server is back; the sidebar footer shows pending changes.
- Pin, favorite, duplicate, private/public, share links (with expiry and sign-in
  requirement), open in browser, recycle bin with restore.

- **Multiple selection**: ⌘-click, ⇧-click or ⌘A in the list or grid. With several snippets
  selected, copy their code, pin, favorite, tag, copy or move them to another account, or
  move them to the Recycle Bin at once (right-click, the Snippet menu, or the pane on the right).
- **Drag and drop** onto the sidebar: a tag adds it (hold ⌥ to replace the tags), Pinned and
  Favorites pin or favorite, the Recycle Bin deletes. Dragging into another app drops the code.
- **Sharing** (Share → Sharing…): private, public, or shared with groups and people,
  each with Can view or Can edit, plus Lock editing. Groups you belong to appear under
  Shared in the sidebar.
- **Several accounts** (Settings → Accounts → Add Account…), for example a personal server
  and a work server. Each account keeps its own token, offline cache and pending changes;
  the servers are never synced with each other.
  - The sidebar's **All · Personal · Work** switch shows every account merged, or one.
    In the merged view each snippet has a colored account badge, and search, quick search
    and the menu bar cover all accounts.
  - New snippets go to the account you're viewing. In the merged view ⌘N, the menu bar and
    the global hotkeys use the default account (Settings → Accounts, normally Personal);
    hold the New button to pick another account.
  - **Copy to / Move to** (right-click, or the Snippet menu) creates a private copy on the
    other server after you confirm. Tags and files carry over; sharing, pins and favorites
    don't, because groups and users differ per server. Move also puts the original in its
    Recycle Bin. Snippets other people own can be copied, not moved.
  - Per account you can set a name, a color, and turn off **Keep an offline copy on this
    Mac** (for example when work snippets must not be stored on a personal laptop).
  - **Drag and drop**: drag snippets onto an account in the sidebar's Accounts section to
    copy them there; hold ⌘ while dropping to move them instead (like dragging files to
    another disk in Finder). Both ask for confirmation first.
  - An expired session only affects that account: its cached snippets stay visible and the
    sidebar footer offers "Sign in again".

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌥⌘Space | Quick search (global) |
| ⇧⌥⌘C | Save selected text as a snippet (global) |
| ⌘N | New snippet |
| ⌘K | Quick search |
| ⌘R | Sync now (every account) |
| ⌃⌘0, ⌃⌘1… | All accounts, or one account (with more than one account) |
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

Requires Xcode 16. Dependencies (Swift packages): KeyboardShortcuts, Highlightr. The Markdown
preview bundles marked, highlight.js and Mermaid under `ByteStash/Resources/MarkdownPreview/vendor`
(no network needed); refresh them with `scripts/update-markdown-vendor.sh`.

```
ByteStash/
  App/          entry point, menus, AppState (accounts, merged views, copy/move)
  API/          REST client and models
  Auth/         Keychain, OIDC web sign-in
  Store/        SnippetStore (cache, sync, outbox), search and filters
  Editor/       syntax-highlighted code view, language table
  Views/        sidebar, list, detail, sign-in, settings, Markdown preview (web view)
  Resources/MarkdownPreview/  preview page (preview.js/css) and bundled JS libraries
  QuickSearch/  global hotkey panel
Design/       AppIcon.svg (source of the app icon in Resources/Assets.xcassets)
ByteStashTests/ model, search, outbox, account and language tests
```

---

## 中文

原生 macOS ByteStash 用戶端，操作方式參考 SnippetsLab。

- **安裝**：到 GitHub Actions 的 **macOS app** 工作流程下載 `ByteStash-macOS.zip`，解壓後把
  `ByteStash.app` 放到「應用程式」。沒有經過公證，第一次請按右鍵選「打開」。需要 macOS 14 以上。
- **登入**：帳號密碼、伺服器的 SSO/OIDC（例如 Google），或伺服器關閉帳號時直接進入。
- **三欄介面**：側欄（全部、置頂、最愛、未分類、共享給我、公開、各標籤和語言、回收桶）、清單、編輯器。
- **編輯器**：語法高亮、行號、多檔案、依檔名自動判斷語言、自動儲存。
- **清單／格狀**（⌥⌘1 / ⌥⌘2）：格狀模式用卡片顯示有語法高亮的程式碼預覽。
- **Markdown**：預覽和網頁版一致：GFM（表格、待辦清單、保留換行）、`> [!NOTE]` 提示框、程式碼語法高亮，以及 **Mermaid 圖表**（放大縮小、⌘ 捲動或雙指縮放、拖曳平移、複製程式碼、下載 SVG/PNG、全螢幕）。相機按鈕可把整份預覽匯出成 PNG（或 PDF）。和原始碼可以切換（⌥⌘P）。
- **搜尋**：標題、說明、標籤、檔名和程式碼全文；`#標籤`、`lang:python` 可縮小範圍。
- **快速搜尋**：任何地方按 ⌥⌘Space，↩ 複製程式碼，⌘↩ 在主視窗開啟。
- **選單列面板**：搜尋框、最近用過、置頂和最愛、最近編輯，點一下就複製。
- **自動貼上**（設定 → 一般）：選好片段直接貼到原本的 App。
- **存選取文字**：任何 App 選好文字按 ⇧⌥⌘C 存成片段。自動貼上和這個功能需要開「輔助使用」權限。
- **分享**：私人、公開，或指定群組和人（可檢視／可編輯），也可以鎖定編輯。側欄「共享」下會列出你的群組。
- **離線**：所有片段都快取在本機，離線時的修改會排隊，連線後依序同步。
- **多選**：⌘點擊、⇧點擊或 ⌘A。選了多個片段之後可以一次複製程式碼、置頂、加入最愛、加標籤、
  複製或移動到其他帳號、丟進回收筒。
- **拖拉到側欄**：拖到標籤是加上這個標籤（按住 ⌥ 是取代原本的標籤），拖到置頂、最愛就加入，
  拖到回收筒就刪除；拖到其他 App 會放入程式碼。
- **多帳號**（設定 → 帳號 → Add Account…）：例如個人和公司各一台伺服器。每個帳號各自有 token、
  離線快取和待同步的修改，兩台伺服器之間不會自動同步。
  - 側欄上方的 **All · Personal · Work** 可以看全部（融合）或只看一個帳號；融合模式下每個片段都有帳號顏色標籤，
    搜尋、快速搜尋和選單列會一起搜所有帳號。
  - 新片段會放在目前看的帳號；融合模式下 ⌘N、選單列和全域快捷鍵用預設帳號（通常是 Personal），
    按住 New 按鈕可以選其他帳號。
  - **Copy to / Move to**（右鍵或 Snippet 選單）：確認後在另一台伺服器建立一份私人片段。
    標籤和檔案會帶過去，分享設定、置頂和最愛不會；Move 會把原本那份放進回收筒。別人的片段只能複製。
  - **拖拉**：把片段拖到側欄「Accounts」裡的帳號是複製，放手時按住 ⌘ 是移動，兩種都會先確認。
  - 每個帳號可以改名字、顏色，也可以關掉「在這台 Mac 保留離線副本」。
