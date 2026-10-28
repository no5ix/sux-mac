# Small Screenshot Missing from Clipboard History

## Fix

Clipboard image capture first uses Hammerspoon's normal `pasteboard.readImage()`. If that returns no image, it inspects the raw data for known bitmap UTIs (PNG, JPEG, GIF, TIFF, and BMP) and decodes those bytes to an `hs.image`. If the clipboard watcher delivers a recognized PNG/JPEG/GIF base64 payload instead of a native image object, the handler also tries to decode that payload.

Recognized image payloads are never persisted as ordinary text. If image decoding fails, the handler logs a warning and skips the entry, rather than inserting corrupted content into text history. Successfully decoded images follow the existing full-size disk save, thumbnail generation, and history metadata flow.

## Manual test plan

1. Reload Hammerspoon.
2. Copy a very small screenshot (for example, a narrow selection only a few pixels wide and high).
3. Open Clipboard History and confirm the entry appears as an image.
4. Paste with Cmd+V to verify the original clipboard data remains intact.
5. Repeat with regular screenshots, screenshot selections, PNG files copied from Finder, and text to ensure image recovery does not alter normal text capture.
6. If an image still fails to appear, inspect Hammerspoon's console for the warning about an undecodable image payload, and capture the clipboard UTI list to identify the specific provider representation.

Live macOS/Hammerspoon runtime tests were not available through the GitHub connector.
