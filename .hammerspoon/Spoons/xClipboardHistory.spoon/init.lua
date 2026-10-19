local pkg = {}


------------------------ A simple clipboard history implement ------------------------

local hotkey = require "hs.hotkey"
local pasteboard = require "hs.pasteboard"
local pbwatcher = require "hs.pasteboard.watcher"
local webview = require "hs.webview"
local application = require "hs.application"

local text_clipboard_history = {}  -- Array to store the clipboard history for text
local img_clipboard_history = {}  -- Array to store the clipboard history for img
local menuData = {}  -- Clipboard history data
local clipboard_webview = nil
local clipboard_usercontent = nil
local clipboard_search = ""
local previousApplication = nil
local suppressFocusDismiss = false
local selectedVisibleIndex = 1
local visibleIndices = {}
local panelScreenUUID = nil

-- Store images as compressed data URLs in history. Decode them only when the
-- user selects an image to paste, not for every row in the chooser.
local function decodeImage(entry)
    if not entry or not entry.imageData then return nil end
    return hs.image.imageFromURL(entry.imageData)
end

local function isImageDataURL(value)
    return type(value) == "string" and value:match("^data:image/") ~= nil
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
        -- Keep the full image for pasting, plus a small encoded thumbnail for
        -- the chooser. This avoids decoding full-resolution screenshots just
        -- to display the history list.
        local thumbnail = item:bitmapRepresentation({w=320, h=320})
        table.insert(img_clipboard_history, {
            ts=cur_ts,
            imageData=item:encodeAsURLString(),
            thumbnailData=thumbnail and thumbnail:encodeAsURLString() or nil
        })
        thumbnail = nil
    end
end

-- Add this function to handle clipboard changes
function handleClipboardChange(content)
    pasteboard_watcher:start()  -- if u don't add this line, it will stop in some seconds for no reason, idk why

    -- cur_change_cnt = pasteboard.changeCount()
    -- print("[handleClipboardChange] start, cur_change_cnt = " .. tostring(cur_change_cnt) .. ", last_change = " .. tostring(last_change))
    -- if (cur_change_cnt > last_change) then
        -- last_change = cur_change_cnt
        local pasteboardImg = pasteboard.readImage()  -- return a hs.image object
        -- Some apps expose the selected image as a data URL in the text flavor;
        -- prefer the decoded image entry and never add the data URL to text history.
        if isImageDataURL(content) and pasteboardImg ~= nil then content = nil end
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
            -- Trim history if it gets too long
            if #img_clipboard_history > max_history_size_for_img then
                table.remove(img_clipboard_history, 1)
            end
            -- print("[handleClipboardChange] img.size.h = " .. content:size()["h"] .. ", img.size.w = " .. content:size()["w"])
            -- print("[handleClipboardChange] img")
        elseif content ~= nil then
            -- Don't add if it's the same as the last entry
            if #text_clipboard_history ~= 0 and 
                (#img_clipboard_history == 0 or (text_clipboard_history[#text_clipboard_history].ts > img_clipboard_history[#img_clipboard_history].ts)) then
                    if text_clipboard_history[#text_clipboard_history].content == content then
                        -- print("[handleClipboardChange] it's the same as the last text, content = " .. string.sub(content, 0, display_max_text_length))
                        return
                    end
            end
            pasteboardToClipboard("text", content)
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
            preview = '<img class="preview" src="' .. escapeHTML(src) .. '" alt="Clipboard image preview">'
        else
            preview = '<div class="preview placeholder">Image preview unavailable</div>'
        end
        return '<button class="item image-item' .. selectedClass .. '" data-action="paste" data-index="' .. index .. '">' ..
            preview .. '<div class="meta"><div class="kind">IMAGE</div><div class="stamp">' ..
            escapeHTML(stamp) .. '</div><div class="hint">Click to paste</div></div></button>'
    end
    local content = tostring(entry.data or "")
    local previewText = content:gsub("[\\r\\n]+", " ")
    if #previewText > display_max_text_length then previewText = previewText:sub(1, display_max_text_length) .. "…" end
    -- If an image MIME payload ever arrives as clipboard text, don't expose a
    -- huge data:image URL as if it were ordinary text. Render a bounded marker.
    if isImageDataURL(content) then
        previewText = "[Image data]"
    end
    return '<button class="item text-item' .. selectedClass .. '" data-action="paste" data-index="' .. index .. '">' ..
        '<div class="kind">TEXT</div><div class="stamp">' .. escapeHTML(stamp) ..
        '</div><div class="text-preview">' .. escapeHTML(previewText) ..
        '</div><div class="hint">Click to paste</div></button>'
end

function clipboardPanelHTML()
    local cards = {}
    visibleIndices = {}
    local filter = string.lower(clipboard_search or "")
    for index, entry in ipairs(menuData or {}) do
        if entry.type == "text" or entry.type == "image" then
            local searchableText = isImageDataURL(entry.data) and "[image data]" or tostring(entry.data or "")
            local searchable = string.lower((entry.type == "image" and "[image] " or "") ..
                searchableText .. " " .. os.date("%Y-%m-%d %H:%M:%S", entry.rowTs or os.time()))
            if filter == "" or searchable:find(filter, 1, true) then
                visibleIndices[#visibleIndices + 1] = index
                cards[#cards + 1] = historyItemHTML(entry, index)
            end
        end
    end
    local html = [[
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
* { box-sizing: border-box; }
body { margin:0; background:#1d1f24; color:#f5f6f8; font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif; }
header { position:sticky; top:0; z-index:5; padding:14px 16px 12px; background:#202329; border-bottom:1px solid #3c4049; }
.top { display:flex; align-items:center; gap:10px; }
h1 { margin:0; font-size:17px; font-weight:650; flex:1; }
.count { color:#aab0bd; font-size:12px; }
input { width:100%; margin-top:10px; padding:9px 11px; border-radius:9px; border:1px solid #454a55; background:#15171b; color:#f5f6f8; font-size:13px; outline:none; }
input:focus { border-color:#7da6ff; }
.actions { display:flex; gap:8px; margin-top:10px; }
.action { border:1px solid #4a505b; border-radius:8px; padding:7px 10px; background:#30343d; color:#f7f7f9; cursor:pointer; font-size:12px; }
.action.primary { background:#3267d6; border-color:#3267d6; }
.action.danger { color:#ff9b9b; }
main { padding:12px; display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); gap:12px; align-items:start; }
.item { font:inherit; width:100%; min-width:0; color:inherit; text-align:left; border:1px solid #414650; border-radius:12px; background:#272a31; padding:10px; cursor:pointer; overflow:hidden; }
.item:hover { border-color:#85aaff; background:#30343d; }
.item.selected { border-color:#8cb1ff; outline:2px solid #6d98ff; outline-offset:1px; background:#343a46; }
.image-item .preview { width:100%; height:160px; max-width:100%; object-fit:contain; object-position:center; display:block; background:#191b20; border-radius:7px; }
.image-item .preview:not([src]), .image-item .preview[src=""] { object-fit:contain; }
.text-preview { overflow-wrap:anywhere; word-break:break-word; }
.preview.placeholder { display:flex; align-items:center; justify-content:center; color:#9ba2af; }
.meta { padding:9px 2px 1px; }
.kind { font-size:10px; letter-spacing:.12em; color:#93b5ff; font-weight:700; }
.stamp { color:#b8beca; font-size:11px; margin-top:5px; }
.text-preview { margin-top:10px; min-height:70px; max-height:120px; overflow:hidden; white-space:pre-wrap; overflow-wrap:anywhere; font-size:13px; line-height:1.45; }
.hint { color:#8e96a5; font-size:10px; margin-top:8px; }
.empty { color:#9ca3b1; text-align:center; padding:40px 12px; grid-column:1/-1; }
footer { padding:8px 16px; color:#9299a7; border-top:1px solid #393d46; font-size:11px; }
body.keyboard-mode #search { border-color:#7da6ff; }
</style></head><body>
<header><div class="top"><h1>Clipboard History</h1><span class="count">]] .. tostring(#cards) .. [[ matching items</span></div>
<input id="search" placeholder="Search clipboard history…" value="]] .. escapeHTML(clipboard_search) .. [[" autocomplete="off">
<div class="actions">
<button class="action danger" data-action="clearAll">Clear All</button>
<button class="action" data-action="close">Close</button></div></header>
<main>]] .. (#cards > 0 and table.concat(cards, "\n") or '<div class="empty">No matching clipboard items</div>') .. [[</main>
<footer>Arrow keys: select · Click: paste · Right-click an item for bulk paste · Esc: close</footer>
<script>
const bridge = (action, index, query) => {
  try { window.webkit.messageHandlers.clipboardHistory.postMessage({action, index, query}); } catch (_) {}
};
document.addEventListener('click', event => {
  const contextItem = event.target.closest('#clipboard-context-menu');
  if (contextItem) return;
  const button = event.target.closest('[data-action]');
  if (button) {
    const index = Number(button.dataset.index || 0);
    bridge(button.dataset.action, index, '');
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
search.addEventListener('input', () => bridge('search', 0, search.value));
let selectedIndex = 0;
function rows() { return Array.from(document.querySelectorAll('.item')); }
function selectRow(next) {
  const items = rows();
  if (!items.length) { selectedIndex = 0; return; }
  selectedIndex = Math.max(0, Math.min(items.length - 1, next));
  items.forEach((item, i) => item.classList.toggle('selected', i === selectedIndex));
  items[selectedIndex].scrollIntoView({block:'nearest'});
}
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
search.addEventListener('input', () => { selectedIndex = 0; setTimeout(() => selectRow(0), 0); });
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    event.preventDefault();
    if (contextMenu.style.display !== 'none') contextMenu.style.display = 'none';
    else bridge('close', 0, '');
    return;
  }
  const items = rows();
  if (['ArrowDown','ArrowUp','ArrowLeft','ArrowRight'].includes(event.key)) {
    event.preventDefault();
    if (event.key === 'ArrowRight') selectRow(selectedIndex + 1);
    else if (event.key === 'ArrowLeft') selectRow(selectedIndex - 1);
    else {
      const columns = Math.max(1, Math.round(document.querySelector('main').clientWidth / 250));
      selectRow(selectedIndex + (event.key === 'ArrowDown' ? columns : -columns));
    }
    return;
  }
  if (event.key === 'Enter') {
    event.preventDefault();
    const item = items[selectedIndex];
    if (item) bridge('paste', Number(item.dataset.index || 0), '');
  }
});
setTimeout(() => selectRow(0), 0);
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

local function handleClipboardPanelMessage(message)
    local body = message and message.body
    if type(body) ~= "table" then return end
    if body.action == "close" then
        if clipboard_webview then clipboard_webview:hide() end
    elseif body.action == "search" then
        clipboard_search = tostring(body.query or "")
        -- Filter the visible cards in-place so the search field keeps focus.
        local filter = string.lower(clipboard_search)
        local cards = {}
        visibleIndices = {}
        selectedVisibleIndex = 1
        for index, entry in ipairs(menuData or {}) do
            if entry.type == "text" or entry.type == "image" then
                local searchableText = isImageDataURL(entry.data) and "[image data]" or tostring(entry.data or "")
                local searchable = string.lower((entry.type == "image" and "[image] " or "") ..
                    searchableText .. " " ..
                    os.date("%Y-%m-%d %H:%M:%S", entry.rowTs or os.time()))
                if filter == "" or searchable:find(filter, 1, true) then
                    visibleIndices[#visibleIndices + 1] = index
                    cards[#cards + 1] = historyItemHTML(entry, index)
                end
            end
        end
        local cardsHTML = #cards > 0 and table.concat(cards, "\n")
            or '<div class="empty">No matching clipboard items</div>'
        clipboard_webview:evaluateJavaScript(
            "document.querySelector('main').innerHTML = " .. jsStringLiteral(cardsHTML) .. ";" ..
            "document.querySelector('.count').textContent = " ..
            jsStringLiteral(tostring(#cards) .. " matching items") .. ";"
        )
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
    {javaScriptEnabled = true, privateBrowsing = true},
    clipboard_usercontent
):windowStyle({"titled", "closable", "resizable"})
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
    pasteboard_watcher:start()  -- if u don't add this line, it will stop in some seconds for no reason, idk why

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

    -- add all the text and img history into the menuData
    local i = #text_clipboard_history
    local j = #img_clipboard_history
    while i >= 1 and j >= 1 do
        if text_clipboard_history[i].ts > img_clipboard_history[j].ts then
            insertToMenuData(text_clipboard_history[i].content, "text", text_clipboard_history[i].ts)
            i = i - 1
        else
            insertToMenuData(img_clipboard_history[j], "image", img_clipboard_history[j].ts)
            j = j - 1
        end
    end

    while i >= 1 do
        insertToMenuData(text_clipboard_history[i].content, "text", text_clipboard_history[i].ts)
        i = i - 1
    end

    while j >= 1 do
        insertToMenuData(img_clipboard_history[j], "image", img_clipboard_history[j].ts)
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