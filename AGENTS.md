# AGENTS.md

## Purpose

This repository contains Sux-Mac, a macOS utility application. The clipboard-history panel is implemented as a Hammerspoon Spoon in Lua.

These instructions apply to all AI coding agents working in this repository. Read `ARCHITECTURE.md` before making changes that affect application behavior or data storage.

## General engineering rules

- Inspect the current branch, working tree, relevant source files, and existing behavior before editing.
- Preserve unrelated user changes. Never reset, discard, or overwrite work you did not create.
- Make the smallest coherent change that solves the requested problem. Avoid broad rewrites and unrelated refactoring.
- Follow existing naming, formatting, logging, error-handling, and file-layout conventions.
- Prefer extending existing abstractions over introducing parallel implementations.
- Do not claim tests, builds, UI interactions, or visual checks passed unless you actually ran them and observed their results.
- Explain any environment limitation honestly.
- Do not place real clipboard contents, credentials, or sensitive user data in logs, tests, or documentation.

## Hammerspoon / Lua safety

- Lua local declarations are lexical. A function that references another local function must be declared after that dependency, or use an explicitly forward-declared local variable. Otherwise Lua may resolve the name as a global and fail at runtime.
- Be especially careful with module-load-time initialization: helpers called while the Spoon file is being evaluated must already be defined.
- Before adding or moving helpers, inspect their declaration order and every module-load-time call site.
- Do not assume an API exists because its name resembles a standard filesystem API. Check the actual Hammerspoon API used by this project.
- Use protected calls only where they improve recovery; do not hide failures that should be surfaced to the user or logged.
- Keep WebView callbacks defensive: validate message bodies, indices, item types, and file paths.
- Avoid retaining large clipboard text payloads, Base64 image data, or decoded NSImage objects in long-lived caches.

## Clipboard History-specific rules

- Main implementation: `.hammerspoon/Spoons/xClipboardHistory.spoon/init.lua`.
- Preserve existing capture, retention, search, date/type filtering, pagination, keyboard navigation, manual Preview, context menu, paste, copy, focus restoration, and dismissal behavior unless the task explicitly changes it.
- Do not reintroduce hover-to-preview behavior.
- Ordinary history is date-partitioned on disk and uses a bounded in-memory cache plus on-demand hydration. Keep that memory-conscious approach.
- Pinning is a separate persistent collection under `clipboard-history/pinned/`; it must not be coupled to the seven-day cleanup of ordinary date folders.
- Pinning copies source files; it must not move or mutate ordinary history files.
- Clear All intentionally clears both ordinary and pinned history.
- The Pin scope is mutually exclusive with date scopes. Text and Images remain independently selectable with Pin.
- Search must be scoped to the active collection and must search full text payloads, not only preview snippets or metadata.
- Preserve the original clipboard timestamp for date filtering and the separate pin timestamp for pin-order/audit metadata.
- When changing the pinned JSON schema, maintain compatibility with the ordinary history record schema where practical, and keep content/file lifecycle explicit.

## Required workflow for code changes

1. Read this file and `ARCHITECTURE.md`.
2. Inspect the relevant source and current branch head.
3. Trace the full data and UI path before changing it.
4. Implement the fix with targeted changes.
5. Add or update regression coverage where the repository supports it.
6. Run relevant syntax/tests and report exact results. For Hammerspoon-only UI behavior, distinguish static checks from live macOS testing.
7. Review the final diff for accidental changes.
8. Commit only intended changes with a descriptive message. Push only when requested.

## Visual testing

For tasks involving the clipboard-history UI, use Peekaboo against the running Hammerspoon application when available. Verify the actual state after each interaction; a successful automation command alone is not proof of success. Capture screenshots for meaningful states and inspect them. If Peekaboo cannot perform an interaction, try a reasonable alternative and describe what remains unverified.
