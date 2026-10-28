# Screenshot Capture Memory Use

## Change summary

Clipboard image capture now validates image dimensions before writing image data or creating a thumbnail. Images with invalid dimensions or either dimension above 32,768 pixels are rejected with a warning. Thumbnail generation continues to cap the longest edge at 112 pixels and reports skipped thumbnails for extreme dimensions.

The image-capture path ignores re-entrant image callbacks while a screenshot is being saved and thumbnailed, which prevents duplicate work from simultaneously holding multiple large image buffers. The full-resolution original is saved to disk, and clipboard history retains the image file path and disk-backed thumbnail path rather than keeping the full-resolution `hs.image` object in Lua history.

After processing, the callback reference is cleared and Lua garbage collection is requested.

## What this may address

Saving a large screenshot and generating a bitmap thumbnail can temporarily require memory for the original native image and a second bitmap. Duplicate or overlapping callbacks can increase that peak. These changes bound invalid/extreme input, reduce duplicate processing, and avoid retaining the source image in clipboard history.

## Manual verification

1. Reload Hammerspoon.
2. Record Hammerspoon's process memory in Activity Monitor.
3. Take a normal screenshot and copy it to the clipboard; wait several seconds after the history entry appears.
4. Repeat with a high-resolution screenshot and verify that memory returns toward its normal baseline rather than continuing to grow after each capture.
5. Take several screenshots in quick succession and check that history entries are not duplicated due to overlapping callbacks.
6. Verify that image history and image previews still work for ordinary screenshots.

## Limitation

The GitHub connector can confirm source changes but cannot run Hammerspoon on a live macOS session or measure resident memory. The change is not runtime-validated here. If Activity Monitor truly reports hundreds of gigabytes rather than hundreds of megabytes, inspect the exact process, memory column, and unit—the reported number is unusual for this app and may reflect a unit or process-selection mix-up.
