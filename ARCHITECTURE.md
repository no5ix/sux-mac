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

Pinned text storage and the exact JSON record representation must follow the chosen schema consistently. The intended design is to make pinned records compatible with the ordinary history record shape wherever possible, while retaining separate storage and lifetime. Pinning copies the original image and creates/retains a thumbnail; it never moves the original ordinary-history file. Pinned items survive ordinary seven-day retention cleanup.

Metadata should preserve both:

- Original clipboard timestamp: used by the existing date presentation/filtering logic.
- Pin timestamp: records when the item was pinned and may be used for pin ordering.

Unpin removes the pinned record and pinned-owned files, but must not remove the ordinary history item.

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
- Handle missing files, invalid JSON, and partial writes without crashing the entire Spoon.
- Avoid storing Base64 image data or large text payloads in long-lived metadata indexes.
- Never log clipboard contents.

## UI behavior to preserve

The existing panel includes search, type/date filters, result counts, pagination, item cards, image thumbnails, on-demand image preview, keyboard navigation, right-click actions, Clear All, and Reload. Closing the panel clears transient browsing state according to the current implementation. Preserve the existing visual design and interaction semantics unless a task explicitly calls for a change.

## Data compatibility principle

When a feature needs a separate persistent collection, prefer reusing the established record schema and existing serialization/hydration/rendering logic. Storage lifetime and storage location can differ without inventing a second record model. Any schema migration must be explicit, backward-compatible where practical, and safe for existing user data.
