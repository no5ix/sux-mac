-- Minimal Hammerspoon stand-in for the isolated Clipboard History harness.
--
-- It implements only the APIs the Spoon touches, backed by the real filesystem
-- under a temporary HOME so persistence, migration, search, and retention are
-- exercised against real files. No Hammerspoon process, window, or pasteboard
-- is involved; live panel behavior is verified separately with Peekaboo.

local M = {}

local function shquote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-------------------------------------------------------------------------------
-- base64

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
    data = tostring(data or "")
    local bits = (data:gsub(".", function(byte)
        local value = string.byte(byte)
        local byte_bits = ""
        for bit = 8, 1, -1 do
            byte_bits = byte_bits .. (math.floor(value / 2 ^ (bit - 1)) % 2)
        end
        return byte_bits
    end))
    local padded = bits .. string.rep("0", (6 - #bits % 6) % 6)
    local output = (padded:gsub("%d%d%d%d%d%d", function(group)
        local value = 0
        for index = 1, 6 do
            value = value * 2 + tonumber(group:sub(index, index))
        end
        return B64_CHARS:sub(value + 1, value + 1)
    end))
    local padding = (3 - #data % 3) % 3
    return output .. string.rep("=", padding)
end

local function base64_decode(data)
    data = tostring(data or ""):gsub("[^" .. B64_CHARS .. "=]", "")
    local lookup = {}
    for index = 1, #B64_CHARS do lookup[B64_CHARS:sub(index, index)] = index - 1 end
    local bytes, bits, accumulator = {}, 0, 0
    for index = 1, #data do
        local char = data:sub(index, index)
        if char == "=" then break end
        accumulator = accumulator * 64 + (lookup[char] or 0)
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            bytes[#bytes + 1] = string.char(math.floor(accumulator / 2 ^ bits) % 256)
            accumulator = accumulator % 2 ^ bits
        end
    end
    return table.concat(bytes)
end

-------------------------------------------------------------------------------
-- JSON

local function utf8_encode(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    elseif codepoint < 0x10000 then
        return string.char(0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    end
    return string.char(0xF0 + math.floor(codepoint / 0x40000),
        0x80 + math.floor(codepoint / 0x1000) % 0x40,
        0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
end

local json_string_escapes = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function json_decode(raw)
    raw = tostring(raw)
    local position, length = 1, #raw

    local function skip_whitespace()
        while position <= length do
            local char = raw:sub(position, position)
            if char == " " or char == "\t" or char == "\n" or char == "\r" then
                position = position + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        position = position + 1
        local parts = {}
        while true do
            if position > length then error("unterminated JSON string", 2) end
            local char = raw:sub(position, position)
            if char == '"' then
                position = position + 1
                return table.concat(parts)
            elseif char == "\\" then
                local next_char = raw:sub(position + 1, position + 1)
                if next_char == "u" then
                    local codepoint = tonumber(raw:sub(position + 2, position + 5), 16)
                    if not codepoint then error("invalid \\u escape", 2) end
                    position = position + 6
                    local surrogate = raw:sub(position + 1, position + 2)
                    if codepoint >= 0xD800 and codepoint < 0xDC00 and surrogate == "\\u" then
                        local low = tonumber(raw:sub(position + 2, position + 5), 16)
                        if low and low >= 0xDC00 and low < 0xE000 then
                            codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + (low - 0xDC00)
                            position = position + 6
                        end
                    end
                    parts[#parts + 1] = utf8_encode(codepoint)
                else
                    parts[#parts + 1] = json_string_escapes[next_char] or next_char
                    position = position + 2
                end
            else
                parts[#parts + 1] = char
                position = position + 1
            end
        end
    end

    function parse_value()
        skip_whitespace()
        local char = raw:sub(position, position)
        if char == '"' then
            return parse_string()
        elseif char == "{" then
            local object = {}
            position = position + 1
            skip_whitespace()
            if raw:sub(position, position) == "}" then
                position = position + 1
                return object
            end
            while true do
                skip_whitespace()
                local key = parse_string()
                skip_whitespace()
                if raw:sub(position, position) ~= ":" then error("expected ':'", 2) end
                position = position + 1
                object[key] = parse_value()
                skip_whitespace()
                local delimiter = raw:sub(position, position)
                position = position + 1
                if delimiter == "}" then return object end
                if delimiter ~= "," then error("expected ',' or '}'", 2) end
            end
        elseif char == "[" then
            local array = {}
            position = position + 1
            skip_whitespace()
            if raw:sub(position, position) == "]" then
                position = position + 1
                return array
            end
            while true do
                array[#array + 1] = parse_value()
                skip_whitespace()
                local delimiter = raw:sub(position, position)
                position = position + 1
                if delimiter == "]" then return array end
                if delimiter ~= "," then error("expected ',' or ']'", 2) end
            end
        elseif char == "t" then
            position = position + 4
            return true
        elseif char == "f" then
            position = position + 5
            return false
        elseif char == "n" then
            position = position + 4
            return nil
        end
        local number = raw:sub(position):match("^-?%d+%.?%d*[eE]?[-+]?%d*")
        if not number then error("unexpected JSON token", 2) end
        position = position + #number
        return tonumber(number)
    end

    local value = parse_value()
    return value
end

local function json_encode_string(value)
    local escaped = tostring(value)
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
        :gsub("[%z\1-\31]", function(char) return string.format("\\u%04x", string.byte(char)) end)
    return '"' .. escaped .. '"'
end

local function json_is_array(value)
    local count, keys = 0, 0
    for _ in pairs(value) do keys = keys + 1 end
    for index = 1, #value do
        if value[index] == nil then return false end
        count = count + 1
    end
    return count == keys
end

local function json_encode(value, indent)
    local kind = type(value)
    if value == nil then
        return "null"
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "number" then
        if value == math.floor(value) and math.abs(value) < 2 ^ 52 then
            return string.format("%d", value)
        end
        return string.format("%.17g", value)
    elseif kind == "string" then
        return json_encode_string(value)
    elseif kind == "table" then
        local parts, pad, inner = {}, "", ""
        if indent then pad = "  "; inner = "\n" end
        if json_is_array(value) then
            for index = 1, #value do parts[#parts + 1] = pad .. json_encode(value[index], indent) end
            if #parts == 0 then return "[]" end
            return "[" .. inner .. table.concat(parts, ",\n" .. inner) .. inner .. "]"
        end
        local keys = {}
        for key in pairs(value) do
            assert(type(key) == "string", "stub JSON encoder needs string keys")
            keys[#keys + 1] = key
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = pad .. json_encode_string(key) .. ": " .. json_encode(value[key], indent)
        end
        if #parts == 0 then return "{}" end
        return "{" .. inner .. table.concat(parts, ",\n" .. inner) .. inner .. "}"
    end
    error("cannot encode a " .. kind .. " as JSON", 2)
end

-------------------------------------------------------------------------------
-- state recorded for assertions

M.state = {
    logs = {},
    alerts = {},
    scripts = {},
    pasted_text = nil,
    pasted_image = nil,
    copied_text = nil,
    copied_image = nil,
    reloads = 0,
    key_strokes = {},
    timer_callbacks = {},
    watcher_started = 0,
    watcher_stopped = 0,
}

function M.reset_recorded_state()
    M.state.logs, M.state.alerts, M.state.scripts = {}, {}, {}
    M.state.pasted_text, M.state.pasted_image = nil, nil
    M.state.copied_text, M.state.copied_image = nil, nil
end

function M.logs_containing(fragment)
    local hits = {}
    for _, entry in ipairs(M.state.logs) do
        if entry.message:find(fragment, 1, true) then hits[#hits + 1] = entry end
    end
    return hits
end

local function record(level, message)
    M.state.logs[#M.state.logs + 1] = { level = level, message = tostring(message) }
end

-------------------------------------------------------------------------------
-- fake images

local function fake_image(source)
    local image_object = { source = source, isFakeImage = true }
    function image_object:size() return { w = 800, h = 600 } end
    function image_object:bitmapRepresentation(options)
        local bitmap = fake_image("bitmap")
        bitmap.bitmapSize = options
        return bitmap
    end
    function image_object:saveToFile(path, flags, format)
        local file = io.open(path, "wb")
        if not file then return false end
        file:write("STUB-" .. string.upper(tostring(format or "PNG")) .. "-PAYLOAD\n")
        local closed = file:close()
        return closed ~= false
    end
    function image_object:encodeAsURLString()
        return "data:image/png;base64," .. base64_encode("STUB-PNG-PAYLOAD\n")
    end
    return image_object
end

-------------------------------------------------------------------------------
-- the hs table and its require-able submodules

local clock_offset = 0

local hs = {}

hs.logger = {}
function hs.logger.new(name, level)
    local logger_object = { name = name, level = level }
    for _, method in ipairs({ "i", "w", "e", "d", "c", "v" }) do
        logger_object[method] = function(message) record(method, message) end
    end
    return logger_object
end

hs.fs = {}
-- fopen() on a directory succeeds on macOS, so the mode test must classify
-- directories before it treats an openable path as a regular file.
function hs.fs.attributes(path)
    if type(path) ~= "string" then return nil end
    local handle = io.popen("if [ -d " .. shquote(path) .. " ]; then echo directory;"
        .. " elif [ -f " .. shquote(path) .. " ]; then echo file; else echo none; fi")
    local kind = handle:read("*l") or "none"
    handle:close()
    if kind == "none" then return nil end
    local size = 0
    if kind == "file" then
        local file = io.open(path, "rb")
        if file then
            size = file:seek("end") or 0
            file:close()
        end
    end
    return { mode = kind, size = size }
end
function hs.fs.mkdir(path)
    local ok = os.execute("mkdir -p " .. shquote(path))
    if ok == nil or ok == true or ok == 0 then return true end
    return nil, "mkdir failed"
end
function hs.fs.dir(path)
    local handle = io.popen("ls -1A " .. shquote(path) .. " 2>/dev/null")
    local names = {}
    for line in handle:lines() do names[#names + 1] = line end
    handle:close()
    local index = 0
    return function()
        index = index + 1
        return names[index]
    end
end

hs.json = { encode = json_encode, decode = json_decode }
hs.base64 = { encode = base64_encode, decode = base64_decode }

hs.image = {}
function hs.image.imageFromURL(url)
    if type(url) ~= "string" or url:sub(1, 5) ~= "data:" then return nil end
    return fake_image(url)
end

hs.timer = {}
function hs.timer.secondsSinceEpoch()
    clock_offset = clock_offset + 1
    return os.time() + clock_offset / 1000000
end
function hs.timer.doAfter(delay, callback)
    M.state.timer_callbacks[#M.state.timer_callbacks + 1] = { delay = delay, callback = callback }
    local timer_object = {}
    function timer_object:stop() return self end
    return timer_object
end
function hs.timer.doEvery(interval, callback)
    return hs.timer.doAfter(interval, callback)
end

hs.alert = {}
function hs.alert.show(message)
    M.state.alerts[#M.state.alerts + 1] = tostring(message)
end

hs.reload = function() M.state.reloads = M.state.reloads + 1 end

hs.application = {}
function hs.application.frontmostApplication()
    local app = {}
    function app:name() return "StubEditor" end
    function app:bundleID() return "com.example.stubeditor" end
    function app:pid() return 4242 end
    function app:isRunning() return true end
    function app:activate(_) return true end
    return app
end

hs.mouse = {}
function hs.mouse.absolutePosition() return { x = 100, y = 100 } end

hs.screen = {}
local function fake_screen()
    local screen = {}
    function screen:getUUID() return "stub-screen" end
    function screen:fullFrame() return { x = 0, y = 0, w = 1920, h = 1080 } end
    function screen:frame() return { x = 0, y = 0, w = 1920, h = 1050 } end
    return screen
end
function hs.screen.allScreens() return { fake_screen() } end
function hs.screen.mainScreen() return fake_screen() end

hs.eventtap = {}
hs.eventtap.event = { types = { leftMouseDown = 1 } }
function hs.eventtap.new(types, callback)
    local tap = {}
    function tap:start() return self end
    function tap:stop() return self end
    return tap
end
function hs.eventtap.keyStroke(modifiers, key, delay)
    M.state.key_strokes[#M.state.key_strokes + 1] = { modifiers = modifiers, key = key }
end

local pasteboard = {}
function pasteboard.setContents(contents)
    M.state.pasted_text = tostring(contents)
    M.state.copied_text = tostring(contents)
    return true
end
function pasteboard.writeObjects(image_object)
    M.state.pasted_image = image_object
    M.state.copied_image = image_object
    return true
end
function pasteboard.changeCount() return 1 end

local watcher = {}
function watcher.new(callback)
    local instance = { callback = callback }
    function instance:start() M.state.watcher_started = M.state.watcher_started + 1; return self end
    function instance:stop() M.state.watcher_stopped = M.state.watcher_stopped + 1; return self end
    return instance
end
function watcher.interval(_) end
pasteboard.watcher = watcher

hs.pasteboard = pasteboard

hs.hotkey = {}
function hs.hotkey.bind(modifiers, key, pressed, released, continuous)
    local binding = { modifiers = modifiers, key = key }
    function binding:enable() return self end
    function binding:disable() return self end
    return binding
end

local webview = {}
function webview.new(frame, options, usercontent)
    local view = { createdFrame = frame, options = options, usercontent = usercontent }
    function view:windowStyle(style) self.windowStyleValue = style; return self end
    function view:shadow(shadow) self.shadowValue = shadow; return self end
    function view:allowTextEntry(allow) self.textEntry = allow; return self end
    function view:closeOnEscape(close) self.closeOnEscapeValue = close; return self end
    function view:windowCallback(callback) self.windowCallbackValue = callback; return self end
    function view:html(html)
        self.htmlValue = html
        self.visible = false
    end
    function view:show() self.visible = true end
    function view:hide() self.visible = false end
    function view:bringToFront(on_top) self.broughtToFront = on_top end
    function view:isVisible() return self.visible == true end
    function view:delete() self.deleted = true end
    function view:frame(frame_value)
        if frame_value then self.frameValue = frame_value end
        return self.frameValue or { x = 0, y = 0, w = 980, h = 760 }
    end
    function view:hswindow()
        local window = {}
        function window:raise() return self end
        function window:focus() return self end
        return window
    end
    function view:evaluateJavaScript(script, callback)
        M.state.scripts[#M.state.scripts + 1] = tostring(script)
        self.scripts = self.scripts or {}
        self.scripts[#self.scripts + 1] = tostring(script)
        if callback then callback(nil, nil) end
    end
    return view
end
webview.usercontent = {}
function webview.usercontent.new(name)
    local instance = { name = name }
    function instance:setCallback(callback)
        self.callback = callback
        M.state.messageCallback = callback
        return self
    end
    return instance
end
hs.webview = webview

hs.hs = hs

M.hs = hs
M.fs = hs.fs
M.fake_image = fake_image
M.json_encode = json_encode
M.json_decode = json_decode
M.base64_encode = base64_encode
M.base64_decode = base64_decode

-------------------------------------------------------------------------------
-- installation

-- Installs the global `hs` table, the hs.* require shims, and a HOME override
-- so the Spoon resolves its data root inside a sandbox.
function M.install(sandbox_home)
    _G.hs = hs

    local modules = {
        ["hs.hotkey"] = hs.hotkey,
        ["hs.pasteboard"] = hs.pasteboard,
        ["hs.pasteboard.watcher"] = watcher,
        ["hs.webview"] = webview,
        ["hs.application"] = hs.application,
        ["hs.json"] = hs.json,
        ["hs.fs"] = hs.fs,
        ["hs.image"] = hs.image,
    }
    for name, module in pairs(modules) do
        package.preload[name] = function() return module end
    end

    if sandbox_home then
        local real_getenv = os.getenv
        os.getenv = function(name)
            if name == "HOME" then return sandbox_home end
            return real_getenv(name)
        end
        M.sandbox_home = sandbox_home
    end
end

return M
