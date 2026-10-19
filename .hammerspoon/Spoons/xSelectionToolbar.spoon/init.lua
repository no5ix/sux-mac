local obj = {}
obj.__index = obj

local pasteboard = require("hs.pasteboard")
local webview = require("hs.webview")
local timer = require("hs.timer")
local json = require("hs.json")
local eventtap = require("hs.eventtap")
local logger = hs.logger.new("xSelectionToolbar", "debug")
local mouseSelectionTap = nil
local hoverWatcher = nil

local toolbar = nil
local selectionWatcher = nil
local selectedText = ""

local DOUbao_SHORTCUT = { "ctrl", "shift", "alt", "cmd" }
local DOUbao_KEY = "o"
local DOUbao_PROMPT = [[Please proofread the following text. Make minimal changes to fix grammar and missing components. Strictly preserve my original word choices and sentence patterns. Do not “improve” the style—only fix the mistakes and Remove all "um/uh" fillers and pauses. Merge fragments into complete, natural spoken sentences. just make it grammatically correct and smooth to read. Then, you need to translate your corrected text into very colloquial Chinese, and please don’t use any periods at the end. 你可以适当加一点中国人常用的口头禅，甚至是粗鄙一点的口头禅都可以，比如说像，“那差别可太他妈大了”，这种。Finally, give me a Natural American Expression that Shows how a native American English speaker would naturally say the same thing in daily life.This section can rewrite the sentence more freely to sound native and conversational.Keep the meaning the same, but make it sound realistic and commonly used in America.Avoid slang that is too extreme or hard to understand: ]]

local CHATGPT_URL = "https://chatgpt.com/c/6ad59284-87fc-83ec-aeeb-282992cb1cb7"
local CHATGPT_PROMPT = [[Please proofread the following text. Make minimal changes to fix grammar and missing components. Strictly preserve my original word choices and sentence patterns. Do not “improve” the style—only fix the mistakes and Remove all "um/uh" fillers and pauses. Merge fragments into complete, natural spoken sentences. just make it grammatically correct and smooth to read. Then, you need to translate your corrected text into very colloquial Chinese, and please don’t use any periods at the end. 你可以适当加一点中国人常用的口头禅，甚至是粗鄙一点的口头禅都可以，比如说像，“那差别可太他妈大了”，这种。Finally, give me a Natural American Expression that Shows how a native American English speaker would naturally say the same thing in daily life.This section can rewrite the sentence more freely to sound native and conversational.Keep the meaning the same, but make it sound realistic and commonly spoken in America.Avoid slang that is too extreme or hard to understand: ]]

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function hideToolbar()
    if toolbar then toolbar:hide() end
end

local function normalizeMessage(message)
    -- Hammerspoon delivers a WKScriptMessage; its JavaScript payload is body.
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
<style>:root{color-scheme:light}*{box-sizing:border-box}html,body{margin:0!important;padding:0!important;width:100%;height:100%;overflow:hidden;background:rgba(0,0,0,0)!important}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:flex-start;justify-content:flex-start}.bar{display:flex;align-items:center;gap:4px;width:max-content;max-width:100%;margin:0;padding:6px;border:1px solid rgba(0,0,0,.1);border-radius:12px;background:rgba(250,250,252,.98);box-shadow:none!important;-webkit-box-shadow:none!important}button{appearance:none;-webkit-appearance:none;position:relative;z-index:1;display:inline-flex;align-items:center;gap:6px;border:0;border-radius:8px;padding:9px 12px;color:#202124;background:transparent;font-family:inherit;font-size:13px;white-space:nowrap;cursor:pointer!important;transition:none!important;-webkit-user-select:none;user-select:none}button.is-hovered{background-color:#e0e3e9!important;outline:none!important}button:active{background-color:#cbd0d9!important}.icon{display:inline-flex;align-items:center;justify-content:center;min-width:14px;font-size:14px;line-height:1}.separator{flex:0 0 1px;width:1px;height:24px;background:#d9dce2;margin:0 2px}</style>
</head><body><div class="bar">
<button data-action="copy" onclick="action('copy')"><span class="icon" aria-hidden="true">⧉</span> Copy</button>
<button data-action="doubao" onclick="action('doubao')"><span class="icon" aria-hidden="true">✎</span> Proofread + translate</button>
<button data-action="chatgpt" onclick="action('chatgpt')"><span class="icon" aria-hidden="true">✦</span> ChatGPT</button>
<span class="separator"></span>
<button data-action="youdao-result" onclick="action('youdao-result')"><span class="icon" aria-hidden="true">⌕</span> Youdao Result</button>
<button data-action="youdao-word" onclick="action('youdao-word')"><span class="icon" aria-hidden="true">📖</span> Youdao Dictionary</button>
</div><script>
const selection = __SELECTION_JSON__;
function action(name){try{window.webkit.messageHandlers.selectionToolbar.postMessage({action:name,text:selection});}catch(e){document.title="Toolbar error: "+e.message;}}
</script></body></html>
]=]
    return (html:gsub("__SELECTION_JSON__", function() return encodedText end))
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
    local textValue = message.text or selectedText
    if type(textValue) == "table" then
        textValue = textValue[1] or textValue.text or ""
    end
    local text = trim(textValue)
    logger.i("Toolbar action=" .. tostring(action) .. ", text length=" .. tostring(#text))
    if text == "" then hs.alert.show("No selected text"); return end

    if action == "copy" then
        pasteboard.setContents(text)
        hideToolbar()
    elseif action == "doubao" then
        local prompt = DOUbao_PROMPT .. " " .. text
        pasteboard.setContents(prompt)
        hideToolbar()
        eventtap.keyStroke(DOUbao_SHORTCUT, DOUbao_KEY, 0.08)
        timer.doAfter(0.6, function() eventtap.keyStroke({ "cmd" }, "v", 0.08) end)
    elseif action == "chatgpt" then
        local prompt = CHATGPT_PROMPT .. " " .. text
        pasteboard.setContents(prompt)
        hideToolbar()
        hs.task.new("/usr/bin/open", nil, { CHATGPT_URL }):start()
        -- Give the browser/conversation a moment to activate before pasting.
        timer.doAfter(1.8, function()
            eventtap.keyStroke({ "cmd" }, "v", 0.08)
        end)
    elseif action == "youdao-result" then
        hideToolbar()
        hs.task.new("/usr/bin/open", nil, { "-a", "Safari", "https://dict.youdao.com/result?word=" .. urlEncode(text) .. "&lang=en" }):start()
    elseif action == "youdao-word" then
        hideToolbar()
        hs.task.new("/usr/bin/open", nil, { "-a", "Safari", "https://dict.youdao.com/w/" .. urlEncode(text) }):start()
    end
end
local function buildToolbar(text)
    if toolbar then toolbar:delete(); toolbar = nil end
    if hoverWatcher then hoverWatcher:stop(); hoverWatcher = nil end
    local usercontent = hs.webview.usercontent.new("selectionToolbar")
    usercontent:setCallback(function(message) onToolbarMessage(message) end)
    toolbar = webview.new({ x = 0, y = 0, w = 550, h = 66 }, {
        developerExtrasEnabled = false,
        javaScriptCanOpenWindowsAutomatically = false,
        transparent = true,
        shadow = false,
        opaque = false
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
    local width, height = 550, 58
    local x = math.max(frame.x + 8, math.min(point.x - width / 2, frame.x + frame.w - width - 8))
    local y = point.y - height - 14
    if y < frame.y + 8 then y = point.y + 18 end
    y = math.max(frame.y + 8, math.min(y, frame.y + frame.h - height - 8))
    toolbar:frame({ x = x, y = y, w = width, h = height })

    toolbar:show()
    toolbar:bringToFront()

    -- Drive hover highlighting from native Hammerspoon mouse coordinates,
    -- avoiding dependence on WKWebView CSS hover/mouse event delivery.
    hoverWatcher = hs.timer.doEvery(0.035, function()
        if not toolbar or not toolbar:isVisible() then
            if hoverWatcher then hoverWatcher:stop(); hoverWatcher = nil end
            return
        end
        local p = hs.mouse.absolutePosition()
        local f = toolbar:frame()
        local lx, ly = p.x - f.x, p.y - f.y
        local targetAction = ""
        if ly >= 5 and ly <= 52 then
            if lx >= 7 and lx <= 73 then
                targetAction = "copy"
            elseif lx >= 77 and lx <= 251 then
                targetAction = "doubao"
            elseif lx >= 255 and lx <= 378 then
                targetAction = "youdao-result"
            elseif lx >= 382 and lx <= 527 then
                targetAction = "youdao-word"
            end
        end
        local actionLiteral = string.format("%q", targetAction)
        local script = "document.querySelectorAll('.bar button').forEach(function(b){" ..
            "var h=b.getAttribute('data-action')===" .. actionLiteral .. ";" ..
            "b.classList.toggle('is-hovered',h);" ..
            "b.style.setProperty('cursor','pointer','important');" ..
            "});"
        pcall(function() toolbar:evaluateJavaScript(script) end)
    end)
end
function obj:start()
    if selectionWatcher then selectionWatcher:stop(); selectionWatcher = nil end
    if mouseSelectionTap then mouseSelectionTap:stop(); mouseSelectionTap = nil end

    local lastText = ""
    local lastShownAt = 0
    local pendingCapture = false

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

    local function showIfSelection(value)
        value = trim(value)
        if value == "" then return false end
        local now = hs.timer.secondsSinceEpoch()
        if value ~= lastText and (now - lastShownAt) > 0.6 then
            selectedText = value
            lastText = value
            lastShownAt = now
            buildToolbar(value)
            return true
        end
        return false
    end

    local function captureAfterMouseSelection()
        if pendingCapture then return end
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

        -- First use native Accessibility selection, which does not touch the clipboard.
        local value = selectionFromAccessibility()
        if showIfSelection(value) then return end

        -- Fallback only on a mouse-up following a real drag. Ordinary clicks and menu
        -- clicks should never synthesize Cmd+C or open the toolbar.
        -- eventtap's mouse-up callback below records whether the pointer moved while down.
    end

    local mouseDownPoint = nil
    local mouseDragDistance = 0
    mouseSelectionTap = hs.eventtap.new({
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.leftMouseDragged,
        hs.eventtap.event.types.leftMouseUp
    }, function(event)
        local eventType = event:getType()
        if eventType == hs.eventtap.event.types.leftMouseDown then
            local p = hs.mouse.absolutePosition()
            mouseDownPoint = { x = p.x, y = p.y }
            mouseDragDistance = 0
            return false
        elseif eventType == hs.eventtap.event.types.leftMouseDragged then
            if mouseDownPoint then
                local p = hs.mouse.absolutePosition()
                local dx, dy = p.x - mouseDownPoint.x, p.y - mouseDownPoint.y
                mouseDragDistance = math.max(mouseDragDistance, math.sqrt(dx * dx + dy * dy))
            end
            return false
        elseif eventType == hs.eventtap.event.types.leftMouseUp then
            local didDrag = mouseDragDistance >= 4
            mouseDownPoint = nil
            mouseDragDistance = 0
            timer.doAfter(0.12, function()
                if toolbar and toolbar:isVisible() then
                    local p = hs.mouse.absolutePosition()
                    local f = toolbar:frame()
                    if p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then
                        hideToolbar()
                    end
                    return
                end

                local app = hs.application.frontmostApplication()
                if not app or app:bundleID() == "org.hammerspoon.Hammerspoon" then return end
                local value = selectionFromAccessibility()
                if showIfSelection(value) then return end
                if not didDrag or pendingCapture then return end

                -- Only keep the toolbar when the drag produced a real text selection.
                -- If Accessibility cannot report a selection, use copy as a fallback,
                -- but require a clipboard change and restore the prior clipboard.
                pendingCapture = true
                local oldClipboard = pasteboard.getContents()
                local oldCount = pasteboard.changeCount()
                hs.eventtap.keyStroke({ "cmd" }, "c", 0.02)
                timer.doAfter(0.16, function()
                    local newCount = pasteboard.changeCount()
                    local copied = trim(pasteboard.getContents())
                    if oldClipboard ~= nil and newCount ~= oldCount then pasteboard.setContents(oldClipboard) end
                    pendingCapture = false
                    if newCount ~= oldCount and copied ~= "" then
                        local axValue = selectionFromAccessibility()
                        local selection = trim(axValue ~= "" and axValue or copied)
                        -- Ignore common stale clipboard values by requiring that
                        -- the selection/copy produced a new pasteboard change.
                        showIfSelection(selection)
                    end
                end)
            end)
            return false
        end
        return false
    end)
    mouseSelectionTap:start()

    -- Keyboard-based selection detection intentionally disabled; only mouse drag selection is supported.
    return self
end
function obj:stop()
    if hoverWatcher then hoverWatcher:stop(); hoverWatcher = nil end
    if selectionWatcher then selectionWatcher:stop(); selectionWatcher = nil end
    if mouseSelectionTap then mouseSelectionTap:stop(); mouseSelectionTap = nil end
    if toolbar then toolbar:delete(); toolbar = nil end
    return self
end

return obj
