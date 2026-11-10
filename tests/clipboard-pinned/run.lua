-- Isolated regression harness for the Clipboard History Spoon's pinned
-- collection. It runs the real init.lua against a sandboxed data root with the
-- hs_stub filesystem/WebView/pasteboard shims, so no Hammerspoon instance,
-- window, clipboard, or real user history is touched.
--
--   lua tests/clipboard-pinned/run.lua            # from the repository root
--   SPOON_PATH=/path/to/init.lua lua tests/clipboard-pinned/run.lua
--
-- The generated panel HTML (header chips, card markup, pin marker, result
-- count) and the Lua state behind it are asserted here. Desktop pointer and
-- keyboard behavior can be confirmed with Peekaboo when a task asks for it;
-- see AGENTS.md "Visual testing".

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

-- Writes a pinned text record that has no ordinary twin, so All-view
-- aggregation, search, and cache behavior can be measured against content that
-- exists only in the pinned collection.
local function seed_pinned_text_only(environment, content, timestamp, id)
    local records = environment.t.readPinnedHistory()
    records[#records + 1] = {
        id = id,
        type = "text",
        ts = timestamp,
        pinnedAt = timestamp + 7,
        content = content,
    }
    assert(environment.t.writePinnedHistory(records))
    environment.t.invalidatePinnedIndex()
    return records[#records]
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

test("the All view shows one pinned card per event; date scopes keep the marker", function()
    local environment = new_environment("marker")
    seed_codex_day(environment)
    local pinned_entry = environment.pin_first_matching("codex", "text")
    local pin_id = environment.t.readPinnedHistory()[1].id

    environment.t.restorePersistentHistory()
    -- All: the ordinary record remains the representative, with the pin
    -- identity attached so rendering shows its marker and offers Unpin.
    environment.t.setPanelState({ allDates = true, pinned = false, query = "", kind = "text" })
    environment.t.updateClipboardPanel("", "text", 0, false)
    local pinned_seen, pinned_index, duplicates, marked_id
    for index, entry in ipairs(environment.t.panelState().menuData) do
        local card = environment.t.historyItemHTML(entry, index)
        if entry.sourceKey == pinned_entry.sourceKey then
            pinned_seen, pinned_index, marked_id = entry, index, entry.id
            check(entry.isPinned == true, "the ordinary representative is marked pinned")
            check(card:find('data-pinned="true"', 1, true), "the unified card is pinned (Unpin menu)")
            check(card:find('class="pin-mark"', 1, true), "the unified card carries the pin marker")
        elseif entry.id == pin_id then
            duplicates = (duplicates or 0) + 1
        end
    end
    check(pinned_seen, "the pinned record is represented by its ordinary history card in All")
    check_equal(marked_id, pin_id, "the card carries the pinned record id")
    check_equal(duplicates, nil, "the pinned-only duplicate is not rendered")
    check_equal(environment.t.panelState().menuCount, 5, "one card per clipboard event")

    -- Context-menu Copy and click-to-paste work on the unified card, reading the
    -- pinned payload through the shared hydration path.
    STUB.reset_recorded_state()
    environment.t.handleMessage({ body = { action = "copyHistoryEntry", index = pinned_index, query = "", kind = "text" } })
    check_equal(STUB.state.copied_text, pinned_entry.content, "Copy from the unified card copies the pinned text")
    STUB.reset_recorded_state()
    environment.t.handleMessage({ body = { action = "paste", index = pinned_index } })
    check_equal(STUB.state.pasted_text, pinned_entry.content, "click-to-paste pastes the pinned text")

    check(environment.t.unpinClipboardEntry(pinned_seen), "Unpin from the All view works")
    check_equal(#environment.t.readPinnedHistory(), 0, "only the pinned copy is removed")
    environment.t.updateClipboardPanel("", "text", 0, false)
    local restored
    for index, entry in ipairs(environment.t.panelState().menuData) do
        if entry.sourceKey == pinned_entry.sourceKey then
            restored = entry
            local card = environment.t.historyItemHTML(entry, index)
            check(card:find('data-pinned="false"', 1, true), "the ordinary record is unpinned again")
            check(not card:find('class="pin-mark"', 1, true), "no pin marker after Unpin")
        end
    end
    check(restored, "the ordinary record stays available in All after Unpin")
    check_equal(environment.t.panelState().menuCount, 5, "card count is unchanged by Unpin")
    check_equal(#environment.t.readDayHistory(DATE), 5, "ordinary records intact")

    -- Date scopes stay ordinary-history-only and keep the in-place Unpin marker.
    environment.pin_first_matching("codex", "text")
    environment.t.setPanelState({ allDates = false, dateFilter = DATE, pinned = false, query = "", kind = "text" })
    environment.t.updateClipboardPanel("", "text", 0, false)
    local state = environment.t.panelState()
    check_equal(state.menuCount, 5, "the date view lists that date's ordinary records only")
    local marked_cards = 0
    for index, entry in ipairs(state.menuData) do
        if environment.t.historyItemHTML(entry, index):find('data-pinned="true"', 1, true) then
            marked_cards = marked_cards + 1
        end
    end
    check_equal(marked_cards, 1, "the date view marks the pinned record so it offers Unpin")
end)

test("All merges ordinary and pinned records into one deduplicated collection", function()
    local environment = new_environment("all-merge")
    seed_codex_day(environment)
    environment.seed_image_day(DATE, "20261107103607", BASE_TS + 120)
    environment.seed_image_day("2026-11-06", "20261106101010", BASE_TS - 86400)
    environment.pin_first_matching("codex", "text")
    local images = environment.t.searchPersistentHistory("[image]", "image")
    check(environment.t.pinClipboardEntry(images[#images]), "the older image is pinned")
    environment.t.restorePersistentHistory()

    environment.t.setPanelState({ allDates = true, pinned = false, query = "", kind = "all" })
    environment.t.updateClipboardPanel("", "all", 0, false)
    local state = environment.t.panelState()
    check_equal(state.menuCount, 7, "five text plus two images, each event once")
    local pinned_cards, text_cards, image_cards = 0, 0, 0
    for _, entry in ipairs(state.menuData) do
        if entry.type == "text" then text_cards = text_cards + 1 else image_cards = image_cards + 1 end
        if entry.isPinned then pinned_cards = pinned_cards + 1 end
    end
    check_equal(pinned_cards, 2, "both pinned records appear in All")
    check_equal(text_cards, 5, "text cards in the unified collection")
    check_equal(image_cards, 2, "image cards in the unified collection")
    check_equal(panel_count_text(), "7 matching items", "the count is the deduplicated collection")

    environment.t.setPanelState({ kind = "text" })
    environment.t.updateClipboardPanel("", "text", 0, false)
    check_equal(panel_count_text(), "5 matching items", "All + Text is ordinary text plus pinned text")
    check_equal(environment.t.panelState().kind, "text", "the Text type filter is recorded")

    environment.t.setPanelState({ kind = "image" })
    environment.t.updateClipboardPanel("", "image", 0, false)
    check_equal(panel_count_text(), "2 matching items", "All + Images is ordinary images plus pinned images")
    check_equal(environment.t.panelState().kind, "image", "the Images type filter is recorded")

    environment.t.setPanelState({ pinned = true })
    environment.t.updateClipboardPanel("", "all", 0, false)
    check_equal(environment.t.panelState().menuCount, 2, "Pin stays pinned-only")
    check_equal(panel_count_text(), "2 matching items", "Pin count")

    environment.t.setPanelState({ pinned = true, kind = "image" })
    environment.t.updateClipboardPanel("", "image", 0, false)
    check_equal(environment.t.panelState().menuCount, 1, "Pin + Images is pinned images only")

    environment.t.setPanelState({ pinned = false, dateFilter = DATE })
    environment.t.updateClipboardPanel("", "all", 0, false)
    check_equal(environment.t.panelState().menuCount, 6, "a date scope is ordinary history only")
end)

test("Load more extends the unified All collection without duplicating pins", function()
    local environment = new_environment("all-loadmore")
    local many = {}
    for index = 1, 40 do many[index] = "bulk note " .. index .. " codex" end
    environment.seed_text_day(DATE, many, BASE_TS)
    seed_pinned_text_only(environment, "pinned-only bulk codex", BASE_TS + 5000, "pin-bulk-1")
    environment.t.restorePersistentHistory()

    environment.t.setPanelState({ allDates = true, pinned = false, query = "", kind = "all" })
    environment.t.updateClipboardPanel("", "all", 0, false)
    local state = environment.t.panelState()
    check_equal(state.menuCount, 33, "the first page is 32 ordinary records plus every pin")

    local cursor
    for index = #STUB.state.scripts, 1, -1 do
        local script = STUB.state.scripts[index]
        if script:find("loadMore", 1, true) then
            cursor = script:match('data%-index=%S-(%d+)')
            if cursor then break end
        end
    end
    check(cursor, "a Load more control is offered for the ordinary side")

    environment.t.handleMessage({ body = { action = "loadMore", index = tonumber(cursor), query = "", kind = "all" } })
    state = environment.t.panelState()
    check_equal(state.menuCount, 41, "Load more appended the remaining ordinary records")
    check_equal(panel_count_text(), "41 matching items", "the count covers both collections")
    local pins, seen = 0, {}
    for _, entry in ipairs(state.menuData) do
        if entry.isPinned then pins = pins + 1 end
        local key = entry.id or entry.sourceKey
        check(not seen[key], "no card is rendered twice for one event")
        seen[key] = true
    end
    check_equal(pins, 1, "the pinned record appears exactly once after Load more")
end)

test("pinning from the All view collapses the pair into one pinned card", function()
    local environment = new_environment("all-pin")
    seed_codex_day(environment)
    environment.t.restorePersistentHistory()

    environment.t.setPanelState({ allDates = true, pinned = false, query = "", kind = "text" })
    environment.t.updateClipboardPanel("", "text", 0, false)
    local state = environment.t.panelState()
    check_equal(state.menuCount, 5, "ordinary collection before pinning")

    -- Pin the card the user right-clicks: the context-menu Pin action runs the
    -- same handler with the All menuData index.
    local target_index
    for index, entry in ipairs(state.menuData) do
        if entry.content == CODEX_TEXTS[2] then target_index = index end
    end
    check(target_index, "the target ordinary record is in All")
    STUB.reset_recorded_state()
    environment.t.handleMessage({ body = { action = "pin", index = target_index, query = "", kind = "text" } })
    check(not table.concat(STUB.state.alerts or {}, "\n"):find("Pinned clipboard item", 1, true), "successful Pin shows no confirmation toast")

    state = environment.t.panelState()
    check_equal(#environment.t.readPinnedHistory(), 1, "one pinned record was created")
    check_equal(state.menuCount, 5, "the pair stays one card; the count does not double")
    check_equal(panel_count_text(), "5 matching items", "count is stable across pinning")
    local pinned_entries, matching_ordinary = 0, 0
    for _, entry in ipairs(state.menuData) do
        if entry.isPinned then pinned_entries = pinned_entries + 1 end
        if entry.content == CODEX_TEXTS[2] and not entry.isPinned then matching_ordinary = matching_ordinary + 1 end
    end
    check_equal(pinned_entries, 1, "the pinned copy is the card that remains")
    check_equal(matching_ordinary, 0, "the ordinary twin is not rendered beside it")
    check_equal(#environment.t.readDayHistory(DATE), 5, "pinning left ordinary history intact")

    -- Unpinning from the same view restores the ordinary card.
    local pin_index
    for index, entry in ipairs(state.menuData) do
        if entry.isPinned then pin_index = index end
    end
    environment.t.handleMessage({ body = { action = "unpin", index = pin_index, query = "", kind = "text" } })
    check_equal(#environment.t.readPinnedHistory(), 0, "the pinned copy is gone")
    local restored = 0
    for _, entry in ipairs(environment.t.panelState().menuData) do
        if entry.content == CODEX_TEXTS[2] then restored = restored + 1 end
    end
    check_equal(restored, 1, "the ordinary record is visible again after Unpin")
end)

test("records that share a timestamp are not deduplicated", function()
    local environment = new_environment("all-ts")
    assert(environment.t.writeDayHistory(DATE, {
        { type = "text", ts = BASE_TS, content = "twin alpha codex" },
        { type = "text", ts = BASE_TS, content = "twin beta codex" },
    }))
    environment.t.restorePersistentHistory()
    local entries = environment.t.searchPersistentHistory("twin", "text")
    check_equal(#entries, 2, "two ordinary records share one timestamp")
    check(environment.t.pinClipboardEntry(entries[1]), "pin one twin")

    environment.t.setPanelState({ allDates = true, pinned = false, query = "", kind = "all" })
    environment.t.updateClipboardPanel("", "all", 0, false)
    local state = environment.t.panelState()
    check_equal(state.menuCount, 2, "identity, not the timestamp, drives deduplication")
    local pinned_cards, plain_cards = 0, 0
    for _, entry in ipairs(state.menuData) do
        if entry.isPinned then pinned_cards = pinned_cards + 1 else plain_cards = plain_cards + 1 end
    end
    check_equal(pinned_cards, 1, "the pinned twin")
    check_equal(plain_cards, 1, "the untouched twin stays as its own card")
    check_equal(panel_count_text(), "2 matching items", "count keeps both events")
end)

test("a rebuilt daily index does not break pinned deduplication", function()
    local environment = new_environment("all-rebuild")
    environment.seed_text_day(DATE, { "rebuild alpha pinme", "rebuild beta", "rebuild gamma" }, BASE_TS)
    environment.t.restorePersistentHistory()
    local target = environment.t.searchPersistentHistory("pinme", "text")
    check_equal(#target, 1, "one seeded target")
    check(environment.t.pinClipboardEntry(target[1]), "pin one record")

    -- Rebuild the daily index in reverse: the file-position part of sourceKey
    -- no longer lines up with the pin, so payload identity must decide.
    local records = environment.t.readDayHistory(DATE)
    local reversed = {}
    for index = #records, 1, -1 do reversed[#reversed + 1] = records[index] end
    assert(environment.t.writeDayHistory(DATE, reversed))
    environment.t.invalidatePinnedIndex()
    environment.t.restorePersistentHistory()

    environment.t.setPanelState({ allDates = true, pinned = false, query = "", kind = "text" })
    environment.t.updateClipboardPanel("", "text", 0, false)
    local state = environment.t.panelState()
    local pinned_cards, twin, beta = 0, 0, 0
    for _, entry in ipairs(state.menuData) do
        if entry.isPinned then
            pinned_cards = pinned_cards + 1
        elseif entry.content == "rebuild alpha pinme" then
            twin = twin + 1
        elseif entry.content == "rebuild beta" then
            beta = beta + 1
        end
    end
    check_equal(pinned_cards, 1, "the pinned card is present")
    check_equal(twin, 0, "the pinned event stays one card, matched by payload identity")
    check_equal(beta, 1, "an unrelated record whose sourceKey moved is not folded away")
    check_equal(state.menuCount, 3, "three events, three cards")
    check_equal(panel_count_text(), "3 matching items", "the count uses the same identity rule")
end)

test("All search spans both collections while Pin and date searches stay scoped", function()
    local environment = new_environment("all-search")
    seed_codex_day(environment)
    seed_pinned_text_only(environment, "UNIFIED-ONLY codex pin payload", BASE_TS + 500, "pin-only-1")
    environment.t.restorePersistentHistory()

    local function send(body)
        environment.t.handleMessage({ body = body })
        return environment.t.panelState()
    end

    local state = send({ action = "search", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 4, "three ordinary matches plus the pinned-only record")
    check_equal(state.searchCacheCollection, "history", "the ordinary cache stays collection-tagged")
    check_equal(state.allCacheCollection, "all", "the merged set is cached as the All collection")
    check_equal(panel_count_text(), "4 matching items", "count reflects the merged set")
    local pinned_found
    for _, entry in ipairs(state.menuData) do
        if entry.isPinned then pinned_found = entry end
    end
    check(pinned_found, "the pinned record is part of the All search")
    check(type(pinned_found.content) == "string"
        and pinned_found.content:find("UNIFIED-ONLY", 1, true) ~= nil,
        "a pinned-only payload is found by full-text search")

    state = send({ action = "search", index = 0, query = "UNIFIED", kind = "all" })
    check_equal(state.menuCount, 1, "case-insensitive search reaches pinned-only content")
    check_equal(panel_count_text(), "1 matching items", "the pinned-only match is counted")

    state = send({ action = "pinScope", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 1, "Pin search stays pinned-only")

    state = send({ action = "dateFilter", index = 0, query = "codex", kind = "all", dateKey = "2026-11-06" })
    check_equal(state.menuCount, 0, "a date search stays scoped to that date")
    state = send({ action = "dateFilter", index = 0, query = "codex", kind = "all", dateKey = DATE })
    check_equal(state.menuCount, 3, "a date search never includes pinned records")

    state = send({ action = "showLatest", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 4, "returning to All restores the merged result set")
    check_equal(state.query, "codex", "the query is preserved across scope switches")

    state = send({ action = "filter", index = 0, query = "codex", kind = "text" })
    check_equal(state.menuCount, 4, "All + Text keeps ordinary and pinned text")
    state = send({ action = "filter", index = 0, query = "codex", kind = "image" })
    check_equal(state.menuCount, 0, "All + Images searches image metadata only")
    check_equal(state.query, "codex", "the query survives type switches")
end)

test("the All search cache is invalidated by pin, unpin, and Clear All", function()
    local environment = new_environment("all-cache")
    seed_codex_day(environment)
    environment.t.restorePersistentHistory()

    local function send(body)
        environment.t.handleMessage({ body = body })
        return environment.t.panelState()
    end

    local state = send({ action = "search", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 3, "ordinary-only All search")
    check_equal(state.allCacheCount, 3, "the All cache holds the merged set")

    seed_pinned_text_only(environment, "codex pinned extra", BASE_TS + 900, "pin-extra-1")
    state = send({ action = "search", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 4, "pinning invalidates the All cache")

    environment.t.unpinClipboardEntry(environment.t.readPinnedHistory()[1])
    state = send({ action = "search", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 3, "unpinning invalidates the All cache")

    -- An ordinary-history cache is never served as an All set, and Pin never
    -- overwrites the ordinary cache.
    check_equal(state.searchCacheCollection, "history", "the ordinary cache is separate from All")
    state = send({ action = "pinScope", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 0, "the Pin set is computed independently")
    check_equal(state.searchCacheCollection, "history", "the Pin path did not overwrite the ordinary cache")

    environment.t.clearClipboardHistory()
    state = send({ action = "search", index = 0, query = "codex", kind = "all" })
    check_equal(state.menuCount, 0, "Clear All empties both collections")
    check_equal(state.allCacheCount, 0, "Clear All emptied the All cache")
    check_equal(#environment.t.readPinnedHistory(), 0, "no pins remain")
end)

test("pinned and ordinary cards render with and without the pin marker", function()
    local environment = new_environment("all-cards")
    seed_codex_day(environment)
    environment.seed_image_day(DATE, "20261107103607", BASE_TS + 120)
    environment.pin_first_matching("codex", "text")
    local images = environment.t.searchPersistentHistory("[image]", "image")
    check(environment.t.pinClipboardEntry(images[1]), "the image is pinned")
    environment.t.restorePersistentHistory()

    for _, scope in ipairs({ "all", "pin" }) do
        environment.t.setPanelState({
            allDates = scope == "all", pinned = scope == "pin",
            query = "", kind = "all",
        })
        environment.t.updateClipboardPanel("", "all", 0, false)
        local marked_text, marked_image, plain_text, plain_image = 0, 0, 0, 0
        for index, entry in ipairs(environment.t.panelState().menuData) do
            local card = environment.t.historyItemHTML(entry, index)
            local has_mark = card:find('class="pin-mark"', 1, true) ~= nil
            local pinned_attr = card:find('data-pinned="true"', 1, true) ~= nil
            check(card:find('data-action="paste"', 1, true) ~= nil, "the card stays click-to-paste")
            check(card:find('tabindex="0"', 1, true) ~= nil
                or entry.type == "text", "image cards keep their focusable role")
            if pinned_attr then check(has_mark, "a pinned card shows the pin marker") end
            if has_mark then check(pinned_attr, "the pin marker implies a pinned card") end
            if entry.isPinned then
                local stamp = os.date("%Y-%m-%d %H:%M:%S", entry.ts)
                check(card:find(stamp, 1, true) ~= nil, "the original clipboard timestamp is shown")
                if entry.pinnedAt and os.date("%Y-%m-%d %H:%M:%S", entry.pinnedAt) ~= stamp then
                    check(not card:find(os.date("%Y-%m-%d %H:%M:%S", entry.pinnedAt), 1, true),
                        "pinnedAt is not presented as the card timestamp")
                end
            end
            if entry.type == "image" then
                if entry.isPinned then marked_image = marked_image + 1 else plain_image = plain_image + 1 end
            else
                if entry.isPinned then marked_text = marked_text + 1 else plain_text = plain_text + 1 end
            end
        end
        check_equal(marked_text, 1, "one pinned text card")
        check_equal(marked_image, 1, "one pinned image card")
        if scope == "all" then
            check(plain_text >= 1, "ordinary text cards remain in All")
        else
            check_equal(plain_text, 0, "the Pin scope has no ordinary cards")
        end
        check_equal(plain_image, 0, "the pinned image replaced its ordinary twin")
    end
end)

test("the filter bar is All, Pin, dates, separator, Text, Images", function()
    local environment = new_environment("all-chips")
    seed_codex_day(environment)
    environment.seed_image_day("2026-11-06", "20261106101010", BASE_TS - 86400)
    environment.t.restorePersistentHistory()
    local html = environment.t.panelHTML()

    local actions = html:match('<div class="actions">(.-)</div></header>')
    check(actions, "the filter bar renders")
    check(actions:find('>All</button>', 1, true) ~= nil, "the scope chip is labelled All")
    check(actions:find('All Dates', 1, true) == nil, "the All Dates label is gone")

    local function position(needle)
        local index = actions:find(needle, 1, true)
        return index or math.huge
    end
    local order = {
        position('data-action="dateScope"'),
        position('data-action="pinScope"'),
        position('data-action="dateFilter"'),
        position('class="filter-separator"'),
        position('data-filter="text"'),
        position('data-filter="image"'),
    }
    for index = 2, #order do
        check(order[index] > order[index - 1],
            "chip " .. tostring(index) .. " follows the previous chip in the required order")
    end
    local _, separator_count = actions:gsub('class="filter%-separator"', '')
    check_equal(separator_count, 1, "exactly one separator")
    local _, type_chip_count = actions:gsub('data%-action="filter"', '')
    check_equal(type_chip_count, 2, "only Text and Images are type chips")
    local _, scope_chip_count = actions:gsub('data%-action="dateScope"', '')
    scope_chip_count = scope_chip_count + select(2, actions:gsub('data%-action="pinScope"', ''))
    check_equal(scope_chip_count, 2, "All and Pin are the scope chips")
    local _, row_count = html:gsub('<div class="actions">', '')
    check_equal(row_count, 1, "one toolbar row")
    check(html:find('<div class="actions">', 1, true) ~= nil, "the toolbar row is the existing one")
    check(html:find('id="search"', 1, true) ~= nil, "the search box is unchanged")
    check(html:find("class=\"count\"", 1, true) ~= nil, "the result count is unchanged")
    check(html:find('.pin-mark {', 1, true) ~= nil, "the pin marker is styled in the panel CSS")
    check(html:find('pointer-events:none', 1, true) ~= nil, "the pin marker is click-through")
end)

test("the context menu is resolved per card and never shared between cards", function()
    local environment = new_environment("context-menu")
    seed_codex_day(environment)
    environment.seed_image_day(DATE, "20261107103607", BASE_TS + 300)
    environment.pin_first_matching("codex", "text")
    local images = environment.t.searchPersistentHistory("[image]", "image")
    check(environment.t.pinClipboardEntry(images[1]), "the image is pinned")
    environment.t.restorePersistentHistory()

    for _, scope in ipairs({ "all", "pin" }) do
        environment.t.setPanelState({
            allDates = scope == "all", pinned = scope == "pin", query = "", kind = "all",
        })
        environment.t.updateClipboardPanel("", "all", 0, false)
        local menu = environment.t.panelState().menuData
        local seen_uids, pinned_indexes, ordinary_indexes = {}, {}, {}
        for index, entry in ipairs(menu) do
            local card = environment.t.historyItemHTML(entry, index)
            local uid = card:match('data%-uid="([^"]*)"')
            check(uid and uid ~= "", "every card carries a stable data-uid")
            if scope == "all" then
                check(not seen_uids[uid], "card identities are unique in the All collection: " .. tostring(uid))
            end
            seen_uids[uid] = card
            check_equal(card:find('data-pinned="true"', 1, true) ~= nil, entry.isPinned == true,
                "data-pinned matches the entry at index " .. index)
            check_equal(card:find('class="pin-mark"', 1, true) ~= nil, entry.isPinned == true,
                "the pin marker matches the entry at index " .. index)
            if entry.isPinned then pinned_indexes[#pinned_indexes + 1] = index
            else ordinary_indexes[#ordinary_indexes + 1] = index end
        end
        check(#pinned_indexes >= 2, "the fixture has a pinned text card and a pinned image card")
        if scope == "all" then check(#ordinary_indexes >= 2, "the fixture has ordinary cards") end

        -- The reported sequence: pinned, ordinary, pinned, ordinary, then the first
        -- ordinary card again. Each card is derived from its own entry, so opening
        -- a pinned menu can never leave Unpin on a later ordinary card.
        local sequence = {}
        for position = 1, math.max(#pinned_indexes, #ordinary_indexes) do
            if ordinary_indexes[position] then sequence[#sequence + 1] = ordinary_indexes[position] end
            if pinned_indexes[position] then sequence[#sequence + 1] = pinned_indexes[position] end
        end
        sequence[#sequence + 1] = ordinary_indexes[1]
        for _, index in ipairs(sequence) do
            local card = environment.t.historyItemHTML(menu[index], index)
            local expect_pinned = menu[index].isPinned == true
            check_equal(card:find('data-pinned="true"', 1, true) ~= nil, expect_pinned,
                "re-rendering index " .. index .. " in the " .. scope .. " scope keeps its own pinned state")
            check_equal(card:find('class="pin-mark"', 1, true) ~= nil, expect_pinned,
                "the pin marker follows the card that is rendered")
        end
    end

    -- The JavaScript that consumes data-pinned must identify its buttons by a
    -- stable slot. The shipped leak came from finding the button by the very
    -- attribute the open handler rewrote.
    local html = environment.t.panelHTML()
    check(html:find("data-context-slot", 1, true) ~= nil, "menu buttons carry a stable data-context-slot")
    check(html:find('const CONTEXT_MENU_ITEMS', 1, true) ~= nil, "the menu items come from one ordered spec")
    check(html:find('applyContextMenuTarget', 1, true) ~= nil, "the menu is rebuilt from the target item")
    check(html:find('[data-context-action="', 1, true) == nil,
        "no button lookup by the attribute an open handler mutates")
    local _, slot_uses = html:gsub('data%-context%-slot', '')
    check(slot_uses >= 3, "the slot attribute is used to build, apply, and read the menu")
    check(html:find("resultsPanel.tabIndex", 1, true) == nil, "the results container is not a tab stop")
    check(html:find("<footer>Tab: next result", 1, true) ~= nil, "the footer documents the sequential Tab model")
end)

test("context menu actions act on the card that requested them", function()
    local environment = new_environment("context-actions")
    seed_codex_day(environment)
    environment.seed_image_day(DATE, "20261107103607", BASE_TS + 400)
    environment.pin_first_matching("codex", "text")
    local images = environment.t.searchPersistentHistory("[image]", "image")
    check(environment.t.pinClipboardEntry(images[1]), "the image is pinned")
    environment.t.restorePersistentHistory()

    check_equal(#environment.t.readPinnedHistory(), 2, "the fixture pins one text and one image record")
    environment.t.setPanelState({ allDates = true, pinned = false, query = "", kind = "all" })
    environment.t.updateClipboardPanel("", "all", 0, false)

    local function find_entry(menu, predicate, message)
        for index, entry in ipairs(menu) do
            if predicate(entry) then return index, entry end
        end
        error("fixture missing: " .. message, 2)
    end

    local menu = environment.t.panelState().menuData
    local pinned_index, pinned_entry = find_entry(menu,
        function(entry) return entry.isPinned and entry.type == "text" end, "pinned text card")
    local _, pinned_image = find_entry(menu,
        function(entry) return entry.isPinned and entry.type == "image" end, "pinned image card")
    local ordinary_index, ordinary_entry = find_entry(menu,
        function(entry) return not entry.isPinned and entry.type == "text" end, "ordinary text card")
    local other_index, other_entry = find_entry(menu, function(entry)
        return not entry.isPinned and entry.type == "text" and entry.ts ~= ordinary_entry.ts
    end, "a second ordinary text card")

    local function pinned_by_id()
        local by_id = {}
        for _, record in ipairs(environment.t.readPinnedHistory()) do by_id[record.id] = record end
        return by_id
    end

    -- Copy follows the requested index, not a previously opened menu.
    environment.t.handleMessage({ body = { action = "copyHistoryEntry", index = ordinary_index } })
    check_equal(STUB.state.copied_text, ordinary_entry.content, "Copy copies the requested ordinary card")
    environment.t.handleMessage({ body = { action = "copyHistoryEntry", index = pinned_index } })
    check_equal(STUB.state.copied_text, pinned_entry.content, "Copy copies the requested pinned card")

    -- Unpin removes exactly the pinned card that was right-clicked.
    environment.t.handleMessage({ body = { action = "unpin", index = pinned_index } })
    local after_unpin = pinned_by_id()
    check(after_unpin[pinned_image.id], "the untouched pinned image survives")
    check(not after_unpin[pinned_entry.id], "the requested pinned text record is removed")

    -- Pin acts on the requested ordinary card and stores that card's content.
    environment.t.handleMessage({ body = { action = "pin", index = ordinary_index } })
    local after_pin = pinned_by_id()
    local copied_pin = false
    for _, record in pairs(after_pin) do
        if record.type == "text" and record.content == ordinary_entry.content then copied_pin = true end
    end
    check(copied_pin, "the requested ordinary card is pinned with its own content")
    check(after_pin[pinned_image.id], "the pinned image is unchanged by the new pin")

    -- The list is rebuilt after every pin/unpin; later requests stay targeted.
    environment.t.updateClipboardPanel("", "all", 0, false)
    local rebuilt = environment.t.panelState().menuData
    local image_pin_index = find_entry(rebuilt,
        function(entry) return entry.isPinned and entry.type == "image" end, "pinned image card after rebuild")
    environment.t.handleMessage({ body = { action = "unpin", index = image_pin_index } })
    check(not pinned_by_id()[pinned_image.id], "the pinned image is removed on request")
    check_equal(#environment.t.readPinnedHistory(), 1, "only the newly pinned text record remains")

    environment.t.updateClipboardPanel("", "all", 0, false)
    local current = environment.t.panelState().menuData
    local other_now = find_entry(current, function(entry)
        return not entry.isPinned and entry.content == other_entry.content
    end, "the second ordinary card after the churn")
    environment.t.handleMessage({ body = { action = "copyHistoryEntry", index = other_now } })
    check_equal(STUB.state.copied_text, other_entry.content, "Copy stays targeted after menu churn")

    -- An Unpin request for a card that is not pinned changes nothing.
    local ordinary_now = find_entry(current,
        function(entry) return not entry.isPinned end, "an ordinary card after the churn")
    environment.t.handleMessage({ body = { action = "unpin", index = ordinary_now } })
    check_equal(#environment.t.readPinnedHistory(), 1, "Unpin on an ordinary card changes nothing")
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
