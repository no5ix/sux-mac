# Space-Key Native Image Preview

## Behavior

In the clipboard-history panel, move the pointer over an image card and press Space to open that stored image in macOS Quick Look. Press Space again for the same image to terminate the preview process. Space does not paste or modify the clipboard item.

## Implementation

- Tracks the image card currently beneath the mouse pointer in the panel's WebView.
- Handles Space in the panel's keyboard event capture path and prevents the key from triggering the browser's default scrolling behavior.
- Dispatches a bridge message to the Hammerspoon Lua handler.
- Starts `/usr/bin/qlmanage -p <imagePath>` through `hs.task` to invoke the native macOS Quick Look UI.
- Tracks the open image path and preview task so Space can toggle the same item off.
- Cleans up the Quick Look task when the clipboard-history panel is dismissed.

## Manual verification

1. Reload the Hammerspoon configuration.
2. Open Clipboard History with the existing shortcut (Control+Shift+V).
3. Move the pointer over an image card and press Space. Confirm macOS Quick Look opens the original stored image.
4. Press Space again while the pointer remains over the same image. Confirm the Quick Look preview closes.
5. Confirm that pressing Space on text cards does not trigger image preview and that image preview does not paste or replace clipboard contents.
6. Dismiss the clipboard-history panel and verify any tracked preview task is terminated.

Automated GUI verification requires a running macOS session with Hammerspoon and Quick Look; it cannot be established by the GitHub connector alone.
