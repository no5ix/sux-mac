# Clipboard History pinned-history harness

Isolated regression coverage for the pinned collection in
`.hammerspoon/Spoons/xClipboardHistory.spoon/init.lua`. It loads the real Spoon
module with `hs_stub.lua` shims (filesystem, JSON, base64, images, WebView,
pasteboard, hotkeys, timers, logging) against a throwaway data root, so no
Hammerspoon instance, window, real pasteboard, or real user history is involved.

```sh
# from the repository root
lua tests/clipboard-pinned/run.lua
SPOON_PATH=/path/to/init.lua lua tests/clipboard-pinned/run.lua   # explicit file
luac -p .hammerspoon/Spoons/xClipboardHistory.spoon/init.lua tests/clipboard-pinned/*.lua
```

Requires a Lua 5.4/5.5 interpreter (`brew install lua`). LuaJIT is not
supported. Hammerspoon itself is not required.

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
| marker | ordinary cards for pinned records render `data-pinned="true"` and Unpin through the same entry |
| empty | empty collection, empty pinned view, and refused pin/unpin edge cases |
| privacy | no clipboard payload text appears in the log output |

## Live UI verification

The harness cannot render the panel, so these need Peekaboo against a running,
unlocked Hammerspoon session (see `AGENTS.md` → Visual testing). Use identifiable
test phrases, and clean up only the records you created:

1. `peekaboo clipboard set "PINLIVE codex <unique>"`, open the panel with
   `peekaboo press ctrl+shift+v --foreground`.
2. Right-click the card → `📌 Pin`; confirm
   `clipboard-history/pinned/pinned-history.json` gains one record with the text
   in `content`, no new `.txt`, and `ts` equal to the copy time.
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
