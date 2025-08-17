local application = require "hs.application"


local pkg = {}

-- Error messages
local functionOrNil = "Callback has to be a function or nil."
local numberOrNil = "Delay has to be nil or a number >= 0."

-- Properties
pkg.cornerDelta = 18 -- Delta is in pixels, area to be considered as a corner
pkg.edgeDeltaLong = 88 -- Delta is in pixels, area to be considered as a edge
pkg.edgeDeltaShort = 8 -- Delta is in pixels, area to be considered as a edge
pkg.hotEdgeDoubleHitInterval = 1388 -- ms, 毫秒内连续触碰到屏幕边缘两次视为双击热边缘, 因为hs本身的原因这个值应该不能小于1300
pkg.isStageManagerEnabled = true  -- please turn it on when u enable stage manager, it will leave some space on the left area of the screen

-- Local variables
local curTs = 0  -- ms
local lastMouseClickTs = 0  -- ms
local lastHitEdgeTs = 0  -- ms
local lastHitEdgeType = 0 -- 0 是重置, 1 是左上, 2 是左下, 逆时针一直到 上左(8)
local revisedPos = {}  -- 被局限在当前显示器内的修正了的mouse pos
local p = hs.mouse.absolutePosition()  -- mouse pos
local lastMouseX = p.x
local lastMouseY = p.y
local sFrameList = {}  -- 所有显示器的原点位置xy 和 宽w 和 高h
local mouseMoveWatcher
local screenWatcher
local mouseLeftClickWatcher
local mouseRightClickWatcher
local mouseMiddleClickWatcher
local gestureWatcher
local lastRotateGestureEvents = {}


-- Local booleans
local middle = true  -- 说明鼠标不在触发角的位置
local middleForDoubleHotEdge = true  -- 说明鼠标不在触发边的位置

-- Corners
local ul, ll, ur, lr


--------------------- 流畅的窗口管理(有窗口移动动画) ---------------------

-- Defines for window maximize toggler
local frameCache = {}
local logger = hs.logger.new("windows")

-- Resize current window

function winresize(how)
    local win = hs.window.focusedWindow()
	if not win then
		return
	end
	
    --local app = win:application():name()
    --local windowLayout
    local newrect

    if how == "left" then
		if pkg.isStageManagerEnabled then
			newrect = { 1 / 27, 0, 13 / 27, 1 }  -- 这个13 / 27是窗口的宽度, 1/27是横向的起始坐标
		else
        	newrect = hs.layout.left50
			-- hs.eventtap.keyStroke({"fn", "ctrl"}, "left", 0)  -- 不能用这个, 实测fn在hs其实并不能当做modifier, 虽然他的doc说可以
		end
    elseif how == "right" then
		if pkg.isStageManagerEnabled then
			newrect = { 14 / 27, 0, 13 / 27, 1 }
		else
			newrect = hs.layout.right50
		end
    elseif how == "up" then
        newrect = { 0, 0, 1, 0.5 }
    elseif how == "down" then
        newrect = { 0, 0.5, 1, 0.5 }
    elseif how == "max" then
		if pkg.isStageManagerEnabled then
			newrect = { 1 / 27, 0, 26 / 27, 1 }
		else
			newrect = hs.layout.maximized
		end
    elseif how == "left_third" or how == "hthird-0" then
        newrect = { 0, 0, 1 / 3, 1 }
    elseif how == "middle_third_h" or how == "hthird-1" then
        newrect = { 1 / 3, 0, 1 / 3, 1 }
    elseif how == "right_third" or how == "hthird-2" then
        newrect = { 2 / 3, 0, 1 / 3, 1 }
    elseif how == "top_third" or how == "vthird-0" then
        newrect = { 0, 0, 1, 1 / 3 }
    elseif how == "middle_third_v" or how == "vthird-1" then
        newrect = { 0, 1 / 3, 1, 1 / 3 }
    elseif how == "bottom_third" or how == "vthird-2" then
        newrect = { 0, 2 / 3, 1, 1 / 3 }
    elseif how == "stage_manager_left" then
        newrect = { 1 / 27, 0, 13 / 27, 1 }  -- 这个13 / 27是窗口的宽度, 1/27是横向的起始坐标
    elseif how == "stage_manager_right" then
        newrect = { 14 / 27, 0, 13 / 27, 1 }
    elseif how == "stage_manager_max" then
        newrect = { 1 / 27, 0, 26 / 27, 1 }
    end

    win:move(newrect)
end

function winmovescreen(how)
    local win = hs.window.focusedWindow()
    if how == "left" then
        win:moveOneScreenWest()
    elseif how == "right" then
        win:moveOneScreenEast()
    end
end

-- Toggle a window between its normal size, and being maximized
function toggle_window_maximized()
    local win = hs.window.focusedWindow()
    if frameCache[win:id()] then
        win:setFrame(frameCache[win:id()])
        frameCache[win:id()] = nil
    else
        frameCache[win:id()] = win:frame()
        win:maximize()
    end
end

-- Move between thirds of the screen
function get_horizontal_third(win)
    local frame = win:frame()
    local screenframe = win:screen():frame()
    local relframe = hs.geometry(frame.x - screenframe.x, frame.y - screenframe.y, frame.w, frame.h)
    local third = math.floor(3.01 * relframe.x / screenframe.w)
    logger.df("Screen frame: %s", screenframe)
    logger.df("Window frame: %s, relframe %s is in horizontal third #%d", frame, relframe, third)
    return third
end

function get_vertical_third(win)
    local frame = win:frame()
    local screenframe = win:screen():frame()
    local relframe = hs.geometry(frame.x - screenframe.x, frame.y - screenframe.y, frame.w, frame.h)
    local third = math.floor(3.01 * relframe.y / screenframe.h)
    logger.df("Screen frame: %s", screenframe)
    logger.df("Window frame: %s, relframe %s is in vertical third #%d", frame, relframe, third)
    return third
end

function left_third()
    local win = hs.window.focusedWindow()
    local third = get_horizontal_third(win)
    if third == 0 then
        winresize("hthird-0")
    else
        winresize("hthird-" .. (third - 1))
    end
end

function right_third()
    local win = hs.window.focusedWindow()
    local third = get_horizontal_third(win)
    if third == 2 then
        winresize("hthird-2")
    else
        winresize("hthird-" .. (third + 1))
    end
end

function up_third()
    local win = hs.window.focusedWindow()
    local third = get_vertical_third(win)
    if third == 0 then
        winresize("vthird-0")
    else
        winresize("vthird-" .. (third - 1))
    end
end

function down_third()
    local win = hs.window.focusedWindow()
    local third = get_vertical_third(win)
    if third == 2 then
        winresize("vthird-2")
    else
        winresize("vthird-" .. (third + 1))
    end
end

function center()
    local win = hs.window.focusedWindow()
    win:centerOnScreen()
end

---- Halves of the screen
--hs.hotkey.bind({ "ctrl", "alt", "cmd", "shift" }, "left", hs.fnutils.partial(winresize, "left"))
--hs.hotkey.bind({ "ctrl", "alt", "cmd", "shift" }, "right", hs.fnutils.partial(winresize, "right"))
---- Maximized
hs.hotkey.bind({ "ctrl", "alt", "cmd", "shift" }, "up", hs.fnutils.partial(winresize, "max"))
-- hs.hotkey.bind({ "ctrl", "alt", "cmd", "shift" }, "up", hs.fnutils.partial(winresize, "stage_manager_max"))


----------------------------------------------------------------

function getMilliseconds()
  local seconds = os.time()
  local fraction = os.clock()
  return seconds * 1000 + math.floor(fraction * 1000)
end

function newCorner()
	local corner =  {
		cb = nil,
	}
	return corner
end

function trigger(corner)
	if not corner.cb then
		print("Err: no corner.cb!!")
		return
	end
	corner.cb()
end

---@(本函数很耗费性能, 不要用于 tick 之类的逻辑, 不然有很高的延迟)判断鼠标是否在某个正在聚焦的窗口所在的显示器上
---@return boolean
function isMouseInsideFocusedWindowScreen()
	-- 获取当前正在聚焦的窗口对象
	local focusedWindow = hs.window.focusedWindow()
	if focusedWindow then
		-- 获取当前鼠标所在的屏幕对象
		local mouseScreen = hs.mouse.getCurrentScreen()
		if mouseScreen == focusedWindow:screen() then
			-- print("Window is on the same screen as the mouse.")
			return true
		end
	end
    -- print("Window is not on the same screen as the mouse.")
	return false
end

---@制作本函数的原因: 因为直接当出发单击 hot edge 来 application.launchOrFocus的时候, 可能跳转到新 app 了然后又被单击当前 app 跳回来了
---@param appName string
function TimerLaunchOrFocusApp(appName)
	hs.timer.doAfter(0.08, function()
        application.launchOrFocus(appName)
	end )
end


EDITOR_BROWSER_APPS = {
    ["Code"] = true,  -- vscode
    ["WebStorm"] = true,
    ["PyCharm"] = true,
    ["Clion"] = true,
    ["IntelliJ IDEA"] = true,
    ["IntelliJ IDEA CE"] = true,
    ["Rider"] = true,
    ["Safari"] = true,
    ["Safari浏览器"] = true,
    ["Microsoft Edge"] = true,
    ["Google Chrome"] = true,
}

EDITOR_APPS = {
    ["Code"] = true,  -- vscode
    ["WebStorm"] = true,
    ["PyCharm"] = true,
    ["Clion"] = true,
    ["IntelliJ IDEA"] = true,
    ["IntelliJ IDEA CE"] = true,
    ["Rider"] = true,
}

function handleGestureAndMouseClickOnEdge(event, gestureOrMouseClick)
	local gestureType = event:getType(true)
	local rotationDegreesSum = 0

	if gestureOrMouseClick == "trackPadGesture" then
		if gestureType == hs.eventtap.event.types.gesture then
			-- print("-- they are touching the trackpad, but it's not for a gesture")
			return false
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
				for _, v in ipairs(lastRotateGestureEvents) do
					rotationDegreesSum = v.rot + rotationDegreesSum
				end

				if rotationDegreesSum <= 38 and rotationDegreesSum >= -38 then
					return true
				else
					lastRotateGestureEvents = {} -- 清空缓存，等待下次手势
				end
			end
		end
	end

	--print("handleGestureAndMouseClickOnEdge", gestureOrMouseClick)
    local flags = event:getFlags()
	-- 记录点击位置
    p = event:location()

	--p = hs.mouse.absolutePosition()
    local curFrame
    for _, _frame in pairs(sFrameList) do
        if p.x >= _frame.x and p.x < (_frame.x + _frame.w) and p.y >= _frame.y and p.y < (_frame.y + _frame.h) then  -- Inside the main screen ?
            revisedPos.x = p.x - _frame.x
            revisedPos.y = p.y - _frame.y
            curFrame = _frame
            break
        end
    end
	if not curFrame then
		--print("no frame")
		return false
	end
	--print("checking edge, " .. gestureOrMouseClick .. ", " .. revisedPos.x .. ", " .. curFrame.w)
	-- Check edge
	if revisedPos.x <= pkg.edgeDeltaShort and revisedPos.y <= (curFrame.h / 2) then  -- 左上
		if gestureOrMouseClick == 'leftMouse' then
		elseif gestureOrMouseClick == 'rightMouse' then
			--print("ul.cb()")
			--ul.cb()
			--print("launchOrFocus NetEaseMusic)")
			--TimerLaunchOrFocusApp("NetEaseMusic")
		elseif gestureOrMouseClick == 'trackPadGesture' then
			if gestureType == hs.eventtap.event.types.smartMagnify then
				-- local app = hs.application.frontmostApplication()
				-- if EDITOR_BROWSER_APPS[app:name()] then
				-- 	hs.eventtap.keyStroke({"cmd"}, "[")
				-- end
			elseif gestureType == hs.eventtap.event.types.rotate then
			end
		end
	elseif revisedPos.x >= (curFrame.w - pkg.edgeDeltaShort) and revisedPos.y <= (curFrame.h / 2) then  -- 右上
		if gestureOrMouseClick == 'leftMouse' then

		elseif gestureOrMouseClick == 'rightMouse' then
			--print("ur.cb()")
			--ur.cb()
			--print("launchOrFocus WeChat")
			--TimerLaunchOrFocusApp("WeChat")
		elseif gestureOrMouseClick == 'middleMouse' then
			--print("cmd up handleGestureAndMouseClickOnEdge")
			--hs.eventtap.event.newKeyEvent({"cmd"}, "up", true):post()
			--hs.eventtap.event.newKeyEvent({"cmd"}, "up", false):post()
		elseif gestureOrMouseClick == 'trackPadGesture' then
			if gestureType == hs.eventtap.event.types.smartMagnify then
				-- local app = hs.application.frontmostApplication()
				-- if EDITOR_BROWSER_APPS[app:name()] then
				-- 	hs.eventtap.keyStroke({"cmd"}, "]")
				-- end
			elseif gestureType == hs.eventtap.event.types.rotate then
			end
		end
	elseif revisedPos.x <= pkg.edgeDeltaShort and revisedPos.y > (curFrame.h / 2) then  -- 左下
		if gestureOrMouseClick == 'leftMouse' then
			--print("ul.cb()")
			--ul.cb()
		elseif gestureOrMouseClick == 'rightMouse' then
		elseif gestureOrMouseClick == 'trackPadGesture' then
			if gestureType == hs.eventtap.event.types.smartMagnify then
				-- local app = hs.application.frontmostApplication()
				-- if EDITOR_BROWSER_APPS[app:name()] then
				-- 	hs.eventtap.keyStroke({"cmd"}, "]")
				-- end
			elseif gestureType == hs.eventtap.event.types.rotate then
			end
		end
	elseif revisedPos.x >= (curFrame.w - pkg.edgeDeltaShort) and revisedPos.y > (curFrame.h / 2) then  -- 右下
		if gestureOrMouseClick == 'leftMouse' then
			--print("ur.cb()")
			--ur.cb()
		elseif gestureOrMouseClick == 'rightMouse' then
		elseif gestureOrMouseClick == 'middleMouse' then
			--print("cmd down handleGestureAndMouseClickOnEdge")
			--hs.eventtap.event.newKeyEvent({"cmd"}, "down", true):post()
			--hs.eventtap.event.newKeyEvent({"cmd"}, "down", false):post()
		elseif gestureOrMouseClick == 'trackPadGesture' then
			if gestureType == hs.eventtap.event.types.smartMagnify then
				-- local app = hs.application.frontmostApplication()
				-- if EDITOR_BROWSER_APPS[app:name()] then
				-- 	hs.eventtap.keyStroke({"cmd"}, "[")
				-- end
			elseif gestureType == hs.eventtap.event.types.rotate then
			end
		end
	elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x < (curFrame.w / 2) and revisedPos.x > pkg.edgeDeltaLong then  -- 上左
		if gestureOrMouseClick == 'leftMouse' then
			--print("ul.cb()")
			--ul.cb()
			-- hs.timer.doAfter(8, function()
				-- local res = hs.wifi.associate("ARRIS-A305", "332444301449")
				-- print("baxian")
				-- print(res)
				-- hs.wifi.setPower(true)
			-- end)
		elseif gestureOrMouseClick == 'rightMouse' then
			-- print("c s t down handleGestureAndMouseClickOnEdge")
			-- hs.eventtap.keyStroke({"ctrl", "shift"}, "tab", 0)
			-- -- 模拟释放 Ctrl+Shift 键
			-- hs.eventtap.keyStroke({}, "ctrl", 0)
			-- hs.eventtap.keyStroke({}, "shift", 0)
			-- print("cmd[")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", false):post()
		elseif gestureOrMouseClick == 'middleMouse' then
		end
	elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x >= (curFrame.w / 2) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 上右
		if gestureOrMouseClick == 'leftMouse' then
			-- print("ur.cb()")
			--ur.cb()
			-- print(hs.wifi.currentNetwork())
			-- for key, value in pairs(hs.wifi.availableNetworks()) do
			-- 	print(key, value)
			-- end
			-- hs.wifi.disassociate()
			-- hs.wifi.setPower(false)
		elseif gestureOrMouseClick == 'rightMouse' then
			-- print("cmd]")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", false):post()
		end
	elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x < (curFrame.w / 2) and revisedPos.x > pkg.edgeDeltaLong then  -- 下左
		if gestureOrMouseClick == 'leftMouse' then
			--print("launchOrFocus NetEaseMusic)")
			--TimerLaunchOrFocusApp("NetEaseMusic")
		elseif gestureOrMouseClick == 'rightMouse' then
			-- print("cmd[")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", false):post()
			--winresize("left")
		elseif gestureOrMouseClick == 'trackPadGesture' then
			if gestureType == hs.eventtap.event.types.smartMagnify then
				local win = hs.window.focusedWindow()
				if win ~= nil then
					win:moveToScreen(hs.mouse.getCurrentScreen())
					hs.timer.doAfter(0.6, function()  -- 这个timer不可少, 不然经常窗口还没出来就执行了 winresize
						winresize("max")
					end)
				end
				return true
			elseif gestureType == hs.eventtap.event.types.rotate then
				if rotationDegreesSum > 38 then  -- counter-clockwise rotation
				elseif rotationDegreesSum < -38 then  -- Clockwise rotation
					local win = hs.window.focusedWindow()
					if win then
						win:close()
					end
				end
				return true
			end
		end
	elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x >= (curFrame.w / 2) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 下右
		if gestureOrMouseClick == 'leftMouse' then
			--print("launchOrFocus WeChat")
			--TimerLaunchOrFocusApp("WeChat")
		elseif gestureOrMouseClick == 'rightMouse' then
			-- print("cmd]")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", false):post()
			--winresize("right")
		elseif gestureOrMouseClick == 'trackPadGesture' then
			if gestureType == hs.eventtap.event.types.smartMagnify then
				local win = hs.window.focusedWindow()
				if win ~= nil then
					win:moveToScreen(hs.mouse.getCurrentScreen())
					hs.timer.doAfter(0.6, function()  -- 这个timer不可少, 不然经常窗口还没出来就执行了 winresize
						winresize("max")
					end)
				end
				return true
			elseif gestureType == hs.eventtap.event.types.rotate then
				if rotationDegreesSum > 38 then  -- counter-clockwise rotation
				elseif rotationDegreesSum < -38 then  -- Clockwise rotation
					local win = hs.window.focusedWindow()
					if win then
						win:close()
					end
				end
				return true
			end
		end
	else
		------------------------ Trackpad gestures: ------------------------
		-- - clockwise rotation: close current window 
		-- - counter-clockwise rotation: quit current App
		-- - double tap with 2 fingers: middle click
		if gestureOrMouseClick == "trackPadGesture" then
			if gestureType == hs.eventtap.event.types.smartMagnify then
				-- print("-- they're preforming a smartMagnify gesture")
				local app = hs.application.frontmostApplication()
				local mousePos = hs.mouse.absolutePosition()
				if EDITOR_APPS[app:name()] then
					hs.eventtap.leftClick(mousePos)
					hs.eventtap.keyStroke({}, "F12")
				else
					hs.eventtap.middleClick(mousePos)
				end
				
				-- -- minimize
				-- local win = hs.window.focusedWindow()
				-- if win then
				--     win:minimize()
				-- end
				return true
			elseif gestureType == hs.eventtap.event.types.rotate then
				-- print("rotationDegreesSum=" .. tostring(rotationDegreesSum))
				if rotationDegreesSum > 38 then  -- counter-clockwise rotation
					hs.eventtap.keyStroke({"cmd"}, "q")
				elseif rotationDegreesSum < -38 then  -- Clockwise rotation
					local app = hs.application.frontmostApplication()
				    if EDITOR_BROWSER_APPS[app:name()] then
						hs.eventtap.keyStroke({"cmd"}, "w")
					else
						local win = hs.window.focusedWindow()
						if win then
							win:close()
						end
					end
				end
				return true
			end
		end
	end

    if flags['cmd'] then
        -- 处理 Cmd + 鼠标单击事件
    else
        -- 处理普通鼠标单击事件
    end

	-- -- -- 处理当多窗口时候点击, 点击则聚焦并且实施真实的点击行为, 双击的第2击不处理
	-- -- 直接点击与鼠标指针下方的窗口进行交互（现在，在你能够与之交互之前，无需先点击其他窗口来“激活”它）。 
	-- if gestureOrMouseClick == 'leftMouse' and getMilliseconds() - lastMouseClickTs < 600 then
	-- 	local focusedWin = hs.window.frontmostWindow()         -- 当前前置窗口
	-- 	local mousePos = hs.mouse.absolutePosition()

	-- 	local clickedWin = nil
	-- 	-- 遍历所有可见窗口，从前到后（前面的窗口更可能是鼠标下的）, 获取鼠标所在窗口
    --     local orderedWindows = hs.window.orderedWindows()
    --     for _, win in ipairs(orderedWindows) do
    --         if win:isStandard() and hs.geometry(mousePos):inside(win:frame()) then
	-- 			clickedWin = win
    --             break
    --         end
    --     end
	-- 	-- if clickedWin then
	-- 	-- 	print("click1: " .. clickedWin:title())
	-- 	-- else
	-- 	-- 	print("click1: " .. " null")
	-- 	-- end
	-- 	-- 确保点击的是后台窗口
	-- 	if clickedWin and focusedWin ~= clickedWin then
	-- 		-- clickedWin:focus()
	-- 		-- mouseLeftClickWatcher:stop()
	-- 		-- 等待窗口激活后，重新发送鼠标点击
	-- 		hs.timer.doAfter(0.1, function()
	-- 			-- print("click12")
	-- 			hs.eventtap.leftClick(mousePos)
	-- 			-- hs.timer.doAfter(0.6, function()
	-- 			-- 	mouseLeftClickWatcher:start()
	-- 			-- end)
	-- 		end)

	-- 	end
	-- 	-- return false  -- 允许正常点击
	-- end

	lastMouseClickTs = getMilliseconds()
	return false  -- 阻止原始点击，避免重复触发
end

function updateScreen()
	for i, scr in pairs(hs.screen.allScreens()) do
		sFrameList[i] = scr:fullFrame()
		-- print("screen[" .. i .. "] info: [原点]" .. sFrameList[i].x .. ", " .. sFrameList[i].y .. "; [宽高]" .. sFrameList[i].w .. ", " .. sFrameList[i].h)
	end
	middle = false
	middleForDoubleHotEdge = false
end

function pkg:init()
	ul = newCorner()
	ur = newCorner()
	ll = newCorner()
	lr = newCorner()

	mouseLeftClickWatcher = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function(e)  return handleGestureAndMouseClickOnEdge(e, "leftMouse") end)
	mouseRightClickWatcher = hs.eventtap.new({hs.eventtap.event.types.rightMouseDown}, function(e) return handleGestureAndMouseClickOnEdge(e, "rightMouse") end)
	-- mouseMiddleClickWatcher = hs.eventtap.new({hs.eventtap.event.types.otherMouseDown}, function(e) return handleGestureAndMouseClickOnEdge(e, "middleMouse") end)

	gestureWatcher = hs.eventtap.new({hs.eventtap.event.types.gesture}, function(e) return handleGestureAndMouseClickOnEdge(e, "trackPadGesture") end)

	screenWatcher = hs.screen.watcher.new(updateScreen)

	mouseMoveWatcher = hs.eventtap.new({
		hs.eventtap.event.types.mouseMoved
	}, function(e)
		--if not isMouseInsideFocusedWindowScreen() then  -- 不要用这个了, 这个函数很耗费性能, 不要用于 tick 之类的逻辑, 不然有很高的延迟
		--	return
		--end
		p = e:location()
		local curFrame
		local screenIndex
		for _i, _frame in pairs(sFrameList) do
			if p.x >= _frame.x and p.x < (_frame.x + _frame.w) and p.y >= _frame.y and p.y < (_frame.y + _frame.h) then  -- Inside the main screen ?
				revisedPos.x = p.x - _frame.x
				revisedPos.y = p.y - _frame.y
				curFrame = _frame
				screenIndex = _i
				break
			end
		end
		if not curFrame then  -- outside the screen is not corner
			middle = true
			--print("middle = true 2")
			middleForDoubleHotEdge = true
			return
		end

		curTs = getMilliseconds()
		--print("curTs = " .. curTs .. " lastHitEdgeTs = " .. lastHitEdgeTs .. " curTs - lastHitEdgeTs = " .. curTs - lastHitEdgeTs)
		local isNiceDoubleHotEdgeHit = curTs - lastHitEdgeTs <= pkg.hotEdgeDoubleHitInterval  -- ms, 毫秒内连续触碰到屏幕边缘两次
		-- Check corners
		if revisedPos.x < pkg.cornerDelta and revisedPos.y < pkg.cornerDelta then -- 左上触发角
			if (p.x <= lastMouseX and p.y <= lastMouseY) then -- `(p.x <= lastMouseX and p.y <= lastMouseY)`意思是: 如果刚刚从另一个显示器移动鼠标过来的, 不应该触发当前显示器的触发角
				--if #sFrameList == 1 or (#sFrameList == 2 and screenIndex == 2) then  -- 双屏的时候不要触发主屏幕的左上角, 从右下角小屏幕(主屏)鼠标左上移动到大屏幕(副屏)很容易误触
				--print("screenIndex: " .. screenIndex)
				if middle and isMouseInsideFocusedWindowScreen() then
					--print("px[" .. revisedPos.x .. "] py[" .. revisedPos.y .. "], lastX[" .. lastMouseX .. "] lastY[" .. lastMouseY)
					-- print("ul corner hit?")
					trigger(ul)
				end

			end
			middle = false
			--end
			lastHitEdgeTs = 0
		elseif revisedPos.x < pkg.cornerDelta and revisedPos.y > (curFrame.h - pkg.cornerDelta) then  -- 左下触发角
			if (p.x <= lastMouseX and p.y >= lastMouseY) then
				if middle and isMouseInsideFocusedWindowScreen() then
					-- print("ll corner hit?")
					trigger(ll)
				end
			end
			middle = false
			lastHitEdgeTs = 0
		elseif revisedPos.x > (curFrame.w - pkg.cornerDelta) and revisedPos.y < pkg.cornerDelta then  -- 右上触发角
			if (p.x >= lastMouseX and p.y <= lastMouseY) then
				if middle and isMouseInsideFocusedWindowScreen() then
					-- print("ur corner hit?")
					trigger(ur)
				end
			end
			middle = false
			lastHitEdgeTs = 0
		elseif revisedPos.x > (curFrame.w - pkg.cornerDelta) and revisedPos.y > (curFrame.h - pkg.cornerDelta) then  -- 右下触发角
			if (p.x >= lastMouseX and p.y >= lastMouseY) then
				--if #sFrameList == 1 or (#sFrameList == 2 and screenIndex == 1) then
				if middle and isMouseInsideFocusedWindowScreen() then
					-- print("lr corner hit?")
					trigger(lr)
				end
				--end
			end
			middle = false
			lastHitEdgeTs = 0
		elseif revisedPos.x < pkg.edgeDeltaShort and revisedPos.y <= (curFrame.h / 2) and revisedPos.y > pkg.edgeDeltaLong then  -- 左上触发边
			if p.x <= lastMouseX then  -- `p.x <= lastMouseX`意思是: 如果刚刚从另一个显示器移动鼠标过来的, 不应该触发当前显示器的触发边
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and (lastHitEdgeType == 1 or lastHitEdgeType == 2) and isMouseInsideFocusedWindowScreen() then
						--trigger(ul)
						-- winresize("left")
						-- print("ul hotedge hit trigggggggggggger?" .. tostring(curTs) .. "?" .. tostring(lastHitEdgeTs)  .. "?" .. tostring(curTs - lastHitEdgeTs) )
						winresize("left")
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						-- print("ul hotedge hit?" .. tostring(curTs) .. "?" .. tostring(lastHitEdgeTs)  .. "?" .. tostring(curTs - lastHitEdgeTs) .. "?" .. tostring(isNiceDoubleHotEdgeHit) .. "?" .. tostring(lastHitEdgeType) .. "?" .. tostring(isMouseInsideFocusedWindowScreen()))
						lastHitEdgeTs = curTs
						lastHitEdgeType = 1
					end
				end
			end
			middleForDoubleHotEdge = false
		elseif revisedPos.x < pkg.edgeDeltaShort and revisedPos.y > (curFrame.h / 2) and revisedPos.y < (curFrame.h - pkg.edgeDeltaLong) then  -- 左下触发边
			if p.x <= lastMouseX then
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and (lastHitEdgeType == 1 or lastHitEdgeType == 2) and isMouseInsideFocusedWindowScreen() then
						--trigger(ll)
						-- winresize("left")
						winresize("right")
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						lastHitEdgeTs = curTs
						lastHitEdgeType = 2
					end
				end
			end
			middleForDoubleHotEdge = false
		elseif revisedPos.x > (curFrame.w - pkg.edgeDeltaShort) and revisedPos.y <= (curFrame.h / 2) and revisedPos.y > pkg.edgeDeltaLong then  -- 右上触发边
			if p.x >= lastMouseX then
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and lastHitEdgeType == 6 and isMouseInsideFocusedWindowScreen() then
						--trigger(ur)
						-- print("ur hotedge hit trigggggggggggger?" .. tostring(curTs) .. "?" .. tostring(lastHitEdgeTs)  .. "?" .. tostring(curTs - lastHitEdgeTs) )
						winresize("right")
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						-- print("ur hotedge hit?" .. tostring(curTs) .. "?" .. tostring(lastHitEdgeTs)  .. "?" .. tostring(curTs - lastHitEdgeTs) .. "?" .. tostring(isNiceDoubleHotEdgeHit) .. "?" .. tostring(lastHitEdgeType) .. "?" .. tostring(isMouseInsideFocusedWindowScreen()))
						lastHitEdgeTs = curTs
						lastHitEdgeType = 6
					end
				end
			end
			middleForDoubleHotEdge = false
		elseif revisedPos.x > (curFrame.w - pkg.edgeDeltaShort) and revisedPos.y > (curFrame.h / 2) and revisedPos.y < (curFrame.h - pkg.edgeDeltaLong) then  -- 右下触发边
			if p.x >= lastMouseX then
				--if #sFrameList == 1 or (#sFrameList == 2 and screenIndex == 1) then
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and lastHitEdgeType == 5 and isMouseInsideFocusedWindowScreen() then
						--print("lr hotedge hit?")
						--trigger(lr)
						winresize("left")
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						-- print("ur hotedge hit?")
						lastHitEdgeTs = curTs
						lastHitEdgeType = 5
					end
				end
			end
			middleForDoubleHotEdge = false
			--end
		elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x < (curFrame.w / 4) and revisedPos.x > pkg.edgeDeltaLong then  -- 上左1/4触发边
			if p.y <= lastMouseY then
				--if #sFrameList == 2 and screenIndex ~= 1 then  -- 容易误触
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and lastHitEdgeType == 8 and isMouseInsideFocusedWindowScreen() then
						--trigger(ul)
						-- hs.eventtap.keyStroke({"ctrl", "shift"}, "tab", 0)
						-- -- 模拟释放 Ctrl+Shift 键
						-- hs.eventtap.keyStroke({}, "ctrl", 0)
						-- hs.eventtap.keyStroke({}, "shift", 0)
						winresize("max")
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						lastHitEdgeTs = curTs
						lastHitEdgeType = 8
					end
				end
			end
			middleForDoubleHotEdge = false
			--end
		elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x >= (curFrame.w * 3 / 4) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 上右1/4触发边
			if p.y <= lastMouseY then
				--if #sFrameList == 2 and screenIndex ~= 1 then  -- 容易误触
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and lastHitEdgeType == 7 and isMouseInsideFocusedWindowScreen() then
						--trigger(ur)
						-- print("cmd up")
						hs.eventtap.event.newKeyEvent({"cmd"}, "up", true):post()
						hs.eventtap.event.newKeyEvent({"cmd"}, "up", false):post()
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						lastHitEdgeTs = curTs
						lastHitEdgeType = 7
					end
				end
			end
			middleForDoubleHotEdge = false
			--end
		elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x < (curFrame.w / 4) and revisedPos.x > pkg.edgeDeltaLong then  -- 下左1/4触发边(why 1/4? because we don't wanna trigger the dock)
			if p.y >= lastMouseY then
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and lastHitEdgeType == 3 and isMouseInsideFocusedWindowScreen() then
						--trigger(ll)
						winresize("max")
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
						-- hs.eventtap.event.newKeyEvent({""}, "F12", true):post()
						-- hs.eventtap.event.newKeyEvent({""}, "F12", false):post()
					else
						lastHitEdgeTs = curTs
						lastHitEdgeType = 3
					end
				end
			end
			middleForDoubleHotEdge = false
		elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x >= (curFrame.w * 3 / 4) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 下右1/4触发边(why 1/4? because we don't wanna trigger the dock)
			if p.y >= lastMouseY then
				--if #sFrameList == 2 and screenIndex == 1 then  -- 容易误触
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and lastHitEdgeType == 4 and isMouseInsideFocusedWindowScreen() then
						--trigger(lr)
						-- print("cmd down")
						hs.eventtap.event.newKeyEvent({"cmd"}, "down", true):post()
						hs.eventtap.event.newKeyEvent({"cmd"}, "down", false):post()
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						lastHitEdgeTs = curTs
						lastHitEdgeType = 4
					end
				end
			end
			middleForDoubleHotEdge = false
			--end
		else
			middle = true
			middleForDoubleHotEdge = true
			--print("middle = true, middleForDoubleHotEdge 1")
		end
		lastMouseX = p.x
		lastMouseY = p.y
	end)
end

function pkg:start()
	updateScreen()
	mouseMoveWatcher:start()
	screenWatcher:start()
	mouseLeftClickWatcher:start()
	mouseRightClickWatcher:start()
	--mouseMiddleClickWatcher:start()

	gestureWatcher:start()

	self:setUpperLeft()
	self:setLowerLeft()
	self:setUpperRight()
	self:setLowerRight()
	return self
end

function pkg:stop()
	mouseMoveWatcher:stop()
	screenWatcher:stop()
	mouseLeftClickWatcher:stop()
	mouseRightClickWatcher:stop()
	--mouseMiddleClickWatcher:stop()

	gestureWatcher:stop()
	return self
end

function setCorner(corner, cb)
	assert(cb == nil or type(cb) == "function", functionOrNil)
	corner.cb = cb
end

function pkg:getULO()
	return ul.cb
end

function pkg:getULT()
	return ul.two
end

function pkg:getULH()
	return ul.hold
end

function pkg:getLLO()
	return ll.cb
end

function pkg:getLLT()
	return ll.two
end

function pkg:getLLH()
	return ll.hold
end

function pkg:getURO()
	return ur.cb
end

function pkg:getURT()
	return ur.two
end

function pkg:getURH()
	return ur.hold
end

function pkg:getLRO()
	return lr.cb
end

function pkg:getLRT()
	return lr.two
end

function pkg:getLRH()
	return lr.hold
end

local leftTabCb = function()
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
end


local rightTabCb = function()
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
end

-- 触发快捷键 ctrl+shift+tab: 前一个APP
function pkg:setLowerLeft()
	local cb = function()
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
	end

	setCorner(ll, rightTabCb)
	return self
end


-- 触发快捷键 ctrl+shift+tab: 前一个标签页
function pkg:setUpperLeft()
	setCorner(ul, leftTabCb)
	return self
end

-- 触发快捷键 cmd+tab: 后一个标签页
function pkg:setLowerRight()
	local cb = function()
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
	end
	
	setCorner(lr, leftTabCb)
	return self
end

-- 触发快捷键 ctrl+tab: 后一个标签页
function pkg:setUpperRight()
	setCorner(ur, rightTabCb)
	return self
end



return pkg
