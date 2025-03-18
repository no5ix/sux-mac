


------------------------ Trackpad gestures: ------------------------
-- - clockwise rotation: close current window 
-- - counter-clockwise rotation: quit current App
-- - double tap with 2 fingers: middle click

local lastRotateGestureEvents = {}

gestureWatcher = hs.eventtap.new({hs.eventtap.event.types.gesture}, function(event)
    local gestureType = event:getType(true)
    if gestureType == hs.eventtap.event.types.gesture then
        -- print("-- they are touching the trackpad, but it's not for a gesture")
        return false
    end

    -- if gestureType == hs.eventtap.event.types.gesture then
    --     print("-- they are touching the trackpad, but it's not for a gesture")
    -- elseif gestureType == hs.eventtap.event.types.magnify then
    --     print("-- they're preforming a magnify gesture")
    
    if gestureType == hs.eventtap.event.types.smartMagnify then
        -- print("-- they're preforming a smartMagnify gesture")
        local mousePos = hs.mouse.absolutePosition()
        hs.eventtap.middleClick(mousePos)
        -- -- minimize
        -- local win = hs.window.focusedWindow()
        -- if win then
        --     win:minimize()
        -- end
        return true
    elseif gestureType == hs.eventtap.event.types.rotate then
        -- print("-- they're preforming a rotate gesture")
        local res = event:getTouchDetails()
        -- for k, v in pairs(res) do
        --     print("k=" .. k)
        --     print("v=" .. v)
        -- end
        local rotation = res["rotation"]
        if rotation then
            local now = hs.timer.secondsSinceEpoch()
            -- 记录最近的滚动事件
            table.insert(lastRotateGestureEvents, {rot = rotation, time = now})
            -- 仅保留最近 xs 秒内的事件，防止因滑动速度问题导致检测失败
            local xs = 1
            while #lastRotateGestureEvents > 0 and now - lastRotateGestureEvents[1].time > xs do
                table.remove(lastRotateGestureEvents, 1)
            end
            -- print("sum=" .. tostring(#lastRotateGestureEvents))
            -- hs.alert.show("sum=" .. tostring(#lastRotateGestureEvents), 1.8);
            local rotationDegreesSum = 0
            for _, v in ipairs(lastRotateGestureEvents) do
                rotationDegreesSum = v.rot + rotationDegreesSum
            end
            -- print("rotationDegreesSum=" .. tostring(rotationDegreesSum))
            if rotationDegreesSum > 50 then  -- counter-clockwise rotation
                hs.eventtap.keyStroke({"cmd"}, "q")
                lastRotateGestureEvents = {} -- 清空缓存，等待下次手势
            elseif rotationDegreesSum < -50 then  -- Clockwise rotation
                local win = hs.window.focusedWindow()
                if win then
                    win:close()
                end
                lastRotateGestureEvents = {} -- 清空缓存，等待下次手势
            end
        end
        return true
    end
end)

gestureWatcher:start()



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






--------------------- 触发角自定义 ---------------------

-- -- Toggle application focus
-- function toggle_application(_app)
--     -- finds a running applications
--     local app = application.find(_app)
--     if not app then
--         -- print("111 taa")
--         -- application not running, launch app
--         application.launchOrFocus(_app)
--         return
--     end
--     -- application running, toggle hide/unhide
--     local mainwin = app:mainWindow()
--     if mainwin then
--         -- print("3333 taa")
--         if true == app:isFrontmost() then
--             -- print("4444 taa")
--             mainwin:application():hide()
--         else
--             -- print("5555 taa")
--             mainwin:application():activate(true)
--             mainwin:application():unhide()
--             mainwin:focus()
--         end
--     else
--         -- no windows, maybe hide
--         if true == app:hide() then
--             -- print("6666 taa")
--             -- focus app
--             application.launchOrFocus(_app)
--         else
--             -- print("7777 taa")
--             -- nothing to do
--         end
--         -- print("8888 taa")
--         -- application.launchOrFocus(_app)
--     end
-- end

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


hs.loadSpoon("xGlobalVim")
hs.loadSpoon("xAppTriggers")
hs.loadSpoon("xClipboardHistory")


hs.loadSpoon("xHotCornersAndEdges")
--spoon.xHotCornersAndEdges.delta = 20 -- 触发角处的正方形边长(单位像素)
spoon.xHotCornersAndEdges:start()

-- 触发快捷键 ctrl+shift+tab: 前一个APP
spoon.xHotCornersAndEdges:setLowerLeft(function()
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
spoon.xHotCornersAndEdges:setUpperLeft(function()
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
spoon.xHotCornersAndEdges:setLowerRight(function()
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
spoon.xHotCornersAndEdges:setUpperRight(function()
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
