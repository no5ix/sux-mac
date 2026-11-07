# Task: Fix Pinned Clipboard Search and Make Pinned JSON Records Match Ordinary History

You are working in the `no5ix/sux-mac` repository.

**Continue on the existing branch `feat/pin-clipboard-history`. Do not create another branch and do not switch to `main`.** Read `AGENTS.md` and `ARCHITECTURE.md` before changing code.

Work autonomously. Make reasonable engineering decisions without waiting for my reply. Do not stop after analysis or a partial fix. Complete implementation, tests, live visual verification with Peekaboo, commit, and push the same branch.

## 1. Git and repository workflow

1. Inspect the current branch, latest commit, and working-tree state.
2. Confirm the current branch is exactly `feat/pin-clipboard-history`.
3. Fetch the latest remote state and update this branch safely if needed. Preserve all existing commits and user changes. Do not reset, rebase destructively, or force-push.
4. Read `AGENTS.md` and `ARCHITECTURE.md`.
5. Inspect the latest implementation and the actual existing data files before changing anything.
6. Keep all implementation changes on `feat/pin-clipboard-history`. Do not merge into `main`.

Main implementation:
`.hammerspoon/Spoons/xClipboardHistory.spoon/init.lua`

Ordinary history example:
`clipboard-history/2026-11-07/2026-11-07-history.json`

Pinned storage:
`clipboard-history/pinned/`

## 2. Issue A — pinned search misses matching text

I searched for the word `codex` with the Pin filter selected. The pinned view showed only one matching item, but the ordinary history search showed five matching items, and those items included text that had already been pinned.

Expected behavior:

- With Pin selected, search the entire pinned collection, not ordinary history.
- Search the complete text content of every pinned text record. Do not search only metadata, card excerpts, DOM attributes, or the current rendered page.
- Preserve the active Pin scope, Text/Images filter, and search query when changing between them.
- Pin + Text + query returns matching pinned text only.
- Pin + Images returns pinned images; image search may search available filename/path/metadata fields, but must not pretend image pixels contain searchable text.
- Result counts must match the actual filtered pinned result set.
- Search all pinned records, not merely the first page or recent-history cache.
- Search should be case-insensitive and follow ordinary-history matching semantics.
- Do not accidentally include unpinned records.

Investigate the root cause rather than applying a one-off workaround.

**Important clue:** current pinned search calls `loadPinnedEntries()` and then `hydratePinnedEntry()`, which expects text content files referenced by `contentPath`. Current pinned storage writes each pinned text item into a separate `.txt` file and stores a `contentPath` reference. Ordinary history stores text directly in each JSON record's `content` field. The second issue below changes this, so update search to consume the final schema.

## 3. Issue B — pinned-history.json should use the ordinary history record schema

I want pinned metadata and text content stored in `pinned-history.json` using the same record structure as the ordinary daily history JSON file.

Inspect:
`clipboard-history/2026-11-07/2026-11-07-history.json`

Use that file as the source of truth. Do not invent a different schema without a strong technical reason.

Expected layout:

```text
clipboard-history/
├── pinned/
│   ├── pinned-images/
│   ├── pinned-thumbnails/
│   └── pinned-history.json
└── [ordinary date-partitioned history]
```

Record requirements:

- Each pinned record uses the same core fields and meanings as an ordinary history record, including `type`, `ts`, and ordinary type-specific fields.
- Text records store their full `content` directly in `pinned-history.json`, matching ordinary history. Do not create a separate `.txt` file for each new pinned text record.
- Image records use the ordinary `imagePath` and `thumbnailPath` fields, pointing to copied files under `pinned/pinned-images/` and `pinned/pinned-thumbnails/`.
- Preserve the original clipboard timestamp in `ts`; do not replace it with pin time.
- Store pin-specific metadata such as a stable unique identifier, source identity where available, and `pinnedAt` as additional fields.
- Keep JSON as an array of records.
- Do not store Base64 image data in JSON.
- Avoid redundant full image payloads in memory.
- Keep pinned storage independent of ordinary seven-day retention cleanup.
- Pinning copies, never moves, ordinary history files.
- Unpin removes pinned records and pinned-owned files, not the ordinary source record.
- Clear All continues clearing both collections.

### Backward compatibility and migration

Existing pinned data may include legacy text records with `contentPath` referring to per-item `.txt` files, and image records with `imagePath`, `thumbnailPath`, `sourceKey`, `id`, and `pinnedAt`.

Implement safe migration:

1. Read the existing pinned array.
2. Convert legacy text records by loading their referenced text files and placing full text in the JSON `content` field.
3. Preserve timestamps, IDs, pin timestamps, image references, and useful metadata.
4. Do not delete legacy text files until the migrated JSON has been written successfully.
5. Use an atomic write.
6. Only after successful persistence, remove obsolete legacy text files.
7. If a source file is missing or migration fails, log a useful diagnostic and preserve recoverable data. Never silently replace the existing collection with an empty array.

Ensure old pinned image paths remain readable. If migration changes image paths, copy first, atomically persist the updated JSON, then remove obsolete files.

## 4. Reuse ordinary history processing

Reuse existing parsing, searching, hydration, thumbnail, rendering, preview, copy, paste, and cleanup logic wherever safe. Avoid maintaining two unrelated record transformations.

Pinned records have a different storage location and retention lifecycle, but should otherwise behave like ordinary history entries.

Inspect paths that assume:
- ordinary text uses `content` or `data`;
- pinned text uses `contentPath`;
- image records use the ordinary image fields;
- `isPinned` changes hydration;
- search caches may not be scoped by collection.

An ordinary search cache must never be reused as a pinned result set. Add collection identity to cache keys if appropriate.

## 5. Data integrity and edge cases

Handle: empty collection; corrupt/missing JSON; legacy text records; missing legacy files; empty, Unicode, and multiline text; duplicate Pin attempts; distinct items with identical timestamps; missing image or thumbnail files; unpin with missing files; Clear All while Pin/search is active; type filters; query preservation; pagination/counts; panel close/reopen; Hammerspoon reload.

Never log actual clipboard text or sensitive image data.

## 6. Preserve current UX

Do not redesign the panel.

Preserve:
- Pin filter beside All Dates.
- Mutually exclusive scope/date filters.
- Text and Images independently combinable with Pin.
- Search preservation across scope/type changes.
- Existing item layout and styling.
- Context menu: ordinary = Preview, Paste All, Copy, Pin; pinned = Preview, Paste All, Copy, Unpin.
- Preview, Paste All, Copy, and click-to-paste for pinned text/images.
- Keyboard navigation, dismissal, focus restoration, ordinary history retention/search/pagination/cache.
- Clear All clears both collections.
- Memory-conscious on-demand hydration.
- No automatic hover-to-preview.

## 7. Tests and checks

Inspect the repository's test infrastructure. Add focused regression coverage where practical. If there is no Lua Spoon harness, add a small isolated test/validation harness for schema conversion, pinned search, legacy migration, and result filtering, without requiring a live Hammerspoon UI.

At minimum cover:
1. Several pinned texts, only some containing `codex`; search returns every and only matching pinned record.
2. Matching ordinary/unpinned records never appear in Pin search.
3. Pinned text is stored in JSON `content`, not per-item `.txt` files.
4. Pinned JSON core schema matches ordinary daily records.
5. Pinned images refer to pinned image and thumbnail directories.
6. Original timestamps, `pinnedAt`, and stable IDs are preserved.
7. Legacy `contentPath` migration.
8. Failed migration preserves recoverable data.
9. Search/type filters remain selected across scope changes.
10. Preview, Copy, Paste, Unpin work for JSON-backed text and images.
11. Clear All clears both collections.
12. Ordinary-history behavior remains unchanged.

Run relevant tests, syntax checks, and static checks. Report actual commands and results. Do not claim live behavior from static inspection.

## 8. Mandatory visual verification with Peekaboo

Use Peekaboo with the actual running Hammerspoon Clipboard History panel. Do not substitute source inspection, mockups, or unit tests for visual tests.

Use the feature branch build and existing clipboard-history data carefully. Do not destroy the user's real clipboard data. Use identifiable temporary test records and clean up only test data you create.

### A. Reproduce search bug
1. Open Clipboard History.
2. Select Pin.
3. Search `codex`.
4. Confirm every pinned text record containing it appears.
5. Confirm the result count is correct and unpinned matches are absent.
6. Capture a screenshot.

### B. Type filters
1. Keep Pin selected.
2. Select Text and verify pinned text only.
3. Select Images and verify pinned images only.
4. Confirm search behaves consistently with each type.
5. Capture screenshots.

### C. JSON-backed text
1. Pin a new identifiable text item with a unique test phrase.
2. Confirm it appears in Pin.
3. Preview and Copy it.
4. Paste it into a safe text editor/test field and verify exact content, including Unicode/newlines where relevant.
5. Unpin it and confirm the ordinary history copy remains.
6. Inspect pinned JSON if possible: full text must be in `content`; no newly created per-item `.txt` file.
7. Capture evidence.

### D. Images
1. Pin an identifiable image.
2. Confirm it appears in Pin + Images with a thumbnail.
3. Open Preview.
4. Verify Copy and click-to-paste if safe.
5. Unpin and confirm ordinary history retains the original.
6. Capture evidence.

### E. Persistence and cleanup safety
1. Close/reopen panel and verify pins remain.
2. If safe, reload Hammerspoon and verify persistence.
3. Do not use Clear All on the user's real data. Use a disposable data root or isolated test records to exercise cleanup.
4. Leave no test records/files behind.

Use Peekaboo for real interactions and screenshots. Verify resulting state after each action. If one interaction cannot be automated, try a reasonable alternative and report the exact limitation.

## 9. Commit and push

After implementation and verification:
- Review the full diff.
- Ensure only intended files changed.
- Commit with a message such as `fix(clipboard): align pinned records with history schema`.
- Push to the existing `feat/pin-clipboard-history` branch.
- Do not create a branch, merge into main, or force-push.
- Confirm final SHA and remote branch state.

## 10. Final report

Report root cause; final pinned JSON schema with a redacted example; migration behavior; files changed; automated test commands/results; Peekaboo scenarios/screenshots; limitations; commit SHA and push status.

**Do not stop until both issues are fixed, existing pinned data is safely migrated, the live UI is tested with Peekaboo, and the changes are committed and pushed to the same branch. Work independently without waiting for my reply.**
