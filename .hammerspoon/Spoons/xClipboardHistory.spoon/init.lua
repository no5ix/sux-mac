local pkg = {}


------------------------ A simple clipboard history implement ------------------------

local hotkey = require "hs.hotkey"
local pasteboard = require "hs.pasteboard"
local pbwatcher = require "hs.pasteboard.watcher"
local webview = require "hs.webview"
local application = require "hs.application"
local logger = hs.logger.new("xClipboardHistory", "info")

local text_clipboard_history = {}  -- Array to store the clipboard history for text
local img_clipboard_history = {}  -- Array to store the clipboard history for img
local menuData = {}  -- Clipboard history data
local clipboard_webview = nil
local clipboard_usercontent = nil
local clipboard_search = ""
local clipboard_type_filter = "all" -- "all", "text", "image", or "none"
local panelCacheKey = nil
local panelCacheHTML = nil
local ignoreNextPasteboardChange = false
local lastAcceptedClipboardValue = nil
local previousApplication = nil
local suppressFocusDismiss = false
local selectedVisibleIndex = 1
local visibleIndices = {}
local panelScreenUUID = nil
local CLIPBOARD_RENDER_BATCH_SIZE = 60

-- Store images as compressed data URLs in history. Decode them only when the
-- user selects an image to paste, not for every row in the chooser.
local function decodeImage(entry)
    if not entry or not entry.imageData then return nil end
    return hs.image.imageFromURL(entry.imageData)
end

local function isImageDataURL(value)
    return type(value) == "string" and value:match("^data:image/") ~= nil
end

local function looksLikeImagePayload(value)
    if type(value) ~= "string" then return false end
    return isImageDataURL(value)
        or value:match("^iVBORw0KGgo") ~= nil
        or value:match("^/9j/") ~= nil
        or value:match("^R0lGOD") ~= nil
end

local function clearClipboardHistory()
    text_clipboard_history = {}
    img_clipboard_history = {}
    menuData = {}
    if clipboard_webview then
        clipboard_search = ""
        clipboard_webview:hide()
        clipboard_webview:html(clipboardPanelHTML())
    end
    collectgarbage("collect")
    -- make sure the lua vm is reloaded, otherwise the memory will not be released
    hs.reload()
end

local max_history_size_for_text = 10000
local max_history_size_for_img = 100
local display_max_text_length = 200

-- local last_change = pasteboard.changeCount() -- keeps track of how many times the pasteboard owner has changed // Indicates a new copy has been made

-- Add the given string to the history
function pasteboardToClipboard(item_type, item)
    local cur_ts = os.time()
    if item_type == "text" then
        table.insert(text_clipboard_history, {ts=cur_ts, content=item})
    else
        -- Keep the original image for pasting. Build a correctly-proportioned
        -- thumbnail; requesting a fixed square bitmap can stretch some source
        -- images depending on the image provider's bitmapRepresentation behavior.
        local thumbnail = nil
        local size = item:size()
        local width = tonumber(size and size.w) or 0
        local height = tonumber(size and size.h) or 0
        if width > 0 and height > 0 then
            local scale = math.min(1, 320 / width, 320 / height)
            local thumbWidth = math.max(1, math.floor(width * scale + 0.5))
            local thumbHeight = math.max(1, math.floor(height * scale + 0.5))
            thumbnail = item:bitmapRepresentation({w=thumbWidth, h=thumbHeight})
        end
        local fullImageURL = item:encodeAsURLString()
        table.insert(img_clipboard_history, {
            ts=cur_ts,
            imageData=fullImageURL,
            thumbnailData=thumbnail and thumbnail:encodeAsURLString() or fullImageURL
        })
        thumbnail = nil
    end
end

-- Add this function to handle clipboard changes
function handleClipboardChange(content)
    -- The selection toolbar sets this marker only for its temporary Cmd+C.
    -- Consume only a clipboard notification that occurs inside that short window;
    -- never suppress unrelated clipboard changes indefinitely.
    local syntheticUntil = tonumber(_G.xSelectionToolbarSyntheticCopyUntil) or 0
    if syntheticUntil > 0 and hs.timer.secondsSinceEpoch() <= syntheticUntil then
        _G.xSelectionToolbarSyntheticCopyUntil = nil
        return
    end
    _G.xSelectionToolbarSyntheticCopyUntil = nil
    if ignoreNextPasteboardChange then
        ignoreNextPasteboardChange = false
        return
    end

    pasteboard_watcher:start()

    -- A text clipboard callback is accepted only when it represents a real value
    -- change. This prevents accessibility selection updates or repeated watcher
    -- notifications from creating phantom history entries.
    if type(content) == "string" and content ~= "" then
        if content == lastAcceptedClipboardValue then return end
    end

    -- cur_change_cnt = pasteboard.changeCount()
    -- print("[handleClipboardChange] start, cur_change_cnt = " .. tostring(cur_change_cnt) .. ", last_change = " .. tostring(last_change))
    -- if (cur_change_cnt > last_change) then
        -- last_change = cur_change_cnt
        local pasteboardImg = pasteboard.readImage()  -- return a hs.image object
        -- Some apps expose image bytes or a data URL through the text flavor.
        -- Never treat recognized image payloads as a user-entered text item.
        if looksLikeImagePayload(content) then
            if pasteboardImg ~= nil then
                content = nil
            else
                -- Ignore image-encoded clipboard payloads rather than recording them as text.
                return
            end
        end
        if (content == nil) and (pasteboardImg ~= nil) then
            -- Don't add if it's the same as the last entry
            if #img_clipboard_history ~= 0 and 
                (#text_clipboard_history == 0 or (img_clipboard_history[#img_clipboard_history].ts > text_clipboard_history[#text_clipboard_history].ts)) then
                    if img_clipboard_history[#img_clipboard_history].imageData == pasteboardImg:encodeAsURLString() then
                        -- print("[handleClipboardChange] it's the same as the last img")
                        return
                    end
            end
            -- print("pasteboardImg.toASCII() = " .. pasteboardImg:toASCII())
            -- local sss = content:encodeAsURLString()
            -- pasteboardToClipboard("image", content:encodeAsURLString())  -- don't encode it , because it will be really slow when u decode a big img from url.
            pasteboardToClipboard("image", pasteboardImg)
            lastAcceptedClipboardValue = pasteboardImg:encodeAsURLString()
            -- Trim history if it gets too long
            if #img_clipboard_history > max_history_size_for_img then
                table.remove(img_clipboard_history, 1)
            end
            -- print("[handleClipboardChange] img.size.h = " .. content:size()["h"] .. ", img.size.w = " .. content:size()["w"])
            -- print("[handleClipboardChange] img")
        elseif content ~= nil then
            -- Trust the watcher callback's exact string. Re-reading the pasteboard
            -- here can race with another clipboard write and associate a different
            -- value with this callback. Keep capture and display byte-for-byte.
            -- Diagnostic capture showed that the watcher and pasteboard both
            -- receive "interesting" intact. Keep this callback payload unchanged;
            -- if the preview still contains missing letters, investigate clipboard
            -- writers or keyboard-remapping tools instead of altering stored text.
            -- logger.i("Clipboard history captured text: " .. string.format("%q", content))

            -- Don't add if it's the same as the last entry
            if #text_clipboard_history ~= 0 and 
                (#img_clipboard_history == 0 or (text_clipboard_history[#text_clipboard_history].ts > img_clipboard_history[#img_clipboard_history].ts)) then
                    if text_clipboard_history[#text_clipboard_history].content == content then
                        -- print("[handleClipboardChange] it's the same as the last text, content = " .. string.sub(content, 0, display_max_text_length))
                        return
                    end
            end
            pasteboardToClipboard("text", content)
            lastAcceptedClipboardValue = content
            -- Trim history if it gets too long
            if #text_clipboard_history > max_history_size_for_text then
                table.remove(text_clipboard_history, 1)
            end
            -- print("[handleClipboardChange] text")
        end
    -- end
end

-- restore the newest clipboard content
function restoreNewestClipContent()
    local newestText = text_clipboard_history[#text_clipboard_history]
    local newestImage = img_clipboard_history[#img_clipboard_history]
    if not newestText and not newestImage then return end
    if newestImage and (not newestText or newestImage.ts > newestText.ts) then
        local image = decodeImage(newestImage)
        if image then pasteboard.writeObjects(image) end
    elseif newestText then
        pasteboard.setContents(newestText.content)
    end
end


local function escapeHTML(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    value = value:gsub('"', "&quot;"):gsub("'", "&#39;")
    return value
end

-- Encode arbitrary Lua strings as JavaScript string literals. hs.json.encode
-- accepts tables only in Hammerspoon, so don't pass strings to it.
local function jsStringLiteral(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
                 :gsub('"', '\\"')
                 :gsub("\b", "\\b")
                 :gsub("\f", "\\f")
                 :gsub("\n", "\\n")
                 :gsub("\r", "\\r")
                 :gsub("\t", "\\t")
                 :gsub("[%z\1-\31]", function(ch)
                     return string.format("\\u%04x", string.byte(ch))
                 end)
                 :gsub("\226\128\168", "\\u2028")
                 :gsub("\226\128\169", "\\u2029")
    return '"' .. value .. '"'
end

local function historyItemHTML(entry, index)
    local stamp = os.date("%Y-%m-%d %H:%M:%S", entry.rowTs or os.time())
    local selectedClass = ""
    if entry.type == "image" then
        local src = entry.historyEntry and entry.historyEntry.thumbnailData or ""
        local preview
        if src ~= "" then
            preview = '<img class="preview" src="' .. escapeHTML(src) .. '" alt="Clipboard image preview" loading="lazy" decoding="async">'
        else
            preview = '<div class="preview placeholder">Image preview unavailable</div>'
        end
        return '<button class="item image-item' .. selectedClass .. '" data-kind="image" data-action="paste" data-index="' .. index .. '" data-search="' .. escapeHTML(string.lower("[image] " .. stamp)) .. '">' ..
            preview .. '<div class="meta"><div class="kind">IMAGE</div><div class="stamp">' ..
            escapeHTML(stamp) .. '</div><div class="hint">Click to paste</div></div></button>'
    end
    local content = tostring(entry.data or "")
    -- Render the captured clipboard string directly. Do not transform its
    -- characters in Lua; CSS handles line wrapping and clipping in the card.
    -- This makes the preview a faithful view of the actual saved clipboard data.
    local previewText = content
    if isImageDataURL(content) or looksLikeImagePayload(content) then
        previewText = "[Image data]"
    end
    return '<button class="item text-item' .. selectedClass .. '" data-kind="text" data-action="paste" data-index="' .. index .. '" data-search="' .. escapeHTML(string.lower(content .. " " .. stamp)) .. '">' ..
        '<div class="kind">TEXT</div><div class="stamp">' .. escapeHTML(stamp) ..
        '</div><div class="text-preview">' .. escapeHTML(previewText) ..
        '</div><div class="hint">Click to paste</div></button>'
end

local function clipboardEntryMatches(entry, query, kind)
    if kind == "none" then return false end
    if kind ~= "all" and entry.type ~= kind then return false end
    local stamp = os.date("%Y-%m-%d %H:%M:%S", entry.rowTs or os.time())
    local searchableText = entry.type == "image" and "[image]" or tostring(entry.data or "")
    local searchable = string.lower(searchableText .. " " .. stamp)
    query = string.lower(tostring(query or ""))
    return query == "" or searchable:find(query, 1, true) ~= nil
end

local function getClipboardMatches(query, kind)
    local matches = {}
    for index, entry in ipairs(menuData or {}) do
        if (entry.type == "text" or entry.type == "image")
            and clipboardEntryMatches(entry, query, kind) then
            matches[#matches + 1] = index
        end
    end
    return matches
end

local function renderClipboardBatch(query, kind, offset)
    local matches = getClipboardMatches(query, kind)
    local cards = {}
    offset = math.max(0, tonumber(offset) or 0)
    local last = math.min(#matches, offset + CLIPBOARD_RENDER_BATCH_SIZE)
    for position = offset + 1, last do
        local index = matches[position]
        cards[#cards + 1] = historyItemHTML(menuData[index], index)
    end
    visibleIndices = matches
    return table.concat(cards, "\n"), #matches, last
end

function clipboardPanelHTML()
    local cardsHTML, matchingCount, renderedCount = renderClipboardBatch("", "all", 0)
    clipboard_search = ""
    clipboard_type_filter = "all"
    local initialCardsHTML = cardsHTML ~= "" and cardsHTML or '<div id="no-matches" class="empty">No clipboard items</div>'
    local loadMoreHTML = renderedCount < matchingCount and
        '<div class="load-more-wrap"><button class="action" data-action="loadMore" data-index="' ..
        renderedCount .. '">Load more (' .. (matchingCount - renderedCount) .. ' remaining)</button></div>' or ''
    local html = [[
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
* { box-sizing: border-box; }
body { margin:0; background:#1d1f24; color:#f5f6f8; font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif; }
header { position:sticky; top:0; z-index:5; padding:14px 16px 12px; background:#202329; border-bottom:1px solid #3c4049; }
.top { display:flex; align-items:center; gap:10px; }
.title-actions { display:flex; align-items:center; gap:10px; min-width:0; }
h1 { margin:0; font-size:17px; font-weight:650; }
.header-clear { flex-shrink:0; }
.count { color:#aab0bd; font-size:12px; margin-left:auto; }
input { width:100%; margin-top:10px; padding:9px 11px; border-radius:9px; border:1px solid #454a55; background:#15171b; color:#f5f6f8; font-size:13px; outline:none; }
input:focus { border-color:#7da6ff; }
main:focus { outline:none; }
.item:focus-visible { outline:2px solid #8cb1ff; outline-offset:2px; }
.item[hidden], .load-more-wrap[hidden], .empty[hidden] { display:none!important; }
.actions { display:flex; gap:8px; margin-top:10px; }
.action { border:1px solid #4a505b; border-radius:8px; padding:7px 10px; background:#30343d; color:#f7f7f9; cursor:pointer; font-size:12px; }
.action.primary { background:#3267d6; border-color:#3267d6; }
.action.filter-button[aria-pressed="true"] { background:#dbeafe; border-color:#bfdbfe; color:#25344a; }
.action.danger { color:#ff9b9b; }
main { padding:12px; display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); gap:12px; align-items:start; }
.item { font:inherit; width:100%; min-width:0; color:inherit; text-align:left; border:1px solid #414650; border-radius:12px; background:#272a31; padding:10px; cursor:pointer; overflow:hidden; }
#clipboard-items .item:focus { outline:2px solid #8cb1ff; outline-offset:2px; }
.item:hover { border-color:#85aaff; background:#30343d; }
.item.selected { border-color:#8cb1ff; outline:2px solid #6d98ff; outline-offset:1px; background:#343a46; }
.image-item .preview { width:100%; height:160px; max-width:100%; object-fit:contain; object-position:center center; display:block; background:#191b20; border-radius:7px; }
.image-item .preview { aspect-ratio:auto; }
.image-item .preview:not([src]), .image-item .preview[src=""] { object-fit:contain; }
.text-preview { overflow-wrap:anywhere; word-break:break-word; }
.preview.placeholder { display:flex; align-items:center; justify-content:center; color:#9ba2af; }
.meta { padding:9px 2px 1px; }
.kind { font-size:10px; letter-spacing:.12em; color:#93b5ff; font-weight:700; }
.stamp { color:#b8beca; font-size:11px; margin-top:5px; }
.text-preview { margin-top:10px; min-height:70px; max-height:120px; overflow:hidden; white-space:pre-wrap; overflow-wrap:anywhere; word-break:normal; font-size:13px; line-height:1.45; }
.hint { color:#8e96a5; font-size:10px; margin-top:8px; }
.empty { color:#9ca3b1; text-align:center; padding:40px 12px; grid-column:1/-1; }
footer { padding:8px 16px; color:#9299a7; border-top:1px solid #393d46; font-size:11px; }
body.keyboard-mode #search { border-color:#7da6ff; }
</style></head><body>
<header><div class="top"><div class="title-actions"><h1>Clipboard History</h1><button class="action danger header-clear" data-action="clearAll">Clear All</button></div><span class="count">]] .. tostring(matchingCount) .. [[ matching items</span></div>
<input id="search" placeholder="Search clipboard history…" value="]] .. escapeHTML(clipboard_search) .. [[" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" data-gramm="false">
<div class="actions">
<button class="action filter-button" data-action="filter" data-filter="text" aria-pressed="false">Text</button>
<button class="action filter-button" data-action="filter" data-filter="image" aria-pressed="false">Images</button></div></header>
<main id="clipboard-items">]] .. initialCardsHTML .. loadMoreHTML .. [[</main>
<footer>Tab: results · Shift+Tab: search · Arrow keys: select when results are focused · Click: paste · Esc: close</footer>
<script>
const bridge = (action, index, query, kind) => {
  try { window.webkit.messageHandlers.clipboardHistory.postMessage({action, index, query, kind}); } catch (_) {}
};
document.addEventListener('click', event => {
  const contextItem = event.target.closest('#clipboard-context-menu');
  if (contextItem) return;
  const button = event.target.closest('[data-action]');
  if (button) {
    const action = button.dataset.action;
    const index = Number(button.dataset.index || 0);
    if (action === 'filter') {
      setActiveFilter(button);
      return;
    }
    if (action === 'loadMore') {
      bridge('loadMore', index, search.value, activeTypeFilter);
      return;
    }
    if (action === 'clearAll') {
      bridge('clearAll', index, '');
      return;
    }
    bridge(action, index, '');
    return;
  }
  const item = event.target.closest('.item');
  if (!item) return;
  event.preventDefault();
  event.stopPropagation();
  const index = Number(item.dataset.index || 0);
  selectRow(rows().indexOf(item));
  bridge('paste', index, '');
});
const search = document.getElementById('search');
let searchTimer = null;
const activeTypeFilters = new Set();
function currentTypeFilter() {
  if (activeTypeFilters.size === 0) return 'all';
  if (activeTypeFilters.size === 2) return 'none';
  return activeTypeFilters.has('text') ? 'text' : 'image';
}
function applyFilters() {
  bridge('search', 0, search.value, currentTypeFilter());
}
function setActiveFilter(button) {
  const kind = button.dataset.filter;
  if (activeTypeFilters.has(kind)) activeTypeFilters.delete(kind);
  else activeTypeFilters.add(kind);
  document.querySelectorAll('[data-action="filter"]').forEach(other => {
    other.setAttribute('aria-pressed', activeTypeFilters.has(other.dataset.filter) ? 'true' : 'false');
  });
  bridge('search', 0, search.value, currentTypeFilter());
}
search.addEventListener('input', () => {
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = setTimeout(applyFilters, 160);
});
const resultsPanel = document.getElementById('clipboard-items');
resultsPanel.tabIndex = 0;
resultsPanel.setAttribute('role', 'listbox');
resultsPanel.setAttribute('aria-label', 'Clipboard history results');

let selectedIndex = 0;
function rows() { return Array.from(document.querySelectorAll('main .item')).filter(item => !item.hidden && item.dataset.action === 'paste'); }
function selectRow(next) {
  const items = rows();
  if (!items.length) { selectedIndex = 0; return; }
  selectedIndex = Math.max(0, Math.min(items.length - 1, next));
  items.forEach((item, i) => item.classList.toggle('selected', i === selectedIndex));
  // Selection/highlight must never move the grid on its own. The user controls
  // viewport position by scrolling; keyboard navigation only changes the row state.
}
function clearRowSelection() {
  rows().forEach(item => item.classList.remove('selected'));
}
resultsPanel.addEventListener('focus', () => {
  const items = rows();
  if (items.length) {
    selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex));
    items.forEach((item, i) => item.classList.toggle('selected', i === selectedIndex));
  }
});
resultsPanel.addEventListener('blur', () => {
  // The blue selection border is keyboard-navigation feedback only. Hide it
  // whenever focus leaves the results area (for example, back to search).
  clearRowSelection();
});
search.addEventListener('focus', clearRowSelection);
resultsPanel.addEventListener('focusout', event => {
  if (event.relatedTarget === search) return;
});
document.addEventListener('focusin', event => {
  if (event.target.classList && event.target.classList.contains('item')) {
    const items = rows();
    const index = items.indexOf(event.target);
    if (index >= 0) selectRow(index);
  }
});
window.resetClipboardSelection = () => {
  selectedIndex = 0;
  clearRowSelection();
};
const contextMenu = document.createElement('div');
contextMenu.id = 'clipboard-context-menu';
contextMenu.innerHTML = '<button type="button">Paste All the rows above this row in the order from early to late, including this row</button>';
contextMenu.style.cssText = 'display:none;position:fixed;z-index:9999;min-width:320px;max-width:460px;padding:5px;background:#252932;border:1px solid #555d6b;border-radius:8px;box-shadow:0 8px 28px rgba(0,0,0,.45);';
contextMenu.querySelector('button').style.cssText = 'display:block;width:100%;padding:10px 12px;border:0;border-radius:5px;background:transparent;color:#f5f6f8;text-align:left;font:13px -apple-system,BlinkMacSystemFont,sans-serif;white-space:normal;cursor:pointer;';
document.body.appendChild(contextMenu);
let contextRowIndex = 0;
document.addEventListener('contextmenu', event => {
  const item = event.target.closest('.item');
  if (!item) return;
  event.preventDefault();
  contextRowIndex = Number(item.dataset.index || 0);
  selectRow(rows().indexOf(item));
  contextMenu.style.display = 'block';
  const menuWidth = Math.min(460, window.innerWidth - 16);
  const menuHeight = contextMenu.offsetHeight || 64;
  contextMenu.style.left = Math.max(8, Math.min(event.clientX, window.innerWidth - menuWidth - 8)) + 'px';
  contextMenu.style.top = Math.max(8, Math.min(event.clientY, window.innerHeight - menuHeight - 8)) + 'px';
});
contextMenu.querySelector('button').addEventListener('mouseenter', () => {
  contextMenu.querySelector('button').style.background = '#3a4250';
});
contextMenu.querySelector('button').addEventListener('mouseleave', () => {
  contextMenu.querySelector('button').style.background = 'transparent';
});
contextMenu.querySelector('button').addEventListener('click', event => {
  event.preventDefault();
  event.stopPropagation();
  const rowIndex = contextRowIndex;
  contextMenu.style.display = 'none';
  bridge('pasteAllFrom', rowIndex, '');
});
document.addEventListener('click', event => {
  if (!event.target.closest('#clipboard-context-menu')) contextMenu.style.display = 'none';
});

document.addEventListener('keydown', event => {
  // Keep arrow keys in the search input native, so the caret can move through
  // the query. Tab moves to the results container; Shift+Tab returns to search.
  if (event.key === 'Tab' && event.target === search && !event.shiftKey) {
    event.preventDefault();
    // Prevent WebKit from revealing the focused results container/card by
    // scrolling the document. Keep the search field's current viewport stable.
    const scrollX = window.scrollX;
    const scrollY = window.scrollY;
    resultsPanel.focus({preventScroll:true});
    window.scrollTo(scrollX, scrollY);
    return;
  }
  if (event.key === 'Tab' && event.shiftKey &&
      (event.target === resultsPanel ||
       (event.target.classList && event.target.classList.contains('item') &&
        resultsPanel.contains(event.target)))) {
    event.preventDefault();
    search.focus();
    search.setSelectionRange(search.value.length, search.value.length);
    return;
  }
  if (event.target === search && ['ArrowDown','ArrowUp','ArrowLeft','ArrowRight','Home','End'].includes(event.key)) {
    return;
  }
  if (event.key === 'Escape') {
    event.preventDefault();
    if (contextMenu.style.display !== 'none') contextMenu.style.display = 'none';
    else bridge('close', 0, '');
    return;
  }
  const items = rows();
  if (resultsPanel.contains(event.target) && ['ArrowDown','ArrowUp','ArrowLeft','ArrowRight'].includes(event.key)) {
    event.preventDefault();
    if (event.key === 'ArrowRight') selectRow(selectedIndex + 1);
    else if (event.key === 'ArrowLeft') selectRow(selectedIndex - 1);
    else {
      const columns = Math.max(1, Math.round(document.querySelector('main').clientWidth / 250));
      selectRow(selectedIndex + (event.key === 'ArrowDown' ? columns : -columns));
    }
    const selected = rows()[selectedIndex];
    if (selected) selected.focus({preventScroll:true});
    return;
  }
  if (event.key === 'Enter') {
    event.preventDefault();
    const item = items[selectedIndex];
    if (item) bridge('paste', Number(item.dataset.index || 0), '');
  }
});
// Do not preselect the first card or scroll the grid on open. Tab should
// only move focus to the results container; the user chooses a row with arrows.
clearRowSelection();
search.focus();
</script></body></html>]]
    return html
end

local function pasteHistoryEntry(index)
    local choice = menuData and menuData[index]
    if not choice or (choice.type ~= "text" and choice.type ~= "image") then return end
    pasteboard_watcher:stop()
    if choice.type == "text" then
        pasteboard.setContents(choice.data)
    else
        local image = decodeImage(choice.historyEntry)
        if not image then
            pasteboard_watcher:start()
            hs.alert.show("Unable to restore this clipboard image")
            return
        end
        pasteboard.writeObjects(image)
    end
    if clipboard_webview then clipboard_webview:hide() end
    hs.timer.doAfter(0.15, function()
        -- Restore focus to the app that was active before the history panel opened.
        if previousApplication and previousApplication:isRunning() then
            previousApplication:activate(true)
        end
        hs.timer.doAfter(0.35, function()
            hs.eventtap.keyStroke({"cmd"}, "v", 0)
            hs.timer.doAfter(0.6, function()
                restoreNewestClipContent()
                pasteboard_watcher:start()
                menuData = {}
                previousApplication = nil
            end)
        end)
    end)
end

local function updateClipboardPanel(query, kind, offset, append)
    query = tostring(query or "")
    if kind ~= "text" and kind ~= "image" and kind ~= "none" then kind = "all" end
    local cardsHTML, matchingCount, renderedCount = renderClipboardBatch(query, kind, offset)
    local hasMore = kind ~= "none" and renderedCount < matchingCount
    local loadMoreHTML = hasMore and
        '<div class="load-more-wrap"><button class="action" data-action="loadMore" data-index="' ..
        renderedCount .. '">Load more (' .. (matchingCount - renderedCount) .. ' remaining)</button></div>' or ''
    if cardsHTML == "" and not append then
        cardsHTML = '<div id="no-matches" class="empty">No matching clipboard items</div>'
    end
    local script
    if append then
        script = "var main=document.getElementById('clipboard-items');" ..
            "var oldMore=main.querySelector('.load-more-wrap');if(oldMore)oldMore.remove();" ..
            "main.insertAdjacentHTML('beforeend'," .. jsStringLiteral(cardsHTML .. loadMoreHTML) .. ");"
    else
        script = "document.getElementById('clipboard-items').innerHTML=" ..
            jsStringLiteral(cardsHTML .. loadMoreHTML) .. ";"
    end
    script = script ..
        "document.querySelector('.count').textContent=" .. jsStringLiteral(tostring(matchingCount) .. " matching items") .. ";" ..
        "var active=" .. jsStringLiteral(kind) .. ";" ..
        "document.querySelectorAll('[data-action=filter]').forEach(function(b){b.setAttribute('aria-pressed',active==='none'?'true':(b.dataset.filter===active?'true':'false'))});" ..
        "if(window.resetClipboardSelection)window.resetClipboardSelection();"
    clipboard_webview:evaluateJavaScript(script)
    clipboard_search = query
    clipboard_type_filter = kind
end

function handleClipboardPanelMessage(message)
    local body = message and message.body
    if type(body) ~= "table" then return end
    if body.action == "close" then
        if clipboard_webview then clipboard_webview:hide() end
    elseif body.action == "search" or body.action == "filter" then
        updateClipboardPanel(body.query or "", body.kind or clipboard_type_filter or "all", 0, false)
    elseif body.action == "loadMore" then
        updateClipboardPanel(body.query or clipboard_search or "", body.kind or clipboard_type_filter or "all", tonumber(body.index) or 0, true)
    elseif body.action == "paste" then
        pasteHistoryEntry(tonumber(body.index))
    elseif body.action == "pasteAllFrom" then
        pasteSomeWithDelimiterFromStartRow(tonumber(body.index))
    elseif body.action == "clearAll" then
        clearClipboardHistory()
        if clipboard_webview then clipboard_webview:html(clipboardPanelHTML()); clipboard_webview:show() end
        pasteboard_watcher:start()
        hs.alert.show("Clipboard history cleared")
    end
end


local function positionPanelOnCurrentScreen()
    local screens = hs.screen.allScreens()
    local pointer = hs.mouse.absolutePosition()
    local target = hs.screen.mainScreen()
    for _, screen in ipairs(screens) do
        local f = screen:fullFrame()
        if pointer.x >= f.x and pointer.x < f.x + f.w and pointer.y >= f.y and pointer.y < f.y + f.h then
            target = screen
            break
        end
    end
    if target then
        panelScreenUUID = target:getUUID()
        local f = target:frame()
        local current = clipboard_webview and clipboard_webview:frame() or {w=980,h=760}
        local w, h = math.min(current.w or 980, f.w), math.min(current.h or 760, f.h)
        clipboard_webview:frame({x=f.x + math.max(0,(f.w-w)/2), y=f.y + math.max(0,(f.h-h)/2), w=w, h=h})
    end
end

clipboard_usercontent = webview.usercontent.new("clipboardHistory")
clipboard_usercontent:setCallback(handleClipboardPanelMessage)
clipboard_webview = webview.new(
    {x = 120, y = 80, w = 980, h = 760},
    {javaScriptEnabled = true, privateBrowsing = true, shadow = true},
    clipboard_usercontent
):windowStyle({"titled", "closable", "resizable"})
clipboard_webview:shadow(true)
clipboard_webview:allowTextEntry(true)
clipboard_webview:windowCallback(function(action, _, focused)
    if action == "focusChange" and focused == false and not suppressFocusDismiss then
        -- Clicking another app or elsewhere dismisses the floating history panel.
        hs.timer.doAfter(0.1, function()
            if clipboard_webview then clipboard_webview:hide() end
        end)
    end
end)

-- Paste clipboard-history rows from the oldest selected item to the newest.
-- The chooser is displayed newest-first, so walk the selected range backwards.
local function finishPasteAll()
    restoreNewestClipContent()
    menuData = {}
    if clipboard_webview then clipboard_webview:html(clipboardPanelHTML()) end
    pasteboard_watcher:start()
    previousApplication = nil
    hs.alert.show("The Paste task has finished.")
end

local function pasteAllRowsStep(row)
    if not menuData or row < 1 then
        finishPasteAll()
        return
    end

    local entry = menuData[row]
    if not entry or (entry.type ~= "text" and entry.type ~= "image") then
        hs.timer.doAfter(0.05, function()
            pasteAllRowsStep(row - 1)
        end)
        return
    end

    local wroteContent = false
    if entry.type == "text" then
        wroteContent = pasteboard.setContents(entry.data .. "\n") ~= false
    else
        local image = decodeImage(entry.historyEntry)
        if image then
            wroteContent = pasteboard.writeObjects(image) ~= false
        else
            hs.alert.show("Skipped an image that could not be decoded.")
        end
    end

    if not wroteContent then
        hs.timer.doAfter(0.05, function()
            pasteAllRowsStep(row - 1)
        end)
        return
    end

    -- Give the destination app time to consume this clipboard item before it
    -- is replaced by the next entry.
    hs.timer.doAfter(0.15, function()
        hs.eventtap.keyStroke({"cmd"}, "v", 0)
        hs.timer.doAfter(0.4, function()
            if entry.type == "image" then
                -- Preserve the existing behavior of separating images with a newline.
                pasteboard.setContents("\n")
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStroke({"cmd"}, "v", 0)
                    hs.timer.doAfter(0.4, function()
                        pasteAllRowsStep(row - 1)
                    end)
                end)
            else
                pasteAllRowsStep(row - 1)
            end
        end)
    end)
end

function pasteAllWithDelimiterRecursionVersion(startRow)
    pasteAllRowsStep(startRow)
end

function pasteSomeWithDelimiterFromStartRow(startRow)
    if type(startRow) ~= "number" or startRow < 1 or not menuData or #menuData == 0 then
        hs.alert.show("No clipboard-history rows to paste.")
        return
    end

    hs.alert.show("Please wait for the Paste task to finish.")
    pasteboard_watcher:stop()
    if clipboard_webview then clipboard_webview:hide() end
    -- Restore the app that was frontmost before the panel opened before any
    -- paste keystrokes are sent.
    hs.timer.doAfter(0.15, function()
        if previousApplication and previousApplication:isRunning() then
            previousApplication:activate(true)
        end
        hs.timer.doAfter(0.35, function()
            -- The web panel lists newest-first; the recursive routine walks
            -- selected row -> newest row, which pastes oldest-to-newest.
            pasteAllWithDelimiterRecursionVersion(startRow)
        end)
    end)
end

-- Function to show clipboard history
function showClipboardHistory()
    -- Initialize defensively in case the watcher was torn down during reload.
    if not pasteboard_watcher then
        pasteboard_watcher = pbwatcher.new(handleClipboardChange)
    end
    pasteboard_watcher:start()
    if not clipboard_webview then
        logger.e("Clipboard history panel is unavailable; cannot show it")
        return
    end

    -- Remember the app that should receive a paste before the panel takes focus.
    local frontApp = application.frontmostApplication()
    if frontApp and frontApp:bundleID() ~= "org.hammerspoon.Hammerspoon" then
        previousApplication = frontApp
    elseif previousApplication and previousApplication:isRunning() then
        -- Preserve the app remembered before an immediate repeated hotkey.
    else
        previousApplication = nil
    end
    suppressFocusDismiss = true
    menuData = {}

    function insertToMenuData(v, type, unixTs)
        -- print("unixTs " .. tostring(unixTs))
        local dateTimeStr = "[" .. os.date("%Y-%m-%d %H:%M:%S", unixTs) .. "] "
        if type == "text" then
            table.insert(menuData, { 
                menuItemIdx = #menuData + 1,
                text = dateTimeStr .. string.sub(v, 0, display_max_text_length),
                type = type,
                rowTs = unixTs,
                data = v
            })
        elseif (type == "image") then
            -- Avoid decoding every full-size screenshot when constructing the list.
            table.insert(menuData, {
                menuItemIdx = #menuData + 1,
                text = dateTimeStr .. "[IMG]",
                type = type,
                rowTs = unixTs,
                historyEntry = v
            })
        end
    end

    -- Merge newest-first snapshots defensively. Clipboard callbacks may trim
    -- history while the panel is being assembled, so never index an absent entry.
    local i = #text_clipboard_history
    local j = #img_clipboard_history
    while i >= 1 and j >= 1 do
        local textEntry = text_clipboard_history[i]
        local imageEntry = img_clipboard_history[j]
        if not textEntry then
            i = i - 1
        elseif not imageEntry then
            j = j - 1
        elseif textEntry.ts > imageEntry.ts then
            insertToMenuData(textEntry.content, "text", textEntry.ts)
            i = i - 1
        else
            insertToMenuData(imageEntry, "image", imageEntry.ts)
            j = j - 1
        end
    end

    while i >= 1 do
        local textEntry = text_clipboard_history[i]
        if textEntry then
            insertToMenuData(textEntry.content, "text", textEntry.ts)
        end
        i = i - 1
    end

    while j >= 1 do
        local imageEntry = img_clipboard_history[j]
        if imageEntry then
            insertToMenuData(imageEntry, "image", imageEntry.ts)
        end
        j = j - 1
    end

    clipboard_search = ""
    clipboard_webview:html(clipboardPanelHTML())
    positionPanelOnCurrentScreen()
    clipboard_webview:show()
    clipboard_webview:hswindow():focus()
    clipboard_webview:evaluateJavaScript("document.body.classList.add('keyboard-mode');")
    -- Clear this guard after the initial key-window transition settles.
    hs.timer.doAfter(0.25, function() suppressFocusDismiss = false end)

end

-- Start the pasteboard watcher
pasteboard_watcher = pbwatcher.new(handleClipboardChange)
pasteboard_watcher:start()

-- Keep an explicit reference to the global shortcut so it remains live after
-- Spoon reloads. Bindings are global, so browser password fields should not
-- prevent the history panel from being triggered by this chord.
local historyHotkey = hotkey.bind({"ctrl", "shift"}, "v", showClipboardHistory)
if historyHotkey then historyHotkey:enable() end



return pkg