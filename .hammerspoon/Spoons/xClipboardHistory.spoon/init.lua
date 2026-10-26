local pkg = {}


------------------------ A simple clipboard history implement ------------------------

local hotkey = require "hs.hotkey"
local pasteboard = require "hs.pasteboard"
local pbwatcher = require "hs.pasteboard.watcher"
-- Keep clipboard observation responsive without performing disk cleanup on every copy.
pbwatcher.interval(0.1)
local webview = require "hs.webview"
local application = require "hs.application"
local json = require "hs.json"
local fs = require "hs.fs"
local image = require "hs.image"
local logger = hs.logger.new("xClipboardHistory", "info")
local HISTORY_ROOT = (os.getenv("HOME") .. "/Documents/github/sux-mac/clipboard-history")
local RETENTION_DAYS = 7
local THUMBNAIL_MAX_DIMENSION = 112
local cleanupLastRunDate = nil
local cleanupOnNextClipboardChange = false
local lastPersistedEntryKey = nil
local imageProcessingCount = 0

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
local previousApplication = nil
-- Declared before panel callbacks so window-close and dismissal handlers can
-- stop the global click monitor safely.
local outsideClickMonitor = nil
local closeOutsideClickPending = false
local stopOutsideClickMonitor
local panelActivationTimer = nil
local panelActivationGeneration = 0
local suppressOutsideClickUntil = 0
local selectedVisibleIndex = 1
local visibleIndices = {}
local panelScreenUUID = nil
local CLIPBOARD_RENDER_BATCH_SIZE = 32
local CLIPBOARD_CACHE_SIZE = 32
local clipboardDateFilter = nil
local lastSearchRestoreDateKey = nil
local browseCursor = 0
local browseMode = "all"
local typeBrowseCursor = {text = nil, image = nil}
local allDatesFilterSelected = true
-- Disk-backed records remain cached only for the lifetime of an open panel.
local clipboardSessionOpen = false
local dateHistoryCache = {}
local allHistoryCache = {}
local allHistoryCacheLoaded = 0
local allHistoryTotalCount = nil
-- Hold one completed global search per query/type for this open-panel session.
-- Switching date chips or returning to All Dates reuses these matches instead
-- of scanning every persisted daily history file again.
local searchResultsCache = nil

-- Persistent, local, day-partitioned clipboard history.
local function localDateKey(timestamp)
    return os.date("%Y-%m-%d", timestamp or os.time())
end

local function validDateKey(name)
    return type(name) == "string" and name:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local function historyDayDirectory(dateKey)
    return HISTORY_ROOT .. "/" .. dateKey
end

local function historyJSONPath(dateKey)
    return historyDayDirectory(dateKey) .. "/" .. dateKey .. "-history.json"
end

local function historyImageDirectory(dateKey)
    return historyDayDirectory(dateKey) .. "/" .. dateKey .. "-images"
end

local function historyThumbnailDirectory(dateKey)
    return historyDayDirectory(dateKey) .. "/" .. dateKey .. "-thumbnails"
end

local function ensureDirectory(path)
    if fs.attributes(path) then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path and not fs.attributes(parent) then
        if not ensureDirectory(parent) then return false end
    end
    local ok, err = fs.mkdir(path)
    if ok then return true end
    if fs.attributes(path) then return true end
    logger.e("Unable to create clipboard history directory: " .. tostring(err or path))
    return false
end

local function atomicWrite(path, data)
    local temporaryPath = path .. ".tmp-" .. tostring(math.floor(hs.timer.secondsSinceEpoch() * 1000000))
    local file, openError = io.open(temporaryPath, "wb")
    if not file then
        logger.e("Unable to open clipboard history temp file: " .. tostring(openError))
        return false
    end
    local writeOk, writeError = file:write(data)
    local closeOk, closeError = file:close()
    if not writeOk or closeOk == nil then
        os.remove(temporaryPath)
        logger.e("Unable to write clipboard history: " .. tostring(writeError or closeError))
        return false
    end
    local renameOk, renameError = os.rename(temporaryPath, path)
    if not renameOk then
        os.remove(temporaryPath)
        logger.e("Unable to replace clipboard history file: " .. tostring(renameError))
        return false
    end
    return true
end

local function saveImageFile(dateKey, item, timestamp)
    local directory = historyImageDirectory(dateKey)
    if not ensureDirectory(HISTORY_ROOT) or not ensureDirectory(historyDayDirectory(dateKey)) or not ensureDirectory(directory) then
        return nil
    end

    -- Use hs.image's native file writer. Encoding the entire screenshot to a
    -- base64 data URL and immediately decoding it again creates large temporary
    -- strings and stalls the pasteboard watcher for high-resolution captures.
    local baseName = os.date("%Y%m%d%H%M%S", timestamp)
    local path = directory .. "/" .. baseName .. ".png"
    local counter = 1
    while fs.attributes(path) do
        counter = counter + 1
        path = directory .. "/" .. baseName .. "-" .. string.format("%03d", counter) .. ".png"
    end

    local ok, saved = pcall(function()
        return item:saveToFile(path, false, "PNG")
    end)
    if not ok or saved ~= true then
        os.remove(path)
        logger.e("Unable to save clipboard image natively: " .. tostring(saved))
        return nil
    end
    return path
end
local function saveThumbnailFile(dateKey, originalPath, thumbnailImage, timestamp)
    local directory = historyThumbnailDirectory(dateKey)
    if not ensureDirectory(HISTORY_ROOT)
        or not ensureDirectory(historyDayDirectory(dateKey))
        or not ensureDirectory(directory) then
        return nil
    end

    local originalName = originalPath:match("([^/]+)$") or os.date("%Y%m%d%H%M%S", timestamp)
    local baseName = originalName:gsub("%.[^.]+$", "")
    local path = directory .. "/" .. baseName .. ".jpg"
    local counter = 1
    while fs.attributes(path) do
        counter = counter + 1
        path = directory .. "/" .. baseName .. "-" .. string.format("%03d", counter) .. ".jpg"
    end

    local ok, saved = pcall(function()
        return thumbnailImage:saveToFile(path, false, "JPEG")
    end)
    if not ok or saved ~= true then
        os.remove(path)
        logger.w("Unable to save clipboard thumbnail: " .. tostring(saved))
        return nil
    end
    return path
end

local function readDayHistory(dateKey)
    local path = historyJSONPath(dateKey)
    local file = io.open(path, "rb")
    if not file then return {} end
    local raw = file:read("*a")
    file:close()
    if not raw or raw == "" then return {} end
    local ok, records = pcall(json.decode, raw)
    if not ok or type(records) ~= "table" then
        logger.e("Ignoring invalid clipboard history JSON: " .. path)
        return {}
    end
    return records
end

local function writeDayHistory(dateKey, records)
    if not ensureDirectory(HISTORY_ROOT) or not ensureDirectory(historyDayDirectory(dateKey)) then return false end
    local encodedOk, encoded = pcall(json.encode, records, true)
    if not encodedOk or type(encoded) ~= "string" then
        logger.e("Unable to encode clipboard history JSON for " .. dateKey)
        return false
    end
    return atomicWrite(historyJSONPath(dateKey), encoded)
end

local function persistClipboardEntry(itemType, content, timestamp)
    timestamp = timestamp or os.time()
    local dateKey = localDateKey(timestamp)
    if not ensureDirectory(HISTORY_ROOT) or not ensureDirectory(historyDayDirectory(dateKey)) then return false end
    -- Daily cleanup runs at startup and on the first copy observed each date.
    local records = readDayHistory(dateKey)
    local record = {type=itemType, ts=timestamp}
    if itemType == "text" then
        record.content = content
    elseif itemType == "image" then
        local imagePath = saveImageFile(dateKey, content, timestamp)
        if not imagePath then return false end
        record.imagePath = imagePath
    else
        return false
    end
    records[#records + 1] = record
    if not writeDayHistory(dateKey, records) then
        if record.imagePath then os.remove(record.imagePath) end
        return false
    end
    return true, record.imagePath
end

local function removeExpiredHistoryDirectories(todayKey)
    local year, month, day = todayKey:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then return end
    local todayNoon = os.time({year=tonumber(year), month=tonumber(month), day=tonumber(day), hour=12})
    if not todayNoon then return end
    local cutoffDate = os.date("%Y-%m-%d", todayNoon - RETENTION_DAYS * 24 * 60 * 60)
    if not ensureDirectory(HISTORY_ROOT) then return end

    -- Compare calendar-date strings rather than local timestamps. This makes
    -- the seven-day cutoff exact and avoids DST/time-zone boundary ambiguity.
    local ok, err = pcall(function()
        for name in fs.dir(HISTORY_ROOT) do
            local folderDate = type(name) == "string"
                and name:match("^(%d%d%d%d%-%d%d%-%d%d)")
                or nil
            if folderDate and folderDate <= cutoffDate then
                local dayPath = HISTORY_ROOT .. "/" .. name
                local attributes = fs.attributes(dayPath)
                if attributes and attributes.mode == "directory" then
                    local function deleteTree(path)
                        local childrenOK, childrenErr = pcall(function()
                            for child in fs.dir(path) do
                                if child ~= "." and child ~= ".." then
                                    local childPath = path .. "/" .. child
                                    local childAttributes = fs.attributes(childPath)
                                    if childAttributes and childAttributes.mode == "directory" then
                                        deleteTree(childPath)
                                    else
                                        local removed, removeError = os.remove(childPath)
                                        if not removed then
                                            error("Unable to remove " .. childPath .. ": " .. tostring(removeError))
                                        end
                                    end
                                end
                            end
                        end)
                        if childrenOK then
                            local removed, removeError = os.remove(path)
                            if not removed then
                                error("Unable to remove directory " .. path .. ": " .. tostring(removeError))
                            end
                        else
                            error(tostring(childrenErr))
                        end
                    end
                    local deleted, deleteError = pcall(deleteTree, dayPath)
                    if not deleted then
                        logger.w("Could not fully clean expired clipboard folder " .. dayPath .. ": " .. tostring(deleteError))
                    else
                        logger.i("Removed expired clipboard history folder: " .. dayPath)
                    end
                end
            end
        end
    end)
    if not ok then
        logger.w("Clipboard retention cleanup stopped safely: " .. tostring(err))
    end
end
local function runDailyCleanupIfNeeded(force)
    local todayKey = localDateKey()
    -- Startup cleanup and the first real clipboard change each trigger a scan.
    -- After that, only run again on a new date.
    if not force and cleanupLastRunDate == todayKey then return end
    ensureDirectory(HISTORY_ROOT)
    removeExpiredHistoryDirectories(todayKey)
    cleanupLastRunDate = todayKey
end

-- These limits must be declared before restorePersistentHistory(), because
-- that function references them when the Spoon is loaded at the bottom of
-- this file. A later local declaration would be out of scope and evaluate to nil.
local max_history_size_for_text = CLIPBOARD_CACHE_SIZE
local max_history_size_for_img = CLIPBOARD_CACHE_SIZE
local display_max_text_length = 200

local function historyDateDirectories()
    local dates={}
    if not fs.attributes(HISTORY_ROOT) then return dates end
    -- Check only whether the day's metadata file exists. Never read JSON or
    -- stat original images merely to populate the date-filter list.
    for name in fs.dir(HISTORY_ROOT) do
        if validDateKey(name) and fs.attributes(historyJSONPath(name)) then
            dates[#dates+1]=name
        end
    end
    table.sort(dates,function(a,b)return a>b end)
    return dates
end

local function trimHistoryCache(limit)
    limit=tonumber(limit) or CLIPBOARD_CACHE_SIZE
    while (#text_clipboard_history+#img_clipboard_history)>limit do
        local t,i=text_clipboard_history[1],img_clipboard_history[1]
        if i and (not t or (tonumber(i.ts) or 0)<=(tonumber(t.ts) or 0)) then table.remove(img_clipboard_history,1)
        elseif t then table.remove(text_clipboard_history,1) else break end
    end
end

local function metadataEntry(record,dateKey)
    local ts=tonumber(record and record.ts); if not ts then return nil end
    if record.type=="text" and type(record.content)=="string" then
        return {type="text",ts=ts,rowTs=ts,content=record.content,data=record.content,dateKey=dateKey}
    end
    if record.type=="image" and type(record.imagePath)=="string" then
        -- Keep ordinary history loading independent of image-file I/O and decoding.
        return {
            type="image", ts=ts, rowTs=ts, dateKey=dateKey, imagePath=record.imagePath,
            thumbnailPath=type(record.thumbnailPath)=="string" and record.thumbnailPath or nil,
            -- Older records remain readable without a disruptive migration.
            thumbnailData=type(record.thumbnailData)=="string" and record.thumbnailData or ""
        }
    end
    return nil
end

local function insertCacheEntry(entry)
    local target=entry.type=="text" and text_clipboard_history or img_clipboard_history
    target[#target+1]=entry
    table.sort(target,function(a,b)return a.ts<b.ts end)
    trimHistoryCache(CLIPBOARD_CACHE_SIZE)
    allHistoryTotalCount=nil
    if clipboardSessionOpen and allHistoryCacheLoaded>0 then
        table.insert(allHistoryCache,1,entry)
        allHistoryCacheLoaded=#allHistoryCache
    end
end

local function restorePersistentHistory()
    text_clipboard_history,img_clipboard_history={},{}
    -- Restore the newest 32 mixed records, scanning newest day first and stopping early.
    local dates=historyDateDirectories()
    local restored=0
    for _,dateKey in ipairs(dates) do
        local records=readDayHistory(dateKey)
        table.sort(records,function(a,b)return (tonumber(a.ts) or 0)>(tonumber(b.ts) or 0) end)
        for _,record in ipairs(records) do
            local entry=metadataEntry(record,dateKey)
            if entry then
                local target=entry.type=="text" and text_clipboard_history or img_clipboard_history
                target[#target+1]=entry
                restored=restored+1
                if restored>=CLIPBOARD_CACHE_SIZE then
                    table.sort(text_clipboard_history,function(a,b)return a.ts<b.ts end)
                    table.sort(img_clipboard_history,function(a,b)return a.ts<b.ts end)
                    trimHistoryCache(CLIPBOARD_CACHE_SIZE)
                    return
                end
            end
        end
    end
    trimHistoryCache(CLIPBOARD_CACHE_SIZE)
end

local function readImageAtPath(path)
    if type(path)~="string" or path=="" then return nil end
    local ok,result=pcall(function()
        local file=io.open(path,"rb"); if not file then return nil end
        local bytes=file:read("*a"); file:close()
        if not bytes or #bytes==0 then return nil end
        local ext=string.lower(path:match("%.([%w]+)$") or "png")
        local mime=({png="image/png",jpg="image/jpeg",jpeg="image/jpeg",gif="image/gif",webp="image/webp",tiff="image/tiff",bmp="image/bmp"})[ext] or "image/png"
        return hs.image.imageFromURL("data:"..mime..";base64,"..hs.base64.encode(bytes))
    end)
    if ok then return result end
    logger.w("Unable to decode clipboard image "..path..": "..tostring(result)); return nil
end

local function makeThumbnailImage(original)
    if not original then return nil end
    local ok, result = pcall(function()
        local size = original:size()
        local width, height = tonumber(size and size.w) or 0, tonumber(size and size.h) or 0
        if width <= 0 or height <= 0 then return nil end
        local scale = math.min(1, THUMBNAIL_MAX_DIMENSION / width, THUMBNAIL_MAX_DIMENSION / height)
        return original:bitmapRepresentation({
            w = math.max(1, math.floor(width * scale + 0.5)),
            h = math.max(1, math.floor(height * scale + 0.5))
        })
    end)
    if not ok then
        logger.w("Unable to generate clipboard thumbnail: " .. tostring(result))
        return nil
    end
    return result
end

local function thumbnailDataURLAtPath(path)
    if type(path) ~= "string" or path == "" then return "" end
    local file = io.open(path, "rb")
    if not file then return "" end
    local bytes = file:read("*a")
    file:close()
    if not bytes or #bytes == 0 then return "" end
    local extension = string.lower(path:match("%.([%w]+)$") or "jpg")
    local mime = extension == "png" and "image/png" or "image/jpeg"
    return "data:" .. mime .. ";base64," .. hs.base64.encode(bytes)
end

local function thumbnailForEntry(entry)
    if not entry then return "" end
    if type(entry.thumbnailPath) == "string" and entry.thumbnailPath ~= "" then
        local thumbnailData = thumbnailDataURLAtPath(entry.thumbnailPath)
        if thumbnailData ~= "" then return thumbnailData end
    end
    -- Legacy embedded thumbnails remain available; never regenerate on a browse path.
    return type(entry.thumbnailData) == "string" and entry.thumbnailData or ""
end

local function decodeImage(entry)
    if not entry then return nil end
    if entry.imageObject then return entry.imageObject end
    if type(entry.imagePath)=="string" then return readImageAtPath(entry.imagePath) end
    return nil
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
    -- Clear only valid daily folders under the dedicated history root.
    if fs.attributes(HISTORY_ROOT) then
        local ok, err = pcall(function()
            for name in fs.dir(HISTORY_ROOT) do
                if validDateKey(name) then
                    local dayPath = historyDayDirectory(name)
                    local function deleteTree(path)
                        local childrenOK, childrenErr = pcall(function()
                            for child in fs.dir(path) do
                                if child ~= "." and child ~= ".." then
                                    local childPath = path .. "/" .. child
                                    local attributes = fs.attributes(childPath)
                                    if attributes and attributes.mode == "directory" then
                                        deleteTree(childPath)
                                    else
                                        os.remove(childPath)
                                    end
                                end
                            end
                        end)
                        if childrenOK then
                            os.remove(path)
                        else
                            logger.w("Could not fully clear clipboard folder " .. path .. ": " .. tostring(childrenErr))
                        end
                    end
                    deleteTree(dayPath)
                end
            end
        end)
        if not ok then logger.w("Clear All could not read clipboard history folders: " .. tostring(err)) end
    end
    if clipboard_webview then
        clipboard_search = ""
        clipboard_webview:hide()
        clipboard_webview:html(clipboardPanelHTML())
    end
    collectgarbage("collect")
    hs.reload()
end




-- local last_change = pasteboard.changeCount() -- keeps track of how many times the pasteboard owner has changed // Indicates a new copy has been made

-- Add the given string to the history
function pasteboardToClipboard(item_type,item)
    local ts=os.time()
    if item_type=="text" then
        local ok=persistClipboardEntry("text",item,ts)
        if ok then insertCacheEntry({type="text",ts=ts,rowTs=ts,content=item,data=item}) end
        return
    end
    imageProcessingCount=imageProcessingCount+1
    local ok,err=pcall(function()
        local dateKey=localDateKey(ts)
        local imagePath=saveImageFile(dateKey,item,ts)
        if not imagePath then logger.e("Clipboard image could not be saved"); return end
        -- Generate a thumbnail immediately on copy and persist it as a small file.
        local thumbnailImage = makeThumbnailImage(item)
        local thumbnailPath = thumbnailImage and saveThumbnailFile(dateKey, imagePath, thumbnailImage, ts) or nil
        thumbnailImage = nil

        local records=readDayHistory(dateKey)
        records[#records+1]={type="image",ts=ts,imagePath=imagePath,thumbnailPath=thumbnailPath}
        if not writeDayHistory(dateKey,records) then
            if thumbnailPath then os.remove(thumbnailPath) end
            os.remove(imagePath)
            logger.e("Clipboard image record could not be persisted")
            return
        end
        insertCacheEntry({
            type="image",ts=ts,rowTs=ts,dateKey=dateKey,imagePath=imagePath,
            thumbnailPath=thumbnailPath,thumbnailData=""
        })
    end)
    imageProcessingCount=math.max(0,imageProcessingCount-1)
    item=nil; collectgarbage("collect")
    if not ok then logger.e("Clipboard image processing failed: "..tostring(err)) end
end

-- Add this function to handle clipboard changes
function handleClipboardChange(content)
    -- Startup cleanup alone is not enough: users may create an expired folder
    -- after reloading. Force one more scan on the first clipboard notification
    -- after startup; future notifications only scan when the date changes.
    if cleanupOnNextClipboardChange then
        cleanupOnNextClipboardChange = false
        runDailyCleanupIfNeeded(true)
    else
        runDailyCleanupIfNeeded()
    end
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

local TEXT_CARD_PREVIEW_MAX_CHARS = 350
local TEXT_HOVER_MAX_LINES = 30

local function persistentHistoryCount(dateFilter,kind)
    if not dateFilter and allHistoryTotalCount then
        if not kind or kind=="all" then return allHistoryTotalCount end
        local count=0
        for _,entry in ipairs(allHistoryCache) do
            if entry.type==kind then count=count+1 end
        end
        -- A type-specific total is exact only after every record is loaded.
        if allHistoryCacheLoaded>=allHistoryTotalCount then return count end
    end
    local count=0
    for _,dateKey in ipairs(dateFilter and {dateFilter} or historyDateDirectories()) do
        local cached=dateHistoryCache[dateKey]
        if cached then
            for _,entry in ipairs(cached) do
                if not kind or kind=="all" or entry.type==kind then count=count+1 end
            end
        else
            for _,record in ipairs(readDayHistory(dateKey)) do
                local entry=metadataEntry(record,dateKey)
                if entry and (not kind or kind=="all" or entry.type==kind) then count=count+1 end
            end
        end
    end
    if not dateFilter then allHistoryTotalCount=count end
    return count
end

local function loadPersistentHistoryPage(offset,count,dateFilter,kind)
    offset=math.max(0,tonumber(offset) or 0); count=math.max(1,tonumber(count) or CLIPBOARD_RENDER_BATCH_SIZE)
    local out,skipped={},0
    for _,dateKey in ipairs(dateFilter and {dateFilter} or historyDateDirectories()) do
        local cached=dateHistoryCache[dateKey]
        local dayEntries=cached
        if not dayEntries then
            dayEntries={}
            for _,record in ipairs(readDayHistory(dateKey)) do
                local entry=metadataEntry(record,dateKey)
                if entry then
                    dayEntries[#dayEntries+1]=entry
                end
            end
            table.sort(dayEntries,function(a,b)return a.ts>b.ts end)
            if clipboardSessionOpen then dateHistoryCache[dateKey]=dayEntries end
        end
        for _,entry in ipairs(dayEntries) do
            if not kind or kind=="all" or entry.type==kind then
                if skipped<offset then skipped=skipped+1 else
                    out[#out+1]=entry
                    if #out>=count then return out end
                end
            end
        end
    end
    return out
end

local function ensureAllHistoryCache(requiredCount)
    requiredCount=math.max(0,tonumber(requiredCount) or CLIPBOARD_RENDER_BATCH_SIZE)
    if allHistoryCacheLoaded==0 then
        allHistoryCache={}
        for _,entry in ipairs(text_clipboard_history) do allHistoryCache[#allHistoryCache+1]=entry end
        for _,entry in ipairs(img_clipboard_history) do allHistoryCache[#allHistoryCache+1]=entry end
        table.sort(allHistoryCache,function(a,b)return a.ts>b.ts end)
        allHistoryCacheLoaded=#allHistoryCache
    end
    while allHistoryCacheLoaded<requiredCount and (not allHistoryTotalCount or allHistoryCacheLoaded<allHistoryTotalCount) do
        local before=allHistoryCacheLoaded
        local nextPage=loadPersistentHistoryPage(before,CLIPBOARD_RENDER_BATCH_SIZE,nil)
        if #nextPage==0 then
            allHistoryTotalCount=allHistoryCacheLoaded
            break
        end
        for _,entry in ipairs(nextPage) do allHistoryCache[#allHistoryCache+1]=entry end
        allHistoryCacheLoaded=#allHistoryCache
        -- Exhaustion is known only when the disk loader returns fewer than a full page.
        if #nextPage<CLIPBOARD_RENDER_BATCH_SIZE then
            allHistoryTotalCount=allHistoryCacheLoaded
        end
    end
    return allHistoryCache,allHistoryCacheLoaded,allHistoryTotalCount
end

local function loadPersistentDateHistory(dateKey,kind)
    local startedAt = hs.timer.secondsSinceEpoch()
    local allEntries=dateHistoryCache[dateKey]
    if not allEntries then
        allEntries={}
        for _,record in ipairs(readDayHistory(dateKey)) do
            local entry=metadataEntry(record,dateKey)
            if entry then
                allEntries[#allEntries+1]=entry
            end
        end
        table.sort(allEntries,function(a,b)return a.ts>b.ts end)
        if clipboardSessionOpen then dateHistoryCache[dateKey]=allEntries end
    end
    logger.i(string.format("Clipboard metadata date load %s: %d records in %.3f ms",
        tostring(dateKey), #allEntries, (hs.timer.secondsSinceEpoch() - startedAt) * 1000))
    if not kind or kind=="all" then return allEntries end
    local filtered={}
    for _,entry in ipairs(allEntries) do
        if entry.type==kind then filtered[#filtered+1]=entry end
    end
    return filtered
end

local function searchPersistentHistory(query,kind)
    local out={}; local needle=string.lower(tostring(query or ""))
    if needle=="" then return out end
    for _,dateKey in ipairs(historyDateDirectories()) do
        for _,record in ipairs(readDayHistory(dateKey)) do
            local entry=metadataEntry(record,dateKey)
            if entry and (not kind or kind=="all" or entry.type==kind) then
                local value=entry.type=="text" and tostring(entry.content or "") or "[image]"
                local stamp=os.date("%Y-%m-%d %H:%M:%S",entry.ts)
                if string.lower(value.." "..stamp):find(needle,1,true) then
                    out[#out+1]=entry
                end
            end
        end
    end
    table.sort(out,function(a,b)return a.ts>b.ts end)
    return out
end

local function historyItemHTML(entry, index)
    local stamp = os.date("%Y-%m-%d %H:%M:%S", entry.rowTs or os.time())
    if entry.type == "image" then
        local imageEntry=entry.historyEntry or entry
        local thumbnail=thumbnailForEntry(imageEntry)
        local preview=thumbnail~="" and ('<img class="preview" src="'..escapeHTML(thumbnail)..'" alt="Clipboard image preview" loading="lazy" decoding="async">') or '<div class="preview placeholder">Image preview unavailable</div>'
        return '<div class="item image-item" role="button" tabindex="0" data-kind="image" data-action="paste" data-index="'..index..'" data-search="'..escapeHTML(string.lower("[image] "..stamp))..'"><div class="meta"><div class="kind">IMAGE</div><div class="stamp">'..escapeHTML(stamp)..'</div></div>'..preview..'<div class="hint">Click to paste</div><div class="hover-detail image-detail" role="tooltip"><img class="hover-image" alt="Clipboard image preview" aria-hidden="true" decoding="async"></div></div>'
    end
    local content = tostring(entry.data or entry.content or "")
    local previewText = content
    if isImageDataURL(content) or looksLikeImagePayload(content) then
        previewText = "[Image data]"
    elseif #content > TEXT_CARD_PREVIEW_MAX_CHARS then
        local stop = TEXT_CARD_PREVIEW_MAX_CHARS
        local utf8Lib = utf8
        if utf8Lib and utf8Lib.offset then
            local ok, offset = pcall(utf8Lib.offset, content, TEXT_CARD_PREVIEW_MAX_CHARS + 1)
            if ok and offset then stop = offset - 1 end
        end
        previewText = content:sub(1, stop) .. "\n… (preview truncated; hover for more)"
    end
    -- Search is performed in Lua. Do not copy the entire clipboard payload into
    -- a DOM attribute; large copied documents otherwise multiply the WebView DOM.
    return '<button class="item text-item" data-kind="text" data-action="paste" data-index="' .. index .. '" data-search="' .. escapeHTML(string.lower("[text] " .. stamp)) .. '">' ..
        '<div class="kind">TEXT</div><div class="stamp">' .. escapeHTML(stamp) ..
        '</div><div class="text-preview">' .. escapeHTML(previewText) ..
        '</div><div class="hint">Click to paste</div>' ..
        '<div class="hover-detail text-detail" role="tooltip">' ..
        '<div class="hover-detail-title">Clipboard text · ' .. escapeHTML(stamp) .. '</div>' ..
        '<div class="hover-full-text" data-loaded="false">Loading preview…</div></div></button>'
end

local function clipboardEntryMatches(entry, query, kind)
    if kind == "none" then return false end
    if kind ~= "all" and entry.type ~= kind then return false end
    query = string.lower(tostring(query or ""))
    -- Filter-only clicks normally have no search query; don't scan or lowercase
    -- the clipboard payload just to decide whether a card matches by type.
    if query == "" then return true end
    local stamp = os.date("%Y-%m-%d %H:%M:%S", entry.rowTs or os.time())
    local searchableText = entry.type == "image" and "[image]" or tostring(entry.data or entry.content or "")
    local searchable = string.lower(searchableText .. " " .. stamp)
    return searchable:find(query, 1, true) ~= nil
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
    -- Render up to the configured 32-item batch from the currently loaded page.
    local batchSize = CLIPBOARD_RENDER_BATCH_SIZE
    local last = math.min(#matches, offset + batchSize)
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
    -- Do not count every daily record just to show this initial page.
    matchingCount = #menuData
    local hasMoreOnDisk = true
    local loadMoreHTML = hasMoreOnDisk and
        '<div class="load-more-wrap"><button class="action" data-action="loadMore" data-index="' ..
        renderedCount .. '">Load more</button></div>' or ''
    local html = [[
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
  color-scheme: light dark;
  --panel-bg: #1d1f24;
  --panel-fg: #f5f6f8;
  --header-bg: #202329;
  --border: #3c4049;
  --control-bg: #15171b;
  --control-border: #454a55;
  --card-bg: #272a31;
  --card-border: #414650;
  --button-bg: #30343d;
  --button-border: #4a505b;
  --muted: #aab0bd;
  --subtle: #8e96a5;
  --accent: #7da6ff;
  --selected-bg: #343a46;
  --selected-border: #8cb1ff;
  --footer-bg: #1d1f24;
}
@media (prefers-color-scheme: light) {
  :root {
    --panel-bg: #f5f6f8;
    --panel-fg: #202124;
    --header-bg: #ffffff;
    --border: #d8dbe2;
    --control-bg: #ffffff;
    --control-border: #c8ccd4;
    --card-bg: #ffffff;
    --card-border: #d5d9e0;
    --button-bg: #edf0f5;
    --button-border: #d0d5de;
    --muted: #626b79;
    --subtle: #697386;
    --accent: #2463eb;
    --selected-bg: #e5edff;
    --selected-border: #5d8df7;
    --footer-bg: #f5f6f8;
  }
}
* { box-sizing: border-box; }
html, body { width:100%; height:100%; margin:0; overflow:hidden; }
body { background:var(--panel-bg); color:var(--panel-fg); font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif; display:flex; flex-direction:column; }
header { flex:0 0 auto; position:relative; z-index:5; padding:14px 16px 12px; background:var(--header-bg); border-bottom:1px solid var(--border); }
.top { display:flex; align-items:center; gap:10px; }
.title-actions { display:flex; align-items:center; gap:10px; min-width:0; }
h1 { margin:0; font-size:17px; font-weight:650; }
.header-clear { flex-shrink:0; }
.count { color:var(--muted); font-size:12px; margin-left:auto; }
input { width:100%; margin-top:10px; padding:9px 11px; border-radius:9px; border:1px solid var(--control-border); background:var(--control-bg); color:var(--panel-fg); font-size:13px; outline:none; }
input:focus { border-color:var(--accent); }
main:focus { outline:none; }
.item:focus-visible { outline:2px solid var(--selected-border); outline-offset:2px; }
.item[hidden], .load-more-wrap[hidden], .empty[hidden] { display:none!important; }
.actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; }
.action { border:1px solid var(--button-border); border-radius:8px; padding:7px 10px; background:var(--button-bg); color:var(--panel-fg); cursor:pointer; font-size:12px; }
.action.primary { background:#3267d6; border-color:#3267d6; color:#ffffff; }
.action.filter-button[aria-pressed="true"] { background:#dbeafe; border-color:#bfdbfe; color:#25344a; }
.action.danger { color:#dc2626; font-weight:700; }
@media (prefers-color-scheme: dark) {
  .action.danger { color:#fb923c; }
}
@media (prefers-color-scheme: light) {
  .action.danger { color:#dc2626; }
}
.image-detail { pointer-events:auto; width:min(92vw,1120px); height:min(86vh,900px); max-width:calc(100vw - 24px); max-height:calc(100vh - 24px); padding:34px 12px 12px; }
.hover-image { max-width:calc(92vw - 48px); max-height:calc(86vh - 60px); object-fit:contain; pointer-events:none; }
main { flex:1 1 auto; min-height:0; overflow-y:auto; overflow-x:hidden; overscroll-behavior:contain; scroll-padding-block:16px; padding:16px 12px; display:flex; flex-direction:column; align-items:stretch; gap:12px; }
#clipboard-items.item-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); grid-auto-rows:min-content; gap:12px; align-items:start; align-content:start; }
.load-more-wrap { flex:0 0 auto; width:100%; display:flex; justify-content:flex-start; }
.item { position:relative; cursor:pointer; }
.item, .item * { cursor:pointer; }
.item:hover { border-color:var(--accent); background:var(--button-bg); }
.hover-detail { display:none; position:fixed; z-index:10000; left:50%; top:50%; transform:translate(-50%, -50%); max-width:min(560px, calc(100vw - 32px)); max-height:min(70vh, 640px); padding:12px; color:var(--panel-fg); background:var(--card-bg); border:1px solid var(--card-border); border-radius:10px; box-shadow:0 12px 36px rgba(0,0,0,.55); pointer-events:none; overflow:hidden; }
.item.detail-open .hover-detail { display:block; }
.text-detail { width:min(560px, calc(100vw - 32px)); }
.hover-detail-title { color:#aab0bd; font-size:11px; margin-bottom:8px; }
.hover-full-text { max-height:calc(70vh - 58px); overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; word-break:break-word; font-size:13px; line-height:1.5; user-select:text; }
.image-detail { pointer-events:auto; padding:34px 12px 12px; width:min(92vw,1120px); height:min(86vh,900px); max-width:calc(100vw - 24px); max-height:calc(100vh - 24px); display:none; align-items:center; justify-content:center; overflow:hidden; }
.item.detail-open .image-detail { display:flex; }
.image-item.preview-loading .image-detail,
.image-item.preview-loading.detail-open .image-detail { display:none; }
.hover-image { display:block; max-width:calc(92vw - 48px); max-height:calc(86vh - 60px); object-fit:contain; border-radius:5px; visibility:hidden; }
.hover-image-placeholder { color:#9ca3af; padding:20px; }
.item { font:inherit; width:100%; min-width:0; color:inherit; text-align:left; border:1px solid var(--card-border); border-radius:12px; background:var(--card-bg); padding:10px; cursor:pointer; overflow:hidden; }
#clipboard-items .item:focus { outline:2px solid var(--selected-border); outline-offset:2px; }
#clipboard-items .item { position:relative; margin:0; }
#clipboard-items .item.selected { z-index:1; }
.item:hover { border-color:var(--accent); background:var(--button-bg); }
.item.selected { border-color:var(--selected-border); outline:2px solid var(--accent); outline-offset:1px; background:var(--selected-bg); }
.image-item .meta { padding-top:0; padding-bottom:9px; }
.image-item .preview { width:100%; height:160px; max-width:100%; object-fit:contain; object-position:center center; display:block; background:var(--control-bg); border-radius:7px; }
.image-item .preview { aspect-ratio:auto; }
.image-item .preview:not([src]), .image-item .preview[src=""] { object-fit:contain; }
.text-preview { overflow-wrap:anywhere; word-break:break-word; }
.preview.placeholder { display:flex; align-items:center; justify-content:center; color:var(--muted); }
.meta { padding:9px 2px 1px; }
.kind { font-size:10px; letter-spacing:.12em; color:var(--accent); font-weight:700; }
.stamp { color:var(--muted); font-size:11px; margin-top:5px; }
.text-preview { margin-top:10px; min-height:70px; max-height:120px; overflow:hidden; white-space:pre-wrap; overflow-wrap:anywhere; word-break:normal; font-size:13px; line-height:1.45; }
.hint { color:var(--subtle); font-size:10px; margin-top:8px; }
.empty { color:var(--muted); text-align:center; padding:40px 12px; grid-column:1/-1; }
footer { flex:0 0 auto; padding:8px 16px; color:var(--muted); background:var(--footer-bg); border-top:1px solid var(--border); font-size:11px; }
body.keyboard-mode #search { border-color:#7da6ff; }
</style></head><body>
<header><div class="top"><div class="title-actions"><h1>Clipboard History</h1><button class="action danger header-clear" data-action="clearAll">⚠️ Clear All</button></div><span class="count">]] .. tostring(matchingCount) .. [[ matching items</span></div>
<input id="search" placeholder="Search clipboard history here... Press Enter to search." value="]] .. escapeHTML(clipboard_search) .. [[" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" data-gramm="false">
<div class="actions">
<button class="action filter-button date-filter" data-action="dateScope" data-date-key="" aria-pressed="true">All Dates</button>
<button class="action filter-button type-filter" data-action="filter" data-filter="text" aria-pressed="false">Text</button>
<button class="action filter-button type-filter" data-action="filter" data-filter="image" aria-pressed="false">Images</button>
]] .. (function()
    local buttons={}
    for ago=0,6 do
        local dt=os.date("*t",os.time()-ago*86400)
        local noon=os.time({year=dt.year,month=dt.month,day=dt.day,hour=12})
        local key=os.date("%Y-%m-%d",noon)
        local hasEntries
        local cached=dateHistoryCache[key]
        if cached then
            hasEntries=#cached>0
        else
            hasEntries=persistentHistoryCount(key)>0
        end
        if hasEntries then
            local label=ago==0 and "Today" or (ago==1 and "Yesterday" or os.date("%m.%d",noon))
            buttons[#buttons+1]='<button class="action filter-button date-filter" data-action="dateFilter" data-date-key="'..key..'" aria-pressed="false">'..label..'</button>'
        end
    end
    return table.concat(buttons,"\n")
end)() .. [[</div></header>
<main> <div id="clipboard-items" class="item-grid">]] .. initialCardsHTML .. [[</div>]] .. loadMoreHTML .. [[</main>
<footer>Tab: results · Shift+Tab: search · Arrow keys: select when results are focused · Click: paste · Esc: close</footer>
<script>
const bridge = (action, index, query, kind, dateKey) => {
  try { window.webkit.messageHandlers.clipboardHistory.postMessage({action, index, query, kind, dateKey}); } catch (_) {}
};
document.addEventListener('click', event => {
  const contextItem = event.target.closest('#clipboard-context-menu');
  if (contextItem) return;
  const button = event.target.closest('[data-action]');
  if (button) {
    const action = button.dataset.action;
    const index = Number(button.dataset.index || 0);
    if (action === 'filter') { setActiveFilter(button); return; }
    if (action === 'dateScope' || action === 'dateFilter') {
      const wasSelected = button.getAttribute('aria-pressed') === 'true';
      const selectedKind = currentTypeFilter();
      const query = committedSearchQuery;
      if (query !== '') {
        // While a search is active, date chips filter its matches; do not
        // permanently replace the pre-search scope used when search is cleared.
        if (action === 'dateScope' || wasSelected) {
          document.querySelectorAll('.date-filter').forEach(b=>b.setAttribute('aria-pressed','false'));
          allDatesFilterSelected = true;
          button.setAttribute('aria-pressed','true');
          bridge('showLatest',0,query,selectedKind);
        } else {
          document.querySelectorAll('.date-filter').forEach(b=>b.setAttribute('aria-pressed','false'));
          button.setAttribute('aria-pressed','true');
          bridge('dateFilter',0,query,selectedKind,button.dataset.dateKey);
        }
      } else if (action === 'dateScope' || wasSelected) {
        lastNonSearchDateKey = null;
        lastNonSearchWasAllDates = true;
        document.querySelectorAll('.date-filter').forEach(b=>b.setAttribute('aria-pressed','false'));
        allDatesFilterSelected = true;
        button.setAttribute('aria-pressed','true');
        bridge('showLatest',0,'',selectedKind);
      } else {
        lastNonSearchDateKey = button.dataset.dateKey;
        lastNonSearchWasAllDates = false;
        document.querySelectorAll('.date-filter').forEach(b=>b.setAttribute('aria-pressed','false'));
        allDatesFilterSelected = false;
        button.setAttribute('aria-pressed','true');
        bridge('dateFilter',0,'',selectedKind,button.dataset.dateKey);
      }
      return;
    }
    if (action === 'loadMore') {
      bridge('loadMore', index, search.value, currentTypeFilter());
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
// Show the preview only after a continuous three-second hover, and keep
// the preview centered in the clipboard-history window. Moving to another card
// or leaving a card cancels the pending timer so previews don't flicker.
let hoverDetailTimer = null;
let pendingHoverItem = null;
let lastPointerX = -1;
let lastPointerY = -1;
let pointerInsideResults = false;
let suppressHoverUntilPointerMoves = false;
let resumeHoverAfterScrollTimer = null;
function hideHoverDetail(item) {
  if (item) {
    item.classList.remove('detail-open');
    item.classList.remove('preview-loading');
  }
}
function cancelPendingHoverDetail() {
  if (hoverDetailTimer !== null) {
    clearTimeout(hoverDetailTimer);
    hoverDetailTimer = null;
  }
  if (pendingHoverItem) hideHoverDetail(pendingHoverItem);
  pendingHoverItem = null;
}
function scheduleHoverDetail(item) {
  if (!item || !item.querySelector('.hover-detail') || suppressHoverUntilPointerMoves) return;
  if (pendingHoverItem === item && hoverDetailTimer !== null) return;
  cancelPendingHoverDetail();
  pendingHoverItem = item;
  hoverDetailTimer = setTimeout(() => {
    hoverDetailTimer = null;
    if (pendingHoverItem !== item || !item.isConnected) return;
    if (!pointerInsideResults || !item.matches(':hover')) {
      cancelPendingHoverDetail();
      return;
    }
    const image = item.querySelector('.hover-image');
    if (image) {
      // Keep the entire preview panel hidden until the image itself has loaded.
      item.classList.add('preview-loading');
      image.dataset.requested = 'true';
      image.onload = () => {
        if (!item.isConnected || pendingHoverItem !== item) return;
        item.classList.remove('preview-loading');
        item.classList.add('detail-open');
        image.style.visibility = 'visible';
      };
      image.onerror = () => {
        item.classList.remove('preview-loading');
        image.style.visibility = 'hidden';
      };
      bridge('loadImagePreview', Number(item.dataset.index || 0), '', 'image');
    } else {
      const fullText = item.querySelector('.hover-full-text');
      if (fullText && fullText.dataset.loaded !== 'true') {
        fullText.textContent = 'Loading preview…';
        bridge('loadTextPreview', Number(item.dataset.index || 0), '', 'text');
        return;
      }
      item.classList.add('detail-open');
    }
  }, 2000);
}
function resumeHoverAfterScrollingSettles() {
  if (resumeHoverAfterScrollTimer !== null) clearTimeout(resumeHoverAfterScrollTimer);
  resumeHoverAfterScrollTimer = setTimeout(() => {
    resumeHoverAfterScrollTimer = null;
    suppressHoverUntilPointerMoves = false;
    // Scrolling can move a different card underneath a stationary pointer and
    // WebKit doesn't always dispatch pointerover/pointermove afterward. Resolve
    // the current target from the saved pointer coordinates and restart dwell.
    if (lastPointerX < 0 || lastPointerY < 0) return;
    const target = document.elementFromPoint(lastPointerX, lastPointerY);
    const item = target && target.closest
      ? target.closest('#clipboard-items .item')
      : null;
    pointerInsideResults = !!item && resultsPanel.contains(item);
    if (pointerInsideResults) scheduleHoverDetail(item);
  }, 350);
}
document.addEventListener('wheel', event => {
  if (resultsPanel && resultsPanel.contains(event.target)) {
    suppressHoverUntilPointerMoves = true;
    cancelPendingHoverDetail();
    resumeHoverAfterScrollingSettles();
  }
}, {capture:true, passive:true});
document.addEventListener('pointerover', event => {
  const item = event.target.closest && event.target.closest('#clipboard-items .item');
  if (!item) return;
  if (event.relatedTarget && item.contains(event.relatedTarget)) return;
  pointerInsideResults = true;
  scheduleHoverDetail(item);
});
document.addEventListener('pointerout', event => {
  const item = event.target.closest && event.target.closest('#clipboard-items .item');
  if (!item) {
    if (!event.relatedTarget || !resultsPanel.contains(event.relatedTarget)) {
      pointerInsideResults = false;
      if (pendingHoverItem) cancelPendingHoverDetail();
    }
    return;
  }
  if (event.relatedTarget && item.contains(event.relatedTarget)) return;
  if (pendingHoverItem === item) cancelPendingHoverDetail();
  else hideHoverDetail(item);
  const nextItem = event.relatedTarget && event.relatedTarget.closest
    ? event.relatedTarget.closest('#clipboard-items .item')
    : null;
  pointerInsideResults = !!nextItem;
  if (nextItem) scheduleHoverDetail(nextItem);
});
document.addEventListener('focusin', event => {
  const item = event.target.closest && event.target.closest('#clipboard-items .item');
  if (!item) return;
  // Keyboard focus should not open details; previews are pointer-hover only.
});
document.addEventListener('pointermove', event => {
  const moved = event.clientX !== lastPointerX || event.clientY !== lastPointerY;
  if (moved) {
    lastPointerX = event.clientX;
    lastPointerY = event.clientY;
    suppressHoverUntilPointerMoves = false;
    // Normal pointer movement must not cancel the dwell timer. pointerover/out
    // handles entering and leaving cards; wheel/scroll handlers dismiss previews.
  }
  const item = event.target.closest && event.target.closest('#clipboard-items .item');
  pointerInsideResults = !!item;
});
document.addEventListener('scroll', event => {
  if (event.target === resultsPanel || resultsPanel.contains(event.target)) {
    suppressHoverUntilPointerMoves = true;
    pointerInsideResults = false;
    cancelPendingHoverDetail();
    resumeHoverAfterScrollingSettles();
  }
}, true);
window.addEventListener('blur', () => {
  pointerInsideResults = false;
  suppressHoverUntilPointerMoves = true;
  cancelPendingHoverDetail();
});
window.addEventListener('resize', () => {
  suppressHoverUntilPointerMoves = true;
  cancelPendingHoverDetail();
});
window.setImageThumbnail = (index, src) => {
  const item = document.querySelector('.image-item[data-index="' + index + '"]');
  if (!item || !item.isConnected || !src) return;
  const placeholder = item.querySelector('.preview.placeholder');
  if (!placeholder) return;
  const img = document.createElement('img');
  img.className = 'preview';
  img.alt = 'Clipboard image preview';
  img.loading = 'lazy';
  img.decoding = 'async';
  img.src = src;
  placeholder.replaceWith(img);
};
window.setImagePreview = (index, src) => {
  const item = document.querySelector('.image-item[data-index="' + index + '"]');
  const img = item && item.querySelector('.hover-image');
  if (!img || img.dataset.requested !== 'true') return;
  // Load into a detached Image first. The tooltip is not shown until this
  // request completes, so neither an empty preview window nor alt text flashes.
  const preloader = new Image();
  preloader.onload = () => {
    if (!item.isConnected || pendingHoverItem !== item) return;
    img.src = src;
    img.style.visibility = 'visible';
  };
  preloader.onerror = () => {
    if (item.isConnected) item.classList.remove('preview-loading');
  };
  preloader.src = src;
};
window.setTextPreview = (index, content) => {
  const item = document.querySelector('.text-item[data-index="' + index + '"]');
  const fullText = item && item.querySelector('.hover-full-text');
  if (!item || !fullText || pendingHoverItem !== item) return;
  fullText.textContent = content;
  fullText.dataset.loaded = 'true';
  item.classList.add('detail-open');
};
const search = document.getElementById('search');
const activeTypeFilters = new Set();
let committedSearchQuery = '';
let previousSearchQuery = '';
let lastNonSearchDateKey = null;
let lastNonSearchWasAllDates = true;
function currentTypeFilter() {
  if (activeTypeFilters.size === 0) return 'all';
  if (activeTypeFilters.size === 2) return 'none';
  return activeTypeFilters.has('text') ? 'text' : 'image';
}
function applyFilters() {
  const nextQuery = search.value.trim();
  if (nextQuery === '') {
    committedSearchQuery = '';
    const restoreDate = lastNonSearchDateKey;
    document.querySelectorAll('.date-filter').forEach(b => b.setAttribute('aria-pressed', 'false'));
    if (restoreDate) {
      document.querySelectorAll('.date-filter').forEach(b => {
        if (b.dataset.dateKey === restoreDate) b.setAttribute('aria-pressed', 'true');
      });
      bridge('dateFilter', 0, '', currentTypeFilter(), restoreDate);
    } else {
      const allDates = document.querySelector('[data-action="dateScope"]');
      if (allDates) allDates.setAttribute('aria-pressed', 'true');
      bridge('showLatest', 0, '', currentTypeFilter());
    }
    return;
  }
  if (committedSearchQuery === '') {
    const selectedDate = document.querySelector('.date-filter[aria-pressed="true"][data-date-key]');
    lastNonSearchDateKey = selectedDate ? selectedDate.dataset.dateKey : null;
  }
  previousSearchQuery = committedSearchQuery;
  committedSearchQuery = nextQuery;
  document.querySelectorAll('.date-filter').forEach(b => b.setAttribute('aria-pressed', 'false'));
  const allDates = document.querySelector('[data-action="dateScope"]');
  if (allDates) allDates.setAttribute('aria-pressed', 'true');
  bridge('search', 0, committedSearchQuery, currentTypeFilter());
}
function setActiveFilter(button) {
  const kind = button.dataset.filter;
  const wasSelected = button.getAttribute('aria-pressed') === 'true';
  const nextKind = wasSelected ? 'all' : kind;
  activeTypeFilters.clear();
  if (nextKind !== 'all') activeTypeFilters.add(nextKind);
  document.querySelectorAll('.type-filter').forEach(other => {
    other.setAttribute('aria-pressed', other.dataset.filter === nextKind ? 'true' : 'false');
  });
  bridge('filter', 0, committedSearchQuery, currentTypeFilter());
}
search.addEventListener('input', () => {
  // Keep normal typing local so searches still run only on Enter. Erasing an
  // active query is the exception: immediately restore the unsearched scope.
  if (search.value.trim() === '' && committedSearchQuery !== '') {
    committedSearchQuery = '';
    document.querySelectorAll('.date-filter').forEach(b => b.setAttribute('aria-pressed', 'false'));
    if (lastNonSearchDateKey) {
      document.querySelectorAll('.date-filter').forEach(b => {
        if (b.dataset.dateKey === lastNonSearchDateKey) b.setAttribute('aria-pressed', 'true');
      });
      bridge('dateFilter', 0, '', currentTypeFilter(), lastNonSearchDateKey);
    } else {
      const allDates = document.querySelector('[data-action="dateScope"]');
      if (allDates) allDates.setAttribute('aria-pressed', 'true');
      bridge('showLatest', 0, '', currentTypeFilter());
    }
  }
});
search.addEventListener('keydown', event => {
  if (event.key === 'Escape' && search.value !== '') {
    event.preventDefault();
    event.stopPropagation();
    search.value = '';
    applyFilters();
  }
});
search.addEventListener('keydown', event => {
  if (event.key === 'Enter') {
    // Enter submits the search only; prevent it from reaching the global
    // result-selection handler, which uses Enter to paste the selected card.
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    applyFilters();
  }
});
const resultsPanel = document.getElementById('clipboard-items');
resultsPanel.tabIndex = 0;
resultsPanel.setAttribute('role', 'listbox');
resultsPanel.setAttribute('aria-label', 'Clipboard history results');

let selectedIndex = 0;
function rows() { return Array.from(document.querySelectorAll('main .item')).filter(item => !item.hidden && item.dataset.action === 'paste'); }
function selectRow(next, shouldScroll = false) {
  const items = rows();
  if (!items.length) { selectedIndex = 0; return; }
  selectedIndex = Math.max(0, Math.min(items.length - 1, next));
  items.forEach((item, i) => item.classList.toggle('selected', i === selectedIndex));
  // Keep cards clear of the fixed header and footer when navigating.
  // Scroll only the results grid (never the whole document/window).
  if (shouldScroll && items[selectedIndex]) {
    const container = resultsPanel;
    const item = items[selectedIndex];
    const containerRect = container.getBoundingClientRect();
    const itemRect = item.getBoundingClientRect();
    const topInset = 16;
    const bottomInset = 16;
    if (itemRect.top < containerRect.top + topInset) {
      container.scrollTop -= (containerRect.top + topInset) - itemRect.top;
    } else if (itemRect.bottom > containerRect.bottom - bottomInset) {
      container.scrollTop += itemRect.bottom - (containerRect.bottom - bottomInset);
    }
  }
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
    if (event.key === 'ArrowRight') selectRow(selectedIndex + 1, true);
    else if (event.key === 'ArrowLeft') selectRow(selectedIndex - 1, true);
    else {
      const columns = Math.max(1, Math.round(document.querySelector('main').clientWidth / 250));
      selectRow(selectedIndex + (event.key === 'ArrowDown' ? columns : -columns), true);
    }
    const selected = rows()[selectedIndex];
    if (selected) selected.focus({preventScroll:true});
    return;
  }
  if (event.key === 'Enter') {
    // Do not let Enter submit a search fall through to paste a selected result.
    if (event.target === search) return;
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
        local image = decodeImage(choice.historyEntry or choice)
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

local function updateClipboardPanel(query,kind,offset,append)
    query=tostring(query or "")
    if kind~="text" and kind~="image" and kind~="none" then kind="all" end
    local previousMenuDataCount=append and #menuData or 0

    if query~="" then
        if clipboardDateFilter then
            -- Date views are subsets of the already computed global query results.
            if searchResultsCache and searchResultsCache.query==query and searchResultsCache.kind==kind then
                menuData={}
                for _,entry in ipairs(searchResultsCache.entries) do
                    if entry.dateKey==clipboardDateFilter then menuData[#menuData+1]=entry end
                end
            else
                local dayEntries=loadPersistentDateHistory(clipboardDateFilter,"all")
                menuData={}
                for _,entry in ipairs(dayEntries) do
                    if clipboardEntryMatches(entry,query,kind) then menuData[#menuData+1]=entry end
                end
            end
            table.sort(menuData,function(a,b)return a.ts>b.ts end)
            browseMode="date"
        else
            if searchResultsCache and searchResultsCache.query==query and searchResultsCache.kind==kind then
                menuData=searchResultsCache.entries
            else
                menuData=searchPersistentHistory(query,kind)
                searchResultsCache={query=query,kind=kind,entries=menuData}
            end
            browseMode="search"
        end
        browseCursor=0
    elseif clipboardDateFilter then
        if not append then menuData=loadPersistentDateHistory(clipboardDateFilter,"all") end
        browseMode="date"
    else
        -- Reuse the session-wide mixed cache. Only Load More extends it by another
        -- 32 mixed records; switching back to All Dates or toggling Text/Images is in-memory.
        local required=append and (allHistoryCacheLoaded+CLIPBOARD_RENDER_BATCH_SIZE)
            or math.max(CLIPBOARD_RENDER_BATCH_SIZE,allHistoryCacheLoaded)
        local cached,loaded=ensureAllHistoryCache(required)
        menuData=cached
        browseCursor=loaded
        browseMode="all"
    end

    local matches={}
    for i,entry in ipairs(menuData) do
        if (kind=="all" or entry.type==kind)
            and (query=="" or clipboardEntryMatches(entry,query,kind)) then
            matches[#matches+1]=i
        end
    end

    local cards={}
    for _,matchedIndex in ipairs(matches) do
        if not append or matchedIndex>previousMenuDataCount then
            cards[#cards+1]=historyItemHTML(menuData[matchedIndex],matchedIndex)
        end
    end
    local html=table.concat(cards,"\n")
    local hasMore=query=="" and not clipboardDateFilter
        and (not allHistoryTotalCount or allHistoryCacheLoaded<allHistoryTotalCount)
    local loadMore=hasMore and '<div class="load-more-wrap"><button class="action" data-action="loadMore" data-index="'..browseCursor..'">Load more</button></div>' or ""
    if #matches==0 then html='<div id="no-matches" class="empty">No matching clipboard items</div>' end
    html=html..loadMore

    local js
    if append then
        js="var m=document.getElementById('clipboard-items');var main=document.querySelector('main');var b=main.querySelector(':scope > .load-more-wrap');if(b)b.remove();var e=m.querySelector('.empty');if(e)e.remove();m.insertAdjacentHTML('beforeend',"..jsStringLiteral(html)..");var last=m.querySelector('.load-more-wrap');if(last)last.remove();if(last)main.appendChild(last);"
    else
        js="var m=document.getElementById('clipboard-items');var main=document.querySelector('main');var b=main.querySelector(':scope > .load-more-wrap');if(b)b.remove();m.innerHTML="..jsStringLiteral(html)..";var last=m.querySelector('.load-more-wrap');if(last)last.remove();if(last)main.appendChild(last);"
    end

    local visibleCount=#matches
    if query=="" and clipboardDateFilter then
        visibleCount=persistentHistoryCount(clipboardDateFilter,kind)
    elseif query=="" and allHistoryTotalCount and allHistoryCacheLoaded>=allHistoryTotalCount then
        if kind=="all" then visibleCount=allHistoryTotalCount end
    end
    js=js.."document.querySelector('.count').textContent="..jsStringLiteral(tostring(visibleCount).." matching items")..";if(window.resetClipboardSelection)window.resetClipboardSelection();"
    if clipboard_webview then clipboard_webview:evaluateJavaScript(js) end
    clipboard_search=query; clipboard_type_filter=kind
end

local closeClipboardPanel

function handleClipboardPanelMessage(message)
    local body = message and message.body
    if type(body) ~= "table" then return end
    if body.action == "close" then closeClipboardPanel()
    elseif body.action == "dateFilter" then
        local dateKey=body.dateKey
        if not validDateKey(dateKey) then return end
        local kind=body.kind or "all"
        if tostring(body.query or "")=="" then lastSearchRestoreDateKey=nil end
        clipboardDateFilter=dateKey
        allDatesFilterSelected=false
        browseMode="date"
        clipboard_search=body.query or ""
        clipboard_type_filter=kind
        -- updateClipboardPanel performs the metadata-only date cache lookup.
        updateClipboardPanel(body.query or "",kind,0,false)
    elseif body.action == "showLatest" then
        -- If a query is active, return to its cached cross-date result set.
        -- Do not perform another persistent-history search when switching back.
        local query=tostring(body.query or "")
        local kind=body.kind or "all"
        clipboardDateFilter=nil
        allDatesFilterSelected=true
        clipboard_search=query
        clipboard_type_filter=kind
        if query~="" then
            browseMode="search"
            if not searchResultsCache or searchResultsCache.query~=query or searchResultsCache.kind~=kind then
                searchResultsCache={query=query,kind=kind,entries=searchPersistentHistory(query,kind)}
            end
            menuData=searchResultsCache.entries
            browseCursor=0
            updateClipboardPanel(query,kind,0,false)
        else
            browseMode="all"
            local cached,loaded=ensureAllHistoryCache(CLIPBOARD_RENDER_BATCH_SIZE)
            menuData=cached
            browseCursor=loaded
            updateClipboardPanel("",kind,0,false)
        end
    elseif body.action == "search" or body.action == "filter" then
        local query=tostring(body.query or "")
        local kind=body.kind or clipboard_type_filter or "all"
        if body.action=="search" then
            if query=="" then
                searchResultsCache=nil
                clipboardDateFilter=lastSearchRestoreDateKey
                allDatesFilterSelected=clipboardDateFilter==nil
            else
                if clipboardDateFilter then lastSearchRestoreDateKey=clipboardDateFilter end
                clipboardDateFilter=nil
                allDatesFilterSelected=true
                if not searchResultsCache or searchResultsCache.query~=query or searchResultsCache.kind~=kind then
                    searchResultsCache={query=query,kind=kind,entries=searchPersistentHistory(query,kind)}
                end
            end
        end
        updateClipboardPanel(query,kind,0,false)
    elseif body.action == "loadMore" then
        updateClipboardPanel(body.query or clipboard_search or "",body.kind or clipboard_type_filter or "all",tonumber(body.index) or browseCursor or 0,true)
    elseif body.action == "loadTextPreview" then
        local index = tonumber(body.index)
        local entry = index and menuData[index]
        if entry and entry.type == "text" and clipboard_webview then
            local excerptLines = {}
            local lineCount = 0
            local content = tostring(entry.data or entry.content or "")
            for line in (content .. "\n"):gmatch("(.-)\n") do
                lineCount = lineCount + 1
                if lineCount > TEXT_HOVER_MAX_LINES then break end
                excerptLines[#excerptLines + 1] = line
            end
            local excerpt = table.concat(excerptLines, "\n")
            if lineCount > TEXT_HOVER_MAX_LINES or #content > #excerpt then
                excerpt = excerpt .. "\n… (preview limited to first " .. TEXT_HOVER_MAX_LINES .. " lines)"
            end
            clipboard_webview:evaluateJavaScript(
                "window.setTextPreview && window.setTextPreview(" .. tostring(index) .. "," .. jsStringLiteral(excerpt) .. ");"
            )
        end
    elseif body.action == "loadImagePreview" then
        local index=tonumber(body.index)
        local entry=index and menuData[index]
        local historyEntry=entry and (entry.historyEntry or entry)
        local img=historyEntry and decodeImage(historyEntry)
        if img and clipboard_webview then
            local ok,url=pcall(function()return img:encodeAsURLString()end)
            img=nil; collectgarbage("collect")
            if ok and url then clipboard_webview:evaluateJavaScript("window.setImagePreview && window.setImagePreview("..tostring(index)..","..jsStringLiteral(url)..");") end
        end
    elseif body.action == "paste" then
        pasteHistoryEntry(tonumber(body.index))
    elseif body.action == "pasteAllFrom" then
        pasteSomeWithDelimiterFromStartRow(tonumber(body.index))
    elseif body.action == "clearAll" then
        clearClipboardHistory()
        if clipboard_webview then
            clipboardPanelHTMLReady = true
            clipboard_webview:html(clipboardPanelHTML())
            clipboard_webview:show()
        end
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

-- Destroy the native window on dismissal. A hidden hs.webview can remain tied
-- to the Space where it was first shown; recreating it on the next hotkey lets
-- macOS attach it to the currently active Space.
closeClipboardPanel = function()
    -- Stop global monitoring and pending activation attempts before destroying the panel.
    stopOutsideClickMonitor()
    panelActivationGeneration = panelActivationGeneration + 1
    if panelActivationTimer then
        panelActivationTimer:stop()
        panelActivationTimer = nil
    end
    -- Invalidate the view first so any delayed callbacks become no-ops.
    local view=clipboard_webview
    clipboard_webview=nil
    clipboardPanelHTMLReady=false
    clipboard_usercontent=nil

    -- Clear every Lua-owned reference to the expanded browse session.
    clipboard_search=""
    clipboard_type_filter="all"
    clipboardDateFilter=nil
    lastSearchRestoreDateKey=nil
    browseMode="all"
    browseCursor=0
    typeBrowseCursor={text=nil,image=nil}
    menuData={}
    dateHistoryCache={}
    allHistoryCache={}
    allHistoryCacheLoaded=0
    allHistoryTotalCount=nil
    searchResultsCache=nil
    clipboardSessionOpen=false
    panelCacheKey=nil
    panelCacheHTML=nil
    visibleIndices={}
    selectedVisibleIndex=1

    -- Drop large transient payloads from the retained base cache too; the
    -- entries are lightweight metadata/path records, but older watcher paths
    -- may have attached full image objects or data URLs.
    for _,list in ipairs({text_clipboard_history,img_clipboard_history}) do
        for _,entry in ipairs(list) do
            if entry.type=="image" then
                entry.imageObject=nil
                entry.imageData=nil
                entry.dataURL=nil
                entry.thumbnailData=entry.thumbnailData or ""
            end
        end
    end
    trimHistoryCache(CLIPBOARD_CACHE_SIZE)
    if view then
        pcall(function()
            view:evaluateJavaScript([[
                if (window.resetClipboardSelection) window.resetClipboardSelection();
                if (window.cancelPendingHoverDetail) window.cancelPendingHoverDetail();
                document.querySelectorAll('img').forEach(function(img) {
                    img.onload=null; img.onerror=null; img.removeAttribute('src');
                });
                document.querySelectorAll('.hover-detail').forEach(function(node) { node.remove(); });
                document.getElementById('clipboard-items')?.replaceChildren();
            ]])
        end)
        pcall(function() view:delete() end)
    end
    collectgarbage("collect")
end

local function configureClipboardWebview(view)
    view:windowStyle({"titled", "closable", "resizable"})
    view:shadow(true)
    view:allowTextEntry(true)
    view:closeOnEscape(false)
    view:windowCallback(function(action, _, focused)
        if action == "closing" then
            stopOutsideClickMonitor()
            panelActivationGeneration = panelActivationGeneration + 1
            if panelActivationTimer then
                panelActivationTimer:stop()
                panelActivationTimer = nil
            end
            if clipboard_webview == view then
                clipboard_webview = nil
                clipboard_usercontent = nil
                clipboardPanelHTMLReady = false
                clipboard_search=""; clipboard_type_filter="all"; clipboardDateFilter=nil; lastSearchRestoreDateKey=nil; browseMode="all"; browseCursor=0; typeBrowseCursor={text=nil,image=nil}; menuData={}
                dateHistoryCache={}; allHistoryCache={}; allHistoryCacheLoaded=0; allHistoryTotalCount=nil; searchResultsCache=nil; clipboardSessionOpen=false
                panelCacheKey=nil; panelCacheHTML=nil; visibleIndices={}; selectedVisibleIndex=1
                for _,list in ipairs({text_clipboard_history,img_clipboard_history}) do
                    for _,entry in ipairs(list) do
                        if entry.type=="image" then
                            entry.imageObject=nil; entry.imageData=nil; entry.dataURL=nil
                        end
                    end
                end
                trimHistoryCache(CLIPBOARD_CACHE_SIZE)
                collectgarbage("collect")
            end
        end
        -- Deliberately ignore focusChange. Outside mouse clicks are handled
        -- by the dedicated monitor below.
    end)
end

local clipboardPanelHTMLReady = false

-- Close the panel after an outside click, while ignoring focus changes alone.
-- This keeps clicks in browser inputs from being treated as an automatic dismiss.
local function pointIsInsideClipboardPanel(point)
    local view = clipboard_webview
    if not view or not view:isVisible() then return false end
    local frame = view:frame()
    if not frame then return false end
    return point.x >= frame.x and point.x <= frame.x + frame.w
        and point.y >= frame.y and point.y <= frame.y + frame.h
end

stopOutsideClickMonitor = function()
    if outsideClickMonitor then
        outsideClickMonitor:stop()
        outsideClickMonitor = nil
    end
end

local function startOutsideClickMonitor()
    stopOutsideClickMonitor()
    outsideClickMonitor = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function(event)
        local view = clipboard_webview
        if not view or not view:isVisible() then
            stopOutsideClickMonitor()
            return false
        end

        -- The deliberate title-bar click used to activate the window is
        -- synthetic and must never trigger the outside-click dismissal logic.
        if hs.timer.secondsSinceEpoch() < suppressOutsideClickUntil then
            return false
        end
        local point = hs.mouse.absolutePosition()
        if not pointIsInsideClipboardPanel(point) then
            -- Only schedule one dismissal for a single outside click. The
            -- click is not swallowed, so it still reaches the target app.
            if not closeOutsideClickPending then
                closeOutsideClickPending = true
                hs.timer.doAfter(0, function()
                    closeOutsideClickPending = false
                    if clipboard_webview == view and view:isVisible()
                        and not pointIsInsideClipboardPanel(hs.mouse.absolutePosition()) then
                        closeClipboardPanel()
                    end
                end)
            end
        end
        return false
    end)
    outsideClickMonitor:start()
end

local function createClipboardWebview()
    clipboardPanelHTMLReady = false
    clipboard_usercontent = webview.usercontent.new("clipboardHistory")
    clipboard_usercontent:setCallback(handleClipboardPanelMessage)
    clipboard_webview = webview.new(
        {x = 120, y = 80, w = 980, h = 760},
        {javaScriptEnabled = true, privateBrowsing = true, shadow = true},
        clipboard_usercontent
    ):windowStyle({"titled", "closable", "resizable"})
    configureClipboardWebview(clipboard_webview)
end
createClipboardWebview()

-- Paste clipboard-history rows from the oldest selected item to the newest.
-- The chooser is displayed newest-first, so walk the selected range backwards.
local function finishPasteAll()
    restoreNewestClipContent()
    menuData = {}
    if clipboard_webview then clipboard_webview:html(clipboardPanelHTML()) end
    pasteboard_watcher:start()
    previousApplication = nil
    collectgarbage("collect")
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
        local image = decodeImage(entry.historyEntry or entry)
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
    if imageProcessingCount > 0 then
        hs.timer.doAfter(0.1, function()
            if imageProcessingCount == 0 then
                showClipboardHistory()
            end
        end)
        return
    end
    -- Run daily retention cleanup when the panel is first requested that day too.
    runDailyCleanupIfNeeded()
    -- Initialize defensively in case the watcher was torn down during reload.
    if not pasteboard_watcher then
        pasteboard_watcher = pbwatcher.new(handleClipboardChange)
    end
    pasteboard_watcher:start()

    -- Keep the current app as the paste destination before showing the panel.
    local frontApp = application.frontmostApplication()
    if frontApp and frontApp:bundleID() ~= "org.hammerspoon.Hammerspoon" then
        previousApplication = frontApp
    elseif not (previousApplication and previousApplication:isRunning()) then
        previousApplication = nil
    end

    -- Keep the existing native window/WebView alive for fast repeat opens.
    -- If the user closed it with the red button, recreate it before rendering.
    if not clipboard_webview then createClipboardWebview() end
    -- Use a local reference for this invocation and all async callbacks.
    local view = clipboard_webview
    if not view then
        logger.e("Unable to create Clipboard History WebView")
        return
    end

    if not clipboardSessionOpen then dateHistoryCache = {} end
    clipboardSessionOpen = true
    clipboard_search = ""
    clipboard_type_filter = "all"
    clipboardDateFilter = nil
    allDatesFilterSelected = true
    browseMode = "all"
    browseCursor = 0
    typeBrowseCursor = {text = nil, image = nil}
    allHistoryCache={}
    allHistoryCacheLoaded=0
    allHistoryTotalCount=nil
    menuData=ensureAllHistoryCache(CLIPBOARD_RENDER_BATCH_SIZE)
    browseCursor=allHistoryCacheLoaded

    local function showAfterHTMLLoaded()
        if clipboard_webview ~= view then return end
        positionPanelOnCurrentScreen()
        view:show()
        view:evaluateJavaScript("document.body.classList.add('keyboard-mode');")

        -- A programmatic raise is only a z-order operation. Use a real native
        -- title-bar click to force macOS to make this window key/main, which
        -- matches the interaction that reliably activates ordinary app windows.
        -- Restore the pointer immediately so the shortcut does not disrupt the
        -- user's cursor position in the API-key field.
        hs.timer.doAfter(0.08, function()
            if clipboard_webview ~= view or not view:isVisible() then return end
            local nativeWindow = view:hswindow()
            if not nativeWindow then
                logger.w("Clipboard History window unavailable after show")
                startOutsideClickMonitor()
                return
            end

            local frame = view:frame()
            local pointerBefore = hs.mouse.absolutePosition()
            local clickPoint = {
                x = frame.x + math.min(70, math.max(24, frame.w * 0.08)),
                y = frame.y + 12
            }
            suppressOutsideClickUntil = hs.timer.secondsSinceEpoch() + 0.35
            view:level(hs.drawing.windowLevels.floating)
            view:bringToFront(true)
            view:orderAbove()
            nativeWindow:raise()

            -- Repeat once in case the first activation reaches the window before
            -- macOS has finished ordering it frontmost. Do not park the pointer.
            hs.eventtap.leftClick(clickPoint)
            hs.timer.doAfter(0.04, function()
                if clipboard_webview ~= view or not view:isVisible() then return end
                local currentWindow = view:hswindow()
                if currentWindow then
                    currentWindow:raise()
                    currentWindow:focus()
                    view:bringToFront(true)
                end
                hs.eventtap.leftClick(clickPoint)
                hs.timer.doAfter(0.04, function()
                    hs.mouse.absolutePosition(pointerBefore)
                    if clipboard_webview ~= view or not view:isVisible() then return end
                    local focusedWindow = hs.window.focusedWindow()
                    local app = currentWindow and currentWindow:application()
                    local frontApp = application.frontmostApplication()
                    local appFocused = app and frontApp and app:pid() == frontApp:pid()
                    local windowFocused = focusedWindow and currentWindow
                        and focusedWindow:id() == currentWindow:id()
                    logger.d("Clipboard History title-bar activation: appFocused="
                        .. tostring(appFocused) .. ", windowFocused=" .. tostring(windowFocused))
                    if not (appFocused and windowFocused) then
                        logger.w("Clipboard History title-bar click did not activate the panel")
                    end
                    startOutsideClickMonitor()
                end)
            end)
        end)
    end

    -- On the first open (or after the native window was recreated), load HTML
    -- directly. Don't send JavaScript into an uninitialized WebView and wait
    -- for a predictable error/rebuild cycle before showing the panel.
    if not clipboardPanelHTMLReady then
        view:html(clipboardPanelHTML())
        clipboardPanelHTMLReady = true
        hs.timer.doAfter(0.15, showAfterHTMLLoaded)
        return
    end

    -- The document is already loaded, so update only the visible batch.
    local cardsHTML, matchingCount, renderedCount = renderClipboardBatch("", "all", 0)
    local loadMoreHTML = persistentHistoryCount() > renderedCount and
        '<div class="load-more-wrap"><button class="action" data-action="loadMore" data-index="' ..
        renderedCount .. '">Load more</button></div>' or ''
    local initialCardsHTML = cardsHTML ~= "" and cardsHTML or '<div id="no-matches" class="empty">No clipboard items</div>'
    local updateScript = "var main=document.getElementById('clipboard-items');" ..
        "if(!main){throw new Error('clipboard panel DOM is not ready');}" ..
        "main.innerHTML=" .. jsStringLiteral(initialCardsHTML .. loadMoreHTML) .. ";" ..
        "document.querySelector('.count').textContent=" .. jsStringLiteral(tostring(matchingCount) .. " matching items") .. ";" ..
        "document.getElementById('search').value='';" ..
        "document.querySelectorAll('.date-filter').forEach(function(b){b.setAttribute('aria-pressed',b.dataset.action==='dateScope'?'true':'false');});" ..
        "document.querySelectorAll('.type-filter').forEach(function(b){b.setAttribute('aria-pressed','false');});" ..
        "document.body.classList.add('keyboard-mode');" ..
        "if(window.resetClipboardSelection)window.resetClipboardSelection();"
    view:evaluateJavaScript(updateScript, function(result, error)
        if clipboard_webview ~= view then return end
        if error then
            -- A DOM refresh can fail when WebKit has discarded or not yet
            -- restored the document. Rebuilding HTML is the intended recovery
            -- path, so don't emit a warning for this handled condition.
            view:html(clipboardPanelHTML())
            clipboardPanelHTMLReady = true
            hs.timer.doAfter(0.1, showAfterHTMLLoaded)
            return
        end
        showAfterHTMLLoaded()
    end)
end

-- Restore disk state before starting the watcher, so previous history is
-- available immediately after Hammerspoon/Sux-Mac starts.
runDailyCleanupIfNeeded()
restorePersistentHistory()
-- Also clean on the first clipboard notification after startup, since expired
-- folders may have been created manually after the startup scan completed.
cleanupOnNextClipboardChange = true

-- Start the pasteboard watcher
pasteboard_watcher = pbwatcher.new(handleClipboardChange)
pasteboard_watcher:start()

-- Keep an explicit reference to the global shortcut so it remains live after
-- Spoon reloads. Bindings are global, so browser password fields should not
-- prevent the history panel from being triggered by this chord.
local historyHotkey = hotkey.bind({"ctrl", "shift"}, "v", showClipboardHistory)
if historyHotkey then historyHotkey:enable() end



return pkg