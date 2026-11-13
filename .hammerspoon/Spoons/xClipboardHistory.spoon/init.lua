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
-- Large screenshots can temporarily exist as several decoded NSImage/bitmap
-- buffers. Keep processing serialized and bound thumbnail dimensions so one
-- capture cannot trigger overlapping full-size conversions.
local MAX_IMAGE_DIMENSION = 32768
local imageCaptureInProgress = false
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
local previousApplicationPid = nil
local panelClosePending = false
local previousApplicationRestoreTimer = nil
local previousApplicationRestoreGeneration = 0
-- Declared before panel callbacks so window-close and dismissal handlers can
-- stop the global click monitor safely.
local outsideClickMonitor = nil
local closeOutsideClickPending = false
local stopOutsideClickMonitor
local selectedVisibleIndex = 1
local visibleIndices = {}
-- Uids of the cards currently in the results panel. The Load-more path appends
-- to the DOM, so it must ask "has this event already been rendered?" rather than
-- trusting a list index: the merged All list re-sorts when a new page arrives,
-- and an index-only guard skips boundary cards and leaves stale cards in place.
local renderedCardUids = {}
local panelScreenUUID = nil
local CLIPBOARD_RENDER_BATCH_SIZE = 32
local CLIPBOARD_CACHE_SIZE = 32
local clipboardDateFilter = nil
local clipboardPinnedFilter = false
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
-- Temporary multi-selection keyed by stable card UID; cleared when the panel closes.
local selectedClipboardUids = {}
local selectedClipboardOrder = {}
-- Hold one completed global search per query/type for this open-panel session.
-- Switching date chips or returning to All Dates reuses these matches instead
-- of scanning every persisted daily history file again.
local searchResultsCache = nil
-- Search results for the unified All collection (ordinary history + pins).
-- Kept separate from searchResultsCache so an ordinary-history cache can never
-- be served as an All result set, and vice versa.
local allSearchCache = nil

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

local PINNED_ROOT=HISTORY_ROOT.."/pinned"
local PINNED_IMAGE_ROOT=PINNED_ROOT.."/pinned-images"
local PINNED_THUMBNAIL_ROOT=PINNED_ROOT.."/pinned-thumbnails"
local PINNED_HISTORY_PATH=PINNED_ROOT.."/pinned-history.json"
local PINNED_MIGRATION_BACKUP_PATH=PINNED_HISTORY_PATH..".pre-migration.bak"
local function ensurePinnedStorage() return ensureDirectory(HISTORY_ROOT) and ensureDirectory(PINNED_ROOT) and ensureDirectory(PINNED_IMAGE_ROOT) and ensureDirectory(PINNED_THUMBNAIL_ROOT) end
-- Pinned records use the ordinary daily-history record shape. Pinned IO and
-- record helpers are declared after metadataEntry() below, because pinned
-- entries are built through that shared ordinary-history transformation.
local function copyPinnedFile(sourcePath, destinationPath)
 if type(sourcePath)~="string" or type(destinationPath)~="string" then return false end
 local source,sourceError=io.open(sourcePath,"rb")
 if not source then
  logger.w("Unable to open source file for pinning: "..tostring(sourceError))
  return false
 end
 local destination,destinationError=io.open(destinationPath,"wb")
 if not destination then
  source:close()
  logger.w("Unable to create pinned file: "..tostring(destinationError))
  return false
 end
 local copied=true
 while true do
  local chunk=source:read(1024*1024)
  if not chunk then break end
  local ok,writeError=destination:write(chunk)
  if not ok then
   copied=false
   logger.e("Unable to write pinned file: "..tostring(writeError))
   break
  end
 end
 local sourceClosed,sourceCloseError=source:close()
 local destinationClosed,destinationCloseError=destination:close()
 if not sourceClosed or not destinationClosed then
  copied=false
  logger.e("Unable to close pinned file copy: "..tostring(sourceCloseError or destinationCloseError))
 end
 if not copied then os.remove(destinationPath) end
 return copied
end

local function saveImageFile(dateKey, item, timestamp)
    if not item then return nil end
    local sizeOK, size = pcall(function() return item:size() end)
    local width = tonumber(size and size.w) or 0
    local height = tonumber(size and size.h) or 0
    if not sizeOK or width <= 0 or height <= 0 then
        logger.w("Refusing clipboard image with invalid dimensions")
        return nil
    end
    if width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION then
        logger.w(string.format("Refusing clipboard image with extreme dimensions (%dx%d)", width, height))
        return nil
    end
    local directory = historyImageDirectory(dateKey)
    if not ensureDirectory(HISTORY_ROOT) or not ensureDirectory(historyDayDirectory(dateKey)) or not ensureDirectory(directory) then
        return nil
    end

    -- Use hs.image's native file writer. Avoid base64 round trips, which can
    -- multiply peak memory for high-resolution screenshots.
    -- Save only after validating the native image dimensions.
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

-- Stable identity for an ordinary record. Ids are assigned when a record is
-- captured and survive a daily-index rewrite, so a pinned record can point at
-- its source record with `sourceId` instead of the array position inside a day
-- file, which shifts whenever that file is rewritten. Built from a monotonic
-- microsecond stamp plus a process-local sequence and prefixed with the date
-- key, so ids stay unique across day files. Clipboard content is never part of
-- an id.
local recordIdSequence = 0
local function nextRecordId(dateKey)
    recordIdSequence = recordIdSequence + 1
    local stamp = math.floor((hs.timer.secondsSinceEpoch and hs.timer.secondsSinceEpoch() or os.time()) * 1000000)
    return tostring(dateKey) .. "-" .. tostring(stamp) .. "-" .. tostring(recordIdSequence)
end

-- Byte-for-byte file copy for ordinary history backups. copyPinnedFile() is the
-- existing streaming copier; this alias names the ordinary-history use.
local function copyFileContents(sourcePath, destinationPath)
    return copyPinnedFile(sourcePath, destinationPath)
end

local function persistClipboardEntry(itemType, content, timestamp)
    timestamp = timestamp or os.time()
    local dateKey = localDateKey(timestamp)
    if not ensureDirectory(HISTORY_ROOT) or not ensureDirectory(historyDayDirectory(dateKey)) then return false end
    -- Daily cleanup runs at startup and on the first copy observed each date.
    local records = readDayHistory(dateKey)
    local record = {type=itemType, ts=timestamp, id=nextRecordId(dateKey)}
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
    -- The caller builds its cache entry from the persisted record, so the
    -- in-memory entry carries the same id, dateKey, and sourceKey as a record
    -- read back from disk.
    return true, record.imagePath, record
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

-- One-time backfill of record ids for daily indexes written before ids existed.
-- Only files that actually change are rewritten, the previous file is kept as a
-- backup, and the write is atomic. Duplicate ids inside a file are re-assigned
-- so the identity stays one-per-record. Pinned storage is never touched: it is
-- not a valid date directory, and pinned ids are assigned by the pin action.
local function migrateDailyHistoryIndexes()
    local assigned, rewritten, failures = 0, 0, 0
    for _, dateKey in ipairs(historyDateDirectories()) do
        local records = readDayHistory(dateKey)
        local seen, changed = {}, false
        for _, record in ipairs(records) do
            if type(record) == "table" and (type(record.id) ~= "string" or record.id == "" or seen[record.id]) then
                local id
                repeat id = nextRecordId(dateKey) until not seen[id]
                record.id = id
                changed = true
                assigned = assigned + 1
            end
            if type(record) == "table" then seen[record.id] = true end
        end
        if changed then
            local path = historyJSONPath(dateKey)
            if not copyFileContents(path, path .. ".pre-migration.bak") then
                logger.w("Unable to back up the clipboard history index for " .. tostring(dateKey))
            end
            if writeDayHistory(dateKey, records) then
                rewritten = rewritten + 1
            else
                failures = failures + 1
                logger.e("Clipboard history id migration failed for " .. tostring(dateKey) .. "; the file is unchanged")
            end
        end
    end
    if assigned > 0 then
        logger.i(string.format("Assigned ids to %d clipboard history records across %d daily indexes", assigned, rewritten))
    end
    return assigned, rewritten, failures
end

local function trimHistoryCache(limit)
    limit=tonumber(limit) or CLIPBOARD_CACHE_SIZE
    while (#text_clipboard_history+#img_clipboard_history)>limit do
        local t,i=text_clipboard_history[1],img_clipboard_history[1]
        if i and (not t or (tonumber(i.ts) or 0)<=(tonumber(t.ts) or 0)) then table.remove(img_clipboard_history,1)
        elseif t then table.remove(text_clipboard_history,1) else break end
    end
end

-- identity distinguishes records that share a timestamp and type, so pin
-- deduplication and the pinned marker cannot confuse two distinct items. A
-- record's own id is the preferred identity because it survives a rewrite of
-- the daily index; the caller-supplied file position is only the fallback for
-- records written before ids existed.
local function metadataEntry(record,dateKey,identity)
 local ts=tonumber(record and record.ts); if not ts then return nil end
 local dayKey=type(dateKey)=="string" and dateKey or localDateKey(ts)
 local hasId=type(record.id)=="string" and record.id~=""
 local identityPart=hasId and record.id or tostring(identity or "")
 local e={type=record.type,ts=ts,rowTs=ts,dateKey=dayKey,sourceKey=tostring(dayKey)..":"..tostring(ts)..":"..tostring(record.type)..":"..identityPart}
 if hasId then e.id=record.id end
 if record.type=="text" and type(record.content)=="string" then e.content=record.content; e.data=record.content
 elseif record.type=="image" and type(record.imagePath)=="string" then e.imagePath=record.imagePath; e.thumbnailPath=type(record.thumbnailPath)=="string" and record.thumbnailPath or nil; e.thumbnailData=type(record.thumbnailData)=="string" and record.thumbnailData or ""
 else return nil end
 return e
end

-- Pinned storage: records are read through the same metadataEntry()
-- transformation as ordinary history, so search, hydration, rendering,
-- preview, copy, paste, and cleanup logic stay shared between collections.
local function readPinnedHistoryRaw()
    if not ensurePinnedStorage() then return nil end
    local file = io.open(PINNED_HISTORY_PATH, "rb")
    if not file then return nil end
    local raw = file:read("*a")
    file:close()
    return raw
end

-- Returns nil (never an empty array) when the stored index cannot be decoded,
-- so callers can distinguish "no pins" from "damaged pin data".
local function decodePinnedRecords(raw)
    if not raw or raw == "" then return {} end
    local ok, records = pcall(json.decode, raw)
    if not ok or type(records) ~= "table" then
        logger.e("Invalid pinned history JSON; the existing file is preserved for recovery")
        return nil
    end
    return records
end

local function readPinnedHistory()
    return decodePinnedRecords(readPinnedHistoryRaw()) or {}
end

local function writePinnedHistory(records)
    if not ensurePinnedStorage() then return false end
    local ok, data = pcall(json.encode, records, true)
    return ok and type(data) == "string" and atomicWrite(PINNED_HISTORY_PATH, data) or false
end

-- Pinned file removal must never reach ordinary history files.
local function pathIsUnderPinned(path)
    return type(path) == "string" and path ~= ""
        and (path == PINNED_ROOT or path:sub(1, #PINNED_ROOT + 1) == PINNED_ROOT .. "/")
end

local function removePinnedFile(path)
    if not pathIsUnderPinned(path) then
        if type(path) == "string" and path ~= "" then
            logger.w("Refusing to remove a pinned file outside the pinned root")
        end
        return false
    end
    os.remove(path)
    return true
end

-- Maps an ordinary record identity to the pinned record id, so the ordinary
-- view can mark the record and offer Unpin without reading the pinned index per
-- card. Keys are, in preference order: the source record's own id (`sourceId`,
-- exact and stable across a daily-index rewrite), the source record's sourceKey,
-- and the legacy 3-part sourceKey prefix recorded by older builds.
local pinnedSourceKeyCache = nil
-- The All scope renders one stream over ordinary history and pinned records.
-- Its cursor lives next to the pinned index it depends on, because any pin,
-- unpin, clear, or session reset must rebuild that stream from the start.
local allStreamState = nil
local function resetAllStreamState()
    allStreamState = nil
end
local function invalidatePinnedIndex()
    pinnedSourceKeyCache = nil
    -- The All result set contains pinned records, so any pin/unpin/clear change
    -- invalidates its search cache and its stream cursor too.
    allSearchCache = nil
    resetAllStreamState()
end
local function pinnedSourceKeyIndex()
    if pinnedSourceKeyCache then return pinnedSourceKeyCache end
    local exact, legacy = {}, {}
    for _, record in ipairs(readPinnedHistory()) do
        if type(record) == "table" and type(record.id) == "string" and record.id ~= "" then
            local pinId = record.id
            if type(record.sourceId) == "string" and record.sourceId ~= "" then
                exact[record.sourceId] = pinId
            end
            if type(record.sourceKey) == "string" and record.sourceKey ~= "" then
                -- A 3-part sourceKey was written before the record-identity
                -- suffix existed, so it can only be matched on its leading
                -- parts. A full 4-part key is never widened to a prefix: that
                -- prefix would fold away every other record captured in the
                -- same second with the same type.
                local _, colons = record.sourceKey:gsub(":", "")
                if colons < 3 then
                    local leading = record.sourceKey:match("^(.-):[^:]*$")
                    if leading then legacy[leading] = pinId end
                else
                    exact[record.sourceKey] = pinId
                end
            end
        end
    end
    pinnedSourceKeyCache = { exact = exact, legacy = legacy }
    return pinnedSourceKeyCache
end

-- The pinned record id for an ordinary record, or nil. `sourceId` is the exact
-- join key for pins created after record ids existed; a full sourceKey is exact
-- for pins created with one, and a 3-part legacy sourceKey is matched on its
-- leading parts.
local function pinnedIdForEntry(entry)
    if not entry then return nil end
    local index = pinnedSourceKeyIndex()
    if type(entry.id) == "string" and entry.id ~= "" then
        local id = index.exact[entry.id]
        if id ~= nil then return id end
    end
    if type(entry.sourceKey) ~= "string" then return nil end
    local id = index.exact[entry.sourceKey]
    if id ~= nil then return id end
    local _, colons = entry.sourceKey:gsub(":", "")
    if colons >= 3 then
        local leading = entry.sourceKey:match("^(.-):[^:]*$")
        if leading then return index.legacy[leading] end
    end
    return nil
end

-- Effective pinned state for one card render: a pinned entry carries it
-- directly, and an ordinary record is pinned when the pinned index links to its
-- identity. Computed per render and never written back to the entry: the same
-- metadata entry object is shared by the history caches, so mutating it here
-- keeps a stale pin marker on the card after an Unpin.
local function effectivePinnedId(entry)
    if entry and entry.isPinned and type(entry.id) == "string" then return entry.id end
    return pinnedIdForEntry(entry)
end

local function pinnedRecordMatchesEntry(record, entry)
    if type(record) ~= "table" or type(entry) ~= "table" then return false end
    -- A card's own pin id, which is how a pinned entry and a pinned record
    -- compare directly. The two id namespaces never collide: an ordinary record
    -- id is prefixed with its date key, a pin id is not.
    if type(entry.id) == "string" and record.id == entry.id then return true end
    -- An ordinary record identified by the id its pin recorded.
    if type(entry.id) == "string" and entry.id ~= "" and record.sourceId == entry.id then return true end
    if type(record.sourceKey) ~= "string" or type(entry.sourceKey) ~= "string" then return false end
    if record.sourceKey == entry.sourceKey then return true end
    return record.sourceKey == entry.sourceKey:match("^(.-):[^:]*$")
end

-- Legacy text pins kept their payload in a per-item .txt file referenced by
-- contentPath. Current pins store the text in the record's content field.
local function legacyPinnedTextPayload(contentPath)
    local file = io.open(contentPath, "rb")
    if not file then return nil, false end
    local payload = file:read("*a")
    file:close()
    if type(payload) ~= "string" then return nil, false end
    return payload, true
end

-- Convert any pinned record (current or legacy) into the ordinary history
-- record shape, carrying the pin-only fields through unchanged.
local function pinnedRecordFields(record)
    local fields = {
        type = record.type,
        ts = tonumber(record.ts),
        id = record.id,
        pinnedAt = record.pinnedAt,
        sourceKey = record.sourceKey,
    }
    if record.type == "text" then
        if type(record.content) == "string" then
            fields.content = record.content
        elseif type(record.contentPath) == "string" then
            local payload, available = legacyPinnedTextPayload(record.contentPath)
            fields.content = available and payload or ""
            -- Keep the legacy reference when its file is missing so a later
            -- reload can recover the payload instead of losing the record.
            if not available then fields.contentPath = record.contentPath end
        end
    elseif record.type == "image" then
        fields.imagePath = record.imagePath
        fields.thumbnailPath = record.thumbnailPath
        fields.thumbnailData = record.thumbnailData
    end
    return fields
end

local function pinnedMetadata(record)
    if type(record) ~= "table" then return nil end
    local entry = metadataEntry(pinnedRecordFields(record), nil, record.id)
    if not entry then return nil end
    entry.isPinned = true
    entry.pinnedAt = tonumber(record.pinnedAt) or entry.ts
    -- The ordinary file path a pin was copied from, used only as a content
    -- identity when matching a pin back to its ordinary record.
    if type(record.sourcePath) == "string" then entry.sourcePath = record.sourcePath end
    if type(record.id) == "string" then
        entry.id = record.id
    else
        -- Stable identity for records written before identifiers existed.
        entry.id = "pin-" .. tostring(entry.ts) .. "-" .. tostring(record.type)
            .. "-" .. tostring(record.contentPath or record.imagePath or "")
    end
    return entry
end

local function loadPinnedEntries()
    local out = {}
    for _, record in ipairs(readPinnedHistory()) do
        local entry = pinnedMetadata(record)
        if entry then out[#out + 1] = entry end
    end
    table.sort(out, function(a, b)
        if a.pinnedAt == b.pinnedAt then return a.ts > b.ts end
        return a.pinnedAt > b.pinnedAt
    end)
    return out
end

-- Pinned text is stored in the JSON record, so the common case needs no disk
-- hydration at all. The legacy per-item file path remains supported.
local function hydratePinnedEntry(entry)
    if not entry or not entry.isPinned then return entry end
    if entry.type == "text" then
        if type(entry.content) == "string" then
            entry.data = entry.content
            return entry
        end
        if type(entry.contentPath) == "string" then
            local payload, available = legacyPinnedTextPayload(entry.contentPath)
            if available then
                entry.content = payload
                entry.data = payload
                return entry
            end
        end
        logger.w("Pinned text payload is unavailable for this record")
        return nil
    end
    return entry
end

-- Identity helpers shared by the pinned marker, the unified All stream, and the
-- migration that links a pinned record back to its source record. They are
-- declared here because the pinned paths below need them; the All aggregation
-- and rendering code reuses the same rules.

-- Stable card identity: a record id, then a sourceKey, then the timestamp and
-- type. The fallback is deliberately last because a timestamp alone cannot
-- separate two distinct records captured in the same second.
local function unifiedIdentity(entry)
    if type(entry.id) == "string" then return entry.id end
    if type(entry.sourceKey) == "string" then return entry.sourceKey end
    return tostring(entry.ts) .. ":" .. tostring(entry.type)
end

-- Content identity used when matching a pin back to its ordinary record. It
-- always carries the payload (text length + text, or the image file name)
-- beside ts, so the timestamp alone never merges two events. This is the
-- fallback rule: a record id, when present, is the exact key. It is needed
-- because a daily index can be rebuilt, which shifts the file-position part of
-- sourceKey, and because pins created before record ids existed recorded no
-- source identity at all.
local function unifiedPayloadKey(entry)
    if entry.type == "text" then
        local payload = entry.content or entry.data
        if type(payload) ~= "string" then return nil end
        return "text:" .. tostring(entry.ts) .. ":" .. tostring(#payload) .. ":" .. payload
    end
    if entry.type == "image" then
        local path = entry.sourcePath or entry.imagePath
        local name = type(path) == "string" and path:match("([^/]+)$")
        if type(name) == "string" and name ~= "" then
            return "image:" .. tostring(entry.ts) .. ":" .. name
        end
    end
    return nil
end

local function pinClipboardEntry(entry)
    if not entry or (entry.type ~= "text" and entry.type ~= "image") or entry.isPinned then return false end
    if not ensurePinnedStorage() then return false end
    local records = readPinnedHistory()
    for _, record in ipairs(records) do
        if pinnedRecordMatchesEntry(record, entry) then invalidatePinnedIndex(); return true end
    end
    local id = tostring(math.floor(hs.timer.secondsSinceEpoch() * 1000000)) .. "-" .. tostring(#records + 1)
    local record = {
        id = id,
        type = entry.type,
        ts = tonumber(entry.ts or entry.rowTs) or os.time(),
        pinnedAt = os.time(),
        sourceKey = entry.sourceKey,
        -- The source record's own id is the exact, stable join key. sourceKey
        -- stays for readers that predate record ids.
        sourceId = type(entry.id) == "string" and entry.id ~= "" and entry.id or nil,
    }
    if entry.type == "text" then
        local payload = entry.content or entry.data
        if type(payload) ~= "string" then
            logger.e("Unable to pin a text record whose content is not loaded")
            return false
        end
        -- Same as ordinary history: the full text lives in the JSON record.
        record.content = payload
    else
        if type(entry.imagePath) ~= "string" or not fs.attributes(entry.imagePath) then
            logger.e("Unable to pin an image whose source file is missing")
            return false
        end
        record.sourcePath = entry.imagePath
        record.imagePath = PINNED_IMAGE_ROOT .. "/" .. id .. ".png"
        if not copyPinnedFile(entry.imagePath, record.imagePath) then
            logger.e("Pinned image copy failed: " .. tostring(entry.imagePath))
            removePinnedFile(record.imagePath)
            return false
        end
        if type(entry.thumbnailPath) == "string" and fs.attributes(entry.thumbnailPath) then
            local extension = entry.thumbnailPath:match("%.([%w]+)$") or "jpg"
            record.thumbnailPath = PINNED_THUMBNAIL_ROOT .. "/" .. id .. "." .. extension
            if not copyPinnedFile(entry.thumbnailPath, record.thumbnailPath) then
                record.thumbnailPath = nil
            end
        end
    end
    records[#records + 1] = record
    if not writePinnedHistory(records) then
        removePinnedFile(record.imagePath)
        removePinnedFile(record.thumbnailPath)
        logger.e("Unable to persist the pinned history index")
        return false
    end
    invalidatePinnedIndex()
    return true
end

local function unpinClipboardEntry(entry)
    if not entry then return false end
    local kept, removedRecords = {}, {}
    for _, record in ipairs(readPinnedHistory()) do
        if pinnedRecordMatchesEntry(record, entry) then
            removedRecords[#removedRecords + 1] = record
        else
            kept[#kept + 1] = record
        end
    end
    if #removedRecords == 0 then return false end
    if not writePinnedHistory(kept) then
        logger.e("Unable to persist the pinned history index after unpin")
        return false
    end
    -- Only pinned-owned files are removed; the ordinary source record and its
    -- files are untouched by design.
    for _, record in ipairs(removedRecords) do
        removePinnedFile(record.contentPath)
        removePinnedFile(record.imagePath)
        removePinnedFile(record.thumbnailPath)
    end
    invalidatePinnedIndex()
    return true
end

-- Maps a payload identity to the ordinary record id, so a pinned record that
-- recorded no source key at all (a pin created from a live in-memory entry)
-- can be linked to the record it was pinned from.
local function ordinaryPayloadIdIndex()
    local index = {}
    for _, dateKey in ipairs(historyDateDirectories()) do
        for _, record in ipairs(readDayHistory(dateKey)) do
            if type(record) == "table" and type(record.id) == "string" and record.id ~= "" then
                local entry = metadataEntry(record, dateKey, record.id)
                local key = entry and unifiedPayloadKey(entry)
                if key and index[key] == nil then index[key] = record.id end
            end
        end
    end
    return index
end

-- One-time conversion of legacy pinned records into the ordinary record shape.
-- The migrated index is written atomically before any legacy payload file is
-- removed, and a pre-migration backup is kept.
local function migratePinnedHistory()
    local raw = readPinnedHistoryRaw()
    if not raw or raw == "" then return false end
    local records = decodePinnedRecords(raw)
    if not records then
        logger.e("Pinned history migration skipped: the pinned JSON could not be decoded")
        return false
    end
    local migrated, legacyFiles, changes = {}, {}, 0
    local payloadIds = nil
    for index, record in ipairs(records) do
        if type(record) ~= "table" then
            changes = changes + 1
            logger.w("Removed a non-table entry from the pinned index during migration")
        else
            local migratedRecord = {}
            for key, value in pairs(record) do migratedRecord[key] = value end
            if migratedRecord.type == "text" and type(migratedRecord.content) ~= "string"
                and type(migratedRecord.contentPath) == "string" then
                local payload, available = legacyPinnedTextPayload(migratedRecord.contentPath)
                if available then
                    migratedRecord.content = payload
                    legacyFiles[#legacyFiles + 1] = migratedRecord.contentPath
                    migratedRecord.contentPath = nil
                else
                    -- Preserve the record and its reference: an unavailable
                    -- payload must not delete data that may become readable.
                    migratedRecord.content = ""
                    logger.w("Pinned text payload file is missing; the record was preserved")
                end
                changes = changes + 1
            end
            if type(migratedRecord.id) ~= "string" then
                migratedRecord.id = "pin-" .. tostring(migratedRecord.ts or 0) .. "-"
                    .. tostring(migratedRecord.type) .. "-" .. tostring(index)
                changes = changes + 1
            end
            if type(migratedRecord.pinnedAt) ~= "number" then
                migratedRecord.pinnedAt = tonumber(migratedRecord.ts) or os.time()
                changes = changes + 1
            end
            -- A pin created from a live in-memory entry recorded no source
            -- identity, so it could never be matched back to its ordinary
            -- record. Link it now, by payload identity, to the source id.
            if type(migratedRecord.sourceId) ~= "string" and type(migratedRecord.sourceKey) ~= "string" then
                payloadIds = payloadIds or ordinaryPayloadIdIndex()
                local pinnedEntry = pinnedMetadata(migratedRecord)
                local key = pinnedEntry and unifiedPayloadKey(pinnedEntry)
                local sourceId = key and payloadIds[key]
                if type(sourceId) == "string" and sourceId ~= "" then
                    migratedRecord.sourceId = sourceId
                    changes = changes + 1
                end
            end
            if type(migratedRecord.imagePath) == "string" and not fs.attributes(migratedRecord.imagePath) then
                logger.w("Pinned image file is missing; the record and metadata were preserved")
            end
            migrated[#migrated + 1] = migratedRecord
        end
    end
    if changes == 0 then return false end
    copyPinnedFile(PINNED_HISTORY_PATH, PINNED_MIGRATION_BACKUP_PATH)
    if not writePinnedHistory(migrated) then
        logger.e("Pinned history migration failed; the previous index and payload files are unchanged")
        return false
    end
    for _, path in ipairs(legacyFiles) do removePinnedFile(path) end
    invalidatePinnedIndex()
    collectgarbage("collect")
    logger.i("Migrated pinned history to the ordinary history record schema")
    return true
end

-- Shared hydration entry point: pinned text is already stored in the record,
-- so only legacy pinned payload files need a disk read here.
local function hydrateEntry(entry)
    if not entry then return nil end
    if entry.isPinned then return hydratePinnedEntry(entry) end
    return entry
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
        -- Keep each record's file position as its identity, then order the
        -- pairs newest-first. Sorting records alone would renumber identities.
        local ordered={}
        for index,record in ipairs(records) do
            ordered[#ordered+1]={record=record,index=index}
        end
        table.sort(ordered,function(a,b)return (tonumber(a.record.ts) or 0)>(tonumber(b.record.ts) or 0) end)
        for _,item in ipairs(ordered) do
            local entry=metadataEntry(item.record,dateKey,item.index)
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

    -- Avoid keeping the source NSImage, its bitmap, and its thumbnail alive
    -- through nested closure scopes. The thumbnail returned here is at most
    -- 112 px on its longest side.
    local ok, result = pcall(function()
        local size = original:size()
        local width = tonumber(size and size.w) or 0
        local height = tonumber(size and size.h) or 0
        if width <= 0 or height <= 0 then return nil end
        if width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION then
            logger.w(string.format("Skipping thumbnail for unusually large image (%dx%d)", width, height))
            return nil
        end
        local scale = math.min(1, THUMBNAIL_MAX_DIMENSION / width, THUMBNAIL_MAX_DIMENSION / height)
        local thumbnail = original:bitmapRepresentation({
            w = math.max(1, math.floor(width * scale + 0.5)),
            h = math.max(1, math.floor(height * scale + 0.5))
        })
        return thumbnail
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
    selectedClipboardUids = {}
    if fs.attributes(PINNED_ROOT) then
        local function rmTree(p) local a=fs.attributes(p); if not a then return end; if a.mode=="directory" then for c in fs.dir(p) do if c~="." and c~=".." then rmTree(p.."/"..c) end end; os.remove(p) else os.remove(p) end end
        rmTree(PINNED_ROOT)
    end
    ensurePinnedStorage(); writePinnedHistory({}); invalidatePinnedIndex(); clipboardPinnedFilter=false
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
    clipboardPinnedFilter=false
    -- Clear All emptied both collections, so no session result may survive it:
    -- drop the ordinary page, the date pages, the ordinary search cache, and the
    -- unified All cache together.
    dateHistoryCache = {}
    allHistoryCache = {}
    allHistoryCacheLoaded = 0
    allHistoryTotalCount = nil
    searchResultsCache = nil
    allSearchCache = nil
    visibleIndices = {}
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
        local ok,_,record=persistClipboardEntry("text",item,ts)
        -- Build the in-memory entry through the same metadataEntry() path as a
        -- record read back from disk, so a live capture carries the same id,
        -- dateKey, and sourceKey. Entries without that identity could not be
        -- matched to a pinned record, which left the newest cards unmarked.
        local entry=ok and metadataEntry(record,localDateKey(ts),record and record.id) or nil
        if entry then insertCacheEntry(entry) end
        return
    end

    -- Hammerspoon may deliver rapid duplicate callbacks for one screenshot.
    -- Ignore re-entry while the current image is being saved and thumbnailed.
    if imageCaptureInProgress then
        logger.i("Skipping overlapping clipboard image capture while processing is in progress")
        item = nil
        collectgarbage("collect")
        return
    end
    imageCaptureInProgress = true
    imageProcessingCount = imageProcessingCount + 1

    local ok,err=pcall(function()
        local dateKey=localDateKey(ts)
        local imagePath=saveImageFile(dateKey,item,ts)
        if not imagePath then logger.e("Clipboard image could not be saved"); return end

        -- Persist only a small thumbnail. Drop intermediate native bitmap
        -- references immediately so the autorelease/GC cycle can reclaim them.
        local thumbnailImage = makeThumbnailImage(item)
        local thumbnailPath = thumbnailImage and saveThumbnailFile(dateKey, imagePath, thumbnailImage, ts) or nil
        thumbnailImage = nil

        local records=readDayHistory(dateKey)
        local record={type="image",ts=ts,id=nextRecordId(dateKey),imagePath=imagePath,thumbnailPath=thumbnailPath}
        records[#records+1]=record
        if not writeDayHistory(dateKey,records) then
            if thumbnailPath then os.remove(thumbnailPath) end
            os.remove(imagePath)
            logger.e("Clipboard image record could not be persisted")
            return
        end
        -- Same identity as the persisted record; see the text path above.
        local entry=metadataEntry(record,dateKey,record.id)
        if entry then insertCacheEntry(entry) end
    end)

    -- Do not retain the full-resolution NSImage on any Lua table. The history
    -- stores only file paths and a disk-backed thumbnail. Release the callback
    -- reference and force Lua collection after leaving the protected block.
    item = nil
    imageCaptureInProgress = false
    imageProcessingCount = math.max(0,imageProcessingCount-1)
    collectgarbage("collect")
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
local TEXT_PREVIEW_MAX_LINES = 30

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
            for index,record in ipairs(readDayHistory(dateKey)) do
                local entry=metadataEntry(record,dateKey,index)
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
            for index,record in ipairs(readDayHistory(dateKey)) do
                local entry=metadataEntry(record,dateKey,index)
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
        for index,record in ipairs(readDayHistory(dateKey)) do
            local entry=metadataEntry(record,dateKey,index)
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
        for index,record in ipairs(readDayHistory(dateKey)) do
            local entry=metadataEntry(record,dateKey,index)
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

-- Image pixels contain no searchable text. Match the type marker, timestamp,
-- and the pinned file names that are available as metadata.
local function pinnedSearchValue(entry)
    if entry.type=="text" then return tostring(entry.content or entry.data or "") end
    local name=tostring(entry.imagePath or ""):match("([^/]+)$") or ""
    return "[image] "..name
end

-- Search the entire pinned collection with the same case-insensitive plain
-- substring semantics as ordinary history. Never uses an ordinary-history
-- search cache and never depends on the rendered page.
local function searchPinnedHistory(query,kind)
    local out={}
    if kind=="none" then return out end
    local needle=string.lower(tostring(query or ""))
    for _,entry in ipairs(loadPinnedEntries()) do
        if not kind or kind=="all" or entry.type==kind then
            local stamp=os.date("%Y-%m-%d %H:%M:%S",entry.ts)
            if needle=="" or string.lower(pinnedSearchValue(entry).." "..stamp):find(needle,1,true) then
                out[#out+1]=entry
            end
        end
    end
    return out
end

local function sortUnifiedEntries(entries)
    table.sort(entries, function(a, b)
        if a.ts ~= b.ts then return a.ts > b.ts end
        return unifiedIdentity(a) < unifiedIdentity(b)
    end)
    return entries
end

-- The rules in unifiedIdentity() and unifiedPayloadKey() (declared with the
-- pinned helpers, above) are what the merge below uses: a pinned record and the
-- ordinary record it was pinned from are one clipboard event, so the ordinary
-- copy is dropped and the pinned copy is kept - its card keeps the pin marker
-- and the Unpin action. The payload identity is what makes the fold stable when
-- a daily index is rebuilt and the file-position part of sourceKey shifts.
local function unifiedPayloadKeys(pinnedEntries)
    local keys = {}
    for _, entry in ipairs(pinnedEntries) do
        local key = unifiedPayloadKey(entry)
        if key then keys[key] = true end
    end
    return keys
end

local function unifiedIsDuplicate(entry, payloadKeys)
    local key = unifiedPayloadKey(entry)
    if key then return payloadKeys[key] == true end
    -- A record whose payload is unavailable has no content identity; the
    -- sourceKey index is then the only reliable handle.
    return pinnedIdForEntry(entry) ~= nil
end

local function mergeUnifiedEntries(ordinaryEntries, pinnedEntries)
    local payloadKeys = unifiedPayloadKeys(pinnedEntries)
    local out = {}
    for _, entry in ipairs(pinnedEntries) do out[#out + 1] = entry end
    for _, entry in ipairs(ordinaryEntries) do
        if not unifiedIsDuplicate(entry, payloadKeys) then out[#out + 1] = entry end
    end
    return sortUnifiedEntries(out)
end

local function pinnedEntriesForKind(kind)
    local out = {}
    for _, entry in ipairs(loadPinnedEntries()) do
        if not kind or kind == "all" or entry.type == kind then out[#out + 1] = entry end
    end
    return out
end

-- All with no query: one stream over ordinary history and pinned records,
-- ordered strictly by clipboard timestamp, newest first. Pagination walks the
-- merged stream rather than the ordinary side alone, so a pinned event sits at
-- its own timestamp: it never clumps at the bottom of a page, and it is not
-- rendered a second time when the page holding its ordinary twin arrives. The
-- cursor is append-only, which is what makes appending a Load-more page to the
-- DOM safe: every event is emitted once and stays where its timestamp puts it.
local function unifiedIsNewer(a, b)
    if a.ts ~= b.ts then return a.ts > b.ts end
    -- On an exact timestamp tie the pinned copy takes the position, so the card
    -- keeps the pin marker and Unpin; identity breaks any remaining tie.
    local aPinned = a.isPinned == true
    local bPinned = b.isPinned == true
    if aPinned ~= bPinned then return aPinned end
    return tostring(unifiedIdentity(a)) < tostring(unifiedIdentity(b))
end

local function extendAllStream(requiredCount)
    requiredCount = math.max(CLIPBOARD_RENDER_BATCH_SIZE, tonumber(requiredCount) or CLIPBOARD_RENDER_BATCH_SIZE)
    local state = allStreamState
    if not state then
        local pins = pinnedEntriesForKind("all")
        table.sort(pins, unifiedIsNewer)
        state = {
            entries = {},
            pinEntries = pins,
            pinPayloadKeys = unifiedPayloadKeys(pins),
            emittedIds = {},
            emittedPayloadKeys = {},
            ordinaryOffset = 0,
            pinnedOffset = 1,
            exhausted = false,
        }
        allStreamState = state
    end

    -- A record already in the stream. Identity first, then payload: the same
    -- capture can reach the stream twice with different sourceKey values, once
    -- from the session cache and once from the daily index page.
    local function isEmitted(entry)
        local id = type(entry.id) == "string" and entry.id or nil
        if id and state.emittedIds[id] then return true end
        local key = unifiedPayloadKey(entry)
        return key ~= nil and state.emittedPayloadKeys[key] == true
    end
    local function markEmitted(entry)
        local id = type(entry.id) == "string" and entry.id or nil
        if id then state.emittedIds[id] = true end
        local key = unifiedPayloadKey(entry)
        if key then state.emittedPayloadKeys[key] = true end
    end
    -- The pinned copy represents its ordinary twin, so the twin is dropped and
    -- the pinned record is the card. Identity (`sourceId`) is exact; the payload
    -- key covers pins created before record ids existed.
    local function ordinaryHasPinTwin(ordinary)
        if pinnedIdForEntry(ordinary) ~= nil then return true end
        local key = unifiedPayloadKey(ordinary)
        return key ~= nil and state.pinPayloadKeys[key] == true
    end
    local function pinTwinAlreadyEmitted(pin)
        if type(pin.sourceId) == "string" and state.emittedIds[pin.sourceId] then return true end
        local key = unifiedPayloadKey(pin)
        return key ~= nil and state.emittedPayloadKeys[key] == true
    end

    while #state.entries < requiredCount and not state.exhausted do
        local before = #state.entries
        local _, loaded = ensureAllHistoryCache(state.ordinaryOffset + CLIPBOARD_RENDER_BATCH_SIZE)
        local ordinaryDone = allHistoryTotalCount ~= nil and allHistoryCacheLoaded >= allHistoryTotalCount
        while #state.entries < requiredCount do
            -- Peek, never consume: the next ordinary record is advanced past
            -- only when it is emitted as a card or folded by its pinned twin.
            -- Reading it here and then letting a pinned record take the position
            -- dropped the ordinary event on the floor, so one clipboard event
            -- vanished from the All collection.
            local ordinary = nil
            while ordinary == nil and state.ordinaryOffset < loaded do
                local candidate = allHistoryCache[state.ordinaryOffset + 1]
                if candidate == nil then
                    state.ordinaryOffset = state.ordinaryOffset + 1
                else
                    ordinary = candidate
                end
            end
            if ordinary ~= nil and (isEmitted(ordinary) or ordinaryHasPinTwin(ordinary)) then
                -- Its pinned copy is the card, or it is already in the stream.
                state.ordinaryOffset = state.ordinaryOffset + 1
                ordinary = nil
            end
            local pin = state.pinEntries[state.pinnedOffset]
            if ordinary ~= nil and pin ~= nil and unifiedIsNewer(ordinary, pin) then
                state.ordinaryOffset = state.ordinaryOffset + 1
                markEmitted(ordinary)
                state.entries[#state.entries + 1] = ordinary
            elseif pin ~= nil and not pinTwinAlreadyEmitted(pin) then
                markEmitted(pin)
                state.pinnedOffset = state.pinnedOffset + 1
                state.entries[#state.entries + 1] = pin
            elseif ordinary ~= nil then
                state.ordinaryOffset = state.ordinaryOffset + 1
                markEmitted(ordinary)
                state.entries[#state.entries + 1] = ordinary
            elseif pin ~= nil then
                -- A pinned record whose twin was already emitted: no card.
                state.pinnedOffset = state.pinnedOffset + 1
            else
                -- This ordinary page is consumed; the outer loop grows it, and
                -- exhaustion is only claimed when the disk side is finished.
                if ordinaryDone then state.exhausted = true end
                break
            end
        end
        if #state.entries == before and not state.exhausted then
            -- No progress is possible: the ordinary side cannot grow and no
            -- pinned record is left.
            state.exhausted = true
        end
    end
    return state.entries, #state.entries, not state.exhausted
end

-- The panel-open path and the All branch of updateClipboardPanel must present
-- the same collection, so both build their first page here. Rendering the
-- ordinary cache straight from showClipboardPanel() skipped every pinned record,
-- and therefore every pin marker, on the first paint.
local function openAllPanelPage(requiredCount)
    resetAllStreamState()
    local entries = extendAllStream(requiredCount or CLIPBOARD_RENDER_BATCH_SIZE)
    menuData = entries
    browseCursor = #entries
    browseMode = "all"
    return entries
end

-- All with a query: merge both collections' full-content search results and
-- cache them as the All collection, keyed by query and content type.
local function unifiedSearchEntries(ordinaryEntries, query, kind)
    if allSearchCache and allSearchCache.query == query and allSearchCache.kind == kind then
        return allSearchCache.entries
    end
    local merged = mergeUnifiedEntries(ordinaryEntries, searchPinnedHistory(query, kind))
    allSearchCache = { collection = "all", query = query, kind = kind, entries = merged }
    return merged
end

-- The data-uid of a card: the pinned record id while the event is pinned, the
-- record identity otherwise. The renderer and the append guard must agree, so
-- both read this one function.
local function cardUid(entry)
    local pinnedId = effectivePinnedId(entry)
    if pinnedId ~= nil then return tostring(pinnedId) end
    return tostring(unifiedIdentity(entry))
end

local function historyItemHTML(entry, index)
    -- The pin marker is resolved for this render only. Cached metadata entries
    -- are shared by the history caches, so writing the pin state onto the entry
    -- here would leave a stale marker on the card after an Unpin.
    local pinnedId = effectivePinnedId(entry)
    local cardIsPinned = pinnedId ~= nil
    -- Pinned cards carry a corner marker while the type label and the original
    -- clipboard timestamp stay unchanged. pointer-events:none keeps the marker
    -- out of the way of click-to-paste, keyboard selection, and the context menu.
    local pinMark = cardIsPinned and
        '<div class="pin-mark" aria-label="Pinned">📍</div>' or ''
    local stamp = os.date("%Y-%m-%d %H:%M:%S", entry.rowTs or os.time())
    -- data-uid is the stable identity used to reconcile keyboard navigation and
    -- an open context menu after the list is rebuilt (search, scope change,
    -- pin/unpin, load more). A pinned event keeps the pinned record id, so the
    -- marker, the menu, and the keyboard focus survive the fold of a pinned pair.
    local uid = escapeHTML(cardUid(entry))
    if entry.type == "image" then
        local imageEntry=entry.historyEntry or entry
        local thumbnail=thumbnailForEntry(imageEntry)
        local preview=thumbnail~="" and ('<img class="preview" src="'..escapeHTML(thumbnail)..'" alt="Clipboard image preview" loading="lazy" decoding="async">') or '<div class="preview placeholder">Image preview unavailable</div>'
        return '<div class="item image-item" role="button" tabindex="0" data-kind="image" data-action="paste" data-index="'..index..'" data-uid="'..uid..'" data-pinned="'..tostring(cardIsPinned)..'" data-search="'..escapeHTML(string.lower("[image] "..stamp))..'">'..pinMark..'<div class="meta"><div class="kind">IMAGE</div><div class="stamp">'..escapeHTML(stamp)..'</div></div>'..preview..'</div>'
    end
    -- Pinned text is stored in the record, so it hydrates like an ordinary one.
    local loaded=hydrateEntry(entry) or entry
    local content=tostring(loaded.data or loaded.content or "")
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
        previewText = content:sub(1, stop) .. "\n… (preview truncated; use the Preview context-menu action for more)"
    end
    -- Search is performed in Lua. Do not copy the entire clipboard payload into
    -- a DOM attribute; large copied documents otherwise multiply the WebView DOM.
    return '<button class="item text-item" data-kind="text" data-action="paste" data-index="' .. index .. '" data-uid="' .. uid .. '" data-pinned="'..tostring(cardIsPinned)..'" data-search="' .. escapeHTML(string.lower("[text] " .. stamp)) .. '">' ..
        pinMark .. '<div class="kind">TEXT</div><div class="stamp">' .. escapeHTML(stamp) ..
        '</div><div class="text-preview">' .. escapeHTML(previewText) ..
        '</div>' ..
        '</button>'
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
    renderedCardUids = {}
    offset = math.max(0, tonumber(offset) or 0)
    -- Render up to the configured 32-item batch from the currently loaded page.
    local batchSize = CLIPBOARD_RENDER_BATCH_SIZE
    local last = math.min(#matches, offset + batchSize)
    for position = offset + 1, last do
        local index = matches[position]
        renderedCardUids[cardUid(menuData[index])] = true
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
/* One thin rule separates the mutually exclusive scope chips (All, Pin, dates)
   from the independent content-type chips (Text, Images). */
.filter-separator { flex:0 0 1px; align-self:center; height:20px; margin:0 2px; background:var(--border); opacity:.85; }
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

main { flex:1 1 auto; min-height:0; overflow-y:auto; overflow-x:hidden; overscroll-behavior:contain; scroll-padding-block:16px; padding:16px 12px; display:flex; flex-direction:column; align-items:stretch; gap:12px; }
#clipboard-items.item-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); grid-auto-rows:min-content; gap:12px; align-items:start; align-content:start; }

/* Tab focuses the results container to enable arrow-key navigation. Keep that
   container focus invisible; individual cards retain their own focus/selection
   outlines so the blue border never wraps the entire grid. */
#clipboard-items:focus,
#clipboard-items:focus-visible {
  outline: none !important;
  box-shadow: none !important;
}
.load-more-wrap { flex:0 0 auto; width:100%; display:flex; justify-content:flex-start; }
.item { position:relative; cursor:default; }
.item, .item * { cursor:default; }
.item:hover { border-color:var(--card-border); background:var(--card-bg); }
/* This overlay lives directly under body, outside the scrolling grid and its
   stacking contexts. Its z-index intentionally exceeds the fixed header. */
body > #clipboard-preview-overlay { display:none; position:fixed; inset:0; z-index:2147483647; align-items:center; justify-content:center; padding:16px; background:rgba(0,0,0,.34); box-sizing:border-box; isolation:isolate; }
body > #clipboard-preview-overlay.open { display:flex; }
body > #clipboard-preview-overlay .manual-preview { display:none; position:relative; inset:auto; transform:none; margin:auto; width:min(720px, calc(100vw - 32px)); max-width:calc(100vw - 32px); max-height:calc(100vh - 32px); padding:16px; color:var(--panel-fg); background:var(--card-bg); border:1px solid var(--card-border); border-radius:12px; box-shadow:0 18px 48px rgba(0,0,0,.85); overflow:auto; box-sizing:border-box; flex:none; }
body > #clipboard-preview-overlay .manual-preview.open { display:block; }
#clipboard-preview-overlay .manual-preview-title { color:var(--muted); font-size:12px; margin-bottom:10px; }
#clipboard-preview-overlay .manual-preview-content { max-height:calc(100vh - 96px); overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; word-break:break-word; font-size:14px; line-height:1.55; user-select:text; }
body > #clipboard-preview-overlay .manual-preview.image-detail { display:none; width:min(1120px, calc(100vw - 32px)); height:calc(100vh - 64px); max-height:calc(100vh - 64px); padding:14px; overflow:hidden; box-sizing:border-box; }
body > #clipboard-preview-overlay .manual-preview.image-detail.open { display:flex; flex-direction:column; align-items:center; justify-content:center; }
body > #clipboard-preview-overlay .manual-preview.image-detail img { display:block; width:100%; height:100%; min-width:0; min-height:0; max-width:100%; max-height:100%; object-fit:contain; border-radius:5px; margin:0 auto; flex:1 1 auto; }
.item { font:inherit; width:100%; min-width:0; color:inherit; text-align:left; border:1px solid var(--card-border); border-radius:12px; background:var(--card-bg); padding:10px; cursor:default; overflow:hidden; }
#clipboard-items .item:focus { outline:2px solid var(--selected-border); outline-offset:2px; }
#clipboard-items .item { position:relative; margin:0; }
#clipboard-items .item.selected { z-index:1; }
.item:hover { border-color:var(--card-border); background:var(--card-bg); }
.item.selected { border-color:var(--selected-border); outline:2px solid var(--accent); outline-offset:1px; background:var(--selected-bg); }
.image-item .meta { padding-top:0; padding-bottom:9px; }
.image-item .preview { width:100%; height:160px; max-width:100%; object-fit:contain; object-position:center center; display:block; background:var(--control-bg); border-radius:7px; }
.image-item .preview { aspect-ratio:auto; }
.image-item .preview:not([src]), .image-item .preview[src=""] { object-fit:contain; }
.text-preview { overflow-wrap:anywhere; word-break:break-word; }
.preview.placeholder { display:flex; align-items:center; justify-content:center; color:var(--muted); }
.meta { padding:9px 2px 1px; }
.kind { font-size:10px; letter-spacing:.12em; color:var(--accent); font-weight:700; }
/* Pinned cards carry a corner marker beside the type label. It is decorative
   and click-through, so selection, click-to-paste, keyboard navigation, and the
   context menu keep working exactly as on ordinary cards. */
.pin-mark { position:absolute; top:9px; right:10px; font-size:15px; line-height:1.1; pointer-events:none; user-select:none; }
.multi-select-mark { position:absolute; left:10px; bottom:9px; width:22px; height:22px; display:flex; align-items:center; justify-content:center; border-radius:50%; background:#2878e8; color:#fff; font-size:14px; font-weight:700; line-height:1; pointer-events:none; user-select:none; box-shadow:0 1px 4px rgba(0,0,0,.35); }
.item.multi-selected .text-preview { padding-bottom:22px; }
.image-item.multi-selected .preview { margin-bottom:22px; }
.item.multi-selected { border-color:var(--selected-border); }
.stamp { color:var(--muted); font-size:11px; margin-top:5px; }
.text-preview { margin-top:10px; min-height:70px; max-height:120px; overflow:hidden; white-space:pre-wrap; overflow-wrap:anywhere; word-break:normal; font-size:13px; line-height:1.45; }
.hint { color:var(--subtle); font-size:10px; margin-top:8px; }
.empty { color:var(--muted); text-align:center; padding:40px 12px; grid-column:1/-1; }
footer { flex:0 0 auto; padding:8px 16px; color:var(--muted); background:var(--footer-bg); border-top:1px solid var(--border); font-size:11px; }
body.keyboard-mode #search { border-color:#7da6ff; }
</style></head><body>
<header><div class="top"><div class="title-actions"><h1>Clipboard History</h1><button class="action danger header-clear" data-action="clearAll">⚠️ Clear All</button><button class="action header-reload" data-action="reloadSoftware">↻ Reload</button></div><span class="count">]] .. tostring(matchingCount) .. [[ matching items</span></div>
<input id="search" placeholder="Search clipboard history here... Press Enter to search." value="]] .. escapeHTML(clipboard_search) .. [[" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" data-gramm="false">
<div class="actions">
<button class="action filter-button date-filter" data-action="dateScope" data-date-key="" aria-pressed="true">All</button>
<button class="action filter-button date-filter" data-action="pinScope" data-date-key="pinned" aria-pressed="false">📍</button>
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
end)() .. [[
<span class="filter-separator" aria-hidden="true"></span>
<button class="action filter-button type-filter" data-action="filter" data-filter="text" aria-pressed="false">Text</button>
<button class="action filter-button type-filter" data-action="filter" data-filter="image" aria-pressed="false">Images</button>
</div></header>
<main> <div id="clipboard-items" class="item-grid">]] .. initialCardsHTML .. [[</div>]] .. loadMoreHTML .. [[</main>
<footer>Tab: next result · Shift+Tab: previous result, then search · Arrow keys: select when results are focused · Click: paste · Esc: close</footer>
<script>
const bridge = (action, index, query, kind, dateKey, uid) => {
  try {
    window.webkit.messageHandlers.clipboardHistory.postMessage({
      action, index, query, kind, dateKey, uid
    });
  } catch (_) {}
};
document.addEventListener('click', event => {
  const contextItem = event.target.closest('#clipboard-context-menu');
  if (contextItem) return;
  const button = event.target.closest('[data-action]');
  if (button) {
    const action = button.dataset.action;
    const index = Number(button.dataset.index || 0);
    if (action === 'filter') { setActiveFilter(button); return; }
    if (action === 'pinScope') {
      document.querySelectorAll('.date-filter').forEach(b=>b.setAttribute('aria-pressed','false'));
      button.setAttribute('aria-pressed','true');
      // Remember the Pin scope as the pre-search scope, so clearing a query
      // returns to the pinned collection instead of All Dates.
      lastNonSearchDateKey = committedSearchQuery === '' ? null : 'pinned';
      lastNonSearchWasAllDates = false;
      bridge('pinScope',0,committedSearchQuery,currentTypeFilter()); return;
    }
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
    if (action === 'reloadSoftware') {
      bridge('reloadSoftware', index, '');
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
// Preview is a single viewport-level overlay so card stacking/overflow and the
// fixed Clipboard History header cannot cover its top edge.
const previewOverlay = document.createElement('div');
previewOverlay.id = 'clipboard-preview-overlay';
previewOverlay.innerHTML =
  '<div class="manual-preview text-detail" role="dialog" aria-modal="true" aria-label="Clipboard text preview">' +
    '<div class="manual-preview-title"></div><div class="manual-preview-content"></div></div>' +
  '<div class="manual-preview image-detail" role="dialog" aria-modal="true" aria-label="Clipboard image preview">' +
    '<img alt="Clipboard image preview" decoding="async"></div>';
document.body.appendChild(previewOverlay);
previewOverlay.style.zIndex = '2147483647';

function closeManualPreviews() {
  previewOverlay.classList.remove('open');
  previewOverlay.querySelectorAll('.manual-preview').forEach(node => node.classList.remove('open'));
}
function openManualPreview(item) {
  if (!item) return;
  closeManualPreviews();
  const index = Number(item.dataset.index || 0);
  previewOverlay.classList.add('open');
  if (item.classList.contains('image-item')) {
    const panel = previewOverlay.querySelector('.image-detail');
    const image = panel.querySelector('img');
    image.removeAttribute('src');
    image.alt = 'Loading clipboard image preview…';
    panel.classList.add('open');
    panel.dataset.index = String(index);
    panel.dataset.previewLoaded = 'false';
    bridge('loadImagePreview', index, '', 'image');
  } else {
    const panel = previewOverlay.querySelector('.text-detail');
    panel.querySelector('.manual-preview-title').textContent = 'Clipboard text · ' + (item.querySelector('.stamp')?.textContent || '');
    panel.querySelector('.manual-preview-content').textContent = 'Loading preview…';
    panel.classList.add('open');
    panel.dataset.index = String(index);
    panel.dataset.previewLoaded = 'false';
    bridge('loadTextPreview', index, '', 'text');
  }
}
window.setImagePreview = (index, src) => {
  const panel = previewOverlay.querySelector('.image-detail');
  const image = panel.querySelector('img');
  if (Number(panel.dataset.index) !== Number(index) || !src) return;
  panel.dataset.previewLoaded = 'true';
  image.src = src;
  image.alt = 'Clipboard image preview';
};
window.setPreviewError = (index, message) => {
  const imagePanel = previewOverlay.querySelector('.image-detail');
  if (Number(imagePanel.dataset.index) === Number(index)) {
    imagePanel.querySelector('img').alt = message || 'Preview unavailable';
  }
  const textPanel = previewOverlay.querySelector('.text-detail');
  if (Number(textPanel.dataset.index) === Number(index)) {
    textPanel.querySelector('.manual-preview-content').textContent = message || 'Preview unavailable';
  }
};
window.setTextPreview = (index, value) => {
  const panel = previewOverlay.querySelector('.text-detail');
  if (Number(panel.dataset.index) !== Number(index)) return;
  panel.dataset.previewLoaded = 'true';
  panel.querySelector('.manual-preview-content').textContent = value || '';
};
previewOverlay.addEventListener('click', event => {
  if (event.target === previewOverlay) closeManualPreviews();
});

// Let a wheel/trackpad scroll dismiss the modal and scroll the history list
// with that same gesture, rather than requiring a second gesture after closing.
previewOverlay.addEventListener('wheel', event => {
  if (!previewOverlay.classList.contains('open')) return;
  const scrollContainer = document.querySelector('main');
  const deltaY = event.deltaY;
  closeManualPreviews();
  if (scrollContainer && deltaY) {
    scrollContainer.scrollTop += deltaY;
  }
  event.preventDefault();
}, { passive: false });

document.addEventListener('keydown', event => {
  if (event.key === 'Escape') closeManualPreviews();
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
const search = document.getElementById('search');
const activeTypeFilters = new Set();
let committedSearchQuery = '';
// The Lua table stores the authoritative stable-ID selection; this Set mirrors it in the WebView.
const selectedClipboardUids = new Set();
const selectedClipboardOrder = [];
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
    if (restoreDate === 'pinned') {
      document.querySelectorAll('.date-filter').forEach(b =>
        b.setAttribute('aria-pressed', b.dataset.action === 'pinScope' ? 'true' : 'false'));
      bridge('pinScope', 0, '', currentTypeFilter());
      return;
    }
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
    if (lastNonSearchDateKey === 'pinned') {
      document.querySelectorAll('.date-filter').forEach(b =>
        b.setAttribute('aria-pressed', b.dataset.action === 'pinScope' ? 'true' : 'false'));
      bridge('pinScope', 0, '', currentTypeFilter());
      return;
    }
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
// The results container is deliberately not a tab stop: an extra stop between
// the search field and the first card made every Tab press land on an element
// the user cannot see, so the visible sequence skipped a card.
resultsPanel.setAttribute('role', 'listbox');
resultsPanel.setAttribute('aria-label', 'Clipboard history results');
// Keep the result grid in the native focus order so keyboard users can enter
// and leave the grid as they did before multi-select was introduced.
resultsPanel.tabIndex = 0;

let selectedIndex = 0;
function rows() { return Array.from(document.querySelectorAll('main .item')).filter(item => !item.hidden && item.dataset.action === 'paste'); }
function selectRow(next, shouldScroll = false) {
  const items = rows();
  if (!items.length) { selectedIndex = 0; return; }
  selectedIndex = Math.max(0, Math.min(items.length - 1, next));
  items.forEach((item, i) => item.classList.toggle('selected', i === selectedIndex));

  if (shouldScroll) {
    
  }

  // Scroll the actual content viewport only when the highlighted card is not
  // fully visible; the grid itself is not the scrollable element.
  if (shouldScroll && items[selectedIndex]) {
    const item = items[selectedIndex];
    const scrollContainer = item.closest('main');
    if (scrollContainer) {
      const containerRect = scrollContainer.getBoundingClientRect();
      const itemRect = item.getBoundingClientRect();
      const topInset = 12;
      const bottomInset = 12;
      if (itemRect.top < containerRect.top + topInset) {
        scrollContainer.scrollTop -= (containerRect.top + topInset) - itemRect.top;
      } else if (itemRect.bottom > containerRect.bottom - bottomInset) {
        scrollContainer.scrollTop += itemRect.bottom - (containerRect.bottom - bottomInset);
      }
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
    if (index >= 0) {
      selectRow(index);
      // Keep the keyboard cursor on the card that really has focus, so the next
      // Tab continues from there instead of restarting at the first card.
      navState.navIndex = index;
      navState.lastCardIndex = index;
      navState.uid = cardUids()[index] || null;
    }
  }
});
search.addEventListener('focus', () => {
  // Focus left the results area. The remembered card stays, so the next Tab
  // returns to it.
  navState.navIndex = -1;
});

/* BEGIN KEYBOARD NAVIGATION MODEL */
function navClamp(index, count) {
  if (!(count > 0)) return -1;
  if (typeof index !== 'number' || !Number.isInteger(index) || index < 0) return 0;
  return Math.min(index, count - 1);
}
function navTransition(state, uids, forward) {
  const count = uids.length;
  const remembered = navClamp(state.lastCardIndex, count);
  const out = { navIndex: state.navIndex, lastCardIndex: remembered, uid: null, target: 'search' };
  if (state.navIndex < 0) {
    if (forward && count > 0) {
      out.navIndex = remembered; out.lastCardIndex = remembered; out.uid = uids[remembered]; out.target = 'card';
    }
    return out;
  }
  const next = forward ? state.navIndex + 1 : state.navIndex - 1;
  if (next < 0 || next >= count) {
    out.navIndex = -1; out.uid = null; out.target = 'search'; return out;
  }
  out.navIndex = next; out.lastCardIndex = next; out.uid = uids[next]; out.target = 'card';
  return out;
}
function navReconcile(state, uids) {
  const count = uids.length;
  const navIndex = typeof state.navIndex === 'number' ? state.navIndex : -1;
  const out = { navIndex: navIndex < 0 ? -1 : navClamp(navIndex, count), lastCardIndex: -1, uid: null };
  if (typeof state.uid === 'string' && state.uid) {
    const found = uids.indexOf(state.uid);
    if (found >= 0) { out.uid = state.uid; out.lastCardIndex = found; if (navIndex >= 0) out.navIndex = found; return out; }
  }
  const fallback = navClamp(typeof state.lastCardIndex === 'number' ? state.lastCardIndex : navIndex, count);
  out.lastCardIndex = fallback; out.uid = fallback >= 0 ? uids[fallback] : null;
  return out;
}
/* END KEYBOARD NAVIGATION MODEL */
/* BEGIN KEYBOARD NAVIGATION BINDING */
const navState = { navIndex: -1, lastCardIndex: -1, uid: null };
function cardUids() {
  return rows().map((node, position) => node.dataset.uid || ('idx:' + (node.dataset.index || position)));
}
function navMove(forward) {
  const next = navTransition(navState, cardUids(), forward);
  Object.assign(navState, next);
  const scrollX = window.scrollX, scrollY = window.scrollY;
  if (next.target === 'search') {
    clearRowSelection();
    search.focus({ preventScroll: true });
    if (search.setSelectionRange) {
      try { search.setSelectionRange(search.value.length, search.value.length); } catch (error) {}
    }
  } else {
    const item = rows()[next.navIndex];
    if (item) {
      selectRow(next.navIndex, true);
      item.focus({ preventScroll: true });
    } else {
      clearRowSelection();
      search.focus({ preventScroll: true });
    }
  }
  window.scrollTo(scrollX, scrollY);
}
window.resetClipboardSelection = () => {
  selectedIndex = 0;
  clearRowSelection();
  Object.assign(navState, navReconcile(navState, cardUids()));
};
function isClipboardPanelKeyboardTarget(target) {
  return target === document.body || target === resultsPanel ||
    target === search || Boolean(target && target.classList && target.classList.contains('item') && resultsPanel.contains(target));
}
function handleClipboardPanelKeydown(event) {
  const key = event.key;
  const target = event.target;

  // Escape first closes transient UI, then clears a search, then closes panel.
  if (key === 'Escape') {
    if (contextMenu.style.display !== 'none') {
      event.preventDefault();
      contextMenu.style.display = 'none';
      return;
    }
    if (target === search && search.value !== '') return; // search's own handler clears it
    if (search.value !== '') {
      event.preventDefault();
      search.value = '';
      applyFilters();
      search.focus({ preventScroll: true });
      return;
    }
    event.preventDefault();
    bridge('close', 0, '');
    return;
  }

  if (!isClipboardPanelKeyboardTarget(target)) return;

  if (key === 'Tab') {
    event.preventDefault();
    event.stopPropagation();
    navMove(!event.shiftKey);
    return;
  }

  // Arrow keys navigate the result grid from either the grid, a focused card,
  // or the search field. In the search field, horizontal arrows retain their
  // normal text-cursor behavior.
  if (target === search && (key === 'ArrowLeft' || key === 'ArrowRight' || key === 'Home' || key === 'End')) return;
  if (['ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight'].includes(key) &&
      (target === resultsPanel || (target && target.classList && target.classList.contains('item')) ||
       (target === search && key === 'ArrowDown'))) {
    event.preventDefault();
    if (key === 'ArrowRight') selectRow(selectedIndex + 1, true);
    else if (key === 'ArrowLeft') selectRow(selectedIndex - 1, true);
    else {
      const main = document.querySelector('main');
      const columns = Math.max(1, Math.round((main ? main.clientWidth : 250) / 250));
      selectRow(selectedIndex + (key === 'ArrowDown' ? columns : -columns), true);
    }
    const selected = rows()[selectedIndex];
    if (selected) {
      navState.navIndex = selectedIndex;
      navState.lastCardIndex = selectedIndex;
      navState.uid = cardUids()[selectedIndex] || null;
      selected.focus({ preventScroll: true });
    }
    return;
  }
}
document.addEventListener('keydown', handleClipboardPanelKeydown);
/* END KEYBOARD NAVIGATION BINDING */
/* BEGIN CONTEXT MENU MODEL */
const CONTEXT_MENU_ITEMS = [
  { slot: 'preview', label: '👁️ Preview' },
  { slot: 'copy', label: '📋 Copy' },
  { slot: 'pin', label: '📍 Pin', pinnedLabel: '📌 Unpin' },
  { slot: 'divider', divider: true },
  { slot: 'pasteAll', label: '🧴 Paste from Current to First' },
  { slot: 'select', label: 'Select/Deselect' },
  { slot: 'pasteSelected', label: '📥 Paste All Selected', selectedOnly: true },
  { slot: 'pasteSelectedOrder', label: '🔢 Paste All Selected in Selection Order', selectedOnly: true },
  { slot: 'pastePath', label: '🗂️ Paste path', imageOnly: true }
];
function contextMenuSpec(isPinned, isImage, isSelected, hasSelection) {
  return CONTEXT_MENU_ITEMS.map(spec => ({
    slot: spec.slot,
    action: spec.slot === 'pin' ? (isPinned ? 'unpin' : 'pin') : spec.slot,
    label: spec.slot === 'pin' ? (isPinned ? spec.pinnedLabel : spec.label) :
      spec.slot === 'select' ? (isSelected ? '❌ Deselect' : '✅ Select') : spec.label,
    visible: spec.divider === true
      ? true
      : (spec.imageOnly !== true || isImage === true) &&
        (spec.selectedOnly !== true || hasSelection === true)
  }));
}
function buildContextMenu(menu) {
  contextMenuSpec(false, false, false, false).forEach(part => {
    if (part.slot === 'divider') {
      const divider = document.createElement('div');
      divider.setAttribute('data-context-slot', 'divider');
      divider.setAttribute('role', 'separator');
      divider.style.cssText = 'height:1px;margin:7px 8px;background:rgba(220,225,235,.28);';
      menu.appendChild(divider);
      return;
    }
    const button = document.createElement('button');
    button.type = 'button';
    button.setAttribute('data-context-slot', part.slot);
    button.dataset.contextAction = part.action;
    button.textContent = part.label;
    button.style.cssText = 'display:block;width:100%;padding:10px 12px;border:0;border-radius:5px;background:transparent;color:#f5f6f8;text-align:left;font:13px -apple-system,BlinkMacSystemFont,sans-serif;white-space:normal;cursor:pointer;transition:background-color .12s ease,color .12s ease;';
    button.style.display = part.visible ? 'block' : 'none';
    menu.appendChild(button);
  });
  return menu;
}
function applyContextMenuTarget(menu, item, hasSelection) {
  if (!menu || !item) return null;
  const spec = contextMenuSpec(item.dataset.pinned === 'true',
    item.dataset.kind === 'image',
    selectedClipboardUids.has(item.dataset.uid || ''),
    hasSelection);
  spec.forEach(part => {
    const node = menu.querySelector('[data-context-slot="' + part.slot + '"]');
    if (!node) return;
    if (part.slot === 'divider') {
      node.style.display = part.visible ? 'block' : 'none';
      return;
    }
    node.dataset.contextAction = part.action;
    node.textContent = part.label;
    node.style.display = part.visible ? 'block' : 'none';
  });
  return spec;
}
function openContextMenu(menu, state, item, point, hasSelection) {
  const parsed = Number(item.dataset.index);
  state.rowIndex = Number.isInteger(parsed) ? parsed : 0;
  state.uid = item.dataset.uid || null;
  item.dataset.selected = String(selectedClipboardUids.has(state.uid || ''));
  applyContextMenuTarget(menu, item, hasSelection);
  menu.style.display = 'block';
  const menuWidth = Math.min(460, window.innerWidth - 16);
  const menuHeight = menu.offsetHeight || 64;
  menu.style.left = Math.max(8, Math.min(point.x, window.innerWidth - menuWidth - 8)) + 'px';
  menu.style.top = Math.max(8, Math.min(point.y, window.innerHeight - menuHeight - 8)) + 'px';
  return state;
}
function findContextRow(state, items) {
  if (state.uid) return items.find(node => node.dataset.uid === state.uid) || null;
  return items.find(node => Number(node.dataset.index || 0) === state.rowIndex) || null;
}
function handleContextMenuClick(menu, state, event, bridge, openManualPreview, items, selectedUids) {
  const button = event.target.closest ? event.target.closest('button[data-context-slot]') : null;
  if (!button) return false;
  const action = button.dataset.contextAction;
  menu.style.display = 'none';
  if (action === 'pasteSelected' || action === 'pasteSelectedOrder') {
    if (selectedUids && selectedUids.length) {
      bridge(action === 'pasteSelected' ? 'pasteSelected' : 'pasteSelectedOrder',
        0, JSON.stringify(selectedUids));
    }
    return true;
  }
  const target = findContextRow(state, items);
  if (!target) return true;
  const rowIndex = Number(target.dataset.index || 0);
  if (action === 'pasteAll') bridge('pasteAllFrom', rowIndex, '');
  else if (action === 'select' || action === 'deselect') {
    const uid = target.dataset.uid || '';
    if (uid) {
      if (selectedClipboardUids.has(uid)) {
        selectedClipboardUids.delete(uid);
        const orderIndex = selectedClipboardOrder.indexOf(uid);
        if (orderIndex >= 0) selectedClipboardOrder.splice(orderIndex, 1);
      } else {
        selectedClipboardUids.add(uid);
        selectedClipboardOrder.push(uid);
      }
      syncClipboardMultiSelection();
      bridge(selectedClipboardUids.has(uid) ? 'selectItem' : 'deselectItem',
        rowIndex, '', '', '', uid);
    }
  } else if (action === 'copy') bridge('copyHistoryEntry', rowIndex, '');
  else if (action === 'pastePath') bridge('pastePath', rowIndex, '');
  else if (action === 'pin' || action === 'unpin') bridge(action, rowIndex, '');
  else if (action === 'preview' && openManualPreview) openManualPreview(target);
  return true;
}
/* END CONTEXT MENU MODEL */
function syncClipboardMultiSelection() {
  rows().forEach(item => {
    const uid = item.dataset.uid || '', selected = selectedClipboardUids.has(uid);
    item.dataset.selected = String(selected); item.classList.toggle('multi-selected', selected);
    let mark = item.querySelector('.multi-select-mark');
    if (selected && !mark) {
      mark = document.createElement('span'); mark.className = 'multi-select-mark';
      mark.textContent = '✓'; mark.setAttribute('aria-label', 'Selected'); item.appendChild(mark);
    } else if (!selected && mark) mark.remove();
  });
}
window.resetMultiSelection = syncClipboardMultiSelection;
const contextMenu = document.createElement('div');
contextMenu.id = 'clipboard-context-menu'; buildContextMenu(contextMenu);
// Keep hover feedback on the actual persistent menu buttons. Delegation also
// covers buttons whose labels/actions change when the menu is reopened.
contextMenu.addEventListener('mouseover', event => {
  const button = event.target.closest && event.target.closest('button[data-context-slot]');
  if (!button || !contextMenu.contains(button)) return;
  button.style.background = '#3a4250';
  button.style.color = '#ffffff';
});
contextMenu.addEventListener('mouseout', event => {
  const button = event.target.closest && event.target.closest('button[data-context-slot]');
  const related = event.relatedTarget;
  if (!button || (related && button.contains(related))) return;
  button.style.background = 'transparent';
  button.style.color = '#f5f6f8';
});
contextMenu.style.cssText = 'display:none;position:fixed;z-index:9999;min-width:320px;max-width:460px;padding:5px;background:#252932;border:1px solid #555d6b;border-radius:8px;box-shadow:0 8px 28px rgba(0,0,0,.45);';
document.body.appendChild(contextMenu);
const contextState = { rowIndex: -1, uid: null };
document.addEventListener('contextmenu', event => {
  const item = event.target.closest ? event.target.closest('.item') : null;
  if (!item) return;
  event.preventDefault();
  openContextMenu(contextMenu, contextState, item, { x: event.clientX, y: event.clientY }, selectedClipboardUids.size > 0);
  selectRow(rows().indexOf(item));
});
contextMenu.addEventListener('click', event => {
  if (handleContextMenuClick(contextMenu, contextState, event, bridge, openManualPreview, rows(), selectedClipboardOrder.slice())) {
    event.preventDefault(); event.stopPropagation();
  }
});
document.addEventListener('click', event => {
  if (!event.target.closest('#clipboard-context-menu')) contextMenu.style.display = 'none';
  if (!event.target.closest('#clipboard-context-menu') && !event.target.closest('#clipboard-preview-overlay')) closeManualPreviews();
});
</script></body></html>]]
    return html
end

local function pasteHistoryEntry(index)
    local choice = menuData and menuData[index]
    if choice and choice.isPinned then choice=hydratePinnedEntry(choice) end
    if not choice or (choice.type ~= "text" and choice.type ~= "image") then return end
    pasteboard_watcher:stop()
    if choice.type == "text" then
        pasteboard.setContents(choice.data or choice.content or "")
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

-- The file that backs a clipboard image. A pinned image records the ordinary
-- record it was copied from in `sourcePath`, so a pinned card reports the same
-- path the ordinary card does; `imagePath` is the pinned copy and is the
-- fallback when the pin has no recorded source (the file still exists, in the
-- pinned collection).
local function firstNonEmptyString(...)
    -- table.pack, not a table constructor: the leading candidates are routinely
    -- nil, and ipairs stops at the first hole.
    local values = table.pack(...)
    for index = 1, values.n do
        local value = values[index]
        if type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function imageEntryPath(entry)
    if not entry then return nil end
    local source = entry.historyEntry or entry
    return firstNonEmptyString(source.sourcePath, source.imagePath, entry.sourcePath, entry.imagePath)
end

-- "Paste path" puts the image file path on the pasteboard as plain text and
-- pastes it into the app that had focus before the panel opened, so a terminal
-- or editor receives a usable path to the clipboard image.
local function pasteHistoryEntryPath(index)
    -- Metadata only: a card's file path is recorded on the entry, so this never
    -- loads the image payload just to report where the file lives.
    local choice = index and menuData and menuData[index]
    if not choice then
        hs.alert.show("Unable to read this clipboard item")
        return
    end
    if choice.type ~= "image" then
        hs.alert.show("Only image items have a file path")
        return
    end
    local path = imageEntryPath(choice)
    if not path then
        hs.alert.show("No image file path is available for this item")
        return
    end
    if not fs.attributes(path) then
        logger.w("Clipboard image path is no longer readable: " .. path)
        hs.alert.show("The image file for this item no longer exists")
        return
    end
    pasteboard_watcher:stop()
    local copyOK = pasteboard.setContents(path) ~= false
    if not copyOK then
        pasteboard_watcher:start()
        hs.alert.show("Unable to copy this image path")
        return
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
    local allStreamHasMore=false

    if clipboardPinnedFilter then
        -- The pinned collection is its own result set: never reuse the
        -- ordinary-history search cache for it.
        menuData=searchPinnedHistory(query,kind); browseMode="pinned"; browseCursor=#menuData
    elseif query~="" then
        if clipboardDateFilter then
            -- Date views are subsets of the already computed global query results.
            if searchResultsCache and searchResultsCache.collection=="history"
                and searchResultsCache.query==query and searchResultsCache.kind==kind then
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
            -- All presents ordinary history and pinned records as one result set.
            -- The ordinary side keeps its own collection-tagged cache so date
            -- subsets can reuse it; the merged set is cached as the All collection.
            local ordinary
            if searchResultsCache and searchResultsCache.collection=="history"
                and searchResultsCache.query==query and searchResultsCache.kind==kind then
                ordinary=searchResultsCache.entries
            else
                ordinary=searchPersistentHistory(query,kind)
                searchResultsCache={collection="history",query=query,kind=kind,entries=ordinary}
            end
            menuData=unifiedSearchEntries(ordinary,query,kind)
            browseMode="search"
        end
        browseCursor=0
    elseif clipboardDateFilter then
        if not append then menuData=loadPersistentDateHistory(clipboardDateFilter,"all") end
        browseMode="date"
    else
        -- All: one stream over ordinary history and pinned records, ordered by
        -- clipboard timestamp. Load more extends the existing stream, so the
        -- rendered list stays append-only and Text/Images switch in memory.
        if not append then resetAllStreamState() end
        local required=append and (previousMenuDataCount+CLIPBOARD_RENDER_BATCH_SIZE)
            or math.max(CLIPBOARD_RENDER_BATCH_SIZE,allHistoryCacheLoaded)
        local entries,_,more=extendAllStream(required)
        menuData=entries
        browseCursor=#entries
        browseMode="all"
        allStreamHasMore=more
    end

    local matches={}
    for i,entry in ipairs(menuData) do
        if (kind=="all" or entry.type==kind)
            and (query=="" or clipboardEntryMatches(entry,query,kind)) then
            matches[#matches+1]=i
        end
    end

    local cards={}
    if not append then renderedCardUids={} end
    for _,matchedIndex in ipairs(matches) do
        local entry=menuData[matchedIndex]
        local uid=cardUid(entry)
        -- Identity, not list position: a card already in the DOM is never added
        -- again, and a card that belongs in the list is never skipped because a
        -- re-sorted page moved its index.
        if not renderedCardUids[uid] then
            renderedCardUids[uid]=true
            cards[#cards+1]=historyItemHTML(entry,matchedIndex)
        end
    end
    local html=table.concat(cards,"\n")
    local hasMore=query=="" and not clipboardDateFilter and not clipboardPinnedFilter and allStreamHasMore
    local loadMore=hasMore and '<div class="load-more-wrap"><button class="action" data-action="loadMore" data-index="'..browseCursor..'">Load more</button></div>' or ""
    if #matches==0 then html='<div id="no-matches" class="empty">No matching clipboard items</div>' end
    html=html..loadMore

    local js
    if append then
        js="var m=document.getElementById('clipboard-items');var main=document.querySelector('main');var b=main.querySelector(':scope > .load-more-wrap');if(b)b.remove();var e=m.querySelector('.empty');if(e)e.remove();m.insertAdjacentHTML('beforeend',"..jsStringLiteral(html)..");var last=m.querySelector('.load-more-wrap');if(last)last.remove();if(last)main.appendChild(last);"
    else
        js="var m=document.getElementById('clipboard-items');var main=document.querySelector('main');var b=main.querySelector(':scope > .load-more-wrap');if(b)b.remove();m.innerHTML="..jsStringLiteral(html)..";var last=m.querySelector('.load-more-wrap');if(last)last.remove();if(last)main.appendChild(last);"
    end

    -- The count is the size of the collection that is presented: the unified
    -- All stream (which holds every pinned event exactly once), the pinned
    -- collection, a date scope, or a search result set.
    local visibleCount=#matches
    if query=="" and clipboardDateFilter then
        visibleCount=persistentHistoryCount(clipboardDateFilter,kind)
    end
    js=js.."if(window.resetMultiSelection)window.resetMultiSelection();"..
        "document.querySelector('.count').textContent="..jsStringLiteral(tostring(visibleCount).." matching items")..";if(window.resetClipboardSelection)window.resetClipboardSelection();"
    if clipboard_webview then clipboard_webview:evaluateJavaScript(js) end
    clipboard_search=query; clipboard_type_filter=kind
end

local closeClipboardPanel
local pasteSelectedClipboardItems

function handleClipboardPanelMessage(message)
    local body = message and message.body
    if type(body) ~= "table" then return end
    if body.action == "close" then closeClipboardPanel()
    elseif body.action == "selectItem" or body.action == "deselectItem" then
        local requestedUid = tostring(body.uid or "")
        if requestedUid ~= "" then
            local found
            for _, entry in ipairs(menuData or {}) do
                if cardUid(entry) == requestedUid then found = true; break end
            end
            if found then
                if body.action == "selectItem" then
                    if not selectedClipboardUids[requestedUid] then
                        selectedClipboardUids[requestedUid] = true
                        selectedClipboardOrder[#selectedClipboardOrder + 1] = requestedUid
                    end
                else
                    selectedClipboardUids[requestedUid] = nil
                    for index = #selectedClipboardOrder, 1, -1 do
                        if selectedClipboardOrder[index] == requestedUid then table.remove(selectedClipboardOrder, index); break end
                    end
                end
                if clipboard_webview then
                    clipboard_webview:evaluateJavaScript("if(window.resetMultiSelection)window.resetMultiSelection();")
                end
            end
        end
    elseif body.action == "pasteSelected" then
        pasteSelectedClipboardItems(body.query, "chronological")
    elseif body.action == "pasteSelectedOrder" then
        pasteSelectedClipboardItems(body.query, "selection")
    elseif body.action == "pinScope" then
        clipboardPinnedFilter=true; clipboardDateFilter=nil; allDatesFilterSelected=false
        clipboard_search=tostring(body.query or ""); clipboard_type_filter=body.kind or "all"
        updateClipboardPanel(clipboard_search,clipboard_type_filter,0,false)
    elseif body.action == "dateFilter" then
        local dateKey=body.dateKey
        if dateKey=="pinned" then
            -- Restoring the Pin scope after a search is cleared.
            clipboardPinnedFilter=true; clipboardDateFilter=nil; allDatesFilterSelected=false
            clipboard_search=tostring(body.query or ""); clipboard_type_filter=body.kind or "all"
            updateClipboardPanel(clipboard_search,clipboard_type_filter,0,false)
            return
        end
        clipboardPinnedFilter=false
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
        clipboardPinnedFilter=false
        -- If a query is active, return to its cached unified (ordinary + pinned)
        -- result set. Do not run another search when switching back.
        local query=tostring(body.query or "")
        local kind=body.kind or "all"
        clipboardDateFilter=nil
        allDatesFilterSelected=true
        clipboard_search=query
        clipboard_type_filter=kind
        if query=="" then
            browseMode="all"
            local cached,loaded=ensureAllHistoryCache(CLIPBOARD_RENDER_BATCH_SIZE)
            menuData=cached
            browseCursor=loaded
        end
        updateClipboardPanel(query,kind,0,false)
    elseif body.action == "search" or body.action == "filter" then
        local query=tostring(body.query or "")
        local kind=body.kind or clipboard_type_filter or "all"
        if body.action=="search" then
            if query=="" then
                searchResultsCache=nil
                if not clipboardPinnedFilter then
                    clipboardDateFilter=lastSearchRestoreDateKey
                    allDatesFilterSelected=clipboardDateFilter==nil
                end
            else
                if not clipboardPinnedFilter and clipboardDateFilter then lastSearchRestoreDateKey=clipboardDateFilter end
                if not clipboardPinnedFilter then clipboardDateFilter=nil; allDatesFilterSelected=true end
                if not clipboardPinnedFilter and (not searchResultsCache or searchResultsCache.collection~="history"
                    or searchResultsCache.query~=query or searchResultsCache.kind~=kind) then
                    searchResultsCache={collection="history",query=query,kind=kind,entries=searchPersistentHistory(query,kind)}
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
            local loaded=entry.isPinned and hydratePinnedEntry(entry) or entry
            local content=tostring(loaded and (loaded.data or loaded.content) or entry.data or entry.content or "")
            for line in (content .. "\n"):gmatch("(.-)\n") do
                lineCount = lineCount + 1
                if lineCount > TEXT_PREVIEW_MAX_LINES then break end
                excerptLines[#excerptLines + 1] = line
            end
            local excerpt = table.concat(excerptLines, "\n")
            if lineCount > TEXT_PREVIEW_MAX_LINES or #content > #excerpt then
                excerpt = excerpt .. "\n… (preview limited to first " .. TEXT_PREVIEW_MAX_LINES .. " lines)"
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
        else
            clipboard_webview:evaluateJavaScript("window.setPreviewError && window.setPreviewError("..tostring(index)..", 'Unable to load image preview');")
        end
    elseif body.action == "paste" then
        pasteHistoryEntry(tonumber(body.index))
    elseif body.action == "pastePath" then
        pasteHistoryEntryPath(tonumber(body.index))
    elseif body.action == "pasteAllFrom" then
        pasteSomeWithDelimiterFromStartRow(tonumber(body.index))
    elseif body.action == "pin" or body.action == "unpin" then
        local index=tonumber(body.index); local choice=index and menuData[index]
        local ok=choice and (body.action=="pin" and pinClipboardEntry(choice) or body.action=="unpin" and unpinClipboardEntry(choice))
        if not ok then
            hs.alert.show(body.action=="pin" and "Unable to pin this clipboard item" or "Unable to unpin this clipboard item")
        else updateClipboardPanel(clipboard_search,clipboard_type_filter,0,false);
        --     hs.alert.show(body.action=="pin" and "Pinned clipboard item" or "Unpinned clipboard item")
        end
    elseif body.action == "copyHistoryEntry" then
        local index = tonumber(body.index)
        local choice = index and menuData[index]
        if choice and choice.isPinned then choice=hydratePinnedEntry(choice) end
        if not choice or (choice.type ~= "text" and choice.type ~= "image") then
            hs.alert.show("Unable to copy this clipboard item")
            return
        end

        pasteboard_watcher:stop()
        local copyOK = false
        if choice.type == "text" then
            copyOK = pasteboard.setContents(tostring(choice.data or choice.content or "")) ~= false
        else
            local image = decodeImage(choice.historyEntry or choice)
            if image then
                copyOK = pasteboard.writeObjects(image) ~= false
            end
            image = nil
            collectgarbage("collect")
        end
        pasteboard_watcher:start()
        if copyOK then
            hs.alert.show("Copied to clipboard — press Cmd+V to paste")
        else
            hs.alert.show("Unable to copy this clipboard item")
        end
    elseif body.action == "clearAll" then
        clearClipboardHistory()
        if clipboard_webview then
            clipboardPanelHTMLReady = true
            clipboard_webview:html(clipboardPanelHTML())
            clipboard_webview:show()
        end
        pasteboard_watcher:start()
        hs.alert.show("Clipboard history cleared")
    elseif body.action == "reloadSoftware" then
        hs.alert.show("Reloading Hammerspoon configuration…")
        -- Reload after the WebView callback returns to the main run loop.
        -- This re-executes init.lua and reloads every configured Spoon.
        hs.timer.doAfter(0.15, function()
            hs.reload()
        end)
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
local function activatePreviousApplication()
    local app = previousApplication
    local pid = previousApplicationPid
    if not app or not app:isRunning() then
        previousApplication = nil
        previousApplicationPid = nil
        return false
    end

    -- Capture identity, then clear the stored target so each panel session has
    -- one restoration request. Retry after the native window has actually had
    -- time to close; a too-early activate() can be immediately undone by AppKit.
    local targetPid = app:pid()
    if not targetPid or (pid and targetPid ~= pid)
        or app:bundleID() == "org.hammerspoon.Hammerspoon" then
        previousApplication = nil
        previousApplicationPid = nil
        logger.w("Skipped invalid previous application restoration target")
        return false
    end
    previousApplication = nil
    previousApplicationPid = nil

    previousApplicationRestoreGeneration = previousApplicationRestoreGeneration + 1
    local generation = previousApplicationRestoreGeneration
    if previousApplicationRestoreTimer then
        previousApplicationRestoreTimer:stop()
        previousApplicationRestoreTimer = nil
    end

    local attempts = 0
    local maxAttempts = 4
    local function restoreAttempt()
        if generation ~= previousApplicationRestoreGeneration then return end
        if not app:isRunning() or app:pid() ~= targetPid then
            previousApplicationRestoreTimer = nil
            logger.w("Previous app exited before focus restoration")
            return
        end

        local frontApp = application.frontmostApplication()
        if frontApp and frontApp:pid() == targetPid then
            previousApplicationRestoreTimer = nil
            logger.d("Previous application restored: " .. tostring(app:name()))
            return
        end

        attempts = attempts + 1
        local ok, activated = pcall(function() return app:activate(true) end)
        logger.d("Restore previous app attempt " .. attempts
            .. ": app=" .. tostring(app:name())
            .. ", activateOK=" .. tostring(ok)
            .. ", activateResult=" .. tostring(activated))

        if attempts < maxAttempts then
            previousApplicationRestoreTimer = hs.timer.doAfter(0.12, restoreAttempt)
        else
            previousApplicationRestoreTimer = nil
            local finalFrontApp = application.frontmostApplication()
            if not finalFrontApp or finalFrontApp:pid() ~= targetPid then
                logger.e("Could not restore previous application after "
                    .. maxAttempts .. " attempts: " .. tostring(app:name()))
            end
        end
    end

    -- Allow the native close/Space transition to complete before activating.
    previousApplicationRestoreTimer = hs.timer.doAfter(0.18, restoreAttempt)
    return true
end

closeClipboardPanel = function()
    if panelClosePending then return end
    panelClosePending = true

    -- Capture the target before destroying the panel and stop dismissal events.
    stopOutsideClickMonitor()
    -- Invalidate the view first so any delayed callbacks become no-ops.
    local view=clipboard_webview
    clipboard_webview=nil
    clipboardPanelHTMLReady=false
    clipboard_usercontent=nil

    -- Clear every Lua-owned reference to the expanded browse session.
    clipboard_search=""
    clipboard_type_filter="all"
    clipboardDateFilter=nil
    clipboardPinnedFilter=false
    lastSearchRestoreDateKey=nil
    browseMode="all"
    browseCursor=0
    typeBrowseCursor={text=nil,image=nil}
    menuData={}
    selectedClipboardUids={}
    selectedClipboardOrder={}
    dateHistoryCache={}
    allHistoryCache={}
    allHistoryCacheLoaded=0
    allHistoryTotalCount=nil
    searchResultsCache=nil
    invalidatePinnedIndex()
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
                document.querySelectorAll('img').forEach(function(img) {
                    img.onload=null; img.onerror=null; img.removeAttribute('src');
                });
                document.querySelectorAll('.manual-preview').forEach(function(node) { node.remove(); });
                document.getElementById('clipboard-items')?.replaceChildren();
            ]])
        end)
        pcall(function() view:delete() end)
    end
    collectgarbage("collect")
    panelClosePending = false
    activatePreviousApplication()
end

local function configureClipboardWebview(view)
    view:windowStyle({"titled", "closable", "resizable"})
    view:shadow(true)
    view:allowTextEntry(true)
    view:closeOnEscape(false)
    view:windowCallback(function(action, _, focused)
        if action == "closing" then
            stopOutsideClickMonitor()
            -- The red close button follows this native callback, unlike the
            -- Escape/outside-click path. Share the same one-shot cleanup.
            if clipboard_webview == view then
                clipboard_webview = nil
                clipboard_usercontent = nil
                clipboardPanelHTMLReady = false
                clipboard_search=""; clipboard_type_filter="all"; clipboardDateFilter=nil; lastSearchRestoreDateKey=nil; browseMode="all"; browseCursor=0; typeBrowseCursor={text=nil,image=nil}; menuData={}
                dateHistoryCache={}; allHistoryCache={}; allHistoryCacheLoaded=0; allHistoryTotalCount=nil; searchResultsCache=nil; invalidatePinnedIndex(); clipboardSessionOpen=false
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
                if not panelClosePending then
                    panelClosePending = true
                    hs.timer.doAfter(0.12, function()
                        panelClosePending = false
                        activatePreviousApplication()
                    end)
                end
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

-- Shared chronological paste executor for range and explicit selections.
local activePasteEntries = nil
local function finishPasteAll()
    restoreNewestClipContent()
    activePasteEntries = nil
    selectedClipboardUids = {}
    selectedClipboardOrder = {}
    if clipboard_webview then
        clipboard_webview:evaluateJavaScript("if(window.resetMultiSelection)window.resetMultiSelection();")
        clipboard_webview:html(clipboardPanelHTML())
    end
    pasteboard_watcher:start()
    previousApplication = nil
    collectgarbage("collect")
    hs.alert.show("The Paste task has finished.")
end

-- Shared chronological paste engine. Its input is newest-first and it walks
-- backward, preserving the existing range-paste timing and image behavior.
local function pasteAllRowsStep(position, direction)
    direction = direction or -1
    local outOfBounds = direction < 0 and position < 1 or direction > 0 and position > #(activePasteEntries or {})
    if not activePasteEntries or outOfBounds then finishPasteAll(); return end
    local entry = activePasteEntries[position]
    if not entry or (entry.type ~= "text" and entry.type ~= "image") then
        hs.timer.doAfter(0.05, function() pasteAllRowsStep(position + direction, direction) end)
        return
    end
    local wroteContent = false
    if entry.type == "text" then
        local loaded = effectivePinnedId(entry) and hydratePinnedEntry(entry) or hydrateEntry(entry) or entry
        wroteContent = pasteboard.setContents(tostring(loaded and (loaded.data or loaded.content) or entry.data or entry.content or "") .. "\n") ~= false
    else
        local image = decodeImage(entry.historyEntry or entry)
        if image then wroteContent = pasteboard.writeObjects(image) ~= false
        else hs.alert.show("Skipped an image that could not be decoded.") end
        image = nil
        collectgarbage("collect")
    end
    if not wroteContent then
        hs.timer.doAfter(0.05, function() pasteAllRowsStep(position + direction, direction) end)
        return
    end
    hs.timer.doAfter(0.15, function()
        hs.eventtap.keyStroke({"cmd"}, "v", 0)
        hs.timer.doAfter(0.4, function()
            if entry.type == "image" then
                pasteboard.setContents("\n")
                hs.timer.doAfter(0.15, function()
                    hs.eventtap.keyStroke({"cmd"}, "v", 0)
                    hs.timer.doAfter(0.4, function() pasteAllRowsStep(position + direction, direction) end)
                end)
            else
                pasteAllRowsStep(position + direction, direction)
            end
        end)
    end)
end
function pasteAllWithDelimiterRecursionVersion(startRow)
    pasteAllRowsStep(startRow, -1)
end

function pasteSomeWithDelimiterFromStartRow(startRow)
    if type(startRow) ~= "number" or startRow < 1 or not menuData or #menuData == 0 then
        hs.alert.show("No clipboard-history rows to paste.")
        return
    end
    -- menuData is newest-first. Collecting startRow down to index 1 puts the
    -- clicked row first, followed by progressively newer rows. Walk forward.
    activePasteEntries = {}
    for index = startRow, 1, -1 do
        if menuData[index] then activePasteEntries[#activePasteEntries + 1] = menuData[index] end
    end
    hs.alert.show("Please wait for the Paste task to finish.")
    pasteboard_watcher:stop()
    if clipboard_webview then clipboard_webview:hide() end
    hs.timer.doAfter(0.15, function()
        if previousApplication and previousApplication:isRunning() then previousApplication:activate(true) end
        hs.timer.doAfter(0.35, function() pasteAllRowsStep(1, 1) end)
    end)
end

pasteSelectedClipboardItems = function(serializedUids, orderMode)
    local ok, requested = pcall(json.decode, tostring(serializedUids or ""))
    if not ok or type(requested) ~= "table" or #requested == 0 then
        hs.alert.show("No clipboard-history items are selected."); return false
    end
    local wanted, resolvedByUid, seen = {}, {}, {}
    for _, uid in ipairs(requested) do if type(uid) == "string" and uid ~= "" then wanted[uid] = true end end
    local candidates = {}
    for _, entry in ipairs(allHistoryCache or {}) do candidates[#candidates + 1] = entry end
    for _, entry in ipairs(loadPinnedEntries()) do candidates[#candidates + 1] = entry end
    for _, entry in ipairs(menuData or {}) do candidates[#candidates + 1] = entry end
    for _, entry in ipairs(candidates) do
        local uid = cardUid(entry)
        if wanted[uid] and not seen[uid] then resolvedByUid[uid] = entry; seen[uid] = true end
    end
    local expected = 0
    for _ in pairs(wanted) do expected = expected + 1 end
    local entries = {}
    if orderMode == "selection" then
        for _, uid in ipairs(requested) do
            local entry = resolvedByUid[uid]
            if entry then entries[#entries + 1] = entry end
        end
    else
        for uid in pairs(wanted) do
            local entry = resolvedByUid[uid]
            if entry then entries[#entries + 1] = entry end
        end
        table.sort(entries, function(left, right)
            local lt, rt = tonumber(left.rowTs or left.ts) or 0, tonumber(right.rowTs or right.ts) or 0
            if lt ~= rt then return lt < rt end
            return cardUid(left) < cardUid(right)
        end)
    end
    if expected == 0 or #entries ~= expected then
        hs.alert.show("Some selected clipboard items are no longer available in this session.")
        return false
    end
    activePasteEntries = entries
    selectedClipboardUids = {}
    selectedClipboardOrder = {}
    pasteboard_watcher:stop()
    if clipboard_webview then
        clipboard_webview:evaluateJavaScript("if(window.resetMultiSelection)window.resetMultiSelection();")
        clipboard_webview:hide()
    end
    hs.alert.show("Please wait for the Paste task to finish.")
    hs.timer.doAfter(0.15, function()
        if previousApplication and previousApplication:isRunning() then previousApplication:activate(true) end
        hs.timer.doAfter(0.35, function() pasteAllRowsStep(1, 1) end)
    end)
    return true
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
        previousApplicationPid = frontApp:pid()
    elseif not (previousApplication and previousApplication:isRunning()
        and previousApplicationPid == previousApplication:pid()) then
        previousApplication = nil
        previousApplicationPid = nil
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

    if not clipboardSessionOpen then
        dateHistoryCache = {}
        selectedClipboardUids = {}
        selectedClipboardOrder = {}
    end
    clipboardSessionOpen = true
    clipboard_search = ""
    clipboard_type_filter = "all"
    clipboardDateFilter = nil
    clipboardPinnedFilter = false
    allDatesFilterSelected = true
    browseMode = "all"
    browseCursor = 0
    typeBrowseCursor = {text = nil, image = nil}
    allHistoryCache={}
    allHistoryCacheLoaded=0
    allHistoryTotalCount=nil
    invalidatePinnedIndex()
    -- The first paint must be the unified All collection. Rendering the ordinary
    -- cache alone dropped every pinned record - and with it every pin marker -
    -- from the panel that opens on the hotkey, which is exactly the view users
    -- compared against the Pin filter.
    openAllPanelPage(CLIPBOARD_RENDER_BATCH_SIZE)

    local function showAfterHTMLLoaded()
        if clipboard_webview ~= view then return end
        positionPanelOnCurrentScreen()
        view:show()
        view:evaluateJavaScript("document.body.classList.add('keyboard-mode');")
        hs.timer.doAfter(0.05, function()
            if clipboard_webview ~= view then return end
            local nativeWindow = view:hswindow()
            if nativeWindow then
                -- Explicitly raise and focus the panel. WebView focus alone
                -- isn't sufficient when another app is already frontmost.
                nativeWindow:raise()
                nativeWindow:focus()
                view:bringToFront(true)
            else
                logger.w("Clipboard History window unavailable after show")
            end
            startOutsideClickMonitor()
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
-- Ordinary records need their ids before the pinned migration can link a pin
-- back to the record it was pinned from, so the daily indexes are migrated first.
migrateDailyHistoryIndexes()
ensurePinnedStorage()
migratePinnedHistory()
if not fs.attributes(PINNED_HISTORY_PATH) then writePinnedHistory({}) end
invalidatePinnedIndex()
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

-- Surface used only by the isolated Lua regression harness in
-- tests/clipboard-pinned. The panel itself never reads this table; it exists so
-- schema conversion, migration, pinned search, and filtering can be tested
-- without a live Hammerspoon UI.
pkg.__test = {
    paths = {
        historyRoot = HISTORY_ROOT,
        pinnedRoot = PINNED_ROOT,
        pinnedImageRoot = PINNED_IMAGE_ROOT,
        pinnedThumbnailRoot = PINNED_THUMBNAIL_ROOT,
        pinnedHistoryPath = PINNED_HISTORY_PATH,
        pinnedMigrationBackupPath = PINNED_MIGRATION_BACKUP_PATH,
    },
    historyDayDirectory = historyDayDirectory,
    historyJSONPath = historyJSONPath,
    historyImageDirectory = historyImageDirectory,
    historyThumbnailDirectory = historyThumbnailDirectory,
    readDayHistory = readDayHistory,
    writeDayHistory = writeDayHistory,
    persistClipboardEntry = persistClipboardEntry,
    nextRecordId = nextRecordId,
    migrateDailyHistoryIndexes = migrateDailyHistoryIndexes,
    insertCacheEntry = insertCacheEntry,
    restorePersistentHistory = restorePersistentHistory,
    removeExpiredHistoryDirectories = removeExpiredHistoryDirectories,
    metadataEntry = metadataEntry,
    readPinnedHistory = readPinnedHistory,
    writePinnedHistory = writePinnedHistory,
    migratePinnedHistory = migratePinnedHistory,
    loadPinnedEntries = loadPinnedEntries,
    pinnedMetadata = pinnedMetadata,
    pinClipboardEntry = pinClipboardEntry,
    unpinClipboardEntry = unpinClipboardEntry,
    hydratePinnedEntry = hydratePinnedEntry,
    hydrateEntry = hydrateEntry,
    invalidatePinnedIndex = invalidatePinnedIndex,
    effectivePinnedId = effectivePinnedId,
    cardUid = cardUid,
    selectedClipboardUids = selectedClipboardUids,
    selectedClipboardOrder = selectedClipboardOrder,
    pasteSelectedClipboardItems = pasteSelectedClipboardItems,
    activePasteEntries = activePasteEntries,
    resolveSelectedClipboardEntries = function(serializedUids)
        local ok, requested = pcall(json.decode, tostring(serializedUids or ""))
        if not ok or type(requested) ~= "table" then return nil end
        local wanted, entries, seen = {}, {}, {}
        for _, uid in ipairs(requested) do
            if type(uid) == "string" and uid ~= "" then wanted[uid] = true end
        end
        local candidates = {}
        for _, entry in ipairs(allHistoryCache or {}) do candidates[#candidates + 1] = entry end
        for _, entry in ipairs(loadPinnedEntries()) do candidates[#candidates + 1] = entry end
        for _, entry in ipairs(menuData or {}) do candidates[#candidates + 1] = entry end
        for _, entry in ipairs(candidates) do
            local uid = cardUid(entry)
            if wanted[uid] and not seen[uid] then entries[#entries + 1] = entry; seen[uid] = true end
        end
        local expected = 0
        for _ in pairs(wanted) do expected = expected + 1 end
        if expected == 0 or #entries ~= expected then return nil end
        table.sort(entries, function(left, right)
            local lt = tonumber(left.rowTs or left.ts) or 0
            local rt = tonumber(right.rowTs or right.ts) or 0
            if lt ~= rt then return lt < rt end
            return cardUid(left) < cardUid(right)
        end)
        return entries
    end,
    openAllPanelPage = openAllPanelPage,
    extendAllStream = extendAllStream,
    resetAllStreamState = resetAllStreamState,
    pasteHistoryEntryPath = pasteHistoryEntryPath,
    imageEntryPath = imageEntryPath,
    searchPinnedHistory = searchPinnedHistory,
    searchPersistentHistory = searchPersistentHistory,
    clipboardEntryMatches = clipboardEntryMatches,
    historyItemHTML = historyItemHTML,
    panelHTML = clipboardPanelHTML,
    updateClipboardPanel = updateClipboardPanel,
    pasteHistoryEntry = pasteHistoryEntry,
    clearClipboardHistory = clearClipboardHistory,
    handleMessage = handleClipboardPanelMessage,
    panelState = function()
        return {
            query = clipboard_search,
            kind = clipboard_type_filter,
            dateFilter = clipboardDateFilter,
            pinned = clipboardPinnedFilter,
            browseMode = browseMode,
            menuCount = #menuData,
            menuData = menuData,
            allDatesFilterSelected = allDatesFilterSelected,
            searchCacheCollection = searchResultsCache and searchResultsCache.collection,
            searchCacheQuery = searchResultsCache and searchResultsCache.query,
            searchCacheKind = searchResultsCache and searchResultsCache.kind,
            searchCacheCount = searchResultsCache and #searchResultsCache.entries,
            allStreamLength = allStreamState and #allStreamState.entries or 0,
            allStreamExhausted = allStreamState and allStreamState.exhausted == true,
            renderedCards = (function()
                local count = 0
                for _ in pairs(renderedCardUids) do count = count + 1 end
                return count
            end)(),
            allCacheCollection = allSearchCache and allSearchCache.collection,
            allCacheQuery = allSearchCache and allSearchCache.query,
            allCacheKind = allSearchCache and allSearchCache.kind,
            allCacheCount = allSearchCache and #allSearchCache.entries,
            selectedCount = (function() local n=0; for _ in pairs(selectedClipboardUids) do n=n+1 end; return n end)(),
            selectedUids = selectedClipboardUids,
            selectedOrder = selectedClipboardOrder,
        }
    end,
    setPanelState = function(state)
        if type(state) ~= "table" then return end
        if state.allDates then clipboardDateFilter = nil; clipboardPinnedFilter = false end
        if state.pinned ~= nil then clipboardPinnedFilter = state.pinned and true or false end
        if state.dateFilter ~= nil then clipboardDateFilter = state.dateFilter end
        if state.query ~= nil then clipboard_search = tostring(state.query) end
        if state.kind ~= nil then clipboard_type_filter = tostring(state.kind) end
    end,
}

return pkg