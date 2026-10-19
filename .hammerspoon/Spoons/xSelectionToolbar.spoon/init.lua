local obj = {}
obj.__index = obj

local pasteboard = require("hs.pasteboard")
local webview = require("hs.webview")
local timer = require("hs.timer")
local json = require("hs.json")
local eventtap = require("hs.eventtap")
local logger = hs.logger.new("xSelectionToolbar", "debug")
local mouseSelectionTap = nil

local toolbar = nil
local selectionWatcher = nil
local selectedText = ""

local DOUbao_SHORTCUT = { "ctrl", "shift", "alt" }
local DOUbao_KEY = "o"
local DOUbao_PROMPT = [[Please proofread the following text. Make minimal changes to fix grammar and missing components. Strictly preserve my original word choices and sentence patterns. Do not “improve” the style—only fix the mistakes and Remove all "um/uh" fillers and pauses. Merge fragments into complete, natural spoken sentences. just make it grammatically correct and smooth to read. Then, you need to translate your corrected text into very colloquial Chinese, and please don’t use any periods at the end. 你可以适当加一点中国人常用的口头禅，甚至是粗鄙一点的口头禅都可以，比如说像，“那差别可太他妈大了”，这种。Finally, give me a Natural American Expression that Shows how a native American English speaker would naturally say the same thing in daily life.This section can rewrite the sentence more freely to sound native and conversational.Keep the meaning the same, but make it sound realistic and commonly used in America.Avoid slang that is too extreme or hard to understand: ]]

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function hideToolbar()
    if toolbar then toolbar:hide() end
end

local function normalizeMessage(message)
    -- hs.webview.usercontent passes a WKScriptMessage table; the posted JS
    -- object is in message.body, not at the top level.
    if type(message) == "table" and type(message.body) == "table" then
        return message.body
    end
    return message
end

local function getToolbarHTML(text)
    -- Hammerspoon hs.json.encode expects a table, so encode the selection as
    -- a single-element array and extract the JSON-escaped string literal.
    local encoded = json.encode({ text })
    local encodedText = type(encoded) == "table" and encoded[1] or encoded or '""'
    local html = [=[
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>:root{color-scheme:light}*{box-sizing:border-box}body{margin:0;padding:8px;background:transparent !important;font-family:-apple-system,BlinkMacSystemFont,sans-serif}.bar{display:flex;align-items:center;gap:4px;width:max-content;max-width:calc(100vw - 16px);padding:6px;border:1px solid rgba(0,0,0,.1);border-radius:12px;background:rgba(250,250,252,.98);box-shadow:0 8px 28px rgba(0,0,0,.22)}button{border:0;border-radius:8px;padding:9px 12px;color:#202124;background:transparent;font-size:13px;white-space:nowrap;cursor:pointer}button:hover{background:#e6e8ed}.separator{width:1px;height:24px;background:#d9dce2;margin:0 2px}</style>
</head><body><div class="bar">
<button onclick="action('copy')">Copy</button>
<button onclick="action('doubao')">Proofread + translate</button>
<span class="separator"></span>
<button onclick="action('youdao-result')">Youdao Result</button>
<button onclick="action('youdao-word')">Youdao Dictionary</button>
</div><script>
const selection = __SELECTION_JSON__;
function action(name){try{window.webkit.messageHandlers.selectionToolbar.postMessage({action:name,text:selection});}catch(e){document.title="Toolbar error: "+e.message;}}
</script></body></html>
]=]
    return html:gsub("__SELECTION_JSON__", function() return encodedText end)
end
local function urlEncode(text)
    return tostring(text or ""):gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end)
end

local function runDoubao(text)
    -- Preserve the text in the pasteboard before switching applications.
    -- The configured shortcut opens the Doubao window; then paste the prepared prompt.
    local prompt = DOUbao_PROMPT .. " " .. text
    pasteboard.setContents(prompt)
    hideToolbar()
    eventtap.keyStroke(DOUbao_SHORTCUT, DOUbao_KEY, 0.08)
    timer.doAfter(0.45, function()
        eventtap.keyStroke({ "cmd" }, "v", 0.08)
    end)
end

local function openSafariURL(url)
    hideToolbar()
    hs.task.new("/usr/bin/open", nil, { "-a", "Safari", url }):start()
end

local function onToolbarMessage(message)
    logger.i("Toolbar message received: " .. tostring(type(message)))
    message = normalizeMessage(message)
    if type(message) ~= "table" then
        hs.alert.show("Toolbar message was not decoded")
        return
    end
    local action = message.action
    local text = trim(message.text or selectedText)
    logger.i("Toolbar action=" .. tostring(action) .. ", text length=" .. tostring(#text))
    if text == "" then hs.alert.show("No selected text"); return end

    if action == "copy" then
        pasteboard.setContents(text)
        hideToolbar()
        hs.alert.show("Copied selection")
    elseif action == "doubao" then
        local prompt = DOUBAO_PROMPT .. " " .. text
        pasteboard.setContents(prompt)
        hideToolbar()
        eventtap.keyStroke(DOUBAO_SHORTCUT, DOUBAO_KEY, 0.08)
        timer.doAfter(0.6, function() eventtap.keyStroke({ "cmd" }, "v", 0.08) end)
    elseif action == "youdao-result" then
        hideToolbar()
        hs.task.new("/usr/bin/open", nil, { "-a", "Safari", "https://dict.youdao.com/result?word=" .. urlEncode(text) .. "&lang=en" }):start()
    elseif action == "youdao-word" then
        hideToolbar()
        hs.task.new("/usr/bin/open", nil, { "-a", "Safari", "https://dict.youdao.com/w/" .. urlEncode(text) }):start()
    end
end
local function buildToolbar(text)
    if toolbar then toolbar:delete() end
    local usercontent = hs.webview.usercontent.new("selectionToolbar")
    usercontent:setCallback(function(message) onToolbarMessage(message) end)
    toolbar = webview.new({ x = 0, y = 0, w = 550, h = 66 }, {
        developerExtrasEnabled = false,
        javaScriptCanOpenWindowsAutomatically = false,
        transparent = true,
        shadow = false
    }, usercontent)
    toolbar:windowStyle(0)
    toolbar:allowTextEntry(false)
    toolbar:transparent(true)
    toolbar:shadow(false)
    toolbar:level(hs.drawing.windowLevels.floating)
    toolbar:windowTitle("Selection Actions")
    toolbar:html(getToolbarHTML(text), "file:///")

    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local frame = screen:fullFrame()
    local point = hs.mouse.absolutePosition()
    local width, height = 550, 66
    local x = math.max(frame.x + 8, math.min(point.x - width / 2, frame.x + frame.w - width - 8))
    local y = point.y - height - 14
    if y < frame.y + 8 then y = point.y + 18 end
    y = math.max(frame.y + 8, math.min(y, frame.y + frame.h - height - 8))
    toolbar:frame({ x = x, y = y, w = width, h = height })
    toolbar:show()
    toolbar:bringToFront()
end
function obj:start()
    if selectionWatcher then selectionWatcher:stop() end
    if mouseSelectionTap then mouseSelectionTap:stop() end
    local lastText = ""
    local lastShownAt = 0
    local function selectionFromAccessibility()
        local ok, value = pcall(function()
            local function walk(element)
                local depth = 0
                while element and depth < 10 do
                    local selected = element:attributeValue("AXSelectedText")
                    if type(selected) == "string" and trim(selected) ~= "" then return selected end
                    element = element:attributeValue("AXParent")
                    depth = depth + 1
                end
                return nil
            end
            local system = hs.axuielement.systemElement()
            local focused = system and system:attributeValue("AXFocusedUIElement")
            return walk(focused) or walk(hs.axuielement.systemElementAtPosition(hs.mouse.absolutePosition()))
        end)
        return ok and trim(value) or ""
    end
    local function captureAfterMouseSelection()
        if toolbar and toolbar:isVisible() then
            local point = hs.mouse.absolutePosition()
            local frame = toolbar:frame()
            local inside = point.x >= frame.x and point.x <= frame.x + frame.w
                and point.y >= frame.y and point.y <= frame.y + frame.h
            if not inside then hideToolbar() end
            return
        end
        local app = hs.application.frontmostApplication()
        if not app or app:bundleID() == "org.hammerspoon.Hammerspoon" then return end
        local value = selectionFromAccessibility()
        if value == "" then
            local oldClipboard = pasteboard.getContents()
            local oldChangeCount = pasteboard.changeCount()
            hs.eventtap.keyStroke({ "cmd" }, "c", 0.02)
            timer.doAfter(0.12, function()
                local copied = trim(pasteboard.getContents())
                local currentCount = pasteboard.changeCount()
                if oldClipboard ~= nil and currentCount ~= oldChangeCount then pasteboard.setContents(oldClipboard) end
                if copied ~= "" and currentCount ~= oldChangeCount then value = copied end
                if value ~= "" and value ~= lastText and (hs.timer.secondsSinceEpoch() - lastShownAt) > 0.6 then
                    selectedText = value
                    lastText = value
                    lastShownAt = hs.timer.secondsSinceEpoch()
                    buildToolbar(value)
                end
            end)
            return
        end
        if value ~= lastText and (hs.timer.secondsSinceEpoch() - lastShownAt) > 0.6 then
            selectedText = value
            lastText = value
            lastShownAt = hs.timer.secondsSinceEpoch()
            buildToolbar(value)
        end
    end
    -- Observe mouse release rather than polling AXSelectedText alone. Text selection
    -- in most apps is finalized when the mouse button is released.
    mouseSelectionTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseUp }, function()
        timer.doAfter(0.08, captureAfterMouseSelection)
        return false
    end)
    mouseSelectionTap:start()
    -- Also monitor Accessibility for apps where keyboard selection updates without mouse input.
    selectionWatcher = hs.timer.doEvery(0.45, function()
        if toolbar and toolbar:isVisible() then return end
        local value = selectionFromAccessibility()
        if value ~= "" and value ~= lastText and (hs.timer.secondsSinceEpoch() - lastShownAt) > 0.6 then
            selectedText = value
            lastText = value
            lastShownAt = hs.timer.secondsSinceEpoch()
            buildToolbar(value)
        elseif value == "" then
            lastText = ""
        end
    end)
    return self
end
function obj:stop()
    if selectionWatcher then selectionWatcher:stop(); selectionWatcher = nil end
    if mouseSelectionTap then mouseSelectionTap:stop(); mouseSelectionTap = nil end
    if toolbar then toolbar:delete(); toolbar = nil end
    return self
end

return obj
