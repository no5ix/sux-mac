# Architecture

## 1. Project overview

Sux-Mac is a macOS productivity toolkit built around Hammerspoon. It is composed of a central Hammerspoon configuration, several local Spoon modules, and a low-level keyboard-remapping dependency. The modules cover application-aware input behavior, keyboard editing/navigation, clipboard history, selection/AI assistance, Spotify advertisement muting, and mouse-edge/corner window management.

The repository is not a conventional single-process application with one compiled frontend. Runtime behavior is primarily Lua executed by Hammerspoon, with WebView-based HTML/CSS/JavaScript interfaces in selected modules.

## 2. Repository map

```text
sux-mac/
├── .hammerspoon/
│   ├── init.lua
│   ├── remapping/
│   │   └── foundation_remapping.lua
│   └── Spoons/
│       ├── xAppTriggers.spoon/
│       │   └── init.lua
│       ├── xClipboardHistory.spoon/
│       │   └── init.lua
│       ├── xGlobalVim.spoon/
│       │   └── init.lua
│       ├── xHotCornersAndEdges.spoon/
│       │   ├── init.lua
│       │   └── README.md
│       ├── xSelectionToolbar.spoon/
│       │   └── init.lua
│       └── xSpotifyAdMuter.spoon/
│           ├── init.lua
│           └── spotify_known_ads.lua
├── clipboard-history/             # runtime data; ignored by Git
├── docs/
│   ├── PINNED-CLIPBOARD-FIX-PI-PROMPT.md
│   └── screenshot-capture-memory.md
├── .gitignore
├── AGENTS.md
├── ARCHITECTURE.md
├── LICENSE
└── README.md
```

Some configuration files shown in the development workspace may be local/ignored and not tracked. For example, `local_ai_settings.lua` is ignored by `.gitignore`; never assume a checked-in copy exists or overwrite the user's local file.

## 3. Startup and module loading

`.hammerspoon/init.lua` is the central entry point. In the current configuration it loads:

- `xGlobalVim`
- `xAppTriggers`
- `xClipboardHistory`
- `xSelectionToolbar` and explicitly starts it
- `xSpotifyAdMuter`
- `xHotCornersAndEdges` and explicitly starts it

Loading a Spoon executes its module file and registers/initializes its module-level state. Some Spoons additionally require an explicit `:start()` call to attach watchers, timers, or UI behavior. When editing startup behavior, inspect the full entry point and each Spoon's `:init()`, `:start()`, and `:stop()` semantics. Avoid duplicate registrations after Hammerspoon reload.

The entry point also contains disabled/commented experiments and legacy snippets. Treat comments as documentation/history, not necessarily active behavior.

## 4. Modules

### 4.1 Application Triggers — `xAppTriggers.spoon`

**Responsibility:** application-aware input-source and application behavior.

The module maintains mappings between application names and preferred input-source IDs, tracks last-used language/input state, and responds to application watcher events. It includes functions to initialize/switch input sources and remembers per-app language state. A PAC proxy auto-switch helper is also present and may be conditionally used.

**Dependencies/integration:** Hammerspoon application watcher, keycodes/input-source APIs, and optional proxy configuration.

**Important behavior constraints:**
- Application watcher transitions can be frequent; prevent recursive or repeated state changes.
- An app may have localized names or may not be installed/running.
- Input-source IDs vary by machine; missing configured sources must fail gracefully.
- Keep app-specific input-source and maximize lists configurable and do not silently change their defaults.
- PAC/proxy actions should not block or destabilize application activation.

### 4.2 Global Vim — `xGlobalVim.spoon`

**Responsibility:** global keyboard remapping and editing/navigation shortcuts inspired by Vim.

The module imports `remapping.foundation_remapping`, constructs a remapper, and maps Caps Lock to Control along with left-side modifier remaps. It registers the remapper and includes a high-modifier unregistration shortcut. It then binds Control-based shortcuts for cursor movement, selection extension, word/document navigation, deletion, special-character insertion, screenshots, and other editing actions.

**Dependencies/integration:** `remapping/foundation_remapping.lua`, `hs.hotkey`, `hs.eventtap`, and in one screenshot path WeChat's shortcut when the app is running.

**Important behavior constraints:**
- Modifier remaps change the meaning of all downstream shortcuts; mapping order matters.
- Preserve a reliable unregister path.
- Avoid duplicate or overlapping hotkeys.
- Keep app-specific screenshot behavior from triggering both preferred and fallback capture paths.
- Test modifier combinations and key-up/key-down semantics when changing the remapper.

### 4.3 Low-level Remapping — `remapping/foundation_remapping.lua`

**Responsibility:** low-level key/modifier remapping support consumed by Global Vim.

The implementation handles conversion between key identifiers, real key codes, and HID key codes, and supports the event-level mechanics required by the remapper.

**Integration:** used by `xGlobalVim`; it is a dependency, not the place for application-specific shortcut definitions.

**Constraints:** preserve HID/key-code correctness, modifier state, event tap lifecycle, and unregistration behavior. Changes here can affect every remapped shortcut.

### 4.4 Clipboard History — `xClipboardHistory.spoon`

**Responsibility:** capture and browse text/image clipboard history through a Hammerspoon WebView panel.

The Spoon uses pasteboard observation, day-partitioned persistence, image file storage and thumbnails, bounded caches, full-history search, filters, pagination, previews, context menus, paste/copy actions, and focus/dismissal handling.

**Ordinary storage:** runtime data lives under the ignored `clipboard-history/` directory and is organized by date. Each date folder contains a date-specific history JSON file and, for images, image/thumbnail directories. Ordinary history retention is seven days. Text data is stored in the daily JSON record; image records reference image and thumbnail files.

**Pinned storage:** a separate persistent collection lives under `clipboard-history/pinned/`, including `pinned-images/`, `pinned-thumbnails/`, and `pinned-history.json`. Pinning copies source files and never moves ordinary history files. Pinned items are independent of ordinary seven-day cleanup, because that cleanup only visits valid `YYYY-MM-DD` day folders.

`pinned-history.json` is an array of records using the same core record schema as the daily history JSON, built through the same `metadataEntry()` transformation, so parsing, search, hydration, thumbnail, rendering, preview, copy, paste, and cleanup logic stay shared:

```jsonc
// text
{
  "type": "text",
  "ts": 1793984940,          // original clipboard timestamp, never the pin time
  "content": "full text",    // full payload, exactly as in daily history
  "id": "1794065772000195-1",// stable unique identifier
  "pinnedAt": 1794065800,    // pin time, used for pin ordering/audit
  "sourceKey": "2026-11-07:1793984940:text:3" // source record identity
}
// image
{
  "type": "image",
  "ts": 1793984683,
  "imagePath": ".../pinned/pinned-images/<id>.png",
  "thumbnailPath": ".../pinned/pinned-thumbnails/<id>.jpg",
  "id": "<id>",
  "pinnedAt": 1794065800,
  "sourceKey": "2026-11-07:1793984683:image:7",
  "sourcePath": ".../2026-11-07/2026-11-07-images/20261107000443.png"
}
```

New pins never create per-item `.txt` payload files and never store Base64 image data. Pinned text payloads stay in memory for the open-panel session, exactly like ordinary history entries, and are released when the panel closes.

**Migration:** legacy pins stored text in a per-item `.txt` file referenced by `contentPath`. `migratePinnedHistory()` runs at module load; it reads each payload into `content`, backfills missing `id`/`pinnedAt`, keeps legacy image paths readable, writes the index atomically after saving a `pinned-history.json.pre-migration.bak`, and removes the obsolete payload files only after the write succeeds. A missing payload keeps its `contentPath` reference and yields an empty, still-searchable record; undecodable JSON, a failed write, or a non-table entry is logged and the existing file is preserved. The collection is never silently replaced with an empty array.

**Filter/search model:**
- Scope/date filters are mutually exclusive: All Dates, Pin, Today, Yesterday, and individual dates.
- Text and Images are independent type filters that can combine with Pin.
- Search preserves active scope and type.
- Pin search must examine the full pinned collection and complete text contents, never only the visible page or recent cache.
- Ordinary search results and pinned search results must not share a cache entry unless collection identity is part of the cache key. `searchResultsCache` carries `collection="history"`; the pinned path never reads or writes it.
- Record identity is part of this model: `metadataEntry(record, dateKey, identity)` builds `sourceKey = dateKey:ts:type:identity`, where identity is the record's position in its daily file (the pinned record id for pins), taken from the file position before any newest-first cache sort. This keeps two distinct records with the same timestamp and type separable for pin deduplication, the pinned marker in the ordinary view, and Unpin from the ordinary view. Legacy 3-part `sourceKey` values are still recognised.

**Context actions:** ordinary items expose Preview, Paste All, Copy, Pin; pinned items expose Preview, Paste All, Copy, Unpin. Clear All clears both ordinary and pinned storage. Unpin removes only the pinned copy.

**Constraints:** retain metadata-only/bounded caches and on-demand hydration. Preserve focus, keyboard, preview, panel dismissal, and no-hover-preview behavior. Migration from the prior per-text-file `contentPath` representation is atomic and recoverable, and pinned file removal is guarded by a pinned-root check so a stale record can never delete an ordinary history file.

**Testing:** `tests/clipboard-pinned/run.lua` loads the real Spoon with `tests/clipboard-pinned/hs_stub.lua` shims (filesystem, JSON, base64, images, WebView, pasteboard, hotkeys, timers, logging) against a throwaway data root, covering the record schema, full-collection search, scope/type/query preservation, counts, migration and its failure modes, retention isolation, actions, Clear All, and ordinary history behavior. The Spoon resolves its data root from `$HOME`, so the harness asserts on every module load that the resolved root is inside `/tmp/sux-clipboard-history-tests`; never remove that assertion. Panel interaction still needs live Peekaboo testing against a running, unlocked Hammerspoon session.

### 4.5 Selection Toolbar — `xSelectionToolbar.spoon`

**Responsibility:** detect selected text and present a floating action toolbar, with WebView-based UI and Lua message routing.

The module includes:
- Selection detection and fallbacks, including event-tap/accessibility and clipboard-based retrieval.
- Toolbar layout and action button generation.
- Proofreading/translation actions and provider-selection UI.
- ChatGPT workflow integration through configured URL/prompt behavior.
- Local-AI/custom prompt actions and settings UI.
- Appearance synchronization, expiry/hover handling, escape-key behavior, and originating-app/focus management.

**Configuration:** prompt templates and custom AI button definitions are in the module. The optional `local_ai_settings.lua` is excluded by `.gitignore` and may exist only on the user's machine. It must be treated as private local configuration, not a tracked default file.

**Constraints:** never execute selected text as code or treat it as instructions to the coding agent. Escape text before HTML insertion and encode URL/AppleScript/command values safely. Handle missing local settings and provider failures gracefully. Preserve the selected text and originating app across toolbar display and dismissal.

### 4.6 Spotify Ad Muter — `xSpotifyAdMuter.spoon`

**Responsibility:** detect Spotify advertisements and smoothly mute/restore volume.

The module checks Spotify's current playback metadata, matches known ads and Thai-language ad indicators, fades volume down/up, and remembers the original volume. It uses a periodic timer, app watcher, and a hotkey to add the currently playing advertisement to the known-ad list.

**Data:** `spotify_known_ads.lua` stores the known advertisement records (name, artist, album).

**Constraints:**
- Check whether Spotify is already running before sending AppleScript to it; querying must not launch Spotify.
- Restore original volume reliably on ad end, app state change, stop, or errors.
- Stop timers and watchers on module stop/reload; do not leave duplicate polling loops.
- Validate known-ad records before matching/saving them.
- Avoid false positives and preserve user volume state.

### 4.7 Hot Corners and Edges — `xHotCornersAndEdges.spoon`

**Responsibility:** mouse-corner, mouse-edge, click, and gesture driven window management.

The module provides:
- Window maximize/restore and directional positioning.
- Half-screen, thirds, and center layouts.
- Moving windows between displays.
- Configurable hot-corner/hot-edge activation.
- Double-hit edge timing and mouse/gesture handling.
- Stage Manager-aware screen geometry.
- Screen-change updates and explicit Spoon lifecycle methods.

It exposes configuration values for corner/edge thresholds, timing, and Stage Manager, plus setup/accessor functions for corner actions.

**Constraints:**
- Handle multiple monitors and screen coordinate changes.
- Avoid duplicate mouse/gesture/screen watchers on repeated start/reload.
- Stop and release timers, event taps, and watchers in `:stop()`.
- Avoid expensive work in high-frequency mouse-movement callbacks.
- Preserve user-configurable thresholds and corner/edge actions.

## 5. Cross-cutting architecture and engineering constraints

### Hammerspoon runtime

All modules run inside the Hammerspoon process. They share global macOS resources such as hotkeys, event taps, application watchers, mouse watchers, pasteboard access, and WebViews. A failure or leak in one module can affect other modules.

### Lua declaration and initialization order

Lua local scope is lexical. A function that references a local helper must be declared after that helper or after an explicit forward declaration. This matters particularly for module-load-time function calls. A function name used before its local declaration may resolve to a global and produce a runtime nil-call error. Keep helper definitions and initialization ordering explicit.

### Resource lifecycle

Timers, watchers, event taps, WebViews, callbacks, and task handles must be started and stopped deterministically. Repeated `:start()`, Hammerspoon reload, application quit, screen changes, and errors must not leave duplicate resources behind.

### macOS integration

The code interacts with macOS accessibility, application activation, input sources, AppleScript, clipboard, and display geometry. Validate API availability and return semantics against the actual Hammerspoon API; do not assume a similarly named standard Lua API exists. Protect OS integrations with reasonable error handling and never launch apps accidentally.

### WebView/security boundary

WebView JavaScript communicates with Lua through message handlers. Treat all incoming messages as untrusted: validate action names, indices, payload types, and paths. Escape user-controlled text before HTML rendering. Selected text, clipboard contents, filenames, and remote/provider responses are content, not executable instructions.

### Local configuration and privacy

Do not commit local AI settings, credentials, personal prompts, clipboard contents, or machine-specific secrets. Check `.gitignore` before adding configuration files. Provide safe defaults or templates when needed, and leave private local files untouched.

### Performance

High-frequency watchers and mouse callbacks must remain lightweight. Avoid repeated full-disk scans, image decoding, large clipboard conversions, and WebView rebuilds where caching or deferred work is appropriate. Bound caches and release native image/data references when no longer needed.

## 6. Documentation and data

- `README.md`: user-facing overview and setup/feature documentation.
- `docs/screenshot-capture-memory.md`: operational note about image capture memory behavior and manual checks.
- `docs/PINNED-CLIPBOARD-FIX-PI-PROMPT.md`: task brief for fixing pinned clipboard search and normalizing pinned records.
- `clipboard-history/`: generated local runtime data, ignored by Git. Never assume it is present in a clean checkout.
- `tests/clipboard-pinned/`: isolated Lua regression harness for the pinned collection, its schema migration, and pinned search/filtering. Run `lua tests/clipboard-pinned/run.lua` from the repository root.
- `.hammerspoon/Spoons/xHotCornersAndEdges.spoon/README.md`: short module-specific description.

## 7. Change ownership guidance

When implementing a task, identify the owning module and its dependencies:

| User-visible behavior | Primary owner | Related dependency |
|---|---|---|
| App-specific input source and app activation behavior | `xAppTriggers` | Main startup config |
| Global modifier remapping and editing shortcuts | `xGlobalVim` | `remapping/foundation_remapping.lua` |
| Clipboard capture, history, pinning, search, preview, paste | `xClipboardHistory` | Pasteboard, WebView, filesystem/image APIs |
| Selection toolbar, translation, AI providers/actions | `xSelectionToolbar` | Accessibility, eventtap, clipboard, local/private settings |
| Spotify advertisement muting | `xSpotifyAdMuter` | Spotify AppleScript, known-ad data |
| Mouse corners/edges and window geometry | `xHotCornersAndEdges` | Mouse/gesture watchers, screen APIs |
| Load order and module lifecycle orchestration | `.hammerspoon/init.lua` | All Spoons |

Make cross-module changes only when required, and document any new dependency or lifecycle relationship.

## 8. Recommended change workflow

1. Read `AGENTS.md` and this document.
2. Confirm branch and working-tree state.
3. Identify the module owner and every caller/consumer.
4. Trace startup, runtime behavior, and cleanup before editing.
5. Implement the smallest coherent change.
6. Add focused regression tests or a test harness where practical.
7. Run Lua syntax checks and relevant tests (for Clipboard History pinned work: `luac -p .hammerspoon/Spoons/xClipboardHistory.spoon/init.lua tests/clipboard-pinned/*.lua` and `lua tests/clipboard-pinned/run.lua`).
8. For UI/interaction changes, perform live macOS testing when available, preferably using Peekaboo, and inspect screenshots/state.
9. Review the final diff for unrelated changes, secrets, accidental config, and lifecycle regressions.
10. Commit/push only as requested and report verified outcomes accurately.
