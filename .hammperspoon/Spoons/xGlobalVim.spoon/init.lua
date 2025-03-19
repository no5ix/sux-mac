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
hs.hotkey.bind({"ctrl"}, "q", hs.fnutils.partial(fn_cb_task, "a", "cmd", "shift", "alt"))

hs.hotkey.bind({"ctrl"}, "g", hs.fnutils.partial(fn_cb_task, "z", "cmd", "shift"), nil , hs.fnutils.partial(fn_cb_task, "z", "cmd", "shift"))

hs.hotkey.bind({"ctrl"}, "b", hs.fnutils.partial(fn_cb_task, "/", "cmd"))

hs.hotkey.bind({"ctrl"}, "r", hs.fnutils.partial(fn_cb_task, "return"))
-- hs.hotkey.bind({"ctrl", "shift"}, "r", function()
--     hs.eventtap.keyStroke({""}, "up", 0)
--     hs.eventtap.keyStroke({"ctrl"}, "e", 0)
--     hs.eventtap.keyStroke({""}, "return", 0)
-- end)

hs.hotkey.bind({"ctrl"}, "t", function()
    hs.eventtap.keyStroke({"ctrl"}, "a", 0)
    hs.eventtap.keyStroke({}, "tab", 0)
end)

hs.hotkey.bind({"ctrl"}, "f", hs.fnutils.partial(fn_cb_task, "down"))
hs.hotkey.bind({"ctrl", "shift"}, "f", hs.fnutils.partial(fn_cb_task, "up"))

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

hs.hotkey.bind({"ctrl", "shift"}, "n", hs.fnutils.partial(fn_cb_task, "delete", "alt"), nil , hs.fnutils.partial(fn_cb_task, "delete", "alt"))

hs.hotkey.bind({"ctrl"}, "m", function()
    hs.eventtap.keyStroke({"ctrl"}, "e", 0)
    hs.eventtap.keyStroke({"shift"}, "up", 0)
    hs.eventtap.keyStroke({"ctrl", "shift"}, "e", 0)
    hs.eventtap.keyStroke({""}, "delete", 0)
end)
hs.hotkey.bind({"ctrl", "shift"}, "m", hs.fnutils.partial(fn_cb_task, "forwarddelete", "alt"), nil , hs.fnutils.partial(fn_cb_task, "forwarddelete", "alt"))

------------- 类似 vi 的键盘设置 2. 下面是特殊字符 ----------

-- hs.hotkey.bind({"ctrl"}, "p", hs.fnutils.partial(fn_cb_char, "&"), nil , hs.fnutils.partial(fn_cb_char, "&"))
hs.hotkey.bind({"ctrl", "shift"}, "p",  hs.fnutils.partial(fn_cb_char, "&"), nil , hs.fnutils.partial(fn_cb_char, "&"))

hs.hotkey.bind({"ctrl"}, "u", hs.fnutils.partial(fn_cb_char, "!"), nil , hs.fnutils.partial(fn_cb_char, "!"))
hs.hotkey.bind({"ctrl", "shift"}, "u",  hs.fnutils.partial(fn_cb_char, "~"), nil , hs.fnutils.partial(fn_cb_char, "~"))

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


return pkg