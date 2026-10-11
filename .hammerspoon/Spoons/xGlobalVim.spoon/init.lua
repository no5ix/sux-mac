local pkg = {}



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


--------------------- 类似 vi 的键盘设置 1. 下面是控制指令 ---------------------

-- 上面已经把 capslock 映射为了 ctrl 键, 所以这里的 ctrl 其实就是 capslock

-- screenshot
-- hs.hotkey.bind({"ctrl"}, "q", hs.fnutils.partial(fn_cb_task, "4", "cmd", "shift", "ctrl"))

-- faster version of the above
hs.hotkey.bind({"ctrl"}, "q", function()
    if captureTask and captureTask:isRunning() then
        hs.alert.show("Screenshot capture is already running")
        return
    end

    captureTask = hs.task.new("/usr/sbin/screencapture", function(exitCode)
        captureTask = nil
        if exitCode == 0 then
            -- hs.alert.show("Screenshot copied to clipboard")
        end -- Nonzero is often just the user cancelling the selection.
    end, {"-i", "-c", "-x"})

    if captureTask then captureTask:start()
    else hs.alert.show("Could not start screencapture") end
end)

hs.hotkey.bind({"ctrl", "shift"}, "q", hs.fnutils.partial(fn_cb_task, "4", "cmd", "shift"))

-- faster version of the above without popping up the screenshot thumbnail at the bottom right corner
-- hs.hotkey.bind({"ctrl", "shift"}, "q", function()
--     local outputPath = os.getenv("HOME") .. "/Desktop/screenshot.png"

--     local task = hs.task.new(
--         "/usr/sbin/screencapture",
--         function(exitCode, stdout, stderr)
--             print("Screenshot exit code:", exitCode)
--             if stderr and stderr ~= "" then
--                 print("Screenshot error:", stderr)
--             end
--         end,
--         {"-i", outputPath}
--     )

--     if task then
--         task:start()
--     else
--         hs.alert.show("Could not start screenshot")
--     end
-- end)


-- failed1
-- hs.hotkey.bind({"ctrl"}, "v", hs.fnutils.partial(fn_cb_task, "v", "alt", "cmd"))

-- failed2
-- hs.hotkey.bind({"ctrl"}, "v", function()
--     -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.alt, true):post()
--         hs.eventtap.event.newKeyEvent("alt", true):post()

--         hs.timer.doAfter(0.66, function()
--             print("啊沙发上?11")
--             hs.eventtap.event.newKeyEvent("cmd", true):post()

--             hs.timer.doAfter(0.66, function()
--                 hs.eventtap.keyStroke({}, "v", 0)
--                 hs.timer.doAfter(0.66, function()
--                     print("啊沙发上?22")
--                     hs.eventtap.event.newKeyEvent("cmd", false):post()
--                     hs.timer.doAfter(0.66, function()
--                         hs.eventtap.event.newKeyEvent("alt", false):post()
--                     -- hs.eventtap.event.newKeyEvent(hs.keycodes.map.alt, false):post()
--                     end)
--                 end)
--             end)
--         end)
-- end)


hs.hotkey.bind({"ctrl"}, "g", hs.fnutils.partial(fn_cb_task, "z", "cmd", "shift"))

-- failed3
-- hs.hotkey.bind({"ctrl", "shift"}, "g", hs.fnutils.partial(fn_cb_task, "g", "cmd", "shift"))

hs.hotkey.bind({"ctrl"}, "b", hs.fnutils.partial(fn_cb_task, "/", "cmd"))

hs.hotkey.bind({"ctrl"}, "r", hs.fnutils.partial(fn_cb_task, "return"))
hs.hotkey.bind({"ctrl", "shift"}, "r", function()
    -- hs.eventtap.keyStroke({""}, "up", 0)
    -- hs.eventtap.keyStroke({"ctrl"}, "e", 0)
    -- hs.eventtap.keyStroke({""}, "return", 0)
    hs.eventtap.keyStroke({"cmd"}, "delete", 0)
end)

hs.hotkey.bind({"ctrl"}, "t", function()
    hs.eventtap.keyStroke({"ctrl"}, "a", 0)
    hs.eventtap.keyStroke({}, "tab", 0)
end)

hs.hotkey.bind({"ctrl"}, "x", function()
    hs.eventtap.keyStroke({"ctrl"}, "a", 0)
    hs.timer.doAfter(0.06, function()
        hs.eventtap.keyStroke({"ctrl"}, "a", 0)
        hs.timer.doAfter(0.06, function()
            hs.eventtap.keyStroke({"shift"}, "down", 0)
            hs.timer.doAfter(0.06, function()
                hs.eventtap.keyStroke({}, "delete", 0)
            end)
        end)
    end)
end)

hs.hotkey.bind({"ctrl"}, "w", hs.fnutils.partial(fn_cb_task, "up"))
hs.hotkey.bind({"ctrl", "shift"}, "w", hs.fnutils.partial(fn_cb_task, "down"))

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

hs.hotkey.bind({"ctrl"}, "f", function()
    hs.eventtap.keyStroke({"cmd", "shift"}, "down", 0)
end)

hs.hotkey.bind({"ctrl", "shift"}, "f", function()
    -- hs.eventtap.keyStroke({"cmd"}, "a", 0)
    hs.eventtap.keyStroke({"cmd", "shift"}, "up", 0)
    -- hs.eventtap.keyStroke({"cmd"}, "v", 0)
    -- hs.eventtap.keyStroke({""}, "delete", 0)
end)

-- forward delete a word
hs.hotkey.bind({"ctrl", "shift"}, "n", hs.fnutils.partial(fn_cb_task, "delete", "alt"))

-- select current word
hs.hotkey.bind({"ctrl"}, "m", function()
    hs.eventtap.keyStroke({"alt"}, "left", 0)
    hs.eventtap.keyStroke({"alt", "shift"}, "right", 0)
    -- hs.eventtap.keyStroke({"ctrl"}, "e", 0)
    -- hs.eventtap.keyStroke({""}, "return", 0)

    -- hs.eventtap.keyStroke({"cmd", "shift"}, "down", 0)
    -- hs.eventtap.keyStroke({"shift"}, "down", 0)
    -- hs.eventtap.keyStroke({"ctrl", "shift"}, "e", 0)
    -- hs.eventtap.keyStroke({""}, "delete", 0)
end)

-- backward delete a word
hs.hotkey.bind({"ctrl", "shift"}, "m", hs.fnutils.partial(fn_cb_task, "forwarddelete", "alt"))

hs.hotkey.bind({"ctrl"}, "h", hs.fnutils.partial(fn_cb_task, "left"))
hs.hotkey.bind({"ctrl", "shift"}, "h",  hs.fnutils.partial(fn_cb_task, "left", "shift"))

hs.hotkey.bind({"ctrl"}, "j", hs.fnutils.partial(fn_cb_task, "down"))
hs.hotkey.bind({"ctrl", "shift"}, "j",  hs.fnutils.partial(fn_cb_task, "down", "shift"))

hs.hotkey.bind({"ctrl"}, "k", hs.fnutils.partial(fn_cb_task, "up"))
hs.hotkey.bind({"ctrl", "shift"}, "k",  hs.fnutils.partial(fn_cb_task, "up", "shift"))

hs.hotkey.bind({"ctrl"}, "l", hs.fnutils.partial(fn_cb_task, "right"))
hs.hotkey.bind({"ctrl", "shift"}, "l",  hs.fnutils.partial(fn_cb_task, "right", "shift"))

hs.hotkey.bind({"ctrl"}, "i", hs.fnutils.partial(fn_cb_task, "left", "alt"))
hs.hotkey.bind({"ctrl", "shift"}, "i",  hs.fnutils.partial(fn_cb_task, "left", "alt", "shift"))

hs.hotkey.bind({"ctrl"}, "o", hs.fnutils.partial(fn_cb_task, "right", "alt"))
hs.hotkey.bind({"ctrl", "shift"}, "o",  hs.fnutils.partial(fn_cb_task, "right", "alt", "shift"))

hs.hotkey.bind({"ctrl"}, ",", hs.fnutils.partial(fn_cb_task, "a", "ctrl"))
hs.hotkey.bind({"ctrl", "shift"}, ",", hs.fnutils.partial(fn_cb_task, "a", "ctrl", "shift"))

hs.hotkey.bind({"ctrl"}, ".", hs.fnutils.partial(fn_cb_task, "e", "ctrl"))
hs.hotkey.bind({"ctrl", "shift"}, ".",  hs.fnutils.partial(fn_cb_task, "e", "ctrl", "shift"))

hs.hotkey.bind({"ctrl"}, "d", hs.fnutils.partial(fn_cb_task, "forwarddelete"))
hs.hotkey.bind({"ctrl", "shift"}, "d",  hs.fnutils.partial(fn_cb_task, "delete"))


------------- 类似 vi 的键盘设置 2. 下面是特殊字符 ----------

-- hs.hotkey.bind({"ctrl"}, "p", hs.fnutils.partial(fn_cb_char, "&"), nil , hs.fnutils.partial(fn_cb_char, "&"))
hs.hotkey.bind({"ctrl", "shift"}, "p",  hs.fnutils.partial(fn_cb_char, "&"))

hs.hotkey.bind({"ctrl"}, "u", hs.fnutils.partial(fn_cb_char, "!"))
hs.hotkey.bind({"ctrl", "shift"}, "u",  hs.fnutils.partial(fn_cb_char, "~"))

hs.hotkey.bind({"ctrl"}, "y", hs.fnutils.partial(fn_cb_char, "*"))
hs.hotkey.bind({"ctrl", "shift"}, "y",  hs.fnutils.partial(fn_cb_char, "%"))

hs.hotkey.bind({"ctrl"}, ";", hs.fnutils.partial(fn_cb_char, "_"))
hs.hotkey.bind({"ctrl", "shift"}, ";",  hs.fnutils.partial(fn_cb_char, "-"))

hs.hotkey.bind({"ctrl"}, "'", hs.fnutils.partial(fn_cb_char, "="))
hs.hotkey.bind({"ctrl", "shift"}, "'",  hs.fnutils.partial(fn_cb_char, "+"))

hs.hotkey.bind({"ctrl"}, "9", hs.fnutils.partial(fn_cb_char, "["))
hs.hotkey.bind({"ctrl", "shift"}, "9",  hs.fnutils.partial(fn_cb_char, "{"))

hs.hotkey.bind({"ctrl"}, "0", hs.fnutils.partial(fn_cb_char, "]"))
hs.hotkey.bind({"ctrl", "shift"}, "0",  hs.fnutils.partial(fn_cb_char, "}"))

hs.hotkey.bind({"ctrl"}, "/", hs.fnutils.partial(fn_cb_char, "\\"))
hs.hotkey.bind({"ctrl", "shift"}, "/",  hs.fnutils.partial(fn_cb_char, "|"))


return pkg