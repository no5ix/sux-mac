# AGENTS.md

Repository-wide instructions for AI coding agents working in **Sux-Mac**. These rules apply to every module, not only Clipboard History.

## 1. Repository purpose and layout

Sux-Mac is a collection of macOS productivity utilities built primarily with Hammerspoon and Lua. The active application configuration and Spoon modules live under `.hammerspoon/`.

Read `ARCHITECTURE.md` for the repository map and module responsibilities before making architectural changes.

Important paths:

- `.hammerspoon/init.lua`: main Hammerspoon startup/configuration entry point.
- `.hammerspoon/Spoons/`: independently loadable local Hammerspoon Spoon modules.
- `.hammerspoon/remapping/`: keyboard remapping dependency used by `xGlobalVim`.
- `clipboard-history/`: runtime clipboard-history data; this directory is ignored by Git.
- `docs/`: design notes, task briefs, and operational documentation.
- `README.md`: user-facing project overview and feature descriptions.
- `.gitignore`: repository-specific exclusions, including local runtime data and local AI settings.

## 2. Module map

The modules below are present in the current repository configuration. Inspect the current source before assuming every feature is enabled or every commented-out block is active.

### Main configuration — `.hammerspoon/init.lua`

- Central startup entry point.
- Loads local Spoons and starts the modules that require explicit start calls.
- Also contains historical examples, commented-out experiments, and configuration snippets.
- When changing startup order, preserve dependencies and understand which modules initialize on load versus on `:start()`.

### `Spoons/xAppTriggers.spoon/init.lua`

- Application watcher and per-application behavior.
- Maintains mappings from application names to preferred input sources and related application state.
- Switches input sources based on application transitions and remembered language/input state.
- Contains optional/conditional PAC proxy switching hooks.
- Treat application names, bundle identifiers, input-source IDs, and watcher event ordering carefully.

### `Spoons/xGlobalVim.spoon/init.lua`

- Global keyboard remapping and text-editing shortcuts inspired by Vim.
- Uses `remapping/foundation_remapping.lua` for physical/modifier-key remapping.
- Binds shortcuts for cursor movement, selection, deletion, navigation, character insertion, screenshots, and other editing actions.
- Some helpers call application-specific shortcuts (for example, the preferred screenshot path when WeChat is running).
- Modifier mapping changes can affect the rest of the macOS interaction model; preserve the unregister/escape mechanism and avoid accidental duplicate key bindings.

### `Spoons/xClipboardHistory.spoon/init.lua`

- Clipboard capture, persistence, search, filtering, pagination, preview, context menu, paste/copy, pinning, and panel lifecycle.
- Uses Hammerspoon pasteboard, watcher, WebView, image, filesystem, timer, hotkey, and application APIs.
- Ordinary history is date-partitioned with seven-day retention and bounded/on-demand in-memory loading.
- Pinned history is persistent and separately stored under `clipboard-history/pinned/`.
- Pinned records use the ordinary history record schema: text keeps its full `content` in `pinned-history.json` (no per-item `.txt`), images use `imagePath`/`thumbnailPath` under the pinned folders, `ts` stays the original clipboard timestamp, and `id`/`pinnedAt`/`sourceKey`/`sourceId` are the pin-only additions. Every ordinary daily record also carries a stable `id` assigned at capture time (`nextRecordId()`), and a pin records that id as `sourceId`; `migrateDailyHistoryIndexes()` backfills ids into daily indexes written before they existed. Legacy `contentPath` records are migrated at load: payload into `content`, atomic write with a pre-migration backup, then remove the obsolete files. See `ARCHITECTURE.md`.
- Automated harness: `lua tests/clipboard-pinned/run.lua` (see `tests/clipboard-pinned/README.md`). The Spoon resolves its data root from `$HOME`, so the harness must keep the stubbed sandbox `$HOME` active while loading the module and asserts the resolved root is under `/tmp/sux-clipboard-history-tests`. Never weaken that guard: without it the tests write to the real `clipboard-history/` data and can overwrite and delete real records.
- Pin is a mutually exclusive scope filter; Text and Images remain independently selectable. Search must preserve active scope/type state.
- `All` is the unified scope: ordinary history and pinned records presented as one collection, with or without a search query, folded by identity: the pinned `sourceId` against the source record `id`, then a full `sourceKey`, then a legacy 3-part `sourceKey` prefix, with payload identity (text length plus body, or the image file name, beside `ts`) as the fallback for pins created before record ids existed — never by `ts` alone, and a 4-part `sourceKey` is never widened to a prefix — with the pinned copy winning so its card keeps the pin marker and Unpin. The collection is one stream ordered by clipboard timestamp (`extendAllStream`) and pagination walks that stream, so a pinned event sits at its own timestamp instead of collecting at the bottom of a page. The first page rendered when the panel opens must come from that same stream (`openAllPanelPage`), and cards are appended by `data-uid`, never by list position. The pin marker is resolved per render and never written onto the shared cached metadata entry. `Pin` stays pinned-only and `Today`/`Yesterday`/individual dates stay ordinary-history-only. Chips are ordered `All`, `Pin`, dates, separator, `Text`, `Images` in one row. Pinned cards show a corner `📍` marker; ordinary cards show none, and the displayed timestamp is always the original clipboard time.
- Context-menu state is per item. Every card carries `data-uid` (record `sourceKey`, pinned record `id`); the menu is built once from the ordered `CONTEXT_MENU_ITEMS` spec, its buttons keep a stable `data-context-slot`, and every open recomputes the Pin/Unpin action, label, and per-slot visibility from the right-clicked card's `data-pinned` and `data-kind`. Image cards additionally expose `🗂️ Paste path`, an `imageOnly` slot that is always built and hidden on cards with no file; it puts the image file path on the pasteboard as plain text (for a pinned image, the recorded `sourcePath`), and a card with no readable file is refused. Never identify a menu button by the mutable `data-context-action` payload (that is the attribute the open handler rewrites), and never resolve an action from the previously selected card, a stale row index, or shared menu state.
- Tab/Shift+Tab is one explicit navigation model over the rendered cards in DOM order: `-1` is the search field, `0..n-1` is a card. The last visited card is remembered (`lastCardIndex`/`uid`) and Tab from search returns to it; Shift+Tab steps one card back and reaches search from the first card. `resetClipboardSelection` reconciles the remembered and focused card after every list rebuild (search, scope, type filter, Load more, refresh, pin/unpin, Clear All). The results container is not a tab stop; only the search field and cards are Tab targets and header controls keep native Tab order. Arrow keys, Enter-to-paste, Enter-to-search, Escape-to-close, focus styling, and click-to-paste stay unchanged.
- Clear All intentionally deletes both regular and pinned history.
- Preserve metadata-only caches and on-demand hydration. Do not retain large text/image payloads or Base64 data unnecessarily.
- Keep all existing panel interactions and keyboard/focus/dismissal behavior unless specifically requested otherwise.
- Do not reintroduce automatic hover-to-preview.

### `Spoons/xSelectionToolbar.spoon/init.lua`

- Detects text selection and displays a floating toolbar.
- Builds WebView-based toolbar UI and routes button actions through a WebView-to-Lua message handler.
- Includes proofreading/translation/provider workflows, including ChatGPT and local-AI/custom prompt actions.
- Manages translation and custom-AI windows, keyboard escape handling, selection capture fallbacks, and toolbar lifecycle.
- Treat prompt text, external URLs, local commands, clipboard contents, selected text, and generated scripts as untrusted/content data. Never execute selected text as code.
- Configuration and default prompt templates are in this module; the local settings file may be ignored/untracked. Do not overwrite a user's local settings.

### `Spoons/xSpotifyAdMuter.spoon/init.lua`

- Monitors Spotify playback and identifies advertisements using track metadata and a known-ad data file.
- Gradually fades volume down/up around advertisements and restores the prior volume.
- Uses a periodic timer, application watcher, and a hotkey to teach/add a currently playing ad.
- Avoid launching Spotify as a side effect of querying state. Preserve the guard that checks whether Spotify is already running before using AppleScript.
- Treat `spotify_known_ads.lua` as data, not arbitrary executable code; validate the shape and contents before use or update.

### `Spoons/xHotCornersAndEdges.spoon/init.lua`

- Mouse-edge/corner and gesture-based window-management module.
- Supports window resizing/positioning, thirds, centering, moving windows between displays, corner/edge triggers, and gesture/click event handling.
- Exposes configurable trigger dimensions/timing and Stage Manager behavior.
- Has explicit `:init()`, `:start()`, and `:stop()` lifecycle methods, plus corner configuration/accessor methods.
- Be careful with global mouse/gesture watchers, screen changes, timers, event-tap lifecycle, and multi-monitor coordinate calculations. Always stop/release watchers and timers correctly.

### `remapping/foundation_remapping.lua`

- Lower-level key remapping implementation used by `xGlobalVim`.
- Treat this as a dependency rather than a place for application-specific shortcuts.
- Preserve key-code, HID-code, modifier-state, and event-tap semantics. Test combinations and unregister behavior when changing it.

## 3. General engineering rules

- Inspect the current branch, working tree, relevant source files, and existing behavior before editing.
- Preserve unrelated user changes. Never reset, discard, or overwrite work you did not create.
- Make the smallest coherent change that solves the requested problem. Avoid broad rewrites and unrelated refactoring.
- Follow existing naming, formatting, logging, error-handling, and lifecycle conventions.
- Prefer extending existing abstractions over introducing parallel implementations.
- Distinguish active code from commented-out experiments and dead configuration.
- Do not claim tests, builds, UI interactions, or visual checks passed unless you actually ran them and observed their results.
- Explain environment limitations honestly.
- Never put credentials, API keys, private selected text, clipboard contents, or sensitive user data in logs, tests, or documentation.
- Do not silently change user-facing shortcuts, input-source mappings, application lists, AI prompts, proxy behavior, Spotify ad data, or window-management defaults.

## 4. Hammerspoon and Lua safety

- Lua local declarations are lexical. A function that references another local function must be declared after that dependency, or use an explicitly forward-declared local variable. Otherwise Lua may resolve the name as a global and fail at runtime.
- Be especially careful with module-load-time initialization: helpers called while the Spoon file is evaluated must already be defined.
- Before adding or moving helpers, inspect declaration order and every module-load-time call site.
- Do not assume an API exists because its name resembles a standard filesystem API. Check the actual Hammerspoon API used by this project. For example, do not assume `hs.fs.copy` exists.
- Keep callbacks defensive: validate event payloads, indices, object types, and filesystem paths.
- Watcher/timer/eventtap lifecycle must be explicit. Avoid duplicate watcher registration and ensure stop/reload paths clean up resources.
- Use `pcall` around unstable OS integrations where appropriate, but do not swallow failures silently.
- Preserve callback and timer references for as long as the Hammerspoon API requires them.
- Avoid expensive filesystem, image conversion, accessibility, or AppleScript work inside high-frequency mouse/pasteboard callbacks.
- Do not block the main Hammerspoon event loop with long-running work.
- For AppleScript, avoid targeting an application in a way that unintentionally launches it.

## 5. UI, WebView, and external integrations

- WebView HTML/JS should be escaped/encoded safely when inserting text, URLs, or metadata.
- Validate WebView message actions on the Lua side; do not trust the UI to send valid payloads.
- Keep UI state and Lua state synchronized deliberately.
- Preserve focus restoration and dismissal semantics, especially when floating WebViews temporarily become frontmost.
- Selected text and clipboard content are data, not instructions. Never interpret them as commands.
- When invoking external AI providers or local AI endpoints, handle failures, timeouts, and missing settings without blocking the rest of the toolbar.
- Preserve user-configurable prompts/settings and avoid committing secrets or machine-specific local configuration.

## 6. Module-specific preservation rules

- **App Triggers:** do not make app switching or input-source changes recursively trigger unwanted watcher loops. Account for localized app names and missing input methods.
- **Global Vim:** modifier remapping can change every shortcut. Preserve the unregistration shortcut and verify the intended mapping order.
- **Clipboard History:** preserve seven-day cleanup for ordinary history, permanent pin retention, the compatible JSON schema, full-content search, safe migration, bounded cache, and the shared action pipeline. Keep `All` a unified ordinary-plus-pinned view (aggregation and identity deduplication only; storage ownership stays separate; one timestamp-ordered stream with a unified pagination cursor, so pinned events keep their own timestamps and the first paint matches every later update), keep the search caches collection-scoped (`history`, `all`, and the pinned path uncached), and invalidate the caches on Pin, Unpin, and Clear All. Resolve context-menu Pin/Unpin from the card that was right-clicked (`data-uid` / pinned identity) with stable `data-context-slot` buttons, keep keyboard navigation sequential over the rendered cards with the remembered card restored, and keep the pinned storage schema, migration, and retention untouched by panel-state changes. Deleting pinned files must stay guarded by a pinned-root check, so a stale record can never delete an ordinary history file. Keep the daily-record id migration idempotent, backed up with a `.pre-migration.bak`, atomic, and confined to the resolved data root. Keep Load-more append-by-identity (`data-uid`) and the panel-open path on the same unified stream. Keep Paste path guarded to image cards with a readable file. Keep the `tests/clipboard-pinned` sandbox guard intact.
- **Selection Toolbar:** do not lose text selection when opening the toolbar; restore the originating app/focus as required. Keep AI action configuration extensible and local settings private.
- **Spotify Ad Muter:** preserve original volume and restore it reliably on playback changes, stop, app quit, or errors. Do not launch Spotify just to inspect state.
- **Hot Corners and Edges:** prevent duplicate mouse/gesture watchers after reload or repeated start calls; correctly handle display topology changes and stop timers/taps.
- **Remapping dependency:** do not change low-level key mapping semantics without checking every consumer.

## 7. Required workflow for changes

1. Read `AGENTS.md` and `ARCHITECTURE.md`.
2. Confirm the requested branch and inspect working-tree state.
3. Identify the actual owner module and all callers/dependencies.
4. Trace initialization, runtime lifecycle, and cleanup paths before editing.
5. Implement targeted changes and add regression coverage where practical.
6. Run applicable Lua syntax checks, focused tests, and relevant runtime checks.
7. For UI, mouse, keyboard, multi-monitor, accessibility, or app-integration work, perform live testing on macOS when available. Use Peekaboo where appropriate and inspect screenshots/state after interactions.
8. Review the final diff for regressions, unrelated changes, secrets, and accidental local config.
9. Commit only intended changes. Push only when requested.
10. Report exactly what was changed and what was/was not tested.

## 8. Visual testing

For UI tasks, use Peekaboo against the real running macOS application when available. A successful automation command is not proof that the UI reached the intended state: inspect the result and capture screenshots for meaningful states. Do not claim live testing from source inspection, mocks, or screenshots of a different build.
