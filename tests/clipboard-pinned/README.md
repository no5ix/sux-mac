# Clipboard History pinned-history harness

Isolated regression coverage for the pinned collection in
`.hammerspoon/Spoons/xClipboardHistory.spoon/init.lua`. It loads the real Spoon
module with `hs_stub.lua` shims (filesystem, JSON, base64, images, WebView,
pasteboard, hotkeys, timers, logging) against a throwaway data root, so no
Hammerspoon instance, window, real pasteboard, or real user history is involved.

```sh
# from the repository root
lua tests/clipboard-pinned/run.lua
node tests/clipboard-pinned/panel_js_test.mjs
SPOON_PATH=/path/to/init.lua lua tests/clipboard-pinned/run.lua   # explicit file
luac -p .hammerspoon/Spoons/xClipboardHistory.spoon/init.lua tests/clipboard-pinned/*.lua
node --check /tmp/panel_script.js   # extract the panel <script> first, see below
```

Requires a Lua 5.4/5.5 interpreter (`brew install lua`). LuaJIT is not
supported. Hammerspoon itself is not required. `panel_js_test.mjs` needs Node
and no packages: it extracts the panel's marked JavaScript blocks from the Spoon
file and runs them against a minimal DOM stub built in the test file.

## Data-root safety (read this before editing the harness)

The Spoon computes its data root as `$HOME/Documents/github/sux-mac/clipboard-history`.
`hs_stub.install(home)` overrides `os.getenv("HOME")`, and `run.lua` asserts on
every module load that the resolved root starts with
`/tmp/sux-clipboard-history-tests/`. That assertion has a real history: an
earlier version of the harness restored the real `os.getenv` after installing
the stub, so the suite ran against the user's real `clipboard-history/` and
deleted the daily JSON indexes. Do not restore `os.getenv`, do not drop the
assertion, and do not add a fixture that writes outside `environment.root` /
`environment.pinned`.

## What is covered

| Scenario | Behavior |
| --- | --- |
| schema | pinned text keeps full `content` in `pinned-history.json`; core fields match the daily record; no per-item `.txt`; pin-only fields are `id`, `pinnedAt`, `sourceKey` |
| unicode | multiline and non-ASCII text survives the JSON round trip and hydration |
| image | image is copied under `pinned/pinned-images/` + `pinned/pinned-thumbnails/`, byte-identical, `sourcePath` recorded, ordinary files kept |
| identity | original `ts` preserved, `pinnedAt` is the pin time, ids unique, distinct records with identical timestamps pin separately, duplicate pin is idempotent |
| search | every and only matching pinned text record is returned; case-insensitive; multiline/Unicode content searchable |
| scope | unpinned records never appear in a Pin search; ordinary search is unaffected |
| full-collection | records beyond the first rendered page are searched; no duplicates |
| types | Pin + Text, Pin + Images, Text+Images (empty), and type + query combine |
| panel | Pin scope, type filter, and query survive scope changes; result counts equal the filtered set; the Pin scope is restorable after clearing a query |
| cache | the ordinary search cache is collection-tagged and never reused as a pinned result set |
| migration | legacy `contentPath` payload moves into `content`, payload file removed after the atomic write, backup kept, ids/`pinnedAt` backfilled, legacy image paths stay readable, missing payload preserved, second run is a no-op |
| migration failure | a read-only pinned folder leaves the index and payload files untouched and logs a diagnostic |
| corrupt JSON | undecodable index yields no records, migration refuses, the file is preserved |
| load migration | startup migration converts legacy data before the panel opens |
| retention | seven-day cleanup removes expired day folders and never the pinned collection |
| actions text | Preview, Copy, click-to-paste, and Unpin on JSON-backed text; ordinary source record survives |
| actions image | thumbnail card, Preview, Copy, paste, Unpin removes pinned copies only |
| unpin edge | unpin works with missing pinned files and legacy 3-part `sourceKey` |
| clear all | Clear All clears ordinary and pinned collections, resets Pin/search state, recreates pinned storage |
| ordinary | ordinary cross-date/date-scoped/type-filtered search, counts, cards, and empty-result behavior stay intact |
| marker | the `All` view renders one pinned card per event (`data-pinned="true"`, `📍` marker, pinned id) and no ordinary twin; Unpin restores the ordinary card; date scopes stay ordinary-only and keep the in-place Unpin marker |
| all unify | `All` merges ordinary text, ordinary images, pinned text, and pinned images into one newest-first collection; counts are the deduplicated totals; `Pin` and date scopes keep their own semantics |
| all dedup | deduplication is identity-based (`sourceKey`/pinned id), never timestamp-based: two records sharing one `ts` stay two cards |
| all rebuild | after a daily index is rewritten, the pinned event is still folded into one card by payload identity (text body / image file name + ts), and an unrelated record whose `sourceKey` moved is not hidden |
| all loadmore | Load more extends the ordinary side while the pinned record appears exactly once and no event is rendered twice |
| all pin | the context-menu Pin action from `All` collapses the pair into one pinned card (count unchanged) and leaves ordinary history intact; Unpin from `All` restores the ordinary card |
| all search | `All` search spans both collections (including pinned-only content), case-insensitively; `Pin` search stays pinned-only; a date search stays scoped to that date and never includes pins; query survives scope/type switches |
| all cache | the merged set is cached as `collection="all"`, the ordinary set as `collection="history"`; pin, unpin, and Clear All invalidate the All cache; the Pin path never overwrites the ordinary cache |
| all cards | pinned text and image cards render the corner `📍` marker with `data-pinned="true"` and the original timestamp; ordinary cards render no marker; cards keep `data-action="paste"` |
| chips | header renders `All` (no `All Dates`), `Pin`, dates, exactly one separator, then only `Text` and `Images`, in one toolbar row, with the search box and count intact |
| context menu | every card carries a unique `data-uid`; `data-pinned` and the pin marker are derived from the entry at that index; rendering pinned and ordinary cards in alternating order (text and image, All and Pin scopes, first card again at the end) never leaks Pin/Unpin state; the menu spec, stable `data-context-slot` buttons, and the absence of a `data-context-action` lookup are asserted |
| context actions | Copy, Pin, and Unpin act on the requested index: Copy copies the requested card's text, Unpin removes exactly that pinned record and leaves the others, Pin pins exactly the requested ordinary record, and an Unpin request for an ordinary card changes nothing after the list is rebuilt |
| empty | empty collection, empty pinned view, and refused pin/unpin edge cases |
| privacy | no clipboard payload text appears in the log output |

## Panel JavaScript checks

`node tests/clipboard-pinned/panel_js_test.mjs` extracts the blocks marked
`BEGIN/END CONTEXT MENU MODEL`, `BEGIN/END KEYBOARD NAVIGATION MODEL`, and
`BEGIN/END KEYBOARD NAVIGATION BINDING` **verbatim** from the Spoon file, so it
exercises the shipped code rather than a copy. It also reads the whole panel
`<script>` for structural assertions. Covered:

- Context menu: ordinary text/image produce Pin, pinned text/image produce
  Unpin, opening a pinned menu cannot leave Unpin on the next ordinary card (and
  the reverse), repeated alternating opens stay correct, the pin button stays
  findable after its `data-context-action` is mutated (the shipped leak), the
  click uses the card that opened the menu, a rebuilt list is resolved by
  `data-uid` and never by a stale index, and a vanished target is ignored.
- Navigation: the full Tab / Shift+Tab sequence, Tab from search returning to
  the remembered card, 12 cards walked in DOM order for grid widths of 1 to 5
  columns, only the search field and cards receiving focus, stable-identity
  reconciliation after search/scope/filter/load-more rebuilds, a removed focused
  card falling back to a clamped position, empty results and Clear All keeping
  focus in search, a single-result cycle, and a stale state object never pointing
  past the list.
- Wiring: exactly one Tab branch that delegates to `navMove`, no tab stop on the
  results container, a post-rebuild `<body>` Tab fallback, and the Escape,
  Enter-to-paste, arrow-key, Enter-to-search, and typing handlers still present.

To syntax-check the whole panel script: extract the text between `<script>` and
`</script>` from the Spoon file into `/tmp/panel_script.js` and run
`node --check /tmp/panel_script.js`.

## Live UI verification

The harness asserts the generated panel HTML (header chips, card markup, pin
marker, count text) and the Lua state behind it, and `panel_js_test.mjs` drives
the panel's context-menu and keyboard-navigation JavaScript directly, so the
unified `All` view, the chip layout, the pinned indicator, per-card menu state,
and the Tab model are covered without a GUI. Optional desktop confirmation of
pointer/keyboard behavior uses Peekaboo against a running, unlocked Hammerspoon
session (see `AGENTS.md` → Visual testing) when the task asks for it. Use
identifiable test phrases, and clean up only the records you created:

1. `peekaboo clipboard set "PINLIVE codex <unique>"`, open the panel with
   `peekaboo press ctrl+shift+v --foreground`.
2. Right-click the card → `📍 Pin`; confirm
   `clipboard-history/pinned/pinned-history.json` gains one record with the text
   in `content`, no new `.txt`, and `ts` equal to the copy time.
2b. Right-click an ordinary card, then a pinned card, then a different ordinary
   card, then a pinned card, then the first ordinary card again: every ordinary
   card's menu must read `📍 Pin` and every pinned card's `📌 Unpin`, never a copy
   of the previously right-clicked card's state.
2c. Focus the search field and press Tab repeatedly: focus must walk the cards
   one by one in DOM order. Shift+Tab steps back one card, reaches search from
   the first card, and the next Tab returns to the remembered card - not item 1.
3. Click `Pin`, search the phrase, Enter: the card list and the
   `N matching items` count must match exactly; unpinned matches must be absent.
4. With Pin still selected, click `Text` then `Images`; confirm only pinned
   records of that type appear, and the query survives both.
5. Right-click → `👁️ Preview` then `📋 Copy`; paste into TextEdit and confirm the
   exact text, including Unicode and newlines.
6. Pin an image, confirm the thumbnail in Pin + Images, open Preview, Copy,
   click-to-paste, then Unpin; confirm the ordinary record and files remain.
7. Unpin the text record; confirm the pinned JSON record and its pinned files are
   gone and the ordinary history record is intact.
8. Close and reopen the panel, then press `↻ Reload` (Hammerspoon reload) and
   confirm pins persist.
9. Remove the test records from the day index and the pinned index, and delete
   any test image files that were created.
