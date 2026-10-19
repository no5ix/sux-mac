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
local appearancePoll = nil

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
<style>
:root{color-scheme:light dark}
*{box-sizing:border-box}
html,body{margin:0!important;padding:0!important;width:100%;height:100%;overflow:hidden;background:rgba(0,0,0,0)!important}
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:flex-start;justify-content:flex-start}
.bar{display:inline-flex;align-items:center;gap:4px;width:max-content;max-width:none;margin:0;padding:6px;border:1px solid var(--toolbar-border);border-radius:12px;background:var(--toolbar-bg);box-shadow:none!important;-webkit-box-shadow:none!important;transition:background-color .12s,border-color .12s}
button{appearance:none;-webkit-appearance:none;position:relative;z-index:1;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:8px;width:38px;height:38px;padding:0;color:var(--toolbar-fg);background:transparent;font-family:inherit;font-size:22px;white-space:nowrap;cursor:pointer!important;transition:none!important;-webkit-user-select:none;user-select:none}
button.is-hovered,button[data-hovered="true"]{background-color:var(--toolbar-hover)!important;box-shadow:inset 0 0 0 1px var(--toolbar-hover-border)!important;outline:none!important}
button:active{background-color:var(--toolbar-active)!important}
button[data-action="translation"]{width:auto;min-width:38px;padding:0 10px;gap:6px;font-size:13px;font-weight:600}
.translation-label{font-size:12px;line-height:1}
.icon{display:inline-flex;align-items:center;justify-content:center;min-width:20px;font-size:22px;line-height:1}
.separator{flex:0 0 1px;width:1px;height:24px;background:var(--toolbar-separator);margin:0 2px}
:root,[data-appearance="light"]{--toolbar-bg:rgba(250,250,252,.98);--toolbar-fg:#202124;--toolbar-border:rgba(0,0,0,.12);--toolbar-hover:#d8dee9;--toolbar-hover-border:rgba(40,50,70,.18);--toolbar-active:#c5ccd8;--toolbar-separator:#d9dce2}
[data-appearance="dark"]{--toolbar-bg:rgba(39,41,46,.98);--toolbar-fg:#f5f6f8;--toolbar-border:rgba(255,255,255,.16);--toolbar-hover:#454951;--toolbar-hover-border:rgba(255,255,255,.18);--toolbar-active:#555b66;--toolbar-separator:#555a64}
@media(prefers-color-scheme:dark){:root:not([data-appearance="light"]){--toolbar-bg:rgba(39,41,46,.98);--toolbar-fg:#f5f6f8;--toolbar-border:rgba(255,255,255,.16);--toolbar-hover:#454951;--toolbar-hover-border:rgba(255,255,255,.18);--toolbar-active:#555b66;--toolbar-separator:#555a64}}
</style>
</head><body><div class="bar">
<button data-action="copy" aria-label="Copy" title="Copy" onclick="action('copy')"><span class="icon" aria-hidden="true">📋</span></button>
<!-- <button data-action="doubao" onclick="action('doubao')"><span class="icon" aria-hidden="true">✎</span> Proofread + translate</button> -->
<button data-action="chatgpt" aria-label="ChatGPT" title="ChatGPT" onclick="action('chatgpt')"><span class="icon" aria-hidden="true">🤖</span></button>
<button data-action="translation" aria-label="Translation" title="Translation" onclick="action('translation')"><span class="icon" aria-hidden="true">🌐</span><span class="translation-label">Translation</span></button>
<span class="separator"></span>
<button data-action="youdao-result" aria-label="Youdao Result" title="Youdao Result" onclick="action('youdao-result')"><span class="icon" aria-hidden="true">🔎</span></button>
<button data-action="youdao-word" aria-label="Youdao Dictionary" title="Youdao Dictionary" onclick="action('youdao-word')"><span class="icon" aria-hidden="true">📖</span></button>
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

local translationWindow = nil
local translationUsercontent = nil
local translationAppearancePoll = nil

local function translationWindowHTML(text)
    local encoded = json.encode({ text })
    local encodedText = type(encoded) == "table" and encoded[1] or encoded or '""'
    local html = [=[
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--panel:#fff;--fg:#202124;--muted:#626b78;--border:#d9dde5;--accent:#2563eb;--field:#fff}
:root[data-appearance="dark"]{--bg:#1d1f24;--panel:#272a31;--fg:#f5f6f8;--muted:#a4acba;--border:#414650;--accent:#8cb1ff;--field:#15171b}
@media(prefers-color-scheme:dark){:root:not([data-appearance="light"]){--bg:#1d1f24;--panel:#272a31;--fg:#f5f6f8;--muted:#a4acba;--border:#414650;--accent:#8cb1ff;--field:#15171b}}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;background:var(--bg);color:var(--fg);font:13px -apple-system,BlinkMacSystemFont,sans-serif}
body{padding:18px}
h1{font-size:17px;margin:0 0 14px;font-weight:650}
label{display:block;font-size:12px;color:var(--muted);margin-bottom:6px}
select,textarea,button{font:inherit;border-radius:8px}
select,textarea{width:100%;background:var(--field);color:var(--fg);border:1px solid var(--border);padding:10px;outline:none}
select:focus,textarea:focus{border-color:var(--accent)}
textarea{resize:vertical;line-height:1.5}
#source{min-height:100px;margin-bottom:14px}
#result{min-height:150px;margin-top:7px}
.row{display:flex;gap:10px;align-items:end}
.field{flex:1;min-width:0}
.actions{display:flex;gap:8px;margin-top:12px}
button{border:1px solid var(--border);background:var(--panel);color:var(--fg);padding:9px 13px;cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:white;font-weight:600}
.status{min-height:17px;margin-top:8px;color:var(--muted);font-size:11px}
</style></head><body>
<h1>Translation</h1>
<div class="row"><div class="field"><label for="direction">Translate from / to</label>
<select id="direction"><option value="en-zh">English → Chinese</option><option value="zh-en">Chinese → English</option><option value="th-zh">Thai → Chinese</option></select></div></div>
<label for="source" style="margin-top:14px">Selected text</label><textarea id="source"></textarea>
<div class="actions"><button class="primary" id="translate">Translate in ChatGPT</button></div>
<div class="status" id="status" role="status">Choose a direction, then translate. ChatGPT will display the result.</div>
<script>
const selectedText=__SELECTED_TEXT__;
const bridge=(action,payload={})=>{try{window.webkit.messageHandlers.translationWindow.postMessage({action,...payload})}catch(e){}};
const source=document.getElementById('source'),direction=document.getElementById('direction'),status=document.getElementById('status');
source.value=selectedText;
document.getElementById('translate').addEventListener('click',()=>bridge('translate',{text:source.value,direction:direction.value}));
source.focus();
</script></body></html>
]=]
    return (html:gsub("__SELECTED_TEXT__", function() return encodedText end))
end

local function syncTranslationAppearance()
    if not translationWindow then return end
    local style = hs.host.interfaceStyle and hs.host.interfaceStyle()
    local appearance = style == "Dark" and "dark" or "light"
    translationWindow:evaluateJavaScript(
        "document.documentElement.setAttribute('data-appearance'," .. string.format("%q", appearance) .. ");" ..
        "document.documentElement.style.colorScheme=" .. string.format("%q", appearance) .. ";"
    )
end

local function showTranslationWindow(text)
    if translationAppearancePoll then translationAppearancePoll:stop(); translationAppearancePoll = nil end
    if translationWindow then translationWindow:delete(); translationWindow = nil end
    translationUsercontent = webview.usercontent.new("translationWindow")
    translationUsercontent:setCallback(function(message)
        message = normalizeMessage(message)
        if type(message) ~= "table" then return end
        local body = message.body or message
        if type(body) ~= "table" then return end
        if body.action == "copy" then
            if type(body.text) == "string" and body.text ~= "" then
                pasteboard.setContents(body.text)
                hs.alert.show("Translation copied")
            end
        elseif body.action == "translate" then
            local sourceText = trim(body.text)
            local direction = body.direction
            local languageInstruction = ({
                ["en-zh"] = "Translate the following text from English into natural, fluent Chinese. Preserve its meaning and tone.",
                ["zh-en"] = "Translate the following text from Chinese into natural, fluent English. Preserve its meaning and tone.",
                ["th-zh"] = "Translate the following text from Thai into natural, fluent Chinese. Preserve its meaning and tone."
            })[direction]
            if not languageInstruction then return end
            if sourceText == "" then
                translationWindow:evaluateJavaScript("document.getElementById('status').textContent='Enter text to translate.'")
                return
            end
            local prompt = languageInstruction .. "\n\n" .. sourceText
            pasteboard.setContents(prompt)
            translationWindow:evaluateJavaScript("document.getElementById('status').textContent='Opening ChatGPT for translation…'")
            -- Reuse the same ChatGPT conversation behavior as the toolbar button:
            -- open/activate the conversation and paste the translation request.
            local appleScript = [[
                tell application "Safari"
                    activate
                    set targetURL to "]] .. CHATGPT_URL .. [["
                    repeat with w in windows
                        repeat with t in tabs of w
                            if (URL of t) is targetURL then
                                set current tab of w to t
                                set index of w to 1
                                return "FOUND"
                            end if
                        end repeat
                    end repeat
                    open location targetURL
                    return "OPENED"
                end tell
            ]]
            local ok, result = pcall(function() return hs.osascript.applescript(appleScript) end)
            if not ok or type(result) ~= "table" or result.ok == false then
                hs.task.new("/usr/bin/open", nil, { CHATGPT_URL }):start()
            end
            timer.doAfter(1.8, function()
                eventtap.keyStroke({ "cmd" }, "v", 0.08)
                timer.doAfter(1.0, function() eventtap.keyStroke({}, "return", 0.08) end)
            end)
        end
    end)
    translationWindow = webview.new({x=180,y=160,w=560,h=620}, {
        developerExtrasEnabled = false,
        javaScriptCanOpenWindowsAutomatically = false,
        transparent = false,
        shadow = true,
        opaque = true
    }, translationUsercontent)
    translationWindow:windowStyle({"titled","closable","resizable"})
    translationWindow:allowTextEntry(true)
    translationWindow:windowTitle("Translation")
    translationWindow:html(translationWindowHTML(text), "file:///")
    syncTranslationAppearance()
    translationAppearancePoll = timer.doEvery(1, syncTranslationAppearance)
    translationWindow:show()
    translationWindow:hswindow():focus()
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
        -- Ask Safari to activate the exact existing tab when it is already open.
        -- If no matching Safari tab exists, open the URL once. The fallback command
        -- opens the URL through the user's default browser without forcing a reload
        -- when the OS can route it to an existing tab.
        local appleScript = [[
            tell application "Safari"
                activate
                set targetURL to "]] .. CHATGPT_URL .. [["
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is targetURL then
                            set current tab of w to t
                            set index of w to 1
                            return "FOUND"
                        end if
                    end repeat
                end repeat
                open location targetURL
                return "OPENED"
            end tell
        ]]
        local ok, task = pcall(function()
            return hs.osascript.applescript(appleScript)
        end)
        if not ok or type(task) ~= "table" or task.ok == false then
            -- Non-Safari default browser fallback. Avoid opening the URL twice
            -- when Safari's script successfully found or opened the conversation.
            hs.task.new("/usr/bin/open", nil, { CHATGPT_URL }):start()
        end
        -- Let the selected conversation become active before pasting.
        timer.doAfter(1.8, function()
            eventtap.keyStroke({ "cmd" }, "v", 0.08)
            timer.doAfter(1.0, function()
                -- print("Pressing return to submit the prompt to ChatGPT ---- ?")
                eventtap.keyStroke({ "" }, "return", 0.08)
            end)
        end)
    elseif action == "translation" then
        hideToolbar()
        showTranslationWindow(text)
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
    toolbar = webview.new({ x = 0, y = 0, w = 360, h = 58 }, {
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
    -- CSS prefers-color-scheme follows the host appearance. Poll the appearance
    -- explicitly as well because hs.host.interfaceStyle() is a getter, not a
    -- watcher-registration API.
    local lastAppearance = nil
    local function syncToolbarAppearance()
        if not toolbar then return end
        local style = hs.host.interfaceStyle and hs.host.interfaceStyle()
        local dark = style == "Dark"
        local appearance = dark and "dark" or "light"
        if appearance == lastAppearance then return end
        lastAppearance = appearance
        toolbar:evaluateJavaScript(
            "document.documentElement.setAttribute('data-appearance'," .. string.format("%q", appearance) .. ");" ..
            "document.documentElement.style.colorScheme=" .. string.format("%q", appearance) .. ";"
        )
    end
    syncToolbarAppearance()
    if appearancePoll then appearancePoll:stop(); appearancePoll = nil end
    appearancePoll = timer.doEvery(1, syncToolbarAppearance)
    local previousHideToolbar = hideToolbar
    hideToolbar = function()
        if appearancePoll then appearancePoll:stop(); appearancePoll = nil end
        previousHideToolbar()
    end

    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local frame = screen:fullFrame()
    local point = hs.mouse.absolutePosition()
    local height = 62
    local x = math.max(frame.x + 8, math.min(point.x - 180, frame.x + frame.w - 360 - 8))
    local y = point.y - height - 14
    if y < frame.y + 8 then y = point.y + 18 end
    y = math.max(frame.y + 8, math.min(y, frame.y + frame.h - height - 8))
    toolbar:frame({ x = x, y = y, w = 360, h = height })
    toolbar:show()
    toolbar:bringToFront()
    -- Set the native frame to the measured layout estimate. The Translation
    -- button includes its word label and is wider than the icon-only buttons.
    -- Match the HTML toolbar geometry: 4 icon buttons and one wider
    -- "🌐 Translation" button, plus the separator between ChatGPT and Translation.
    local buttonWidths = { 38, 38, 116, 38, 38 }
    local gap, padding = 4, 6
    local separatorWidthWithMargins = 5 -- 1px separator + 2px margins on both sides
    local toolbarWidth = 2 + padding * 2 + gap * 5 + separatorWidthWithMargins
    for _, width in ipairs(buttonWidths) do toolbarWidth = toolbarWidth + width end
    toolbarWidth = toolbarWidth + 8 -- safety allowance for WebKit subpixel rounding
    local actualWidth = math.min(toolbarWidth, frame.w - 16)
    x = math.max(frame.x + 8, math.min(point.x - actualWidth / 2, frame.x + frame.w - actualWidth - 8))
    toolbar:frame({ x = x, y = y, w = actualWidth, h = height })

    -- Native Hammerspoon polling only: use the toolbar's known layout and the
    -- native mouse coordinates to determine the target button. No DOM-based
    -- hit testing is used. A tiny JS update only paints the selected button.
    local previousTarget = nil
    hoverWatcher = hs.timer.doEvery(0.025, function()
        local currentToolbar = toolbar
        if not currentToolbar or not currentToolbar:isVisible() then
            if hoverWatcher then hoverWatcher:stop(); hoverWatcher = nil end
            return
        end

        local mouse = hs.mouse.absolutePosition()
        local bounds = currentToolbar:frame()
        local rx, ry = mouse.x - bounds.x, mouse.y - bounds.y
        local target = nil
        if ry >= 7 and ry <= 51 then
            local cursor = padding + 1 -- left border + bar padding
            local buttonActions = { "copy", "chatgpt", "translation", "youdao-result", "youdao-word" }
            for i, name in ipairs(buttonActions) do
                local width = buttonWidths[i]
                if rx >= cursor and rx <= cursor + width then
                    target = name
                    break
                end
                cursor = cursor + width + gap
                if i == 3 then cursor = cursor + separatorWidthWithMargins + gap end
            end
        end

        if target ~= previousTarget then
            previousTarget = target
            local targetLiteral = target and string.format("%q", target) or "null"
            -- Use action names encoded into the page script rather than CSS
            -- attribute selectors, so punctuation or selector parsing cannot
            -- prevent the highlight update from applying.
            local script = "document.querySelectorAll('.bar button').forEach(function(b){" ..
                "var active=" .. targetLiteral .. "!==null && b.getAttribute('data-action')===" .. targetLiteral .. ";" ..
                "b.style.setProperty('background-color',active?getComputedStyle(document.documentElement).getPropertyValue('--toolbar-hover').trim():'transparent','important');" ..
                -- "b.style.setProperty('box-shadow',active?'inset 0 0 0 1px rgba(40,50,70,.18)':'none','important');" ..
                "});"
            currentToolbar:evaluateJavaScript(script)
        end
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
    if appearancePoll then appearancePoll:stop(); appearancePoll = nil end
    if selectionWatcher then selectionWatcher:stop(); selectionWatcher = nil end
    if mouseSelectionTap then mouseSelectionTap:stop(); mouseSelectionTap = nil end
    if toolbar then toolbar:delete(); toolbar = nil end
    return self
end

return obj
