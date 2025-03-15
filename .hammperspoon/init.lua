
------------------------ A simple clipboard history implement ------------------------

local hotkey = require "hs.hotkey"
local pasteboard = require "hs.pasteboard"
local pbwatcher = require "hs.pasteboard.watcher"
local chooser = require "hs.chooser"

local text_clipboard_history = {}  -- Array to store the clipboard history for text
local img_clipboard_history = {}  -- Array to store the clipboard history for img
local menuData = {}  -- chooser menu data

local pasteboard_watcher = nil
local clipboard_chooser = nil  -- Chooser/menu object

local max_history_size_for_text = 100
local max_history_size_for_img = 10
local display_max_text_length = 200

-- local last_change = pasteboard.changeCount() -- keeps track of how many times the pasteboard owner has changed // Indicates a new copy has been made

-- Add the given string to the history
function pasteboardToClipboard(item_type, item)
    local cur_ts = os.time()
    if item_type == "text" then
        table.insert(text_clipboard_history, {ts=cur_ts, content=item})
    else
        -- table.insert(img_clipboard_history, {ts=cur_ts, content=item, imgEncodedString=item:encodeAsURLString()})
        table.insert(img_clipboard_history, {ts=cur_ts, content=item})
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
        if (content == nil) and (pasteboardImg ~= nil) then
            -- Don't add if it's the same as the last entry
            if #img_clipboard_history ~= 0 and 
                (#text_clipboard_history == 0 or (img_clipboard_history[#img_clipboard_history].ts > text_clipboard_history[#text_clipboard_history].ts)) then
                    if img_clipboard_history[#img_clipboard_history].content:encodeAsURLString() == pasteboardImg:encodeAsURLString() then
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
    if #img_clipboard_history == 0 and #text_clipboard_history == 0 then
        return
    end
    if menuData[3].type == "text" then
        pasteboard.setContents(menuData[3].data)
    else
        pasteboard.writeObjects(menuData[3].data)
    end
end

clipboard_chooser = chooser.new(function(choice)
    if choice then
        pasteboard_watcher:stop()
        if choice.type == "text" then
            pasteboard.setContents(choice.data)
            hs.eventtap.keyStroke({"cmd"}, "v")
            restoreNewestClipContent()
        elseif choice.type == "image" then 
            pasteboard.writeObjects(choice.data)
            hs.eventtap.keyStroke({"cmd"}, "v")
            restoreNewestClipContent()
        elseif choice.type == "paste_all" then 
            pasteSomeWithDelimiterFromStartRow(#menuData)
        elseif choice.type == "clear_all" then 
            -- pasteboard.clearContents()
            text_clipboard_history = {}  -- Array to store the clipboard history for text
            img_clipboard_history = {}  -- Array to store the clipboard history for img
            -- last_change = pasteboard.changeCount()
        end
        if choice.type ~= "paste_all" then  -- why? because pasteSomeWithDelimiterFromStartRow will do the logic below itself
            -- last_change = pasteboard.changeCount()
            pasteboard_watcher:start()
            menuData = nil
        end
    end
end)

function pasteAllWithDelimiterRecursionVersion(startRow)
    if startRow < 3 then
        restoreNewestClipContent()
        menuData = nil
        pasteboard_watcher:start()
        hs.alert.show("the Paste task has finished !!")
        return
    end    

    local entry = menuData[startRow]
    if entry.type == "text" then
        -- 这个方法不稳定, 经常打不出来
        -- hs.eventtap.keyStrokes(text_clipboard_history[i].content)
        -- hs.eventtap.keyStrokes("\n")
        -- print(k)
        pasteboard.setContents(entry.data .. "\n")
        hs.eventtap.keyStroke({"cmd"}, "v")
    else
        pasteboard.writeObjects(entry.data)
        hs.eventtap.keyStroke({"cmd"}, "v")
        pasteboard.setContents("\n")
        hs.eventtap.keyStroke({"cmd"}, "v")
    end
    hs.timer.doAfter(0.6, function()
        pasteAllWithDelimiterRecursionVersion(startRow - 1)
    end)
end

function pasteSomeWithDelimiterFromStartRow(startRow)
    -- print("[pasteSomeWithDelimiterFromStartRow: " .. os.date("%Y-%m-%d %H:%M:%S", selectedRowTs) .. "] ")
    if startRow < 3 then
        return
    end    
    
    hs.alert.show("Please wait for the Paste task to finish !!")
    pasteboard_watcher:stop()
    clipboard_chooser:hide()
    pasteAllWithDelimiterRecursionVersion(startRow)  -- this is the recursion version

    -- -----------------**** below is the traversal version ****------------------------
    -- local k = startRow
    -- while k >= 3 do
    --     local entry = menuData[k]
    --     if entry.type == "text" then
    --         -- 这个方法不稳定, 经常打不出来
    --         -- hs.eventtap.keyStrokes(text_clipboard_history[i].content)
    --         -- hs.eventtap.keyStrokes("\n")
    --         print(k)
    --         pasteboard.setContents(entry.data .. "\n")
    --         hs.eventtap.keyStroke({"cmd"}, "v")
    --     else
    --         pasteboard.writeObjects(entry.data)
    --         hs.eventtap.keyStroke({"cmd"}, "v")
    --         pasteboard.setContents("\n")
    --         hs.eventtap.keyStroke({"cmd"}, "v")
    --     end
    --     k = k - 1
    -- end
    -- restoreNewestClipContent()
    -- menuData = nil
    -- pasteboard_watcher:start()
end

clipboard_chooser:rightClickCallback(function(row)
    -- print("_showContextMenu row:" .. row)
    point = hs.mouse.absolutePosition()
    -- print(clipboard_chooser:selectedRowContents(row).text)
    -- print(clipboard_chooser:selectedRowContents(row).type)
    -- print(clipboard_chooser:selectedRowContents(row).data)
    -- local selectedRowTs = clipboard_chooser:selectedRowContents(row).rowTs
    local menu = hs.menubar.new(false)
    local menuTable = {
        { 
            title = "Paste All the rows above this row in the order from early to late, including this row", fn = hs.fnutils.partial(pasteSomeWithDelimiterFromStartRow, row)
        },
    }
    menu:setMenu(menuTable)
    menu:popupMenu(point)
    -- print(hs.inspect(point))
end)

-- Function to show clipboard history
function showClipboardHistory()
    pasteboard_watcher:start()  -- if u don't add this line, it will stop in some seconds for no reason, idk why

    menuData = {}

    -- insert a "Paste All" action into the menuData at the first place
    table.insert(
        menuData,
        { 
            text = "Paste All",
            type = "paste_all",
            image = hs.image.imageFromName('NSMultipleDocuments')
        }
    )

    -- insert a "Clear All" action into the menuData at the second place
    table.insert(
        menuData,
        { 
            text = "Clear All",
            type = "clear_all",
            image = hs.image.imageFromName('NSTrashFull')
        }
    )

    function insertToMenuData(v, type, unixTs)
        -- print("unixTs " .. tostring(unixTs))
        local dateTimeStr = "[" .. os.date("%Y-%m-%d %H:%M:%S", unixTs) .. "] "
        if type == "text" then
            table.insert(menuData, { text = dateTimeStr .. string.sub(v, 0, display_max_text_length),
                                    type = type,
                                    rowTs = unixTs,
                                    data = v})
        elseif (type == "image") then
            table.insert(menuData, { text = dateTimeStr .. "[IMG]",
                                    type = type,
                                    rowTs = unixTs,
                                    data = v,
                                    --    image = hs.image.imageFromURL(v)})
                                    image = v})
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
            insertToMenuData(img_clipboard_history[j].content, "image", img_clipboard_history[j].ts)
            j = j - 1
        end
    end

    while i >= 1 do
        insertToMenuData(text_clipboard_history[i].content, "text", text_clipboard_history[i].ts)
        i = i - 1
    end

    while j >= 1 do
        insertToMenuData(img_clipboard_history[j].content, "image", img_clipboard_history[j].ts)
        j = j - 1
    end

    clipboard_chooser:choices(menuData)
    clipboard_chooser:show()

end

-- Start the pasteboard watcher
pasteboard_watcher = pbwatcher.new(handleClipboardChange)
pasteboard_watcher:start()

-- Add to your hotkey bindings (you can change the key combination as needed)
hotkey.bind({"ctrl", "shift"}, "v", showClipboardHistory)



------------------------ when your mac is fully charged, make some noise to notify ------------------------

lastBatteryPercentage = hs.battery.percentage()

-- Function to alert and beep when battery hits 78%
function batteryLevelChanged()
    local batteryPercentage = hs.battery.percentage()
    if (lastBatteryPercentage < 78 and batteryPercentage == 78) or (lastBatteryPercentage > 36 and batteryPercentage == 36) then

        lastBatteryPercentage = batteryPercentage

        -- hs.alert.show("Battery is at " .. tostring(batteryPercentage) .. "% !!")
        -- print("Battery is at 78%!")

        hs.timer.doAfter(1, function()
            hs.sound.getByName("Funk"):play() -- Plays a system sound
            hs.timer.doAfter(1, function()
                hs.sound.getByName("Submarine"):play()
                hs.timer.doAfter(1, function()
                    hs.sound.getByName("Glass"):play()
                    hs.timer.doAfter(1, function()
                        hs.sound.getByName("Hero"):play()
                        hs.timer.doAfter(1, function()
                            hs.sound.getByName("Ping"):play()
                            hs.timer.doAfter(1, function()
                                hs.sound.getByName("Pop"):play()
                                hs.timer.doAfter(1, function()
                                    hs.sound.getByName("Purr"):play()
                                    hs.timer.doAfter(1, function()
                                        hs.sound.getByName("Tink"):play()
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
--
    end
end

-- Create a battery watcher
batteryWatcher = hs.battery.watcher.new(batteryLevelChanged)
batteryWatcher:start() -- Start the watcher



--------------------- 当聚焦某些app时, 自动切换到上一次离开app时的输入法(已失效) & 科学上网 ---------------------

-- 切换app的时候触发太多了次了, 所以弃用
-- hs.keycodes.inputSourceChanged(
--     function()
--         local app = hs.application.frontmostApplication()
--         if app then
--             local app_name = app:name()
--             local last_input_source = APP_NAME_2_LAST_INPUT_SOURCE[app_name]
--             local cur_input_source = hs.keycodes.currentSourceID()
--             print("主动改变 hs.keycodes.inputSourceChanged: 改之前: " .. cur_input_source .. ", appName是: " .. app_name .. " last_input_source=" .. (last_input_source or "nil"))
--             if last_input_source and last_input_source ~= cur_input_source then
--                 hs.timer.doAfter(0.16, function()  -- 这个timer不可少, 不然经常会输入法没有改掉而错乱
--                     print("主动改变 hs.keycodes.inputSourceChanged: " .. hs.keycodes.currentSourceID() .. ", appName是: " .. app:name())
--                     APP_NAME_2_LAST_INPUT_SOURCE[app:name()] = hs.keycodes.currentSourceID()
--                 end)
--             end
--         end
--     end
-- )

function changeInputSourceToLastInputSource(app)
    local app_name = app:name()
    local last_input_source = APP_NAME_2_LAST_INPUT_SOURCE[app_name]
    local cur_input_source = hs.keycodes.currentSourceID()
    local new_input_source = cur_input_source
    if last_input_source then
        if last_input_source ~= cur_input_source then
            -- print("切换了app后,  changeInputSourceToLastInputSource, 改之前: " .. cur_input_source .. ", appName是: " .. app_name)
            -- hs.keycodes.currentSourceID(last_input_source)
            new_input_source = fn_cb_switch_input_source()
            -- print("切换了app后,  changeInputSourceToLastInputSource, 改之后: last_input_source:" .. last_input_source .. ", 当前为: " .. hs.keycodes.currentSourceID() .. ", appName是: " .. app_name)
        end
    else
        APP_NAME_2_LAST_INPUT_SOURCE[app_name] = cur_input_source
    end
    return new_input_source
end

-- 以下代码专属于开启搜狗输入法的英文输入法模式
function changeInputSourceToLastLang(app)
    hs.keycodes.currentSourceID("com.sogou.inputmethod.sogou.pinyin")  -- 永远保证是搜狗输入法
    local app_name = app:name()
    local last_input_lang = APP_NAME_2_LAST_INPUT_LANG[app_name]
    if last_input_lang and last_input_lang ~= CUR_INPUT_LANG then
        print("切换了app后,  changeInputSourceToLastLang, 改之前: " .. tostring(CUR_INPUT_LANG) .. ", appName是: " .. app_name)
        hs.eventtap.keyStroke({"cmd", "shift"}, "e", 0)
        if CUR_INPUT_LANG == 1 then
            CUR_INPUT_LANG = 0
        else 
            CUR_INPUT_LANG = 1
        end
        print("切换了app后,  changeInputSourceToLastLang, 改之后: last_input_lang:" .. tostring(last_input_lang) .. ", 当前为: " .. tostring(CUR_INPUT_LANG) .. ", appName是: " .. app_name)
    end
end


  
function autoProxyPac(app)  -- 科学上网自动切换pac
    -- # 科学上网
    -- 科学上网软件： ClashX    
    -- 下载地址: https://itlanyan.com/trojan-clients-download/
    -- 步骤:  
    -- 1. 去 just my socks 拷贝那些服务节点的配置然后去google搜“ss配置转clash配置”的网站(但是似乎很有可能会泄露相关 ss 密码之类的)，比如 https://subconverter.speedupvpn.com ， 然后在线转换为clash的配置然后点击 ClashX 的菜单栏的图标， 然后 `Config`-`Remote Config`-`Manage`-`Add`
    -- 2. 如果发现上不了网的话, 点击 ClashX 的图标, 然后 `Config`-`Open Config Folder` 查看生成的 config 文件是否和 本 github 项目的 `clashx`里的类似
    -- 3. 请不要打开 clashx 的"设置为系统代理", 否则剪映等一些软件无法联网, 
        -- 1. 但此时 safari 也会翻不了墙 (以下教程参考 https://www.youtube.com/watch?v=pAY8pNou9Gk)
        --     1. 此时需要先把 `safari_proxy` 文件夹中的 `proxy.pac`(这个是由 edge 的 SwitchyOmega插件里的配置生成的) 放到 `/Library/WebServer/Documents` 里
        --     2. 然后在`设置`-`网络`-`高级`-`代理`的`Automatic proxy configuration` 里输入 `http://127.0.0.1/proxy.pac`, 然后点击 右下角的 `ok`, 点击完`ok`之后会退回上一层菜单, 然后再点击 `Apply`
        --     3. 然后在 terminal 里输入命令 `sudo apachectl start`
        --     4. 去 safari 的地址栏输入`http://127.0.0.1/proxy.pac` 测试一下是否能访问这个, 有内容说明成功了, 此时再看看是否能谷歌/油管
        -- 2. 此时还有个问题就是:可能会因为其它软件给关掉，如 ClashX 设置为系统代理的时候会把这个 pac 给清除掉, 所以我们需要检查一下 `hammerspoon` 里的 `init.lua`是否有 `networksetup -setautoproxyurl ` 相关的代码, 有的话就会自动在激活 safari 的时候自动设置一下 pac 设置(相关代码其实是参考了 https://nowtime.cc/macos/1753.html , `networksetup -setautoproxyurl "Wi-Fi" "http://127.0.0.1/proxy.pac"` , 这个 "Wi-Fi" 是通过命令 `networksetup -listallnetworkservices` 拿到的)

    -- 当 safari 被激活的时候
    -- 会自动在激活 safari 的时候自动设置一下 pac 设置(相关代码其实是参考了 https://nowtime.cc/macos/1753.html), (`networksetup -setautoproxyurl "Wi-Fi" "http://127.0.0.1/proxy.pac"` (这个 "Wi-Fi" 是通过命令 `networksetup -listallnetworkservices` 拿到的)
    -- 设置一下 proxy.pac
    os.execute('networksetup -setautoproxyurl "Wi-Fi" "http://127.0.0.1/proxy.pac"');
    -- local copyret = os.execute('networksetup -setautoproxyurl "Wi-Fi" "http://127.0.0.1/proxy.pac"');
    -- print("copyret = "..copyret)
    -- print("auto proxy pac")
end

CUR_INPUT_LANG = 0  -- 0 for chinese, 1 for english
APP_NAME_2_LAST_INPUT_LANG = {}

APP_NAME_2_LAST_INPUT_SOURCE = {
    ["Terminal"] = "com.apple.keylayout.ABC",
    ["Code"] = "com.apple.keylayout.ABC",  -- vs code
    ["WebStorm"] = "com.apple.keylayout.ABC",
    ["PyCharm"] = "com.apple.keylayout.ABC",
    ["Clion"] = "com.apple.keylayout.ABC",
    ["IntelliJ IDEA"] = "com.apple.keylayout.ABC",
    ["IntelliJ IDEA CE"] = "com.apple.keylayout.ABC",
    ["Rider"] = "com.apple.keylayout.ABC",
    ["网易有道翻译"] = "com.apple.keylayout.ABC",
    ["Messages"] = "com.apple.keylayout.ABC",
    
    ["TencentDocs"] = "com.sogou.inputmethod.sogou.pinyin",
    ["腾讯文档"] = "com.sogou.inputmethod.sogou.pinyin",
    ["WeChat"] = "com.sogou.inputmethod.sogou.pinyin",
    ["微信"] = "com.sogou.inputmethod.sogou.pinyin",
    ["WPS Office"] = "com.sogou.inputmethod.sogou.pinyin",
}

APP_NAME_2_FOCUSED_ACTION = {
    -- ["Safari"] = autoProxyPac,
    -- ["Safari浏览器"] = autoProxyPac,
}

SHOULD_MAXIMIZE_APPS = {
    ["Terminal"] = true,
    ["Code"] = true,  -- vscode
    ["WebStorm"] = true,
    ["PyCharm"] = true,
    ["Clion"] = true,
    ["IntelliJ IDEA"] = true,
    ["IntelliJ IDEA CE"] = true,
    ["Rider"] = true,
    ["TencentDocs"] = true,
    ["腾讯文档"] = true,
    -- ["WeChat"] = true,
    -- ["微信"] = true,  开视频的小窗口也会放大, 所以注释
    ["WPS Office"] = true,
    ["Safari"] = true,
    ["Safari浏览器"] = true,
    ["豆包"] = true,
    ["ChatGPT"] = true,
    ["Microsoft Edge"] = true,
    ["Mail"] = true,
    ["Maps"] = true,
    ["Notes"] = true,
    ["Docker Desktop"] = true,
    ["Spotify"] = true,
    ["Finder"] = true,
    ["Preview"] = true,
    ["Activity Monitor"] = true,
    ["NeteaseMusic"] = true,
    ["阿里云盘"] = true,
}

-- -- event 可以是: hs.window.filter.windowCreated 或者 hs.window.filter.windowFocused, 不填则为 hs.window.filter.windowFocused
-- local function set_app_focused_func(app_name, app_focused_func, event)
--     event = event or hs.window.filter.windowFocused
  
--     hs.window.filter.new(app_name):subscribe(
--         event,
--         function()
--             app_focused_func()
--         end
--     )
-- end

-- for k, v in pairs(APP_NAME_2_FOCUSED_ACTION) do
--     set_app_focused_func(k, v[1], v[2])
-- end


local application = require "hs.application"

function applicationWatcher(appName, eventType, appObject)
    -- print(appName)
    -- print(eventType)
    -- print("mmms")
    if (eventType == application.watcher.activated or eventType == application.watcher.launched) then
        if SHOULD_MAXIMIZE_APPS[appName] then
            hs.timer.doAfter(0.4, function()  -- 这个timer不可少, 不然经常窗口还没出来就执行了 winresize
                winresize("max")

                -- if pkg.isStageManagerEnabled then
                    -- newrect = { 1 / 27, 0, 26 / 27, 1 }
                -- else
                    -- newrect = hs.layout.maximized
                -- end
                -- appObject:getWindow():move(newrect)
                -- print("mmmmmmmmmmmaxxx???")
            end)
        end

        -- if eventType == application.watcher.activated and appName == "Finder" then
        --     winresize("max")
        --     -- print("mmmmmmmmmmmaxxx???")
        -- end

        hs.timer.doAfter(0.16, function()  -- 这个timer不可少, 不然经常会输入法没有改掉
            -- print("applicationWatcher 000")
            -- local app = application.frontmostApplication()
            -- local focusedAction = APP_NAME_2_FOCUSED_ACTION[appObject:name()]
            local focusedAction = APP_NAME_2_FOCUSED_ACTION[appName]
            if focusedAction then
                focusedAction(appObject)
            end
            -- print(appObject:bundleID())
            local new_input_source = changeInputSourceToLastInputSource(appObject)
            local tempMap = {
                ["com.apple.keylayout.ABC"] = "English",
                ["com.sogou.inputmethod.sogou.pinyin"] = "中文",
            }
            hs.alert.show(tempMap[new_input_source], 1.8);

            -- changeInputSourceToLastLang(appObject)
            -- hs.alert.show(str, [style], [screen], [seconds]) -> uuid
            -- hs.keycodes.currentSourceID("com.sogou.inputmethod.sogou.pinyin")  -- 永远保证是搜狗输入法
        end)
    end
end

appWatcher = application.watcher.new(applicationWatcher)
appWatcher:start()


--------------------- 触发角自定义 ---------------------

-- Toggle application focus
function toggle_application(_app)
    -- finds a running applications
    local app = application.find(_app)
    if not app then
        -- print("111 taa")
        -- application not running, launch app
        application.launchOrFocus(_app)
        return
    end
    -- application running, toggle hide/unhide
    local mainwin = app:mainWindow()
    if mainwin then
        -- print("3333 taa")
        if true == app:isFrontmost() then
            -- print("4444 taa")
            mainwin:application():hide()
        else
            -- print("5555 taa")
            mainwin:application():activate(true)
            mainwin:application():unhide()
            mainwin:focus()
        end
    else
        -- no windows, maybe hide
        if true == app:hide() then
            -- print("6666 taa")
            -- focus app
            application.launchOrFocus(_app)
        else
            -- print("7777 taa")
            -- nothing to do
        end
        -- print("8888 taa")
        -- application.launchOrFocus(_app)
    end
end

-- hs.loadSpoon("ClipboardTool")
-- spoon.ClipboardTool:start()

-- hs.loadSpoon("WindowScreenLeftAndRight")
-- spoon.WindowScreenLeftAndRight:bindHotkeys(
--     {
--         screen_left = { { "ctrl", "alt", "cmd" }, "L" },
--         screen_right = { { "ctrl", "alt", "cmd" }, "N" },
-- })

-- hs.loadSpoon("DeepLTranslate")
-- spoon.DeepLTranslate:bindHotkeys(
--     {
--         translate = { { "ctrl", "alt", "cmd" }, "L" },
--         rephrase = { { "ctrl", "alt", "cmd" }, "N" },
-- })

-- hs.loadSpoon("LookupSelection")
-- spoon.LookupSelection:bindHotkeys(
-- {
--     lexicon = { { "ctrl", "alt", "cmd" }, "L" },
--     neue_notiz = { { "ctrl", "alt", "cmd" }, "N" },
--     hsdocs = { { "ctrl", "alt", "cmd" }, "H" },
--  }
-- )

-- hs.loadSpoon("PopupTranslateSelection")
-- spoon.PopupTranslateSelection:bindHotkeys(
--     {
--         translate = { { "ctrl", "alt", "cmd" }, "L" },
--         rephrase = { { "ctrl", "alt", "cmd" }, "N" },
-- })

-- hs.loadSpoon("Seal")
-- spoon.Seal:loadPlugins({"filesearch", "pasteboard", "safari_bookmarks", "screencapture", "apps", "calc"})
-- spoon.Seal:bindHotkeys(
--     {
--         show = { { "ctrl", "alt", "cmd" }, "L" },
--         toggle = { { "ctrl", "alt", "cmd" }, "N" },
--     })
-- spoon.Seal:refreshAllCommands()
-- spoon.Seal:start()
-- spoon.Seal:loadPlugins({"filesearch"})


hs.loadSpoon("HotCornersAndEdges")
--spoon.HotCornersAndEdges.delta = 20 -- 触发角处的正方形边长(单位像素)
spoon.HotCornersAndEdges:start()

-- 触发快捷键 ctrl+shift+tab: 前一个APP
spoon.HotCornersAndEdges:setLowerLeft(function()
    -- hs.timer.doAfter(0.16, function()
    --     -- 模拟释放 Ctrl+Shift 键
    --     hs.eventtap.keyStroke({}, "ctrl", 0)
    --     hs.eventtap.keyStroke({}, "shift", 0)
    -- end)
    -- hs.eventtap.keyStroke({"ctrl", "shift"}, "tab", 1600)
    -- toggle_application("Finder")
    -- application.launchOrFocus("Finder")
    -- application.launchOrFocus("NetEaseMusic")
    --application.launchOrFocus("Listen1")
    -- application.launchOrFocus("WeChat")
    -- 下面这行代码可以开启一个新的 finder 窗口但是无法聚焦他, 有可能只是后台开启了一个
    -- hs.osascript.applescript('tell application "Finder" to make new Finder window')

    -- local win = hs.window.focusedWindow()
    -- win:toggleZoom()
    

    hs.eventtap.keyStroke({}, "cmd", 0) -- 经常后面这段代码执行了没效果可能是背什么东西卡住了, 先按一下cmd试试解除
    
    -- print("low right 1")
    hs.eventtap.event.newKeyEvent("cmd", true):post()
    -- print("low right 12")
    hs.timer.doAfter(0.16, function()
        -- print("low right 13")
        hs.eventtap.event.newKeyEvent("tab", true):post()
        hs.timer.doAfter(0.16, function()
            -- print("low right 14")
            hs.eventtap.event.newKeyEvent("tab", false):post()
            -- print("low right 15")
            -- print("setLowerRight-tab-false")
            hs.timer.doAfter(0.16, function()
                -- print("low right 16")
                -- print("setLowerRight-cmd-false")
                -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.cmd, false):post()
                hs.eventtap.event.newKeyEvent("cmd", false):post()
                -- print("low right 17")
            end)
        end)
    end)
end)


-- 触发快捷键 ctrl+shift+tab: 前一个标签页
spoon.HotCornersAndEdges:setUpperLeft(function()
    -- 模拟按下 Ctrl+Shift 键
    -- hs.eventtap.keyStroke({"ctrl", "shift"}, "tab", 1600)
    -- hs.timer.doAfter(0.16, function()
    --     -- 模拟释放 Ctrl+Shift 键
    --     hs.eventtap.keyStroke({}, "tab", 0)
    --     hs.eventtap.keyStroke({}, "shift", 0)
    --     hs.eventtap.keyStroke({}, "ctrl", 0)
    -- end)
    -- hs.eventtap.event.newKeyEvent({"ctrl", "shift"}, "tab", true):post()
    -- hs.timer.doAfter(0.16, function()
    --     hs.eventtap.event.newKeyEvent({"ctrl"}, "tab", false):post()
    -- end)


    hs.eventtap.keyStroke({}, "cmd", 0) -- 经常后面这段代码执行了没效果可能是背什么东西卡住了, 先按一下cmd试试解除

    -- print("up left 1")
    hs.eventtap.event.newKeyEvent("ctrl", true):post()
    -- print("up left 12")
    hs.timer.doAfter(0.01, function()
        -- print("up left 13")
       hs.eventtap.event.newKeyEvent("shift", true):post()
    --    print("up left 14")
    --    print("setUpperLeft-shift-true")
       hs.timer.doAfter(0.01, function()
        -- print("up left 15")
           hs.eventtap.event.newKeyEvent("tab", true):post()
        --    print("up left 16")
           hs.eventtap.event.newKeyEvent("tab", false):post()
        --    print("up left 17")
        --    print("setUpperLeft-tab-false")
           hs.timer.doAfter(0.16, function()
            -- print("up left 18")
            --    print("setUpperLeft-shift-false")
               hs.eventtap.event.newKeyEvent("shift", false):post()
            --    print("up left 19")
               hs.timer.doAfter(0.01, function()
                --    print("setUpperLeft-ctrl-false")
                    -- print("up left 111")
                   hs.eventtap.event.newKeyEvent("ctrl", false):post()
                --    print("up left 112")
               end)
           end)
       end)
    end)
end)

-- 触发快捷键 cmd+tab: 后一个标签页
spoon.HotCornersAndEdges:setLowerRight(function()
    --    hs.alert.show('setLowerRight')
    -- hs.eventtap.keyStroke({"cmd"}, "tab", 1600)
    -- hs.eventtap.event.newKeyEvent({"cmd"}, "tab", true):post()
    -- hs.eventtap.event.newKeyEvent({"cmd"}, "tab", false):post()

    -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.cmd, true):post()
    --application.launchOrFocus("Microsoft Edge")
    --application.launchOrFocus("NeteaseMusic")
    --application.launchOrFocus("网易有道翻译")

    -- -- 触发快捷键 ctrl+shift+tab: 前一个标签页
    -- hs.eventtap.keyStroke({"ctrl", "shift"}, "tab", 0)
    -- -- 模拟释放 Ctrl+Shift 键
    -- hs.eventtap.keyStroke({}, "ctrl", 0)
    -- hs.eventtap.keyStroke({}, "shift", 0)


    hs.eventtap.keyStroke({}, "cmd", 0) -- 经常后面这段代码执行了没效果可能是背什么东西卡住了, 先按一下cmd试试解除
    
    -- print("low left 1")
    hs.eventtap.event.newKeyEvent("ctrl", true):post()
    -- print("low left 12")
    hs.timer.doAfter(0.02, function()
        -- print("low left 13")
        -- hs.eventtap.event.newKeyEvent("shift", true):post()
        -- print("setUpperLeft-shift-true")
        -- print("low left 14")
        hs.timer.doAfter(0.02, function()
        -- print("low left 15")
            hs.eventtap.event.newKeyEvent("tab", true):post()
            -- print("low left 16")
            hs.eventtap.event.newKeyEvent("tab", false):post()
            -- print("low left 17")
            -- print("setUpperLeft-tab-false")
            hs.timer.doAfter(0.16, function()
            --    print("setUpperLeft-shift-false")
                -- print("low left 18")
                -- hs.eventtap.event.newKeyEvent("shift", false):post()
                -- print("low left 19")
                hs.timer.doAfter(0.02, function()
                -- print("low left 111")
                    -- print("setUpperLeft-ctrl-false")
                    hs.eventtap.event.newKeyEvent("ctrl", false):post()
                    -- print("low left 112")
               end)
           end)
       end)
    end)
end)

-- 触发快捷键 ctrl+tab: 后一个标签页
spoon.HotCornersAndEdges:setUpperRight(function()
    --    hs.alert.show('setUpperRight')
    -- hs.eventtap.keyStroke({"ctrl"}, "tab", 1600)
    -- hs.eventtap.event.newKeyEvent({"ctrl"}, "tab", true):post()
    -- hs.eventtap.event.newKeyEvent({"ctrl"}, "tab", false):post()
    
    -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.ctrl, true):post()
    -- print("uppppright triggered! 1")
    --hs.eventtap.event.newKeyEvent("ctrl", true):post()
    --hs.timer.doAfter(0.68, function()
    --    print("uppppright triggered! 2")
    --    hs.eventtap.event.newKeyEvent("tab", true):post()
    --    -- print("setUpperRight-tab-false")
    --    hs.timer.doAfter(0.68, function()
    --        hs.eventtap.event.newKeyEvent("tab", false):post()
    --        -- print("setUpperRight-tab-false")
    --        hs.timer.doAfter(0.68, function()
    --            -- print("setUpperRight-ctrl-false")
    --            -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.ctrl, false):post()
    --            print("uppppright triggered! 3")
    --            hs.eventtap.event.newKeyEvent("ctrl", false):post()
    --        end)
    --    end)
    --end)

    -- hs.eventtap.keyStroke({"ctrl"}, "tab", 0)
    -- hs.eventtap.keyStroke({}, "ctrl", 0)


    hs.eventtap.keyStroke({}, "cmd", 0) -- 经常后面这段代码执行了没效果可能是背什么东西卡住了, 先按一下cmd试试解除
    -- print("up right 1")
    hs.eventtap.event.newKeyEvent("ctrl", true):post()
    hs.timer.doAfter(0.01, function()
        -- print("up right 12")
        hs.eventtap.event.newKeyEvent("tab", true):post()
        -- print("up right 13")
        hs.eventtap.event.newKeyEvent("tab", false):post()
        -- print("up right 14")
        -- print("setLowerRight-tab-false")
        hs.timer.doAfter(0.16, function()
            -- print("up right 15")
            -- print("setLowerRight-cmd-false")
            -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.cmd, false):post()
            hs.eventtap.event.newKeyEvent("ctrl", false):post()
            -- print("up right 16")
        end)
    end)
end)



--------------------- 类似 vi 的键盘设置 ---------------------

-- cd ~/.hammerspoon/ && wget https://raw.githubusercontent.com/hetima/hammerspoon-foundation_remapping/master/foundation_remapping.lua
-- init.lua
local FRemap = require('remapping.foundation_remapping')
local remapper = FRemap.new()
-- syntax
-- :remap(fromKey, toKey)
remapper:remap("capslock", "ctrl")  -- 这里把 capslock 映射为了 ctrl 键
remapper:remap("lcmd", "lshift")
remapper:remap("lshift", "lalt")
remapper:remap("lalt", "lcmd")
remapper:register()


hs.hotkey.bind({ "ctrl", "alt", "cmd", "shift" }, "u", function()
    remapper:unregister()
end)


-- 处理控制指令人物的回调
-- 这个 ... 是可变参数, 在此指的是 modifier 参数, 比如 "ctrl" / "shift" / "option" / "command"
function fn_cb_task(key, ...)
    hs.eventtap.keyStroke(... and {...} or {}, key, 0)
end

-- 处理特殊字符的回调
function fn_cb_char(key)
    hs.eventtap.keyStrokes(key)
end

-- 处理切换输入法
function fn_cb_switch_input_source(from_shift)
    -- 因为 `hs.eventtap.keyStroke({"ctrl", "shift", "cmd"}, "space")`切换输入法是有延时的, 所以这里提前自己算出来写一个输入法名字
    local curInputSource = "com.apple.keylayout.ABC"
    if (hs.keycodes.currentSourceID() == "com.apple.keylayout.ABC") then
        curInputSource = "com.sogou.inputmethod.sogou.pinyin"
    end
    if from_shift then
        -- 按 shift 的时候用 `hs.keycodes.currentSourceID(curInputSource)`经常输入法没有真正的切换, 不知道原因, 
        -- 所以改为快捷键触发
        hs.eventtap.keyStroke({"ctrl", "shift", "cmd"}, "space")
    else
        hs.keycodes.currentSourceID(curInputSource)
    end

    local app = hs.application.frontmostApplication()
    if app then
        local app_name = app:name()
        -- print("主动按键设置改变 curInputSource=" .. curInputSource .. ", appName是: " .. app_name)
        APP_NAME_2_LAST_INPUT_SOURCE[app_name] = curInputSource
    end
    return curInputSource
end

--------------------- 类似 vi 的键盘设置 1. 下面是控制指令 ---------------------

-- 上面已经把 capslock 映射为了 ctrl 键, 所以这里的 ctrl 其实就是 capslock
hs.hotkey.bind({"ctrl"}, "q", hs.fnutils.partial(fn_cb_task, "a", "cmd", "shift", "alt"))

hs.hotkey.bind({"ctrl"}, "g", hs.fnutils.partial(fn_cb_task, "z", "cmd", "shift"), nil , hs.fnutils.partial(fn_cb_task, "z", "cmd", "shift"))

hs.hotkey.bind({"ctrl"}, "b", hs.fnutils.partial(fn_cb_task, "/", "cmd"))

hs.hotkey.bind({"ctrl"}, "r", hs.fnutils.partial(fn_cb_task, "return"))

hs.hotkey.bind({"ctrl"}, "t", function()
    hs.eventtap.keyStroke({"ctrl"}, "a", 0)
    hs.eventtap.keyStroke({}, "tab", 0)
end)

-- hs.hotkey.bind({"alt", "shift"}, "s", function()
--     fn_cb_switch_input_source()
--     hs.eventtap.keyStroke({"alt"}, 'delete')  -- 模拟往左删除一个词

--     -- -- 注: 以下代码均不能很好的模拟单独触发shift或者ctrl
--     -- print("啊沙发上?")
--     -- hs.timer.doAfter(0.66, function()
--     --         -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, true):post()
--     --         -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, false):post()

--     --         print("啊沙发上?11")
--     --         hs.eventtap.event.newKeyEvent("ctrl", true):post()
--     --         hs.timer.doAfter(0.66, function()
--     --             print("啊沙发上?22")
--     --             hs.eventtap.event.newKeyEvent("ctrl", false):post()
--     --         end)
--     -- end)
-- end)

hs.hotkey.bind({"ctrl"}, "w", function()
    hs.eventtap.keyStroke({"alt"}, "left", 0)
    hs.eventtap.keyStroke({"alt", "shift"}, "right", 0)
end)

hs.hotkey.bind({"ctrl", "shift"}, "w", function()
    hs.eventtap.keyStroke({"ctrl"}, "a", 0)
    hs.eventtap.keyStroke({"ctrl", "shift"}, "e", 0)
end)

hs.hotkey.bind({"ctrl"}, "h", hs.fnutils.partial(fn_cb_task, "left"), nil , hs.fnutils.partial(fn_cb_task, "left"))
hs.hotkey.bind({"ctrl", "shift"}, "h",  hs.fnutils.partial(fn_cb_task, "left", "shift"), nil , hs.fnutils.partial(fn_cb_task, "left", "shift"))

hs.hotkey.bind({"ctrl"}, "j", hs.fnutils.partial(fn_cb_task, "down"), nil , hs.fnutils.partial(fn_cb_task, "down"))
hs.hotkey.bind({"ctrl", "shift"}, "j",  hs.fnutils.partial(fn_cb_task, "down", "shift"), nil , hs.fnutils.partial(fn_cb_task, "down", "shift"))

hs.hotkey.bind({"ctrl"}, "k", hs.fnutils.partial(fn_cb_task, "up"), nil , hs.fnutils.partial(fn_cb_task, "up"))
hs.hotkey.bind({"ctrl", "shift"}, "k",  hs.fnutils.partial(fn_cb_task, "up", "shift"), nil , hs.fnutils.partial(fn_cb_task, "up", "shift"))

hs.hotkey.bind({"ctrl"}, "l", hs.fnutils.partial(fn_cb_task, "right"), nil , hs.fnutils.partial(fn_cb_task, "right"))
hs.hotkey.bind({"ctrl", "shift"}, "l",  hs.fnutils.partial(fn_cb_task, "right", "shift"), nil , hs.fnutils.partial(fn_cb_task, "right", "shift"))

hs.hotkey.bind({"ctrl"}, "i", hs.fnutils.partial(fn_cb_task, "left", "alt"), nil , hs.fnutils.partial(fn_cb_task, "left", "alt"))
hs.hotkey.bind({"ctrl", "shift"}, "i",  hs.fnutils.partial(fn_cb_task, "left", "alt", "shift"), nil , hs.fnutils.partial(fn_cb_task, "left", "alt", "shift"))

hs.hotkey.bind({"ctrl"}, "o", hs.fnutils.partial(fn_cb_task, "right", "alt"), nil , hs.fnutils.partial(fn_cb_task, "right", "alt"))
hs.hotkey.bind({"ctrl", "shift"}, "o",  hs.fnutils.partial(fn_cb_task, "right", "alt", "shift"), nil , hs.fnutils.partial(fn_cb_task, "right", "alt", "shift"))

hs.hotkey.bind({"ctrl"}, ",", hs.fnutils.partial(fn_cb_task, "a", "ctrl"), nil , hs.fnutils.partial(fn_cb_task, "a", "ctrl"))
hs.hotkey.bind({"ctrl", "shift"}, ",", hs.fnutils.partial(fn_cb_task, "a", "ctrl", "shift"), nil , hs.fnutils.partial(fn_cb_task, "a", "ctrl", "shift"))

hs.hotkey.bind({"ctrl"}, ".", hs.fnutils.partial(fn_cb_task, "e", "ctrl"), nil , hs.fnutils.partial(fn_cb_task, "e", "ctrl"))
hs.hotkey.bind({"ctrl", "shift"}, ".",  hs.fnutils.partial(fn_cb_task, "e", "ctrl", "shift"), nil , hs.fnutils.partial(fn_cb_task, "e", "ctrl", "shift"))

hs.hotkey.bind({"ctrl"}, "d", hs.fnutils.partial(fn_cb_task, "forwarddelete"), nil , hs.fnutils.partial(fn_cb_task, "forwarddelete"))
hs.hotkey.bind({"ctrl", "shift"}, "d",  hs.fnutils.partial(fn_cb_task, "delete"), nil , hs.fnutils.partial(fn_cb_task, "delete"))

hs.hotkey.bind({"ctrl"}, "n", hs.fnutils.partial(fn_cb_task, "delete", "alt"), nil , hs.fnutils.partial(fn_cb_task, "delete", "alt"))

hs.hotkey.bind({"ctrl"}, "m", hs.fnutils.partial(fn_cb_task, "forwarddelete", "alt"), nil , hs.fnutils.partial(fn_cb_task, "forwarddelete", "alt"))

------------- 类似 vi 的键盘设置 2. 下面是特殊字符 ----------

hs.hotkey.bind({"ctrl"}, "p", hs.fnutils.partial(fn_cb_char, "&"), nil , hs.fnutils.partial(fn_cb_char, "&"))
hs.hotkey.bind({"ctrl", "shift"}, "p",  hs.fnutils.partial(fn_cb_char, "#"), nil , hs.fnutils.partial(fn_cb_char, "#"))

hs.hotkey.bind({"ctrl"}, "u", hs.fnutils.partial(fn_cb_char, "!"), nil , hs.fnutils.partial(fn_cb_char, "!"))
hs.hotkey.bind({"ctrl", "shift"}, "u",  hs.fnutils.partial(fn_cb_char, "@"), nil , hs.fnutils.partial(fn_cb_char, "@"))

hs.hotkey.bind({"ctrl"}, "y", hs.fnutils.partial(fn_cb_char, "*"), nil , hs.fnutils.partial(fn_cb_char, "*"))
hs.hotkey.bind({"ctrl", "shift"}, "y",  hs.fnutils.partial(fn_cb_char, "%"), nil , hs.fnutils.partial(fn_cb_char, "%"))

hs.hotkey.bind({"ctrl"}, ";", hs.fnutils.partial(fn_cb_char, "_"), nil , hs.fnutils.partial(fn_cb_char, "_"))
hs.hotkey.bind({"ctrl", "shift"}, ";",  hs.fnutils.partial(fn_cb_char, "-"), nil , hs.fnutils.partial(fn_cb_char, "-"))

hs.hotkey.bind({"ctrl"}, "'", hs.fnutils.partial(fn_cb_char, "="), nil , hs.fnutils.partial(fn_cb_char, "="))
hs.hotkey.bind({"ctrl", "shift"}, "'",  hs.fnutils.partial(fn_cb_char, "+"), nil , hs.fnutils.partial(fn_cb_char, "+"))

hs.hotkey.bind({"ctrl"}, "9", hs.fnutils.partial(fn_cb_char, "["), nil , hs.fnutils.partial(fn_cb_char, "["))
hs.hotkey.bind({"ctrl", "shift"}, "9",  hs.fnutils.partial(fn_cb_char, "{"), nil , hs.fnutils.partial(fn_cb_char, "{"))

hs.hotkey.bind({"ctrl"}, "0", hs.fnutils.partial(fn_cb_char, "]"), nil , hs.fnutils.partial(fn_cb_char, "]"))
hs.hotkey.bind({"ctrl", "shift"}, "0",  hs.fnutils.partial(fn_cb_char, "}"), nil , hs.fnutils.partial(fn_cb_char, "}"))

hs.hotkey.bind({"ctrl"}, "/", hs.fnutils.partial(fn_cb_char, "\\"), nil , hs.fnutils.partial(fn_cb_char, "\\"))
hs.hotkey.bind({"ctrl", "shift"}, "/",  hs.fnutils.partial(fn_cb_char, "|"), nil , hs.fnutils.partial(fn_cb_char, "|"))


--------------------- 双击修饰键的逻辑 (模拟切换输入法快捷键, 英文用自带的, 中文用搜狗, 缺点: 两个输入法之间切换得有点慢, 如果打字快的话会导致英文切中文的时候前几个字符打的是英文因为几毫秒之后才从英文切到中文输入法)---------------------

doubleHitMod = {}
doubleHitMod.lastHitTs = 0
doubleHitMod.lastInputSource = ""
doubleHitMod.flagsChangeCallbacks = {}

doubleHitMod.flagsChangeListener = hs.eventtap.new({
        hs.eventtap.event.types.flagsChanged,
        -- hs.eventtap.event.types.keyDown,
        -- hs.eventtap.event.types.keyUp
    },
    function(e)
        for i = 1, #doubleHitMod.flagsChangeCallbacks do
            doubleHitMod.flagsChangeCallbacks[i](e)
        end
    end):start()

-- double shift 逻辑
table.insert(doubleHitMod.flagsChangeCallbacks, function(event)
    local rawFlags = event:getRawEventData().CGEventData.flags & 0xdffffeff
    -- print(rawFlags)
    -- print(event:getKeyCode())
    local f = event:getFlags()
    -- 1048592 is right cmd
    -- 131076 is right shift
    -- if f.cmd and not (f.ctrl or f.alt or f.fn or f.shift) then
    if rawFlags == 131076 and not (f.ctrl or f.alt or f.fn or f.cmd) then
        -- print(999999)
        
        local now = hs.timer.secondsSinceEpoch()
        if now - doubleHitMod.lastHitTs < 0.6 then
            -- print(88888)
            -- 下面这些单独模拟 shift 的代码都是无效的, 特此注明
            -- The keycode of right shift is 60. 
            --             hs.osascript.applescript('tell application "System Events" to key code 60')
            --             hs.eventtap.event.newKeyEvent({}, " ", true):setKeyCode(60):post()
            -- hs.eventtap.event.newKeyEvent({}, " ", false):setKeyCode(60):post()

            -- hs.eventtap.event.newKeyEvent(hs.eventtap.event.modifierKeys.shift, true):post()
            -- hs.eventtap.event.newKeyEvent(hs.eventtap.event.modifierKeys.shift, false):post()
            -- 模拟shift, 因为已经按了两次shift了, 此时需要再模拟按一次shift才能让 搜狗输入法 真正的切中英文(已经证实无效)
            -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, true):post()
            -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, false):post()
            
            -- -- 模拟 cmd, 因为已经按了两次shift了, 此时需要模拟按一次 cmd 才能干扰让 搜狗输入法 对于第二次的 shift 以为是 shift+cmd, 从而第二次不切输入法了
            hs.eventtap.keyStroke({}, "cmd", 0) 

            hs.eventtap.keyStroke({"alt"}, 'delete')  -- 模拟往左删除一个词
        else
            -- 注: 这样会有点慢, 按了 shift 切换输入法之后瞬间立即打字的话, 可能打了几个英文字母才打出中文来
            -- hs.eventtap.keyStroke({"ctrl", "cmd", "shift"}, "space")  -- 模拟切换输入法快捷键, 英文用自带的, 中文用搜狗
            fn_cb_switch_input_source(true)
            -- doubleHitMod.lastInputSource = hs.keycodes.currentSourceID()
            -- if (doubleHitMod.lastInputSource == "com.apple.keylayout.ABC") then
            --     doubleHitMod.lastInputSource = "com.sogou.inputmethod.sogou.pinyin"
            -- else
            --     doubleHitMod.lastInputSource = "com.apple.keylayout.ABC"
            -- end
            -- 用这个方式有可能输入法没有真正的切换, 不知道原因
            -- hs.keycodes.currentSourceID(doubleHitMod.lastInputSource)
            -- local app = hs.application.frontmostApplication()
            -- if app then
            --     local app_name = app:name()
            --     print("主动按键设置改变 hs.keycodes.inputSourceChanged: doubleHitMod.lastInputSource= " .. doubleHitMod.lastInputSource .. ", hs.keycodes.currentSourceID()=" .. hs.keycodes.currentSourceID() .. ", appName是: " .. app_name)
            --     -- APP_NAME_2_LAST_INPUT_SOURCE[app_name] = doubleHitMod.lastInputSource
            --     APP_NAME_2_LAST_INPUT_SOURCE[app_name] = hs.keycodes.currentSourceID()
            -- end

            -- -- 以下代码专属于开启搜狗输入法的英文输入法模式
            -- hs.eventtap.keyStroke({"cmd", "shift"}, "e", 0)
            -- local app = hs.application.frontmostApplication()
            -- if app then
            --     local app_name = app:name()
            --     if CUR_INPUT_LANG == 1 then
            --         CUR_INPUT_LANG = 0
            --     else 
            --         CUR_INPUT_LANG = 1
            --     end
            --     print("主动按键设置改变 CUR_INPUT_LANG=" .. CUR_INPUT_LANG .. ", appName是: " .. app_name)
            --     APP_NAME_2_LAST_INPUT_LANG[app_name] = CUR_INPUT_LANG
            -- end
        end
        doubleHitMod.lastHitTs = now
    end
    -- print("---------***----")
end)




--------------------- 以下是废弃代码 ---------------------

-- gg = hs.eventtap.new({
--    hs.eventtap.event.types.flagsChanged,
--    hs.eventtap.event.types.keyDown,
--    hs.eventtap.event.types.keyUp
-- }, function(evt)
--     local modTable = hs.eventtap.checkKeyboardModifiers()
--     print("shift " .. tostring(modTable["shift"]))
--     print("capslo " .. tostring(modTable["capslock"]))
--     print("cmd " .. tostring(modTable["cmd"]))
--     print("alt " .. tostring(modTable["alt"]))
--     print("ctrl " .. tostring(modTable["ctrl"]))
--     print("fn " .. tostring(modTable["fn"]))
--     -- local rawFlags = evt:getRawEventData().CGEventData.flags & 0xdffffeff
--     -- print(rawFlags)
--     print(evt:getRawEventData().CGEventData.flags)
--     print(evt:getKeyCode())
--     print(evt:getUnicodeString())
--     local chars = evt:getCharacters()
--     print(tostring(chars))
--     if modTable["fn"] and chars == "h" then
--         if modTable["shift"] then
--             hs.eventtap.keyStroke({"shift"}, "Left")
--         else
--             hs.eventtap.keyStroke({}, "Left")
--         end
--     end
-- end):start()


-- -- Sends "escape" if "caps lock" is held for less than .2 seconds, and no other keys are pressed.
-- local send_escape = false
-- local last_mods = {}
-- local control_key_timer = hs.timer.delayed.new(0.2, function()
--     send_escape = false
-- end)
-- hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(evt)
--     local new_mods = evt:getFlags()
--     if last_mods["ctrl"] == new_mods["ctrl"] then
--         return false
--     end
--     if not last_mods["ctrl"] then
--         last_mods = new_mods
--         send_escape = true
--         control_key_timer:start()
--     else
--         if send_escape then
--             hs.eventtap.keyStroke({}, "escape")
--         end
--         last_mods = new_mods
--         control_key_timer:stop()
--     end
--     return false
-- end):start()
-- hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(evt)
--     send_escape = false
--     return false
-- end):start()


-- -- A global variable for the Hyper Mode
-- hyper = hs.hotkey.modal.new({}, nil) -- 这个方法有个问题就是 按caps+shift+h生效, 但是 shift+caps+h就不生效了, 跟按键顺序相关了, 所以弃用

-- -- Enter Hyper Mode when F19 (Hyper/Capslock) is pressed
-- function enterHyperMode()
--     -- hs.alert'Entered mode'
--     -- hyper.triggered = false
--     hyper:enter()
--    --  hs.alert.show('Hyper on')
-- end

-- -- Leave Hyper Mode when F19 (Hyper/Capslock) is pressed,
-- -- send ESCAPE if no other keys are pressed.
-- function exitHyperMode()
--     hyper:exit()
--     -- if not hyper.triggered then
--     --   hs.eventtap.keyStroke({}, 'ESCAPE')
--     -- end
--    --  hs.alert.show('Hyper off')
--     -- hs.alert'Entered mode22'
-- end

-- -- Bind the Hyper key
-- -- 上面已经把 capslock 映射为了 F19 键(全尺寸苹果键盘的一个键), 所以这里的 f19 其实就是 capslock
-- f19 = hs.hotkey.bind({}, 'f19', enterHyperMode, exitHyperMode)

-- -- Vim Colemak bindings (hzColemak)
-- -- Basic Movements {{{2

-- -- h - move left {{{3
-- function left()
--     local modTable = hs.eventtap.checkKeyboardModifiers()
--     print(modTable["shift"])
--     if modTable["shift"] then
--         hs.eventtap.keyStroke({"shift"}, "Left", 0)
--     else
--         hs.eventtap.keyStroke({}, "Left", 0)
--     end
-- end
-- hyper:bind({}, 'h', left, nil, left)
-- -- hyper:bind({}, 'h', left)

-- -- h - move left {{{3
-- -- function left() hs.eventtap.keyStroke({"shift"}, "Left", 0) end
-- -- hyper:bind({'shift'}, 'h', function()
-- --    hs.eventtap.keyStroke({"shift"}, "Left", 0)
-- -- end)
-- -- }}}3

-- -- n - move down {{{3
-- function down() hs.eventtap.keyStroke({}, "Down", 0) end
-- hyper:bind({}, 'j', down, nil, down)
-- -- }}}3

-- -- e - move up {{{3
-- function up() hs.eventtap.keyStroke({}, "Up", 0) end
-- hyper:bind({}, 'k', up, nil, up)
-- -- }}}3

-- -- i - move right {{{3
-- function right() hs.eventtap.keyStroke({}, "Right", 0) end
-- hyper:bind({}, 'l', right, nil, right)
-- -- }}}3

-- -- -- i - move right {{{3
-- -- function move_front() hs.eventtap.keyStroke({"ctrl"}, "a", 0) end
-- -- hyper:bind({}, 'comma', move_front)
-- -- -- }}}3

-- -- -- i - move right {{{3
-- -- function move_end() hs.eventtap.keyStroke({"ctrl"}, "e", 0) end
-- -- hyper:bind({}, 'period', move_end)
-- -- -- }}}3

-- -- -- ) - right programming brace {{{3
-- -- function rbroundL() hs.eventtap.keyStrokes("(") end
-- -- hyper:bind({}, 'k', rbroundL, nil, rbroundL)
-- -- -- }}}3

-- -- -- ) - left programming brace {{{3
-- -- function rbroundR() hs.eventtap.keyStrokes(")") end
-- -- hyper:bind({}, 'v', rbroundR, nil, rbroundR)
-- -- -- }}}3

-- -- -- o - open new line below cursor {{{3
-- -- hyper:bind({}, 'o', nil, function()
-- --     local app = hs.application.frontmostApplication()
-- --     if app:name() == "Finder" then
-- --         hs.eventtap.keyStroke({"cmd"}, "o", 0)
-- --     else
-- --         hs.eventtap.keyStroke({}, "Return", 0)
-- --     end
-- -- end)
-- -- -- }}}3

-- -- -- Extend+AltGr layer
-- -- -- Delete {{{3

-- -- -- cmd+h - delete character before the cursor {{{3
-- -- local function delete()
-- --     hs.eventtap.keyStroke({}, "delete", 0)
-- -- end
-- -- hyper:bind({"cmd"}, 'h', delete, nil, delete)
-- -- -- }}}3

-- -- -- cmd+i - delete character after the cursor {{{3
-- -- local function fndelete()
-- --     hs.eventtap.keyStroke({}, "Right", 0)
-- --     hs.eventtap.keyStroke({}, "delete", 0)
-- -- end
-- -- hyper:bind({"cmd"}, 'i', fndelete, nil, fndelete)
-- -- -- }}}3

-- -- ) - right programming brace {{{3
-- function rbcurlyL() hs.eventtap.keyStrokes("[") end
-- hyper:bind({}, '9', rbcurlyL, nil, rbcurlyL)
-- -- }}}3

-- -- ) - left programming brace {{{3
-- function rbcurlyR() hs.eventtap.keyStrokes("]") end
-- hyper:bind({}, '0', rbcurlyR, nil, rbcurlyR)
-- -- }}}3

-- -- Extend+Shift

-- -- ) - right programming brace {{{3
-- function rbsqrL() hs.eventtap.keyStrokes("{") end
-- hyper:bind({"shift"}, '9', rbsqrL, nil, rbsqrL)
-- -- }}}3

-- -- ) - left programming brace {{{3
-- function rbsqrR() hs.eventtap.keyStrokes("}") end
-- hyper:bind({"shift"}, '0', rbsqrR, nil, rbsqrR)
-- -- }}}3

-- -- -- Special Movements
-- -- -- w - move to next word {{{3
-- -- function word() hs.eventtap.keyStroke({"alt"}, "Right", 0) end
-- -- hyper:bind({}, 'w', word, nil, word)
-- -- -- }}}3

-- -- -- b - move to previous word {{{3
-- -- function back() hs.eventtap.keyStroke({"alt"}, "Left", 0) end
-- -- hyper:bind({}, 'b', back, nil, back)
-- -- -- }}}3
