
local application = require "hs.application"

local pkg = {}


--------------------- 当聚焦某些app时, 自动切换到上一次离开app时的输入法 & 科学上网 ---------------------

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

-- mac自带的英文输入法
local firstInputSource = "com.apple.keylayout.US"  -- for American Mac
if (hs.keycodes.layouts()[1] == "ABC") then
    firstInputSource = "com.apple.keylayout.ABC"  -- for Chinese Mac
end

-- 除了mac自带的英文输入法以外的另一个输入法( 搜狗 或者 mac自带的简体中文拼音输入法 )
local secondInputSource = "com.sogou.inputmethod.sogou.pinyin"
if (hs.keycodes.methods()[1] == "Pinyin - Simplified") then
    secondInputSource = "com.apple.inputmethod.SCIM.ITABC"
end

-- 处理切换输入法
function fn_cb_switch_input_source(from_shift)
    -- 因为 `hs.eventtap.keyStroke({"ctrl", "shift", "cmd"}, "space")`切换输入法是有延时的, 所以这里提前自己算出来写一个输入法名字
    local curInputSource = firstInputSource
    if (hs.keycodes.currentSourceID() == firstInputSource) then
        curInputSource = secondInputSource
    end
    if from_shift then
        -- 按 shift 的时候用 `hs.keycodes.currentSourceID(curInputSource)`经常输入法没有真正的切换, 不知道原因, 
        -- 所以改为快捷键触发
        hs.eventtap.keyStroke({"ctrl", "alt"}, "space")
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
    hs.keycodes.currentSourceID(secondInputSource)  -- 永远保证是搜狗输入法
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


--------------------- 双击修饰键的逻辑 (模拟切换输入法快捷键, 英文用自带的, 中文用搜狗, 缺点: 两个输入法之间切换得有点慢, 如果打字快的有可能会导致英文切中文的时候前几个字符打的是英文因为几毫秒之后才从英文切到中文输入法) ---------------------

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
            
            -- -- 如果只用搜狗输入法打中英文的话, 此处模拟 cmd, 是因为已经按了两次shift了, 此时需要模拟按一次 cmd 才能干扰让 搜狗输入法 对于第二次的 shift 以为是 shift+cmd, 从而第二次不切输入法了
            -- hs.eventtap.keyStroke({}, "cmd", 0) 

            hs.eventtap.keyStroke({"alt"}, 'delete')  -- 模拟往左删除一个词
        else
            -- 注: 这样会有点慢, 按了 shift 切换输入法之后瞬间立即打字的话, 可能打了几个英文字母才打出中文来
            -- hs.eventtap.keyStroke({"ctrl", "cmd", "shift"}, "space")  -- 模拟切换输入法快捷键, 英文用自带的, 中文用搜狗
            fn_cb_switch_input_source(true)
            -- doubleHitMod.lastInputSource = hs.keycodes.currentSourceID()
            -- if (doubleHitMod.lastInputSource == firstInputSource) then
            --     doubleHitMod.lastInputSource = secondInputSource
            -- else
            --     doubleHitMod.lastInputSource = firstInputSource
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




CUR_INPUT_LANG = 0  -- 0 for chinese, 1 for english
APP_NAME_2_LAST_INPUT_LANG = {}

APP_NAME_2_LAST_INPUT_SOURCE = {
    ["Terminal"] = firstInputSource,
    ["Code"] = firstInputSource,  -- vs code
    ["WebStorm"] = firstInputSource,
    ["PyCharm"] = firstInputSource,
    ["Clion"] = firstInputSource,
    ["IntelliJ IDEA"] = firstInputSource,
    ["IntelliJ IDEA CE"] = firstInputSource,
    ["Rider"] = firstInputSource,
    ["网易有道翻译"] = firstInputSource,
    ["Messages"] = firstInputSource,
    
    ["TencentDocs"] = secondInputSource,
    ["腾讯文档"] = secondInputSource,
    ["WeChat"] = secondInputSource,
    ["微信"] = secondInputSource,
    ["WPS Office"] = secondInputSource,
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


function applicationWatcher(appName, eventType, appObject)
    -- print(appName)
    -- print(eventType)
    -- print("mmms")
    if (eventType == application.watcher.activated or eventType == application.watcher.launched) then
        if (eventType == application.watcher.launched) then
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
        end

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
            -- local tempMap = {
            --     [firstInputSource] = "English",
            --     [secondInputSource] = "Chinese",
            -- }
            -- local style =
            -- {
            --     fillColor = {red=0, green=0.5, blue=1, alpha=0.2}, -- 蓝色背景
            --     strokeColor = {red=1, green=1, blue=1, alpha=1}, -- 白色边框
            --     strokeWidth = 2, -- 边框宽度
            --     textColor = {red=1, green=1, blue=1, alpha=1}, -- 白色文字
            --     -- textSize = 60, -- 文字大小
            --     atScreenEdge = 2, -- - 0: screen center (default); 1: top edge; 2: bottom edge .
            --     -- radius = 10 -- 圆角
            -- }
            -- local tipsStr = tempMap[new_input_source]
            -- hs.alert.show(tipsStr, style, 1)
            -- hs.timer.doAfter(0.6, function()  -- Sometimes it will show only on the screen where the previous app you clicked, because switching to another app needs a moment. 
            --     style.fillColor = { red = 1, green = 0.5, blue = 0, alpha = 0.2} -- 橙色
            --     -- style.atScreenEdge = 0
            --     hs.alert.show(tipsStr, style, 1)
            --     hs.timer.doAfter(0.6, function()
            --         style.fillColor = {red=0.5, green=0, blue=0.5, alpha=0.2} -- 紫色背景
            --         hs.alert.show(tipsStr, style, 1) -- 显示 1.0 秒
            --         hs.timer.doAfter(0.6, function()
            --             -- style.atScreenEdge = 2
            --             style.fillColor = { red = 1, green = 0.5, blue = 0, alpha = 0.2} -- 橙色
            --             hs.alert.show(tipsStr, style, 1) -- 显示 1.0 秒
            --         end)
            --     end)
            -- end)
        end)
    end
end

appWatcher = application.watcher.new(applicationWatcher)
appWatcher:start()


return pkg