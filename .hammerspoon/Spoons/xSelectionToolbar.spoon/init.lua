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

-- Configurable local-AI toolbar actions. Add entries here to create buttons.
-- {{text}} is replaced by the selected text when the prompt is sent.

local CUSTOM_AI_BUTTONS = {
    {
        id = "Chinese",
        label = "Chinese",
        icon = "🀄️",
        prompt = [[
            Translate the input text into highly colloquial, natural-sounding Chinese, as if a native Chinese speaker were chatting casually with a friend.

                - Use everyday spoken Chinese rather than formal, written, or textbook-style language
                - Adapt expressions freely when necessary to make the translation sound natural in Chinese, while preserving the original meaning, tone, and intent
                - Appropriately incorporate common Chinese conversational expressions, slang, interjections, and even mild profanity when they fit the context. For example, use expressions like “那差别可太他妈大了” when they naturally convey the intended meaning
                - Match the emotional intensity and personality of the original text. Don't force slang, profanity, or catchphrases into every sentence
                - Prefer concise, fluent expressions that people actually use in everyday conversations
                - Do not add explanations, notes, quotation marks, or any content that is not part of the translation
                - Never use periods (。 or .) at the end of sentences or paragraphs. Use commas, question marks, exclamation marks, or other appropriate punctuation when needed
                - Output only the final Chinese translation.

            **Text to Process:**

            {{text}}
        ]],
    },{
        id = "Polishing",
        label = "Polishing",
        icon = "👞",
        prompt = [[
            **Organize the speech-to-text content rules:**
            
                - Proofread the original text and fix grammar, spelling, punctuation, and missing words with minimal changes. Strictly preserve the original meaning, word choices, and sentence structure. Do not rewrite, paraphrase, or improve the writing style. Only make changes necessary for grammatical correctness and natural readability. Remove all “um” and “uh” fillers and unnecessary pauses, and merge sentence fragments into complete, natural sentences where necessary.
                - When the input text contains sequential or transitional markers such as "First," "Second," "Third," "Finally," or similar expressions, convert the relevant content into a numbered list (e.g., "1. ", "2. ", "3. "). Preserve the original meaning and wording as much as possible, ensuring that each list item represents a distinct point or step. Remove the original transitional markers when they become redundant after formatting.
                - only output the final text, without adding other content.   

            **Text to Process:**

            {{text}}
        ]],
    },
    {
        id = "correct",
        label = "Correct",
        icon = "✏️",
        -- prompt = "Proofread the text below. Fix grammar, spelling, punctuation, and missing words with minimal changes. Preserve the original meaning, wording, and sentence structure. Output only the corrected text.\\n\\n{{text}}",
        prompt = [[Please process the text below according to the following instructions.

            **1. Corrected English**

            Proofread the original text and fix grammar, spelling, punctuation, and missing words with minimal changes. Strictly preserve the original meaning, word choices, and sentence structure. Do not rewrite, paraphrase, or improve the writing style. Only make changes necessary for grammatical correctness and natural readability. Remove all “um” and “uh” fillers and unnecessary pauses, and merge sentence fragments into complete, natural sentences where necessary.

            **2. Colloquial Chinese Translation**

            Translate the corrected English into very colloquial, natural-sounding Chinese, as people would actually speak in everyday life. Preserve the original meaning, tone, and intent rather than translating word for word. Make the Chinese easy to understand and conversational.

            **3. Natural American Expression**

            Rewrite the corrected English to show how a native American English speaker would naturally express the same meaning in everyday conversation. You may rephrase sentences more freely in this section, but preserve the original meaning. Use natural, conversational American English without excessive slang, overly formal expressions, or unnecessarily complicated vocabulary.

            **Output Format**

            For each section, use the following format:

            **1. Corrected English**
            [The minimally corrected English text]

            **2. Colloquial Chinese Translation**
            [The natural, conversational Chinese translation]

            **3. Natural American Expression**
            [The natural, everyday American English version]

            **Important Rules**
            - Keep the three sections in the exact order specified above.
            - Do not omit any meaningful information from the original text.
            - Do not add explanations, grammar notes, commentary, or extra sections.
            - If the original text contains multiple sentences or paragraphs, preserve the original organization as much as possible.
            - Make the first section as conservative as possible and reserve freer rephrasing for the third section.
            - If the text contains Chinese words embedded in English sentences, translate those Chinese words into appropriate English in Sections 1 and 3 while preserving their intended meaning.

            **Text to Process:**

            {{text}}
        ]],
        -- prompt = "Please proofread the following text. Make minimal changes to fix grammar and missing components. Strictly preserve my original word choices and sentence patterns. Do not “improve” the style—only fix the mistakes and Remove all 'um/uh' fillers and pauses. Merge fragments into complete, natural spoken sentences. just make it grammatically correct and smooth to read. Then, you need to translate your corrected text into very colloquial Chinese, and please don’t use any periods at the end. 你可以适当加一点中国人常用的口头禅，甚至是粗鄙一点的口头禅都可以，比如说像，“那差别可太他妈大了”，这种。Finally, give me a Natural American Expression that Shows how a native American English speaker would naturally say the same thing in daily life.This section can rewrite the sentence more freely to sound native and conversational.Keep the meaning the same, but make it sound realistic and commonly spoken in America.Avoid slang that is too extreme or hard to understand: \\n\\n{{text}}",
    },
}

local function htmlEscape(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"):gsub("'", "&#39;")
end

local function customActionName(config)
    return "custom-" .. tostring(config.id or ""):gsub("[^%w_-]", "")
end

local function customButtonWidth(config)
    local label = tostring(config.label or "")
    local ok, count = pcall(function() return utf8.len(label) end)
    count = ok and count or #label
    return math.max(58, 42 + count * 7)
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function looksLikeImagePayload(value)
    if type(value) ~= "string" then return false end
    return value:match("^data:image/") ~= nil
        or value:match("^iVBORw0KGgo") ~= nil
        or value:match("^/9j/") ~= nil
        or value:match("^R0lGOD") ~= nil
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
    local customButtons = {}
    for _, config in ipairs(CUSTOM_AI_BUTTONS or {}) do
        local action = customActionName(config)
        customButtons[#customButtons + 1] =
            "<button class=\"custom-ai-button\" data-action=\"" .. htmlEscape(action) ..
            "\" aria-label=\"" .. htmlEscape(config.label) .. "\" title=\"" .. htmlEscape(config.label) ..
            "\" onclick=\"action('" .. htmlEscape(action) .. "')\"><span class=\"icon\" aria-hidden=\"true\">" ..
            htmlEscape(config.icon) .. "</span></button>"
    end
    local customButtonsHTML = table.concat(customButtons, "\n")
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
.icon{display:inline-flex;align-items:center;justify-content:center;min-width:20px;font-size:22px;line-height:1}
.separator{flex:0 0 1px;width:1px;height:24px;background:var(--toolbar-separator);margin:0 2px}
:root,[data-appearance="light"]{--toolbar-bg:rgba(250,250,252,.98);--toolbar-fg:#202124;--toolbar-border:rgba(0,0,0,.12);--toolbar-hover:#d8dee9;--toolbar-hover-border:rgba(40,50,70,.18);--toolbar-active:#c5ccd8;--toolbar-separator:#d9dce2}
[data-appearance="dark"]{--toolbar-bg:rgba(39,41,46,.98);--toolbar-fg:#f5f6f8;--toolbar-border:rgba(255,255,255,.16);--toolbar-hover:#454951;--toolbar-hover-border:rgba(255,255,255,.18);--toolbar-active:#555b66;--toolbar-separator:#555a64}
@media(prefers-color-scheme:dark){:root:not([data-appearance="light"]){--toolbar-bg:rgba(39,41,46,.98);--toolbar-fg:#f5f6f8;--toolbar-border:rgba(255,255,255,.16);--toolbar-hover:#454951;--toolbar-hover-border:rgba(255,255,255,.18);--toolbar-active:#555b66;--toolbar-separator:#555a64}}
</style>
</head><body><div class="bar">
<button data-action="copy" aria-label="Copy" title="Copy" onclick="action('copy')"><span class="icon" aria-hidden="true">📋</span></button>
<!-- <button data-action="doubao" onclick="action('doubao')"><span class="icon" aria-hidden="true">✎</span> Proofread + translate</button> -->
<button data-action="translation-provider" aria-label="Translation provider" title="Translation provider" onclick="action('translation-provider')"><span class="icon" aria-hidden="true">🔀</span></button>

__CUSTOM_AI_BUTTONS__
<span class="separator"></span>
<button data-action="youdao-result" aria-label="Youdao Result" title="Youdao Result" onclick="action('youdao-result')"><span class="icon" aria-hidden="true">🔍</span></button>
<button data-action="youdao-word" aria-label="Youdao Dictionary" title="Youdao Dictionary" onclick="action('youdao-word')"><span class="icon" aria-hidden="true">📚</span></button>
</div><script>
const selection = __SELECTION_JSON__;
function action(name){try{window.webkit.messageHandlers.selectionToolbar.postMessage({action:name,text:selection});}catch(e){document.title="Toolbar error: "+e.message;}}
</script></body></html>
]=]
    html = html:gsub("__CUSTOM_AI_BUTTONS__", function() return customButtonsHTML end)
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
local translationRequestTask = nil
local translationRequestId = 0
local translationWindowPinned = false

local TRANSLATION_API_BASE = "http://127.0.0.1:8000/v1"
local TRANSLATION_MODEL = "Qwen3-4B-Instruct-2507-4bit"
local TRANSLATION_PROVIDER_CHOICE = "local" -- local oMLX+Qwen or ChatGPT

-- Add custom local-AI actions here. Each entry creates a toolbar button and
-- uses its prompt template with the selected text. Use {{text}} where the
-- selection should be inserted into the prompt.

local function translationWindowHTML(text)
    local encoded = json.encode({ text })
    local encodedText = type(encoded) == "table" and encoded[1] or encoded or '""'
    local html = [=[
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--fg:#202124;--muted:#626b78;--border:#d9dde5;--accent:#2563eb;--panel:#fff}
:root[data-appearance="dark"]{--bg:#1d1f24;--fg:#f5f6f8;--muted:#a4acba;--border:#414650;--accent:#8cb1ff;--panel:#272a31}
@media(prefers-color-scheme:dark){:root:not([data-appearance="light"]){--bg:#1d1f24;--fg:#f5f6f8;--muted:#a4acba;--border:#414650;--accent:#8cb1ff;--panel:#272a31}}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;background:var(--bg);color:var(--fg);font:13px -apple-system,BlinkMacSystemFont,sans-serif}
body{padding:16px}
header{display:flex;align-items:center;gap:8px;margin-bottom:12px}
h1{font-size:15px;margin:0;font-weight:650;flex:1}
.status{font-size:11px;color:var(--muted)}
#pin{padding:5px 8px;min-width:32px;font-size:14px;line-height:1}
#pin[aria-pressed="true"]{background:#dbeafe;border-color:#bfdbfe;color:#334155}
:root[data-appearance="dark"] #pin[aria-pressed="true"]{background:#3b4658;border-color:#59677d;color:#f1f5f9}
@media(prefers-color-scheme:dark){:root:not([data-appearance="light"]) #pin[aria-pressed="true"]{background:#3b4658;border-color:#59677d;color:#f1f5f9}}
#pin:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
html,body{height:auto;min-height:0}
body{padding:16px;overflow:visible}
#conversation{width:100%;max-height:none;overflow:visible;display:flex;flex-direction:column;gap:8px;padding:0;scroll-behavior:auto;overscroll-behavior:contain}
#followup{margin:0}

.conversation-message{position:relative;background:var(--panel);color:var(--fg);border:1px solid var(--border);border-radius:9px;padding:12px;white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.5}
.conversation-message.user{background:var(--bg);border-color:var(--border);margin-left:9%}
.conversation-message.assistant{margin-right:0;padding-top:42px;padding-right:44px;padding-bottom:12px}
.message-role{font-size:11px;color:var(--muted);font-weight:650;margin-bottom:6px}
.conversation-message.assistant .message-role{position:absolute;top:12px;left:12px;margin:0}
.message-content{font-size:13px;white-space:pre-wrap;overflow-wrap:anywhere}
.message-copy{position:absolute;right:8px;top:6px;width:28px;height:28px;padding:0;border-radius:6px;font-size:19px;line-height:1;color:var(--muted)}
.message-copy:hover{background:var(--bg);color:var(--fg)}
#followup{display:none;box-sizing:border-box;width:100%;height:38px;min-height:38px;max-height:38px;resize:none;line-height:1.4;overflow:auto;margin-top:12px;margin-bottom:0;background:var(--panel);color:var(--fg);border:1px solid var(--border);border-radius:9px;padding:8px 12px;font:13px -apple-system,BlinkMacSystemFont,sans-serif}
#followup.visible{display:block}
#followup:focus{outline:1px solid var(--accent);outline-offset:0}
.actions{display:flex;justify-content:flex-end;align-items:center;gap:8px;margin-top:10px}
button{border:1px solid var(--border);border-radius:8px;background:var(--panel);color:var(--fg);padding:7px 11px;font:inherit;cursor:pointer}
button:disabled{opacity:.4;cursor:default}
</style></head><body>
<header><h1>Translation</h1><span class="status" id="status">Translating locally…</span><button id="pin" type="button" aria-label="Pin window" aria-pressed="false" title="Keep window open when clicking outside">📌</button></header>
<div id="conversation" aria-live="polite"></div>
<textarea id="followup" aria-label="Follow-up instruction" placeholder="follow up ... press enter to send"></textarea>
<script>
const bridge=(action,payload={})=>{try{window.webkit.messageHandlers.translationWindow.postMessage({action,...payload})}catch(e){}};
const status=document.getElementById('status'),pin=document.getElementById('pin'),followup=document.getElementById('followup'),conversation=document.getElementById('conversation');
let latestAssistantText='';
let messageSequence=0;
const addMessage=(role,text)=>{
  const card=document.createElement('section');
  card.className='conversation-message '+role;
  const label=document.createElement('div');
  label.className='message-role';
  label.textContent=role==='user'?'You':'AI';
  const content=document.createElement('div');
  content.className='message-content';
  content.textContent=text||'';
  card.append(label,content);
  if(role==='assistant'){
    const copyButton=document.createElement('button');
    copyButton.className='message-copy';
    copyButton.type='button';
    copyButton.textContent='⧉';
    copyButton.title='Copy this response';
    copyButton.setAttribute('aria-label','Copy this AI response');
    copyButton.addEventListener('click',()=>{
      bridge('copy',{text:content.textContent||''});
    });
    card.appendChild(copyButton);
  }
  conversation.appendChild(card);
  card.dataset.messageId=String(++messageSequence);
  return card;
};
let currentAssistantCard=addMessage('assistant','');
let currentAssistantText='';
const sendFollowupMessage=()=>{const text=followup.value.trim();if(!text)return;bridge('followup',{text});followup.value='';};
followup.addEventListener('keydown',event=>{
  if(event.key==='Escape'){event.preventDefault();bridge('close');return;}
  // Ignore Enter while an IME is composing/selecting a Chinese candidate.
  if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing&&event.keyCode!==229){
    event.preventDefault();
    sendFollowupMessage();
  }
});
document.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();bridge('close');}});
let pinned=false;
pin.addEventListener('click',()=>{
  pinned=!pinned;
  pin.setAttribute('aria-pressed',pinned?'true':'false');
  pin.setAttribute('aria-label',pinned?'Unpin window':'Pin window');
  pin.title=pinned?'Allow window to close when clicking outside':'Keep window open when clicking outside';
  pin.textContent=pinned?'📍':'📌';
  bridge('pin',{pinned});
});
window.translationPinned=value=>{
  pinned=!!value;
  pin.setAttribute('aria-pressed',pinned?'true':'false');
  pin.setAttribute('aria-label',pinned?'Unpin window':'Pin window');
  pin.title=pinned?'Allow window to close when clicking outside':'Keep window open when clicking outside';
  pin.textContent=pinned?'📍':'📌';
};
window.translationStatus=value=>status.textContent=value||'';
window.translationResult=value=>{
  currentAssistantText=value||'';
  latestAssistantText=currentAssistantText;
  const content=currentAssistantCard.querySelector('.message-content');
  if(content)content.textContent=currentAssistantText;
  const copyButton=currentAssistantCard.querySelector('.message-copy');
  if(copyButton)copyButton.disabled=!latestAssistantText;
  if(latestAssistantText)followup.classList.add('visible');

  // Resize to fit the full conversation when possible. If the physical screen
  // limit prevents that, keep the bottom follow-up field visible by scrolling
  // down to it rather than scrolling up to the newest AI card.
  requestAnimationFrame(()=>{
    bridge('resize',{contentHeight:document.documentElement.scrollHeight});
    requestAnimationFrame(()=>setTimeout(()=>{
      revealFollowupIfClipped();
    },120));
  });
};
window.revealFollowupIfClipped=()=>{
  if(!followup||!followup.classList.contains('visible'))return;
  const rect=followup.getBoundingClientRect();
  const bottom=window.innerHeight;
  // Scroll only when the follow-up box is actually clipped by the bottom edge.
  if(rect.bottom>bottom-12){
    window.scrollTo({top:window.scrollY+(rect.bottom-(bottom-12)),behavior:'auto'});
  }
};
window.beginFollowup=(userText)=>{
  addMessage('user',userText);
  currentAssistantCard=addMessage('assistant','');
  currentAssistantText='';
  const copyButton=currentAssistantCard.querySelector('.message-copy');
  if(copyButton)copyButton.disabled=true;
  followup.classList.remove('visible');
  status.textContent='Working locally…';
};
window.setPopupResultHeight=maxHeight=>{
  const limit=Math.max(90,Number(maxHeight)||90);
  result.style.height=Math.min(Math.max(90,result.scrollHeight),limit)+'px';
  result.style.overflowY=result.scrollHeight>limit?'auto':'hidden';
};
copy.addEventListener('click',()=>bridge('copy',{text:result.value}));
</script></body></html>
]=]
    return (html:gsub("__SELECTED_TEXT__", function() return encodedText end))
end

local function translationJSCall(functionName, value)
    local encoded = json.encode({ tostring(value or "") })
    local literal = type(encoded) == "table" and encoded[1] or encoded or '""'
    return "window." .. functionName .. "(" .. literal .. ");"
end

local lastTranslationResult = ""

local translationEscapeTap = nil
local destroyTranslationWindow

local function stopTranslationEscapeTap()
    if translationEscapeTap then
        translationEscapeTap:stop()
        translationEscapeTap = nil
    end
end

local function startTranslationEscapeTap()
    stopTranslationEscapeTap()
    translationEscapeTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
        if event:getKeyCode() == hs.keycodes.map.escape and translationWindow then
            -- Use the forward-declared local so the callback resolves the
            -- function assigned below, not a nonexistent global.
            if destroyTranslationWindow then destroyTranslationWindow() end
            return true
        end
        return false
    end)
    if translationEscapeTap then translationEscapeTap:start() end
end

destroyTranslationWindow = function()
    stopTranslationEscapeTap()
    -- Restore the standard window level before clearing the pinned popup.
    if translationWindow then
        pcall(function() translationWindow:level(hs.drawing.windowLevels.normal) end)
    end
    translationWindowPinned = false
    -- Invalidate callbacks from any request associated with the old popup.
    translationRequestId = translationRequestId + 1
    if translationRequestTask then
        pcall(function() translationRequestTask:terminate() end)
        translationRequestTask = nil
    end
    if translationAppearancePoll then
        translationAppearancePoll:stop()
        translationAppearancePoll = nil
    end
    if translationWindow then
        local oldWindow = translationWindow
        translationWindow = nil
        pcall(function() oldWindow:delete() end)
    end
    translationUsercontent = nil
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

local function sendLocalPromptRequest(sourceText, promptTemplate, windowTitle)
    if translationRequestTask then
        pcall(function() translationRequestTask:terminate() end)
        translationRequestTask = nil
    end
    translationRequestId = translationRequestId + 1
    local requestId = translationRequestId
    local prompt = tostring(promptTemplate or ""):gsub("{{text}}", function() return sourceText end)
    local body = {
        model = TRANSLATION_MODEL,
        messages = {
            { role = "system", content = "Follow the user's instruction precisely and return only the requested result." },
            { role = "user", content = prompt }
        },
        temperature = 0.1,
        stream = false
    }
    local encodedBody = json.encode(body)
    if type(encodedBody) == "table" then encodedBody = encodedBody[1] end
    if type(encodedBody) ~= "string" then
        translationWindow:evaluateJavaScript(translationJSCall("translationStatus", "Could not encode request."))
        return
    end
    -- The local OpenAI-compatible endpoint may require an API key. Keep the
    -- credential outside the repository and read it from the Hammerspoon process
    -- environment (for example, launch Hammerspoon with SUX_AI_API_KEY set).
    local apiKey = os.getenv("SUX_AI_API_KEY") or ""
    if trim(apiKey) == "" then
        translationWindow:evaluateJavaScript(
            translationJSCall("translationStatus", "API key required (set SUX_AI_API_KEY in Hammerspoon's environment)")
        )
        return
    end

    translationWindow:evaluateJavaScript(translationJSCall("translationStatus", "Working locally…"))
    local task = hs.task.new("/usr/bin/curl", function(exitCode, stdOut, stdErr)
        if requestId ~= translationRequestId or not translationWindow then return end
        translationRequestTask = nil
        if exitCode ~= 0 then
            local detail = trim(stdErr)
            local message = "Local AI request failed at " .. TRANSLATION_API_BASE
            if detail ~= "" then message = message .. "\\n" .. detail end
            translationWindow:evaluateJavaScript(translationJSCall("translationStatus", message))
            return
        end
        local ok, response = pcall(function() return json.decode(stdOut or "") end)
        if not ok or type(response) ~= "table" then
            translationWindow:evaluateJavaScript(translationJSCall("translationStatus", "The local AI server returned invalid JSON."))
            return
        end
        local result = response.choices and response.choices[1]
            and response.choices[1].message and response.choices[1].message.content
        if type(result) ~= "string" or trim(result) == "" then
            local errorMessage = response.error and (response.error.message or response.error) or "No result returned."
            translationWindow:evaluateJavaScript(translationJSCall("translationStatus", tostring(errorMessage)))
            return
        end
        lastTranslationResult = trim(result)
        translationWindow:evaluateJavaScript(
            translationJSCall("translationResult", lastTranslationResult) ..
            translationJSCall("translationStatus", windowTitle .. " · local AI")
        )
    end, {
        "-sS", "--max-time", "120", "-X", "POST",
        TRANSLATION_API_BASE .. "/chat/completions",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " .. apiKey,
        "--data-binary", encodedBody
    })
    if not task then
        translationWindow:evaluateJavaScript(translationJSCall("translationStatus", "Could not start local AI request."))
        return
    end
    translationRequestTask = task
    task:start()
end

local function showCustomAIWindow(text, config)
    destroyTranslationWindow()
    translationWindowPinned = false
    translationUsercontent = webview.usercontent.new("translationWindow")
    translationUsercontent:setCallback(function(message)
        message = normalizeMessage(message)
        if type(message) ~= "table" then return end
        local body = message.body or message
        if type(body) ~= "table" then return end
        if body.action == "copy" then
            if type(body.text) == "string" and body.text ~= "" then
                pasteboard.setContents(body.text)
                destroyTranslationWindow()
            end
        elseif body.action == "close" then
            destroyTranslationWindow()
        elseif body.action == "followup" then
            local followupText = trim(body.text)
            if followupText ~= "" and translationWindow then
                local title = config.label or "AI"
                local followupPrompt = [[You have already answered the original request below. Answer the user's follow-up question directly, using the full conversation context. Keep earlier answers intact and do not repeat them unless needed for clarity.

Original selected text:
]] .. text .. [[

Previous AI response:
]] .. tostring(lastTranslationResult or "") .. [[

Follow-up question:
]] .. followupText
                local encodedFollowup = json.encode({followupText})
                local followupLiteral = type(encodedFollowup) == "table" and encodedFollowup[1] or encodedFollowup or '""'
                translationWindow:evaluateJavaScript(
                    "window.beginFollowup && window.beginFollowup(" .. followupLiteral .. ");"
                )
                sendLocalPromptRequest(followupPrompt, "{{text}}", title)
            end
        elseif body.action == "pin" and type(body.pinned) == "boolean" then
            translationWindowPinned = body.pinned
            if translationWindow then
                if translationWindowPinned then
                    -- Raise the response above normal application windows and keep it there.
                    translationWindow:level(hs.drawing.windowLevels.screenSaver)
                    translationWindow:bringToFront(true)
                    translationWindow:hswindow():focus()
                else
                    translationWindow:level(hs.drawing.windowLevels.normal)
                    translationWindow:bringToFront(true)
                end
                translationWindow:evaluateJavaScript(
                    "window.translationPinned && window.translationPinned(" .. tostring(translationWindowPinned) .. ");"
                )
            end
        elseif body.action == "resize" and type(body.contentHeight) == "number" then
            local currentScreen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
            if translationWindow and currentScreen then
                local screenFrame = currentScreen:frame()
                local availableHeight = math.max(260, screenFrame.h - 40)
                -- Body height now reflects the complete conversation, but a native
                -- window cannot exceed the screen. Use the smaller of content height
                -- and screen height, and let WebView shrink the layout naturally only
                -- when the whole conversation cannot fit on screen.
                local targetHeight = math.min(availableHeight, math.max(220, body.contentHeight + 24))
                local windowFrame = translationWindow:frame()
                local bottom = windowFrame.y + windowFrame.h
                local y = math.max(screenFrame.y + 20, math.min(bottom - targetHeight, screenFrame.y + screenFrame.h - targetHeight - 20))
                if targetHeight >= availableHeight then
                    y = screenFrame.y + 20
                    targetHeight = availableHeight
                end
                translationWindow:frame({x=windowFrame.x,y=y,w=windowFrame.w,h=targetHeight})
                -- Let the page finish layout after resizing, then keep the follow-up input visible.
                timer.doAfter(0.12, function()
                    if translationWindow then
                        translationWindow:evaluateJavaScript("window.revealFollowupIfClipped && window.revealFollowupIfClipped();")
                    end
                end)
            end
        end
    end)
    -- Reuse the compact result-popup UI with a custom title.
    local popupText = string.format("%s", text)
    local mousePoint = hs.mouse.absolutePosition()
    local targetScreen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local f = targetScreen:frame()
    local w, h = 420, 230
    local maxWindowHeight = math.max(180, f.h - 40)
    local x = math.max(f.x, math.min(mousePoint.x - w / 2, f.x + f.w - w))
    local y = math.max(f.y + 20, math.min(mousePoint.y - h - 18, f.y + f.h - h - 20))
    if mousePoint.y - h - 18 < f.y + 20 then y = math.min(mousePoint.y + 18, f.y + f.h - h - 20) end
    y = math.max(f.y + 20, math.min(y, f.y + f.h - h - 20))
    translationWindow = webview.new({x=x,y=y,w=w,h=h}, {
        developerExtrasEnabled = false, 
        javaScriptCanOpenWindowsAutomatically = false,
        transparent = false, 
        shadow = true,
        opaque = true
    }, translationUsercontent)
    translationWindow:shadow(true)
    translationWindow:windowStyle({"titled","closable","resizable"})
    translationWindow:allowTextEntry(true)
    translationWindow:windowTitle(config.label)
    translationWindow:level(hs.drawing.windowLevels.normal)
    translationWindow:windowCallback(function(action, _, focused)
        if action == "focusChange" and focused == false and translationWindow and not translationWindowPinned then
            destroyTranslationWindow()
        end
    end)
    translationWindow:html(translationWindowHTML(popupText):gsub("<h1>Translation</h1>", "<h1>" .. htmlEscape(config.label) .. "</h1>"), "file:///")
    -- The conversation view sizes itself to its content; no fixed textarea height.
    syncTranslationAppearance()
    translationAppearancePoll = timer.doEvery(1, syncTranslationAppearance)
    translationWindow:show()
    translationWindow:hswindow():focus()
    startTranslationEscapeTap()
    timer.doAfter(0.15, function()
        if translationWindow then sendLocalPromptRequest(text, config.prompt, config.label) end
    end)
end

local function openSafariURL(url)
    hideToolbar()
    hs.task.new("/usr/bin/open", nil, { "-a", "Safari", url }):start()
end

local function showTranslationProviderChooser()
    local chooser = hs.chooser.new(function(selected)
        if not selected then return end
        if selected.id == "provider-label" then return end
        TRANSLATION_PROVIDER_CHOICE = selected.id
        hs.alert.show(selected.id == "local" and "Provider: Local oMLX + Qwen" or "Provider: ChatGPT")
    end)
    chooser:choices({
        {id="local", text="1. Local AI", subText=TRANSLATION_PROVIDER_CHOICE == "local" and "🔀 Current Provider" or "Switch to Local AI"},
        {id="chatgpt", text="2. ChatGPT", subText=TRANSLATION_PROVIDER_CHOICE == "chatgpt" and "🔀 Current Provider" or "Switch to ChatGPT"}
    })
    chooser:show()
end

local function runChatGPTWorkflow(text, promptTemplate)
    local prompt = tostring(promptTemplate or CHATGPT_PROMPT) .. "\n\n" .. text
    pasteboard.setContents(prompt)
    hideToolbar()

    -- Keep the simple, predictable workflow: open ChatGPT, wait for the page,
    -- paste the prepared prompt, then press Return one second later.
    hs.task.new("/usr/bin/open", nil, { CHATGPT_URL }):start()
    timer.doAfter(5.0, function()
        eventtap.keyStroke({ "cmd" }, "v", 0.08)
        timer.doAfter(1.0, function()
            eventtap.keyStroke({}, "return", 0.08)
        end)
    end)
end

local function onToolbarMessage(message)
    -- logger.i("Toolbar message received: " .. tostring(type(message)))
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
    -- logger.i("Toolbar action=" .. tostring(action) .. ", text length=" .. tostring(#text))
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
    elseif action == "translation-provider" then
        hideToolbar()
        showTranslationProviderChooser()
    elseif type(action) == "string" and action:sub(1, 7) == "custom-" then
        local actionId = action:sub(8)
        for _, config in ipairs(CUSTOM_AI_BUTTONS or {}) do
            if tostring(config.id) == actionId then
                hideToolbar()
                if TRANSLATION_PROVIDER_CHOICE == "chatgpt" then
                    runChatGPTWorkflow(text, config.prompt)
                else
                    showCustomAIWindow(text, config)
                end
                break
            end
        end
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
    -- The toolbar has five icon-only buttons and a separator. Add a safety allowance for WebKit subpixel rounding.
    local buttonWidths = { 38, 38, 38, 38 } -- Copy, provider, Youdao Result, Youdao Dictionary
    for _, config in ipairs(CUSTOM_AI_BUTTONS or {}) do
        buttonWidths[#buttonWidths + 1] = 38
    end
    local gap, padding = 4, 6
    local separatorWidthWithMargins = 5 -- 1px separator + 2px margins on both sides
    local toolbarWidth = 2 + padding * 2 + gap * #buttonWidths + separatorWidthWithMargins
    for _, width in ipairs(buttonWidths) do toolbarWidth = toolbarWidth + width end
    toolbarWidth = toolbarWidth + 8
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
            local buttonActions = { "copy", "translation-provider" }
            for _, config in ipairs(CUSTOM_AI_BUTTONS or {}) do
                buttonActions[#buttonActions + 1] = customActionName(config)
            end
            buttonActions[#buttonActions + 1] = "youdao-result"
            buttonActions[#buttonActions + 1] = "youdao-word"
            for i, name in ipairs(buttonActions) do
                local width = buttonWidths[i]
                if rx >= cursor and rx <= cursor + width then
                    target = name
                    break
                end
                cursor = cursor + width + gap
                if i == 1 + #(CUSTOM_AI_BUTTONS or {}) then cursor = cursor + separatorWidthWithMargins + gap end
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
    local toolbarExpiryTimer = nil
    local pendingCapture = false
    local eventTapHealthTimer = nil

    -- Hide the selection toolbar three seconds after showing it. Duplicate
    -- selection detections must not keep extending the toolbar's lifetime.
    local TOOLBAR_VISIBLE_TIMEOUT = 3

    local function scheduleToolbarExpiry()
        if toolbarExpiryTimer then
            toolbarExpiryTimer:stop()
            toolbarExpiryTimer = nil
        end
        toolbarExpiryTimer = timer.doAfter(TOOLBAR_VISIBLE_TIMEOUT, function()
            toolbarExpiryTimer = nil
            if toolbar and toolbar:isVisible()
                and timer.secondsSinceEpoch() - lastShownAt >= TOOLBAR_VISIBLE_TIMEOUT then
                hideToolbar()
            end
        end)
    end
    local captureSelectionFromClipboardFallback

    -- On this Mac, WeChat creates multiple windows while its screenshot overlay is active.
    -- Zero windows is a transition/unknown state, not proof that the tool is inactive.
    local WECHAT_BUNDLE_ID = "com.tencent.xinWeChat"
    local function getWeChatScreenshotState()
        local app = hs.application.get(WECHAT_BUNDLE_ID)
        if not app then return "unknown", 0 end

        local ok, windows = pcall(function() return app:allWindows() end)
        if not ok or type(windows) ~= "table" then return "unknown", 0 end

        local count = #windows
        if count > 1 then return "active", count end
        if count == 1 then return "inactive", count end
        return "unknown", 0
    end

    local function screenshotStateAllowsSelection()
        local state, count = getWeChatScreenshotState()
        if state ~= "inactive" then
            logger.d(string.format(
                "Skipping selection detection: WeChat state=%s, windows=%d",
                state, count
            ))
            return false
        end
        return true
    end

    local function reportEventTapState(reason)
        local enabled = false
        if mouseSelectionTap then
            local ok, value = pcall(function() return mouseSelectionTap:isEnabled() end)
            enabled = ok and value == true
        end
        logger.w(string.format(
            "Selection mouse event tap %s (enabled=%s, reason=%s)",
            enabled and "healthy" or "disabled",
            tostring(enabled),
            tostring(reason or "health-check")
        ))
        return enabled
    end

    local function ensureMouseSelectionTap()
        if not mouseSelectionTap then return false end
        local enabled = false
        local ok, value = pcall(function() return mouseSelectionTap:isEnabled() end)
        enabled = ok and value == true
        if enabled then return true end

        logger.w("Selection mouse event tap is disabled; attempting to restart it")
        pcall(function() mouseSelectionTap:stop() end)
        local started, err = pcall(function() mouseSelectionTap:start() end)
        if not started then
            logger.e("Failed to restart selection mouse event tap: " .. tostring(err))
            return false
        end
        local checkOk, checkEnabled = pcall(function() return mouseSelectionTap:isEnabled() end)
        if not checkOk or not checkEnabled then
            logger.e("Selection mouse event tap is still disabled after restart")
            return false
        end
        logger.i("Selection mouse event tap recovered")
        return true
    end

    local function selectionFromAccessibility()
        local ok, value = pcall(function()
            local function walk(element)
                local depth = 0
                while element and depth < 10 do
                    -- Only accept actual selected text from text-capable controls.
                    -- Finder file selections and generic AXSelectedText-like values
                    -- must not trigger the floating text toolbar.
                    local role = element:attributeValue("AXRole")
                    local subrole = element:attributeValue("AXSubrole")
                    local selected = element:attributeValue("AXSelectedText")
                    local textRole = role == "AXTextField" or role == "AXTextArea"
                        or role == "AXTextView" or role == "AXComboBox"
                        or role == "AXWebArea" or role == "AXSearchField"
                    local textSubrole = subrole == "AXSearchField"
                    if textRole or textSubrole then
                        if type(selected) == "string" and trim(selected) ~= "" then return selected end
                    end
                    element = element:attributeValue("AXParent")
                    depth = depth + 1
                end
                return nil
            end
            local system = hs.axuielement.systemElement()
            local focused = system and system:attributeValue("AXFocusedUIElement")
            return walk(focused)
        end)
        return ok and trim(value) or ""
    end

    local function showIfSelection(value)
        value = trim(value)
        if value == "" then return false end
        local now = hs.timer.secondsSinceEpoch()
        -- Suppress duplicate detections from the same gesture, but don't suppress
        -- later selections just because the selected text matches the previous one.
        if toolbar and toolbar:isVisible() and selectedText == value then
            -- Treat this as a duplicate event from the same selection gesture,
            -- not a new show request: do not reset the three-second countdown.
            return true
        end
        -- A hidden toolbar must never suppress a genuine new selection, even if
        -- the user selects the same text again quickly.
        selectedText = value
        lastText = value
        lastShownAt = now
        buildToolbar(value)
        scheduleToolbarExpiry()
        return true
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

    local function captureSelectionFromClipboardFallback()
        if pendingCapture or not screenshotStateAllowsSelection() then return end
        local fallbackApp = hs.application.frontmostApplication()
        if not fallbackApp or fallbackApp:bundleID() == "org.hammerspoon.Hammerspoon" then return end
        local appName = string.lower(fallbackApp:name() or "")
        local bundleID = string.lower(fallbackApp:bundleID() or "")
        if bundleID == "com.apple.finder" or appName == "finder" then return end

        -- Recheck immediately before synthesizing Cmd+C; the state may have changed
        -- during the delayed Accessibility retries.
        if not screenshotStateAllowsSelection() then return end

        pendingCapture = true
        local oldClipboard = pasteboard.getContents()
        local oldCount = pasteboard.changeCount()
        _G.xSelectionToolbarSyntheticCopyUntil = hs.timer.secondsSinceEpoch() + 0.7
        hs.eventtap.keyStroke({"cmd"}, "c", 0.02)
        timer.doAfter(0.22, function()
            local newCount = pasteboard.changeCount()
            local copied = trim(pasteboard.getContents())
            if oldClipboard ~= nil and newCount ~= oldCount then
                pasteboard.setContents(oldClipboard)
            end
            pendingCapture = false

            -- Don't show a toolbar if WeChat entered screenshot mode while the
            -- synthetic copy was in flight. The clipboard restoration above still runs.
            if not screenshotStateAllowsSelection() then return end

            local isPlainText = copied ~= "" and not looksLikeImagePayload(copied)
                and not copied:match("^file://")
                and not copied:match("^/[^%s]+$")
            if newCount ~= oldCount and isPlainText then
                local axValue = selectionFromAccessibility()
                local selection = trim(axValue ~= "" and axValue or copied)
                if selection ~= "" and not looksLikeImagePayload(selection) then
                    showIfSelection(selection)
                end
            end
        end)
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
            mouseDownPoint = {x=p.x, y=p.y}
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
            local state, windowCount = getWeChatScreenshotState()
            local didDrag = mouseDragDistance >= 4
            mouseDownPoint = nil
            mouseDragDistance = 0

            if state ~= "inactive" then
                logger.d(string.format(
                    "Skipping mouse-up selection detection: WeChat state=%s, windows=%d",
                    state, windowCount
                ))
                return false
            end

            timer.doAfter(0.12, function()
                if not screenshotStateAllowsSelection() then return end
                if toolbar and toolbar:isVisible() then
                    local p = hs.mouse.absolutePosition()
                    local f = toolbar:frame()
                    if p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then
                        hideToolbar()
                    end
                    return
                end

                local attempts = 0
                local function retrySelectionRead()
                    if toolbar and toolbar:isVisible() then return end
                    if not screenshotStateAllowsSelection() then return end
                    local app = hs.application.frontmostApplication()
                    if not app or app:bundleID() == "org.hammerspoon.Hammerspoon" then return end

                    attempts = attempts + 1
                    local value = selectionFromAccessibility()
                    if showIfSelection(value) then return end

                    -- AXSelectedText can lag behind mouse-up in browsers and other
                    -- apps. Retry for ~320 ms; only then use clipboard fallback
                    -- for an actual drag so normal clicks never synthesize Cmd+C.
                    if attempts < 4 then
                        timer.doAfter(0.08, retrySelectionRead)
                    elseif didDrag then
                        captureSelectionFromClipboardFallback()
                    end
                end
                retrySelectionRead()
            end)
            return false
        end
        return false
    end)
    mouseSelectionTap:start()
    reportEventTapState("after-start")

    -- Recover if macOS disables the event tap temporarily. This timer also emits
    -- a diagnostic only when it observes a disabled tap, avoiding noisy logs.
    eventTapHealthTimer = timer.doEvery(5, function()
        if not mouseSelectionTap then
            if eventTapHealthTimer then eventTapHealthTimer:stop(); eventTapHealthTimer = nil end
            return
        end
        ensureMouseSelectionTap()
    end)

    -- Keyboard-based selection detection intentionally disabled; only mouse drag selection is supported.
    return self
end
function obj:stop()
    if hoverWatcher then hoverWatcher:stop(); hoverWatcher = nil end
    if appearancePoll then appearancePoll:stop(); appearancePoll = nil end
    if selectionWatcher then selectionWatcher:stop(); selectionWatcher = nil end
    if toolbarExpiryTimer then toolbarExpiryTimer:stop(); toolbarExpiryTimer = nil end
    if eventTapHealthTimer then eventTapHealthTimer:stop(); eventTapHealthTimer = nil end
    if mouseSelectionTap then mouseSelectionTap:stop(); mouseSelectionTap = nil end
    if toolbar then toolbar:delete(); toolbar = nil end
    return self
end

return obj
