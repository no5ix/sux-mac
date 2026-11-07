-- Isolated regression harness for the Clipboard History Spoon's pinned
-- collection. It runs the real init.lua against a sandboxed data root with the
-- hs_stub filesystem/WebView/pasteboard shims, so no Hammerspoon instance,
-- window, clipboard, or real user history is touched.
--
--   lua tests/clipboard-pinned/run.lua            # from the repository root
--   SPOON_PATH=/path/to/init.lua lua tests/clipboard-pinned/run.lua
--
-- Live panel behavior (context menu, preview, paste, screenshots) is verified
-- separately with Peekaboo; see AGENTS.md "Visual testing".

package.path = "./tests/clipboard-pinned/?.lua;" .. package.path

local STUB = require("hs_stub")

local SPOON_PATH = os.getenv("SPOON_PATH")
    or ".hammerspoon/Spoons/xClipboardHistory.spoon/init.lua"
local REAL_GETENV = os.getenv

local sandboxes = {}
math.randomseed(os.time())

local function shquote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function shell(command)
    return os.execute(command)
end

local function sandbox_directory(label)
    local base = "/tmp/sux-clipboard-history-tests"
    shell("mkdir -p " .. shquote(base))
    local index = #sandboxes + 1
    local path = string.format("%s/%02d-%s-%d-%d", base, index,
        (label or "case"):gsub("[^%w%-]", "_"), os.time(), math.random(100000, 999999))
    shell("rm -rf " .. shquote(path) .. "; mkdir -p " .. shquote(path))
    sandboxes[#sandboxes + 1] = path
    return path
end

local function write_file(path, contents)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then shell("mkdir -p " .. shquote(parent)) end
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
    return path
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function list_files(directory)
    local handle = io.popen("ls -1A " .. shquote(directory) .. " 2>/dev/null")
    local names = {}
    for line in handle:lines() do names[#names + 1] = line end
    handle:close()
    table.sort(names)
    return names
end

-- Loads a fresh copy of the Spoon inside a sandboxed HOME. Pass reuse_home to
-- reload the module against an existing sandbox (simulates hs.reload).
--
-- SAFETY: the Spoon resolves its data root from $HOME, so every load must run
-- while STUB's sandbox HOME override is active. Never restore the real
-- os.getenv here: that points the harness at the user's real clipboard-history
-- data, where it would overwrite and delete real records.
local function new_environment(label, reuse_home)
    local home = reuse_home or sandbox_directory(label)
    STUB.install(home)
    assert(os.getenv("HOME") == home, "the harness lost its sandbox HOME override")
    local chunk = assert(loadfile(SPOON_PATH))
    local pkg = chunk()
    local test = pkg.__test
    assert(type(test) == "table", "the Spoon must expose pkg.__test for the harness")
    assert(test.paths.historyRoot:match("^/tmp/sux%-clipboard%-history%-tests/"),
        "refusing to run outside the sandbox data root: " .. tostring(test.paths.historyRoot))
    local environment = {
        home = home,
        pkg = pkg,
        t = test,
        root = test.paths.historyRoot,
        pinned = test.paths.pinnedRoot,
        pinned_history = test.paths.pinnedHistoryPath,
    }
    function environment.date_directory(date_key)
        return test.historyDayDirectory(date_key)
    end
    function environment.seed_text_day(date_key, contents, timestamp)
        local records = {}
        for index, content in ipairs(contents) do
            records[index] = {
                type = "text",
                ts = timestamp + (index - 1) * 60,
                content = content,
            }
        end
        assert(test.writeDayHistory(date_key, records))
        return records
    end
    -- Appends an image record so an existing day's text records are kept.
    function environment.seed_image_day(date_key, base_name, timestamp)
        local image_directory = test.historyImageDirectory(date_key)
        local thumbnail_directory = test.historyThumbnailDirectory(date_key)
        shell("mkdir -p " .. shquote(image_directory) .. " " .. shquote(thumbnail_directory))
        write_file(image_directory .. "/" .. base_name .. ".png", "STUB-PNG-PAYLOAD\n")
        write_file(thumbnail_directory .. "/" .. base_name .. ".jpg", "STUB-JPEG-PAYLOAD\n")
        local record = {
            type = "image",
            ts = timestamp,
            imagePath = image_directory .. "/" .. base_name .. ".png",
            thumbnailPath = thumbnail_directory .. "/" .. base_name .. ".jpg",
        }
        local records = test.readDayHistory(date_key)
        records[#records + 1] = record
        assert(test.writeDayHistory(date_key, records))
        return record
    end
    -- Deterministic: pins the oldest ordinary record whose text contains the
    -- fragment, so expectations do not depend on sort order.
    function environment.pin_matching(fragment, kind)
        local entries = test.searchPersistentHistory(fragment, kind or "text")
        assert(#entries > 0, "no ordinary entry matched " .. tostring(fragment))
        local oldest = entries[#entries]
        for _, entry in ipairs(entries) do
            if entry.ts < oldest.ts then oldest = entry end
        end
        assert(test.pinClipboardEntry(oldest), "pinning failed for " .. tostring(fragment))
        return oldest
    end
    function environment.pin_first_matching(query, kind)
        return environment.pin_matching(query, kind)
    end
    return environment
end

-------------------------------------------------------------------------------
-- tiny test framework

local results, failures = {}, {}

local function check(condition, message)
    if not condition then
        error("assertion failed: " .. message, 2)
    end
end

local function check_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("assertion failed: %s (expected %s, got %s)",
            message, tostring(expected), tostring(actual)), 2)
    end
end

local function test(label, body)
    local ok, err = pcall(body)
    if ok then
        results[#results + 1] = "PASS " .. label
    else
        results[#results + 1] = "FAIL " .. label .. ": " .. tostring(err)
        failures[#failures + 1] = label
    end
end

local function count_matching(records, predicate)
    local total = 0
    for _, record in ipairs(records) do
        if predicate(record) then total = total + 1 end
    end
    return total
end

local function panel_count_text()
    for index = #STUB.state.scripts, 1, -1 do
        local script = STUB.state.scripts[index]
        local text = script:match("document%.querySelector%('%.count'%).textContent=\"([^\"]*)\"")
        if text then return text end
    end
    return nil
end

local SECRETS = {}
local function secret_value(value)
    SECRETS[#SECRETS + 1] = value
    return value
end

-------------------------------------------------------------------------------
-- fixtures

local DATE = "2026-11-07"
local BASE_TS = 1793984940

local CODEX_TEXTS = {
    "codex relay notes for the pinned clipboard search",
    "ordinary note without the keyword",
    "CODEX config: keep the\nmultiline\ncase-insensitive match",
    "another unpinned note",
    "pinned résumé ✓ payload about codex with unicode",
}

local function seed_codex_day(environment)
    environment.seed_text_day(DATE, CODEX_TEXTS, BASE_TS)
    environment.t.restorePersistentHistory()
end

-------------------------------------------------------------------------------
-- Issue B: pinned records use the ordinary history record schema

test("pinned text JSON record matches the ordinary record schema", function()
    local environment = new_environment("schema")
    seed_codex_day(environment)
    local entry = environment.pin_first_matching("codex", "text")

    local records = environment.t.readPinnedHistory()
    check_equal(#records, 1, "one pinned record")
    local record = records[1]

    -- Core fields and meanings from the daily history file.
    check_equal(record.type, "text", "type field")
    check_equal(record.ts, entry.ts, "ts keeps the original clipboard timestamp")
    check_equal(record.content, CODEX_TEXTS[1], "full text is stored in content")
    check(record.content:find("\n") == nil, "this fixture is single line")

    local core_fields = { type = true, ts = true, content = true }
    local allowed_pin_fields = { id = true, pinnedAt = true, sourceKey = true, sourcePath = true }
    for field in pairs(record) do
        if not core_fields[field] and not allowed_pin_fields[field] then
            error("unexpected pinned field: " .. tostring(field))
        end
    end

    check(type(record.id) == "string" and #record.id > 0, "stable string id")
    check(type(record.pinnedAt) == "number" and record.pinnedAt >= record.ts, "numeric pinnedAt")
    check(type(record.sourceKey) == "string" and #record.sourceKey > 0, "source identity")
    check(record.contentPath == nil, "no per-item content file reference")

    -- No per-item .txt payload files may be created for new pins.
    for _, name in ipairs(list_files(environment.pinned)) do
        check(not name:match("%.txt$"), "no legacy text file created, found " .. name)
    end
    check_equal(#list_files(environment.pinned .. "/pinned-images"), 0, "no pinned image written")
end)

test("multiline and unicode pinned text round-trips through JSON", function()
    local environment = new_environment("unicode")
    seed_codex_day(environment)
    local unicode_text = CODEX_TEXTS[5]
    local ordinary = environment.t.searchPersistentHistory("unicode", "text")
    check_equal(#ordinary, 1, "one ordinary unicode record")
    check(environment.t.pinClipboardEntry(ordinary[1]))

    local pinned = environment.t.loadPinnedEntries()
    check_equal(#pinned, 1, "one pinned entry")
    check_equal(pinned[1].content, unicode_text, "content survives the JSON round trip")

    local hydrated = environment.t.hydratePinnedEntry(pinned[1])
    check(hydrated, "pinned entry hydrates without a payload file")
    check_equal(hydrated.data, unicode_text, "hydrated data matches")
    check_equal(hydrated.content, unicode_text, "hydrated content matches")
end)

test("pinned images reference pinned image and thumbnail directories", function()
    local environment = new_environment("image")
    local ordinary_record = environment.seed_image_day(DATE, "20261107000443", BASE_TS)
    environment.t.restorePersistentHistory()

    local entries = environment.t.searchPersistentHistory("[image]", "image")
    check_equal(#entries, 1, "one ordinary image entry")
    check(environment.t.pinClipboardEntry(entries[1]), "pin the image")

    local records = environment.t.readPinnedHistory()
    check_equal(#records, 1, "one pinned image record")
    local record = records[1]
    check_equal(record.type, "image", "type")
    check_equal(record.ts, ordinary_record.ts, "original clipboard timestamp")
    check(record.imagePath:find("/pinned/pinned-images/", 1, true), "image copied under pinned-images")
    check(record.thumbnailPath:find("/pinned/pinned-thumbnails/", 1, true), "thumbnail under pinned-thumbnails")
    check(STUB.fs.attributes(record.imagePath), "pinned image file exists")
    check(STUB.fs.attributes(record.thumbnailPath), "pinned thumbnail file exists")
    check_equal(read_file(record.imagePath), read_file(ordinary_record.imagePath), "byte-identical copy")
    check(STUB.fs.attributes(ordinary_record.imagePath), "ordinary image file is preserved")
    check(STUB.fs.attributes(ordinary_record.thumbnailPath), "ordinary thumbnail file is preserved")
    check_equal(record.sourcePath, ordinary_record.imagePath, "source identity recorded")
    check_equal(#environment.t.readDayHistory(DATE), 1, "ordinary record untouched")
    check(not record.contentPath, "image record has no text payload field")
end)

test("pinning preserves timestamps, ids, and separates identical timestamps", function()
    local environment = new_environment("identity")
    -- Two distinct records that share a timestamp and type.
    local records = {
        { type = "text", ts = BASE_TS, content = "shared ts first codex item" },
        { type = "text", ts = BASE_TS, content = "shared ts second codex item" },
    }
    assert(environment.t.writeDayHistory(DATE, records))
    environment.t.restorePersistentHistory()

    local entries = environment.t.searchPersistentHistory("shared ts", "text")
    check_equal(#entries, 2, "two ordinary records share the timestamp")
    local keys = {}
    for _, entry in ipairs(entries) do
        check(not keys[entry.sourceKey], "sourceKey must be unique per record")
        keys[entry.sourceKey] = true
    end

    check(environment.t.pinClipboardEntry(entries[1]))
    check(environment.t.pinClipboardEntry(entries[2]), "second record with the same ts pins too")
    local pinned = environment.t.readPinnedHistory()
    check_equal(#pinned, 2, "both records are pinned")
    check_equal(pinned[1].ts, BASE_TS, "original clipboard ts preserved")
    check_equal(pinned[2].ts, BASE_TS, "original clipboard ts preserved")
    check(pinned[1].id ~= pinned[2].id, "pinned ids are distinct")
    check(pinned[1].pinnedAt >= BASE_TS, "pinnedAt is the pin time")

    -- Duplicate pin attempts must not duplicate the record.
    check(environment.t.pinClipboardEntry(entries[1]), "duplicate pin is idempotent")
    check_equal(#environment.t.readPinnedHistory(), 2, "duplicate pin created no extra record")
end)

-------------------------------------------------------------------------------
-- Issue A: pinned search covers the whole pinned collection

test("pinned search returns every and only matching pinned text record", function()
    local environment = new_environment("search")
    seed_codex_day(environment)

    -- Pin two matching records plus one non-matching record.
    local ordinary = environment.t.searchPersistentHistory("codex", "text")
    check_equal(#ordinary, 3, "ordinary search finds every codex record")
    environment.pin_matching("codex relay notes")
    environment.pin_matching("CODEX config")
    environment.pin_matching("ordinary note without")

    local matches = environment.t.searchPinnedHistory("codex", "all")
    check_equal(#matches, 2, "pinned search returns exactly the matching pinned records")
    for _, entry in ipairs(matches) do
        check(entry.isPinned, "match is a pinned record")
        check(string.lower(entry.content):find("codex", 1, true), "match contains the query")
    end

    local case_insensitive = environment.t.searchPinnedHistory("CODEX", "all")
    check_equal(#case_insensitive, 2, "search is case-insensitive like ordinary history")

    local multiline = environment.t.searchPinnedHistory("multiline", "all")
    check_equal(#multiline, 1, "multiline pinned content is searchable")

    local unicode = environment.t.searchPinnedHistory("résumé ✓", "all")
    check_equal(#unicode, 0, "the unicode record is not pinned in this scenario")
end)

test("pinned search never includes unpinned records", function()
    local environment = new_environment("scope")
    seed_codex_day(environment)
    environment.pin_first_matching("codex", "text")

    local pinned_matches = environment.t.searchPinnedHistory("codex", "all")
    check_equal(#pinned_matches, 1, "one pinned match")
    local ordinary_matches = environment.t.searchPersistentHistory("codex", "all")
    check_equal(#ordinary_matches, 3, "ordinary search keeps finding all three")
    for _, entry in ipairs(pinned_matches) do
        check_equal(entry.content, CODEX_TEXTS[1], "only the pinned record is returned")
    end
end)

test("pinned search reads the full collection, not a page or cache", function()
    local environment = new_environment("full-collection")
    local contents = {}
    for index = 1, 90 do
        contents[index] = "pinned record " .. index .. (index % 9 == 0 and " codex needle" or "")
    end
    environment.seed_text_day(DATE, contents, BASE_TS)
    environment.t.restorePersistentHistory()

    local entries = environment.t.searchPersistentHistory("pinned record", "text")
    check_equal(#entries, 90, "all ordinary records loaded")
    for _, entry in ipairs(entries) do
        assert(environment.t.pinClipboardEntry(entry))
    end
    check_equal(#environment.t.readPinnedHistory(), 90, "90 pinned records")

    local matches = environment.t.searchPinnedHistory("codex needle", "all")
    check_equal(#matches, 10, "every record beyond the first 32 is searched")
    local unique = {}
    for _, entry in ipairs(matches) do
        check(not unique[entry.id], "no duplicate pinned match")
        unique[entry.id] = true
    end
end)

test("pinned type filters combine with Pin and search", function()
    local environment = new_environment("types")
    seed_codex_day(environment)
    environment.seed_image_day("2026-11-06", "20261106101010", BASE_TS - 86400)
    environment.pin_first_matching("codex", "text")
    local images = environment.t.searchPersistentHistory("[image]", "image")
    check_equal(#images, 1, "one ordinary image")
    check(environment.t.pinClipboardEntry(images[1]), "pin the image")

    local text_matches = environment.t.searchPinnedHistory("", "text")
    check_equal(#text_matches, 1, "Pin + Text returns pinned text only")
    local image_matches = environment.t.searchPinnedHistory("", "image")
    check_equal(#image_matches, 1, "Pin + Images returns pinned images only")
    check_equal(image_matches[1].type, "image", "image record type")
    check_equal(#environment.t.searchPinnedHistory("", "none"), 0, "Text+Images selected means no type")
    check_equal(#environment.t.searchPinnedHistory("codex", "image"), 0,
        "a text query does not match pinned image pixels")
    check_equal(#environment.t.searchPinnedHistory("codex", "text"), 1, "Pin + Text + query")
end)

-------------------------------------------------------------------------------
-- panel integration: scope, query preservation, and result counts

test("Pin scope, type filter, and query are preserved across scope changes", function()
    local environment = new_environment("panel")
    seed_codex_day(environment)
    environment.seed_image_day("2026-11-06", "20261106101010", BASE_TS - 86400)
    environment.pin_first_matching("codex", "text")
    local images = environment.t.searchPersistentHistory("[image]", "image")
    environment.t.pinClipboardEntry(images[1])
    environment.t.restorePersistentHistory()

    local function send(body)
        environment.t.handleMessage({ body = body })
        return environment.t.panelState()
    end

    local state = send({ action = "pinScope", index = 0, query = "", kind = "all" })
    check(state.pinned, "Pin scope is active")
    check_equal(state.dateFilter, nil, "date scope is cleared")
    check_equal(state.menuCount, 2, "both pinned records listed")
    check_equal(panel_count_text(), "2 matching items", "count matches the pinned set")

    state = send({ action = "pinScope", index = 0, query = "codex", kind = "all" })
    check(state.pinned, "Pin scope stays active during search")
    check_equal(state.query, "codex", "query preserved")
    check_equal(state.menuCount, 1, "only the matching pinned record")
    check_equal(panel_count_text(), "1 matching items", "count matches the filtered pinned set")

    state = send({ action = "filter", index = 0, query = "codex", kind = "image" })
    check(state.pinned, "Pin scope survives the type filter")
    check_equal(state.query, "codex", "query survives the type filter")
    check_equal(state.kind, "image", "image filter recorded")
    check_equal(state.menuCount, 0, "no pinned image matches the text query")
    check_equal(panel_count_text(), "0 matching items", "count matches the empty pinned result set")

    state = send({ action = "filter", index = 0, query = "codex", kind = "text" })
    check_equal(state.menuCount, 1, "Pin + Text + query returns the pinned text match")
    check_equal(panel_count_text(), "1 matching items", "Pin + Text + query count")

    state = send({ action = "dateFilter", index = 0, query = "", kind = "all", dateKey = "pinned" })
    check(state.pinned, "the pinned scope key restores Pin instead of a date")
    check_equal(state.menuCount, 2, "full pinned collection restored")

    state = send({ action = "dateFilter", index = 0, query = "", kind = "text", dateKey = DATE })
    check(not state.pinned, "date scope leaves the Pin scope")
    check_equal(state.kind, "text", "type filter preserved across the scope change")
    check_equal(state.menuCount, 5, "the date's ordinary text records")

    state = send({ action = "showLatest", index = 0, query = "codex", kind = "text" })
    check(not state.pinned, "search from All Dates is not pinned")
    check_equal(state.menuCount, 3, "ordinary search finds all three codex records")
    check_equal(state.searchCacheCollection, "history", "the ordinary search cache is collection-tagged")
end)

test("an ordinary search cache is never reused as a pinned result set", function()
    local environment = new_environment("cache")
    seed_codex_day(environment)
    environment.pin_first_matching("codex", "text")
    environment.t.restorePersistentHistory()

    local function send(body)
        environment.t.handleMessage({ body = body })
        return environment.t.panelState()
    end

    local state = send({ action = "search", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 3, "ordinary search result set")
    check_equal(state.searchCacheCollection, "history", "cache tagged as history")
    check_equal(state.searchCacheCount, 3, "cached ordinary matches")

    state = send({ action = "pinScope", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 1, "the pinned result set is computed independently")
    for _, entry in ipairs(state.menuData) do
        check(entry.isPinned, "every pinned entry is a pinned record")
    end
    check_equal(state.searchCacheCollection, "history", "the pinned path did not overwrite the cache")

    state = send({ action = "showLatest", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 3, "returning to All Dates reuses the history cache")
end)

-------------------------------------------------------------------------------
-- migration

test("legacy contentPath pins migrate into JSON content and drop payload files", function()
    local environment = new_environment("migration")
    local legacy_text_path = environment.pinned .. "/legacy-1.txt"
    write_file(legacy_text_path, "legacy pinned codex payload with\nnewlines")
    local legacy_missing = environment.pinned .. "/legacy-2.txt"
    local image_path = environment.pinned .. "/pinned-images/legacy-image.png"
    local thumbnail_path = environment.pinned .. "/pinned-thumbnails/legacy-image.jpg"
    write_file(image_path, "STUB-PNG-PAYLOAD\n")
    write_file(thumbnail_path, "STUB-JPEG-PAYLOAD\n")

    write_file(environment.pinned_history, STUB.json_encode({
        {
            id = "legacy-1",
            type = "text",
            ts = BASE_TS,
            pinnedAt = BASE_TS + 10,
            sourceKey = "2026-11-07:" .. tostring(BASE_TS) .. ":text",
            contentPath = legacy_text_path,
        },
        {
            type = "image",
            ts = BASE_TS + 20,
            imagePath = image_path,
            thumbnailPath = thumbnail_path,
        },
        {
            id = "legacy-missing",
            type = "text",
            ts = BASE_TS + 30,
            sourceKey = "2026-11-07:" .. tostring(BASE_TS + 30) .. ":text",
            contentPath = legacy_missing,
        },
    }, true))

    check(environment.t.migratePinnedHistory(), "migration runs")

    local records = environment.t.readPinnedHistory()
    check_equal(#records, 3, "every legacy record is preserved")
    check_equal(records[1].content, "legacy pinned codex payload with\nnewlines", "text moved into content")
    check(records[1].contentPath == nil, "contentPath removed after a successful copy")
    check(STUB.fs.attributes(legacy_text_path) == nil, "legacy payload file removed after persistence")
    check(STUB.fs.attributes(environment.t.paths.pinnedMigrationBackupPath), "pre-migration backup kept")

    check(type(records[2].id) == "string", "id assigned to the legacy image record")
    check_equal(records[2].pinnedAt, BASE_TS + 20, "pinnedAt falls back to the clipboard timestamp")
    check_equal(records[2].imagePath, image_path, "legacy image path stays readable")
    check_equal(records[2].thumbnailPath, thumbnail_path, "legacy thumbnail path stays readable")
    check(STUB.fs.attributes(image_path), "legacy image file kept")
    check(STUB.fs.attributes(thumbnail_path), "legacy thumbnail file kept")

    check_equal(records[3].content, "", "missing payload preserved as an empty record")
    check_equal(records[3].contentPath, legacy_missing, "reference kept when the payload is missing")
    check_equal(records[3].id, "legacy-missing", "id preserved")
    check(#STUB.logs_containing("Pinned text payload file is missing") > 0, "missing payload logged")

    local entries = environment.t.loadPinnedEntries()
    check_equal(#entries, 3, "all migrated records produce entries")
    check_equal(#environment.t.searchPinnedHistory("codex", "all"), 1, "migrated text is searchable")
    check_equal(#environment.t.searchPinnedHistory("", "image"), 1, "migrated image is listed")

    check(not environment.t.migratePinnedHistory(), "a second migration is a no-op")
end)

test("failed migration preserves recoverable data", function()
    local environment = new_environment("migration-failure")
    local legacy_text_path = environment.pinned .. "/legacy-fail.txt"
    write_file(legacy_text_path, "recoverable legacy codex payload")
    local raw = STUB.json_encode({ {
        id = "legacy-fail",
        type = "text",
        ts = BASE_TS,
        pinnedAt = BASE_TS + 5,
        sourceKey = "2026-11-07:" .. tostring(BASE_TS) .. ":text",
        contentPath = legacy_text_path,
    } }, true)
    write_file(environment.pinned_history, raw)

    shell("chmod 500 " .. shquote(environment.pinned))
    local migrated = environment.t.migratePinnedHistory()
    shell("chmod 755 " .. shquote(environment.pinned))

    check(not migrated, "migration reports failure")
    check_equal(read_file(environment.pinned_history), raw, "the pinned index is unchanged")
    check(STUB.fs.attributes(legacy_text_path), "the legacy payload file is preserved")
    check_equal(#environment.t.readPinnedHistory(), 1, "the collection is never replaced by an empty array")
    check(#STUB.logs_containing("migration failed") > 0, "failure logged with a diagnostic")
end)

test("corrupt pinned JSON is preserved and reported, not emptied", function()
    local environment = new_environment("corrupt")
    local raw = "{ this is not valid json"
    write_file(environment.pinned_history, raw)
    check_equal(#environment.t.readPinnedHistory(), 0, "an undecodable index yields no records")
    check(not environment.t.migratePinnedHistory(), "migration refuses undecodable JSON")
    check_equal(read_file(environment.pinned_history), raw, "the damaged file is preserved untouched")
    check(#STUB.logs_containing("Invalid pinned history JSON") > 0, "decode failure logged")
end)

test("load-time migration converts legacy data before the panel opens", function()
    local environment = new_environment("load-migration")
    -- The Spoon's own load path created the pinned root; write legacy data and
    -- reload the module so its startup migration runs.
    local legacy_text_path = environment.pinned .. "/load-legacy.txt"
    write_file(legacy_text_path, "legacy payload loaded at startup codex")
    write_file(environment.pinned_history, STUB.json_encode({ {
        type = "text",
        ts = BASE_TS,
        contentPath = legacy_text_path,
    } }, true))

    local reloaded = new_environment("load-migration", environment.home)
    check_equal(reloaded.root, environment.root, "the reloaded module shares the sandbox data root")
    local records = reloaded.t.readPinnedHistory()
    check_equal(#records, 1, "one migrated record")
    check_equal(records[1].content, "legacy payload loaded at startup codex", "content migrated at load")
    check(type(records[1].id) == "string", "a stable id was assigned at load")
    check(STUB.fs.attributes(legacy_text_path) == nil, "legacy file removed after load migration")
    check_equal(#reloaded.t.searchPinnedHistory("codex", "all"), 1, "the load-migrated record is searchable")
end)

test("retention cleanup never removes the pinned collection", function()
    local environment = new_environment("retention")
    seed_codex_day(environment)
    environment.pin_first_matching("codex", "text")
    local expired = "1999-01-01"
    assert(environment.t.writeDayHistory(expired, { { type = "text", ts = 915148800, content = "expired" } }))
    check(STUB.fs.attributes(environment.date_directory(expired)), "expired folder exists")

    environment.t.removeExpiredHistoryDirectories(DATE)
    check(STUB.fs.attributes(environment.date_directory(expired)) == nil, "expired folder removed")
    check(STUB.fs.attributes(environment.pinned), "pinned root survives retention cleanup")
    check(STUB.fs.attributes(environment.pinned_history), "pinned index survives retention cleanup")
    check_equal(#environment.t.readPinnedHistory(), 1, "pinned record survives retention cleanup")
end)

-------------------------------------------------------------------------------
-- actions on JSON-backed pinned records

test("preview, copy, paste, and unpin work for JSON-backed pinned text", function()
    local environment = new_environment("actions-text")
    local phrase = secret_value("PINNED-ACTION-phi-epsilon phrase")
    environment.seed_text_day(DATE, { "plain note", phrase .. " with\na second line" }, BASE_TS)
    environment.t.restorePersistentHistory()
    local ordinary = environment.t.searchPersistentHistory("PINNED-ACTION", "text")
    check_equal(#ordinary, 1, "one seeded record")
    check(environment.t.pinClipboardEntry(ordinary[1]))
    environment.t.restorePersistentHistory()

    environment.t.setPanelState({ pinned = true })
    environment.t.updateClipboardPanel("PINNED-ACTION", "all", 0, false)
    check_equal(environment.t.panelState().menuCount, 1, "the pinned record is the search result")

    environment.t.handleMessage({ body = { action = "loadTextPreview", index = 1, kind = "text" } })
    local preview_script = STUB.state.scripts[#STUB.state.scripts]
    check(preview_script:find("window.setTextPreview", 1, false), "preview callback sent")
    check(preview_script:find("PINNED-ACTION", 1, true), "preview carries the stored text")

    STUB.reset_recorded_state()
    environment.t.handleMessage({ body = { action = "copyHistoryEntry", index = 1 } })
    check_equal(STUB.state.copied_text, phrase .. " with\na second line", "Copy writes the exact text")

    STUB.reset_recorded_state()
    environment.t.handleMessage({ body = { action = "paste", index = 1 } })
    check_equal(STUB.state.pasted_text, phrase .. " with\na second line", "click-to-paste writes the exact text")

    STUB.reset_recorded_state()
    environment.t.handleMessage({ body = { action = "unpin", index = 1 } })
    check_equal(#environment.t.readPinnedHistory(), 0, "unpin removed the pinned record")
    check_equal(#environment.t.readDayHistory(DATE), 2, "the ordinary history records remain")
    check_equal(#environment.t.searchPersistentHistory("PINNED-ACTION", "text"), 1,
        "the ordinary source record is untouched")
    check_equal(#environment.t.loadPinnedEntries(), 0, "no pinned entries remain")
end)

test("preview, copy, and unpin work for pinned images", function()
    local environment = new_environment("actions-image")
    local ordinary_record = environment.seed_image_day(DATE, "20261107113359", BASE_TS)
    environment.t.restorePersistentHistory()
    local images = environment.t.searchPersistentHistory("[image]", "image")
    check(environment.t.pinClipboardEntry(images[1]))
    environment.t.restorePersistentHistory()

    environment.t.setPanelState({ pinned = true })
    environment.t.updateClipboardPanel("", "image", 0, false)
    check_equal(environment.t.panelState().menuCount, 1, "the pinned image is listed")

    local card = environment.t.historyItemHTML(environment.t.panelState().menuData[1], 1)
    check(card:find('data-pinned="true"', 1, true), "card is marked pinned")
    check(card:find('src="data:image/jpeg;base64,', 1, true), "card renders the pinned thumbnail")

    environment.t.handleMessage({ body = { action = "loadImagePreview", index = 1, kind = "image" } })
    local preview_script = STUB.state.scripts[#STUB.state.scripts]
    check(preview_script:find("window.setImagePreview", 1, false), "image preview callback sent")

    STUB.reset_recorded_state()
    environment.t.handleMessage({ body = { action = "copyHistoryEntry", index = 1 } })
    check(STUB.state.copied_image, "Copy decodes and writes the pinned image")

    STUB.reset_recorded_state()
    environment.t.pasteHistoryEntry(1)
    check(STUB.state.pasted_image, "click-to-paste writes the pinned image")

    environment.t.handleMessage({ body = { action = "unpin", index = 1 } })
    check_equal(#environment.t.readPinnedHistory(), 0, "unpin removed the pinned image record")
    check_equal(#list_files(environment.pinned .. "/pinned-images"), 0, "pinned image file removed")
    check_equal(#list_files(environment.pinned .. "/pinned-thumbnails"), 0, "pinned thumbnail removed")
    check(STUB.fs.attributes(ordinary_record.imagePath), "ordinary image file kept")
    check(STUB.fs.attributes(ordinary_record.thumbnailPath), "ordinary thumbnail kept")
    check_equal(#environment.t.readDayHistory(DATE), 1, "ordinary image record kept")
end)

test("unpin with missing pinned files and a legacy sourceKey still succeeds", function()
    local environment = new_environment("unpin-edge")
    seed_codex_day(environment)
    local image_path = environment.pinned .. "/pinned-images/missing.png"
    write_file(environment.pinned_history, STUB.json_encode({
        {
            id = "legacy-legacy-key",
            type = "text",
            ts = BASE_TS,
            pinnedAt = BASE_TS,
            sourceKey = "2026-11-07:" .. tostring(BASE_TS) .. ":text",
            content = "unpinned legacy record",
        },
        {
            id = "missing-files",
            type = "image",
            ts = BASE_TS + 1,
            pinnedAt = BASE_TS,
            sourceKey = "2026-11-07:" .. tostring(BASE_TS + 1) .. ":image",
            imagePath = image_path,
            thumbnailPath = environment.pinned .. "/pinned-thumbnails/missing.jpg",
        },
    }, true))
    environment.t.invalidatePinnedIndex()

    local entries = environment.t.loadPinnedEntries()
    check_equal(#entries, 2, "both legacy records load")

    -- Ordinary entries carry the current 4-part sourceKey; legacy pins stored 3.
    local ordinary_entry = environment.t.metadataEntry(
        { type = "text", ts = BASE_TS, content = CODEX_TEXTS[1] }, DATE, 1)
    check(environment.t.pinClipboardEntry(ordinary_entry),
        "a legacy 3-part sourceKey must deduplicate the same ordinary record")
    check_equal(#environment.t.readPinnedHistory(), 2, "no duplicate pin was appended")

    check(environment.t.unpinClipboardEntry(entries[1]), "unpin by a legacy record works")
    check(environment.t.unpinClipboardEntry(entries[2]), "unpin works when the files are missing")
    check_equal(#environment.t.readPinnedHistory(), 0, "both records removed")
    check(STUB.fs.attributes(environment.pinned_history), "the pinned index still exists")
    check_equal(#environment.t.readDayHistory(DATE), 5, "ordinary history is untouched by unpin")
end)

test("Clear All clears the ordinary and pinned collections together", function()
    local environment = new_environment("clear-all")
    seed_codex_day(environment)
    environment.seed_image_day("2026-11-06", "20261106101010", BASE_TS - 86400)
    environment.pin_first_matching("codex", "text")
    local images = environment.t.searchPersistentHistory("[image]", "image")
    environment.t.pinClipboardEntry(images[1])
    check_equal(#environment.t.readPinnedHistory(), 2, "two pins exist before Clear All")

    -- Clear All while a Pin search is active.
    environment.t.setPanelState({ pinned = true, query = "codex", kind = "text" })
    environment.t.updateClipboardPanel("codex", "text", 0, false)
    environment.t.clearClipboardHistory()

    check_equal(#environment.t.readPinnedHistory(), 0, "the pinned collection is cleared")
    check_equal(#environment.t.searchPersistentHistory("codex", "text"), 0, "ordinary history is cleared")
    check_equal(#environment.t.loadPinnedEntries(), 0, "no pinned entries remain")
    check(STUB.fs.attributes(environment.pinned), "pinned storage recreated")
    check(STUB.fs.attributes(environment.pinned .. "/pinned-images"), "pinned image dir recreated")
    check(STUB.fs.attributes(environment.pinned .. "/pinned-thumbnails"), "pinned thumbnail dir recreated")
    check_equal(#list_files(environment.pinned .. "/pinned-images"), 0, "no pinned image files remain")
    check_equal(#list_files(environment.pinned .. "/pinned-thumbnails"), 0, "no pinned thumbnails remain")
    local state = environment.t.panelState()
    check(not state.pinned, "Clear All resets the Pin filter")
    check_equal(state.query, "", "Clear All resets the search query")
    check(STUB.state.reloads > 0, "Clear All reloads the configuration as designed")
end)

-------------------------------------------------------------------------------
-- ordinary history behavior must remain intact

test("ordinary history search, dates, and cards keep working", function()
    local environment = new_environment("ordinary")
    seed_codex_day(environment)
    environment.seed_image_day(DATE, "20261107103607", BASE_TS + 120)
    environment.seed_text_day("2026-11-06", { "earlier codex note", "older note" }, BASE_TS - 86400)
    environment.t.restorePersistentHistory()

    check_equal(#environment.t.searchPersistentHistory("codex", "text"), 4, "cross-date text search")
    check_equal(#environment.t.searchPersistentHistory("codex", "image"), 0, "image search has no text hits")
    check_equal(#environment.t.searchPersistentHistory("codex", "all"), 4, "mixed search")

    local matches = environment.t.searchPersistentHistory("codex", "all")
    local today = count_matching(matches, function(entry) return entry.dateKey == DATE end)
    check_equal(today, 3, "today's matches counted for the date subset")

    environment.t.setPanelState({ dateFilter = DATE, pinned = false, query = "codex", kind = "all" })
    environment.t.updateClipboardPanel("codex", "all", 0, false)
    check_equal(environment.t.panelState().menuCount, 3, "date-scoped search subset")

    environment.t.setPanelState({ dateFilter = DATE, pinned = false, query = "", kind = "all" })
    environment.t.updateClipboardPanel("", "all", 0, false)
    check_equal(panel_count_text(), "6 matching items", "date-scope total is the day's record count")

    environment.t.setPanelState({ allDates = true, query = "", kind = "all" })
    environment.t.updateClipboardPanel("", "all", 0, false)
    local state = environment.t.panelState()
    check_equal(state.menuCount, 8, "All Dates cache includes text and image records")
    check_equal(panel_count_text(), "8 matching items", "All Dates count")

    environment.t.setPanelState({ kind = "image" })
    environment.t.updateClipboardPanel("", "image", 0, false)
    check_equal(panel_count_text(), "1 matching items", "Images filter counts ordinary images")
    local image_card = environment.t.historyItemHTML(environment.t.panelState().menuData[1], 1)
    check(image_card:find('data-pinned="false"', 1, true), "an ordinary image card is not pinned")

    environment.t.setPanelState({ kind = "text" })
    environment.t.updateClipboardPanel("", "text", 0, false)
    local text_card = environment.t.historyItemHTML(environment.t.panelState().menuData[1], 1)
    check(text_card:find('<div class="text-preview">', 1, true), "an ordinary text card renders a preview")

    check_equal(#environment.t.searchPersistentHistory("nothing matches this query", "all"), 0,
        "a query with no matches returns an empty set")
end)

test("ordinary cards are marked pinned and offer unpin", function()
    local environment = new_environment("marker")
    seed_codex_day(environment)
    local pinned_entry = environment.pin_first_matching("codex", "text")

    environment.t.restorePersistentHistory()
    environment.t.setPanelState({ pinned = false, query = "", kind = "text" })
    environment.t.updateClipboardPanel("", "text", 0, false)
    local menu = environment.t.panelState().menuData
    local marked, marked_id
    for index, entry in ipairs(menu) do
        local card = environment.t.historyItemHTML(entry, index)
        if entry.sourceKey == pinned_entry.sourceKey then
            check(card:find('data-pinned="true"', 1, true), "the pinned ordinary record shows Unpin")
            marked, marked_id = entry, entry.id
        end
    end
    check(marked, "found the matching ordinary entry")
    check_equal(marked_id, environment.t.readPinnedHistory()[1].id, "the marker carries the pinned record id")

    check(environment.t.unpinClipboardEntry(marked), "Unpin from the ordinary view works")
    check_equal(#environment.t.readPinnedHistory(), 0, "record removed")
    check_equal(#environment.t.readDayHistory(DATE), 5, "ordinary records intact")
end)

test("empty collection and panel rendering edge cases", function()
    local environment = new_environment("empty")
    check_equal(#environment.t.readPinnedHistory(), 0, "empty pinned index")
    check_equal(#environment.t.loadPinnedEntries(), 0, "no pinned entries")
    check_equal(#environment.t.searchPinnedHistory("codex", "all"), 0, "search on an empty collection")

    environment.t.setPanelState({ pinned = true, query = "codex", kind = "all" })
    environment.t.updateClipboardPanel("codex", "all", 0, false)
    check_equal(environment.t.panelState().menuCount, 0, "no results in an empty pinned view")
    check_equal(panel_count_text(), "0 matching items", "empty count")

    check(not environment.t.pinClipboardEntry(nil), "pinning nil is refused")
    check(not environment.t.pinClipboardEntry({ type = "text" }), "pinning content-less text is refused")
    check(not environment.t.pinClipboardEntry({ type = "image", imagePath = "/nope/missing.png" }),
        "pinning a missing image is refused")
    check(not environment.t.unpinClipboardEntry(nil), "unpinning nil is refused")
    check(not environment.t.unpinClipboardEntry({ id = "absent" }), "unpinning an absent id is refused")
    check_equal(#environment.t.readPinnedHistory(), 0, "the collection stayed empty")
end)

test("clipboard payloads never reach the log", function()
    local environment = new_environment("privacy")
    local phrase = secret_value("PRIVACY-CHECK-delta-omega-payload")
    environment.seed_text_day(DATE, { phrase .. " codex" }, BASE_TS)
    environment.t.restorePersistentHistory()
    environment.t.pinClipboardEntry(environment.t.searchPersistentHistory("PRIVACY-CHECK", "text")[1])
    environment.t.setPanelState({ pinned = true })
    environment.t.updateClipboardPanel("PRIVACY-CHECK", "all", 0, false)
    environment.t.handleMessage({ body = { action = "copyHistoryEntry", index = 1 } })
    environment.t.handleMessage({ body = { action = "unpin", index = 1 } })
    environment.t.clearClipboardHistory()

    for _, entry in ipairs(STUB.state.logs) do
        for _, secret in ipairs(SECRETS) do
            check(not entry.message:find(secret, 1, true),
                "logs must not contain clipboard text: " .. entry.message)
        end
    end
end)

-------------------------------------------------------------------------------
-- report

for _, line in ipairs(results) do
    print(line)
end
print(string.format("%d passed, %d failed (%d sandboxes under /tmp/sux-clipboard-history-tests)",
    #results - #failures, #failures, #sandboxes))
if #failures > 0 then
    print("failed scenarios: " .. table.concat(failures, "; "))
    os.exit(1)
end
for _, path in ipairs(sandboxes) do
    shell("rm -rf " .. shquote(path))
end
print("sandboxes cleaned up")
