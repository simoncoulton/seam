# AGENTS.md

Notes for AI agents working on Seam, a keyboard-first, Miller-column file manager for macOS. It is a native Swift
(SwiftUI + AppKit) app, heavily inspired by Strata (stratafiles.io). The project folder is still called
`stratafiles-macos`; everything inside is named Seam. It is not a git repository.

## Build and run

    swift build                    # compile
    scripts/bundle.sh debug        # -> build/Seam.app (release by default without the argument)
    swift scripts/make-icon.swift Resources/AppIcon.icns   # regenerate the icon

- Bundle id `dev.seam.macos`; settings live in that UserDefaults domain and in `~/Library/Application Support/Seam/`.
- Only the Command Line Tools are installed, not Xcode. There is no SwiftUIMacros plugin, so **`@State` does not
  compile**. Use `Local<T>` (an `ObservableObject` in `Model.swift`) with `@StateObject`. `@Observable` works.
- Swift 5 language mode, macOS 14 minimum. Build warnings about Sendable and `NSEvent` are known and harmless.
- There are no unit tests in the package. See "Testing without disturbing the user" below.

## Layout (`Sources/Seam/`)

| File | Role |
| --- | --- |
| `App.swift` | `@main` app, `AppDelegate` (activation, key monitor, `application(_:open:)` for folders opened by other apps), menu commands |
| `Workspace.swift` | Singleton app state: tabs, theme, places and pins, file operations, and the **single keyboard handler** `handle(_:)` |
| `BrowserState.swift` | Per-tab Miller-column model: `columns`, `focus`, selection, marks, filters, per-folder sort, navigation |
| `Browsers.swift` | `MillerView`, `ColumnView`, `FileRow`, `ColumnFilter` and `SortBar`, context menus |
| `RootView.swift` | Window layout: sidebar, tab bar, path bar, status bar (footer sizes), preview pane and its resize handle, options menu |
| `Sidebar.swift` | Pinned, Places (editable, drag-reorderable), AirDrop, Network, Devices |
| `Overlays.swift` | Search, location bar and shortcuts overlays |
| `Location.swift` | Location bar: shell-style Tab completion, `smb://` share listing and mounting |
| `SearchModel.swift` | Fuzzy file search (on-demand index, see below) |
| `DiskSize.swift` | Recursive size scanner (`getattrlistbulk`) and cache, used by the footer |
| `Preview.swift`, `Hover.swift`, `Theme.swift`, `Model.swift` | Previews, hover and icon helpers, themes (17 presets + TOML), shared types |

## Conventions and invariants

- **All keys go through `Workspace.handle(_:)`**, installed with `NSEvent.addLocalMonitorForEvents`. It sees events
  before the menu bar does, which is why menu items only mirror shortcuts (for display) and why ⌘+HJKL-style
  shortcuts are avoided (the user runs Aerospace). Letters are matched by physical key code (`letterByKeyCode`), so
  vim keys work on non-Latin layouts. When you add or change a binding, update the shortcuts overlay
  (`ShortcutsOverlay` in `Overlays.swift`), the README and any context-menu hint.
- **Column invariant:** the focused column's selected folder always has a column right after it
  (`columns.count == focus + 2`). `select()` truncates/appends columns; `stepLeft` closes only the trailing one.
- **Paths:** compare paths through `URL.realURL` (`realpath`). Foundation's `resolvingSymlinksInPath` and
  `standardizedFileURL` strip `/private`, the opposite of what `contentsOfDirectory` returns, so `/var`, `/tmp` and
  `/etc` selections stop matching.
- **Scanning is shared in shape:** `DiskSize.swift` and the search index in `SearchModel.swift` both use
  `getattrlistbulk` with a 256 KB buffer, a 4...8 thread pool over a shared directory stack, no symlink following
  and no crossing volumes. The packed record offsets (name ref at 24, devid at 32, objtype at 36, ...) depend on the
  requested attribute set; change the attribute list and you must change the offsets.
- **Search is deliberately on demand:** it indexes the current folder only while the overlay is open and frees it on
  close. The user explicitly does not want home-folder or background indexing. Do not add either.
- **Footer size** is logical bytes (Finder-style) with the on-disk figure in the tooltip. It is cancelled when the
  selection moves, debounced 120 ms, and cached in `SizeCache` until a directory-watcher event or `reloadAll()`.
- **Sidebar reordering** uses `Workspace.draggingRow` and `dropTarget` rather than reading the drag pasteboard. A
  plain-text payload that looks like a URL gets treated as a file drop, which is how an earlier version broke.
- **SwiftUI scroll quirk:** when the preview opens, `MillerView` scrolls once immediately and again 0.25 s later,
  because the first scroll is computed against a mid-animation width and leaves the last column clipped.
- Cursor changes on the preview divider use `NSCursor.set()` on every hover event; push/pop gets undone by
  neighbouring views.

## Behaviours the user asked for (do not regress)

- No view-mode switcher (grid/list). Filter bar appears only after `/`, per column, with a sort-type tab row and a
  separate direction button. Hidden files are shown by default.
- `y`/⌘C copy, `p`/⌘V paste; **`p` no longer pins**. ⌘⌫ moves to Trash, ⇧⌘⌫ deletes permanently after a
  confirmation alert. Return renames (`l`/→ opens). ⌘N new file, ⇧⌘N new folder. ⌘-click marks a row.
- Cmd+L and Cmd+D are not used (Aerospace); location is Cmd+O or `:`, search is Cmd+F (they replaced Ctrl+L/K; Cmd+O no longer opens items, use `l`, → or ⌘↓).
- Vim navigation everywhere: counts, `gg`/`G`, `gh`, `gt`/`gT`, Ctrl-D/U/F/B/O, `-`, Tab.
- Selected row takes the theme colour with a border only in the focused column. Moving left removes a column.
- `smb://server` with no share must list shares (`smbutil view -N`), falling back to the macOS login UI.
- Window opacity goes down to 20%. Monochrome icons are tinted from the theme.

## Testing without disturbing the user

The user works on this machine while you run. **Never drive the real GUI with synthetic HID events** (they can
land in whatever app is frontmost), and never write test values into the real defaults domain `dev.seam.macos`
(an earlier test wiped the user's pins).

What worked well:

- Compile the app's real sources (everything except `App.swift`) together with a custom `main.swift` using `swiftc`,
  and drive them in process: synthesize key events with `NSEvent.keyEvent(...)` and `NSApp.sendEvent`.
- For layout and screenshots, host `RootView()` in a borderless `NSWindow` placed off-screen (for example at
  -20000,-20000) and use `cacheDisplay`. `ImageRenderer` cannot draw `ScrollView`s.
- For GUI launches, use a copy of the bundle with a different bundle id and `open -n`, and have harnesses call
  `removePersistentDomain` for their own domain when finished.
- Check the scanner against `du -sk` and an independent Python walk, not against itself.
- Pure helpers (`SMBAddress`, `parseShares`, completion, search matching) can be tested by compiling their files
  into a small script.

## Environment gotchas

- The user's `ls` is aliased to `eza`; use `find` or `/bin/ls` in scripts. `timeout` is not installed.
- Installed helpers: `fd`, `rg`, `fzf` (homebrew). The app does not depend on them.
- Confirm before anything outward-facing or hard to reverse. Use they/them for anyone whose pronouns are unknown.
