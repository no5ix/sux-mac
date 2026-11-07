# Architecture

## Repository overview

Sux-Mac is a macOS utility repository. One of its components is a Hammerspoon Spoon that provides clipboard history using a native Hammerspoon WebView and a JavaScript-driven interface.

## Clipboard History component

### Source of truth

The main implementation is:

`.hammerspoon/Spoons/xClipboardHistory.spoon/init.lua`

The Spoon integrates with Hammerspoon APIs for:

- Pasteboard observation and clipboard reads/writes.
- WebView creation, rendering, and user-content message callbacks.
- Application activation and focus restoration.
- Filesystem access and image decoding.
- Hotkeys, timers, and logging.

The panel is rendered as HTML/CSS/JavaScript inside the Hammerspoon WebView. JavaScript interactions are sent to Lua through the WebView user-content bridge. Lua owns filesystem persistence and clipboard operations.

### Ordinary history storage

Ordinary history is stored under the repository's `clipboard-history/` data directory, partitioned by local date. A date folder contains a JSON history file and, for image records, image and thumbnail subdirectories.

The ordinary history JSON stores records with a `type`, timestamp (`ts`), and type-specific data. Text records store their text content in the JSON record. Image records reference original image and thumbnail paths. The implementation also supports existing legacy image metadata.

The runtime maintains bounded recent caches and metadata-backed persistent browsing/search paths. Large data should be hydrated from disk only when required for rendering or an action. Avoid adding permanent in-memory copies of full text/image payloads.

### Pinned history

Pinned data is stored independently beneath:

```text
clipboard-history/
└── pinned/
    ├── pinned-images/
    ├── pinned-thumbnails/
    └── pinned-history.json
```

Pinned records use the same record shape as the ordinary daily history file.
`pinned-history.json` is an array of records:

```jsonc
// text
{
  "type": "text",
  "ts": 1793984940,          // original clipboard timestamp, never pin time
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

No per-item `.txt` payload files and no Base64 image data are written for new
pins. Pinned entries are built through the same `metadataEntry()`
transformation as ordinary history, so parsing, search, hydration, thumbnail,
rendering, preview, copy, paste, and cleanup logic stay shared; only the storage
location and retention lifetime differ. Pinned text payloads live in memory for
the open-panel session, exactly like ordinary history entries, and are released
when the panel closes.

Legacy pins stored text in a per-item `.txt` file referenced by `contentPath`.
`migratePinnedHistory()` converts those records at load: it reads each payload,
places the text in `content`, writes the index atomically (keeping a
`pinned-history.json.pre-migration.bak`), and only then removes the obsolete
payload files. A missing payload file, an undecodable index, or a failed write
preserves the existing data and logs a diagnostic; the collection is never
silently replaced with an empty array.

Pinning copies the original image and creates/retains a thumbnail; it never
moves the original ordinary-history file. Pinned items survive ordinary
seven-day retention cleanup because that cleanup only visits valid
`YYYY-MM-DD` day folders.

Metadata preserves both:

- Original clipboard timestamp: used by the existing date presentation/filtering logic.
- Pin timestamp: records when the item was pinned and is used for pin ordering.

Unpin removes the pinned record and pinned-owned files, guarded so only paths
under the pinned root are deleted, and must not remove the ordinary history item.

Clear All is deliberately broader than ordinary retention cleanup: it removes both ordinary history and the pinned collection, then resets runtime caches and UI state.

### Filtering and search model

The panel has mutually exclusive scope/date filters:

- All Dates.
- Pin.
- Today.
- Yesterday.
- Individual date filters.

Text and Images are independent content-type filters and may be combined with any scope, including Pin.

Search preserves the active scope and content-type filter. With Pin active, search must examine the full pinned collection and full text content. It must not silently use the ordinary-history search cache or only the currently rendered page.

Record identity is part of this model. `metadataEntry(record, dateKey, identity)` builds a `sourceKey` of `dateKey:ts:type:identity`, where identity is the record's position in its daily file (or the pinned record id for pins). Identity is taken from the record's file position, before any newest-first cache sort, so two distinct records that share a timestamp and type stay distinguishable. Pinned deduplication, the pinned marker in the ordinary view, and Unpin from the ordinary view all use this key, and older 3-part `sourceKey` values left by the previous pinned schema are still recognised. `searchResultsCache` is tagged with a `collection` field (`"history"`); the pinned path never reads or writes it.

### Context menu and actions

Both ordinary and pinned text/image entries use the shared context-menu and action pipeline.

Expected menu items:

- Ordinary item: Preview, Paste All, Copy, Pin.
- Pinned item: Preview, Paste All, Copy, Unpin.

Pinned items must hydrate their stored data when Preview, Paste All, Copy, or Paste requires it. After Pin/Unpin, refresh the current result set without losing the user's active search/filter selection.

### Important implementation constraints

- All module-level dependencies must be declared before helpers that reference them and before any module-load-time initialization that calls them. This specifically includes filesystem helpers such as `ensureDirectory` and atomic JSON writers such as `atomicWrite`.
- Use APIs actually provided by Hammerspoon. Do not assume `hs.fs.copy` exists. A binary copy implemented with Lua file I/O is an acceptable approach where appropriate.
- Prefer atomic writes for JSON indexes, with cleanup of temporary/partial files on failure.
- Use safe, deterministic file names and unique record identifiers.
- Deleting pinned files must be guarded by a pinned-root check, so a stale record can never delete an ordinary history file.
- Handle missing files, invalid JSON, and partial writes without crashing the entire Spoon.
- Avoid storing Base64 image data or large text payloads in long-lived metadata indexes.
- Never log clipboard contents.

## UI behavior to preserve

The existing panel includes search, type/date filters, result counts, pagination, item cards, image thumbnails, on-demand image preview, keyboard navigation, right-click actions, Clear All, and Reload. Closing the panel clears transient browsing state according to the current implementation. Preserve the existing visual design and interaction semantics unless a task explicitly calls for a change.

## Data compatibility principle

When a feature needs a separate persistent collection, prefer reusing the established record schema and existing serialization/hydration/rendering logic. Storage lifetime and storage location can differ without inventing a second record model. Any schema migration must be explicit, backward-compatible where practical, and safe for existing user data.

## Testing

`tests/clipboard-pinned/run.lua` runs the real Spoon against a sandboxed data
root using `tests/clipboard-pinned/hs_stub.lua` (filesystem, JSON, WebView,
pasteboard, image shims). It covers the pinned record schema, full-collection
search, scope/type preservation, result counts, legacy migration, migration
failure, corrupt JSON, retention isolation, actions, Clear All, and ordinary
history behavior. Run it from the repository root with `lua
tests/clipboard-pinned/run.lua`.

The Spoon resolves its data root from `$HOME`, so the harness must load the
module while the stub `$HOME` override is active; `run.lua` asserts the resolved
root is inside `/tmp/sux-clipboard-history-tests` and refuses to continue
otherwise. Never weaken that guard: without it the harness writes to the real
`clipboard-history/` data and can overwrite and delete real records. Panel
interaction (context menu, preview, paste, keyboard) still requires live
Peekaboo testing against a running, unlocked Hammerspoon session.
