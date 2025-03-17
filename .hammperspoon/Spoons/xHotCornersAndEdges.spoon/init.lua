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
pkg.isStageManagerEnabled = false  -- please turn it on when u enable stage manager

-- Local variables
local curTs = 0  -- ms
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

function handleMouseClickOnEdge(event, whichMouseClick)
	--print("handleMouseClickOnEdge", whichMouseClick)
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
		return
	end
	--print("checking edge, " .. whichMouseClick .. ", " .. revisedPos.x .. ", " .. curFrame.w)
	-- Check edge
	if revisedPos.x <= pkg.edgeDeltaShort and revisedPos.y <= (curFrame.h / 2) then  -- 左上
		if whichMouseClick == 'leftMouse' then
		elseif whichMouseClick == 'rightMouse' then
			--print("ul.cb()")
			--ul.cb()
			--print("launchOrFocus NetEaseMusic)")
			--TimerLaunchOrFocusApp("NetEaseMusic")
		end
	elseif revisedPos.x >= (curFrame.w - pkg.edgeDeltaShort) and revisedPos.y <= (curFrame.h / 2) then  -- 右上
		if whichMouseClick == 'leftMouse' then

		elseif whichMouseClick == 'rightMouse' then
			--print("ur.cb()")
			--ur.cb()
			--print("launchOrFocus WeChat")
			--TimerLaunchOrFocusApp("WeChat")
		elseif whichMouseClick == 'middleMouse' then
			--print("cmd up handleMouseClickOnEdge")
			--hs.eventtap.event.newKeyEvent({"cmd"}, "up", true):post()
			--hs.eventtap.event.newKeyEvent({"cmd"}, "up", false):post()
		end
	elseif revisedPos.x <= pkg.edgeDeltaShort and revisedPos.y > (curFrame.h / 2) then  -- 左下
		if whichMouseClick == 'leftMouse' then
			--print("ul.cb()")
			--ul.cb()
		elseif whichMouseClick == 'rightMouse' then

		end
	elseif revisedPos.x >= (curFrame.w - pkg.edgeDeltaShort) and revisedPos.y > (curFrame.h / 2) then  -- 右下
		if whichMouseClick == 'leftMouse' then
			--print("ur.cb()")
			--ur.cb()
		elseif whichMouseClick == 'rightMouse' then
		elseif whichMouseClick == 'middleMouse' then
			--print("cmd down handleMouseClickOnEdge")
			--hs.eventtap.event.newKeyEvent({"cmd"}, "down", true):post()
			--hs.eventtap.event.newKeyEvent({"cmd"}, "down", false):post()
		end
	elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x < (curFrame.w / 2) and revisedPos.x > pkg.edgeDeltaLong then  -- 上左
		if whichMouseClick == 'leftMouse' then
			--print("ul.cb()")
			--ul.cb()
			-- hs.timer.doAfter(8, function()
				-- local res = hs.wifi.associate("ARRIS-A305", "332444301449")
				-- print("baxian")
				-- print(res)
				-- hs.wifi.setPower(true)
			-- end)
		elseif whichMouseClick == 'rightMouse' then
			-- print("c s t down handleMouseClickOnEdge")
			-- hs.eventtap.keyStroke({"ctrl", "shift"}, "tab", 0)
			-- -- 模拟释放 Ctrl+Shift 键
			-- hs.eventtap.keyStroke({}, "ctrl", 0)
			-- hs.eventtap.keyStroke({}, "shift", 0)
			-- print("cmd[")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", false):post()
			local win = hs.window.focusedWindow()
			if win ~= nil then
				win:moveOneScreenWest(nil, nil, 0.3)  -- 0.3 是动画时长, move the focused window to the left(west) screen
				hs.timer.doAfter(0.6, function()  -- 这个timer不可少, 不然经常窗口还没出来就执行了 winresize
					winresize("max")
				end)
			end
		elseif whichMouseClick == 'middleMouse' then
		end
	elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x >= (curFrame.w / 2) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 上右
		if whichMouseClick == 'leftMouse' then
			-- print("ur.cb()")
			--ur.cb()
			-- print(hs.wifi.currentNetwork())
			-- for key, value in pairs(hs.wifi.availableNetworks()) do
			-- 	print(key, value)
			-- end
			-- hs.wifi.disassociate()
			-- hs.wifi.setPower(false)
		elseif whichMouseClick == 'rightMouse' then
			-- print("cmd]")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", false):post()
			local win = hs.window.focusedWindow()
			if win ~= nil then
				win:moveOneScreenEast(nil, nil, 0.3)  -- 0.3 是动画时长, move the focused window to the right(east) screen
				hs.timer.doAfter(0.6, function()  -- 这个timer不可少, 不然经常窗口还没出来就执行了 winresize
					winresize("max")
				end)
			end
		end
	elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x < (curFrame.w / 2) and revisedPos.x > pkg.edgeDeltaLong then  -- 下左
		if whichMouseClick == 'leftMouse' then
			--print("launchOrFocus NetEaseMusic)")
			--TimerLaunchOrFocusApp("NetEaseMusic")
		elseif whichMouseClick == 'rightMouse' then
			-- print("cmd[")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "[", false):post()
			--winresize("left")
		end
	elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x >= (curFrame.w / 2) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 下右
		if whichMouseClick == 'leftMouse' then
			--print("launchOrFocus WeChat")
			--TimerLaunchOrFocusApp("WeChat")
		elseif whichMouseClick == 'rightMouse' then
			-- print("cmd]")
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", true):post()
			-- hs.eventtap.event.newKeyEvent({"cmd"}, "]", false):post()
			--winresize("right")
		end
	end

    if flags['cmd'] then
        -- 处理 Cmd + 鼠标单击事件
    else
        -- 处理普通鼠标单击事件
    end

	-- 处理当多窗口时候点击, 点击则聚焦并且实施真实的点击行为
	-- if whichMouseClick == 'leftMouse' then
	-- 	local mousePos = hs.mouse.getAbsolutePosition()  -- 获取鼠标点击位置
	-- 	local win = hs.window.frontmostWindow()         -- 当前前置窗口
	-- 	-- 获取鼠标所在窗口
	-- 	local clickedWin = nil
	-- 	for _, w in ipairs(hs.window.orderedWindows()) do
	-- 		local f = w:frame()
	-- 		if mousePos.x >= f.x and mousePos.x <= f.x + f.w and
	-- 		mousePos.y >= f.y and mousePos.y <= f.y + f.h then
	-- 			clickedWin = w
	-- 			break
	-- 		end
	-- 	end
	-- 	-- 确保点击的是后台窗口
	-- 	if clickedWin and win ~= clickedWin then
	-- 		clickedWin:focus()
	-- 		-- 等待窗口激活后，重新发送鼠标点击
	-- 		hs.timer.doAfter(0.1, function()
	-- 			hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, mousePos):post()
	-- 			hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, mousePos):post()
	-- 		end)
	-- 		return true  -- 阻止原始点击，避免重复触发
	-- 	end
	-- 	return false  -- 允许正常点击
	-- end
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

	mouseLeftClickWatcher = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function(e) handleMouseClickOnEdge(e, "leftMouse") end)
	mouseRightClickWatcher = hs.eventtap.new({hs.eventtap.event.types.rightMouseDown}, function(e) handleMouseClickOnEdge(e, "rightMouse") end)
	--mouseMiddleClickWatcher = hs.eventtap.new({hs.eventtap.event.types.otherMouseDown}, function(e) handleMouseClickOnEdge(e, "middleMouse") end)

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
						winresize("left")
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
						winresize("right")
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
		elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x < (curFrame.w / 2) and revisedPos.x > pkg.edgeDeltaLong then  -- 上左触发边
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
		elseif revisedPos.y < pkg.edgeDeltaShort and revisedPos.x >= (curFrame.w / 2) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 上右触发边
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
		elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x < (curFrame.w / 2) and revisedPos.x > pkg.edgeDeltaLong then  -- 下左触发边
			if p.y >= lastMouseY then
				if middleForDoubleHotEdge then
					if isNiceDoubleHotEdgeHit and lastHitEdgeType == 3 and isMouseInsideFocusedWindowScreen() then
						--trigger(ll)
						lastHitEdgeTs = 0
						lastHitEdgeType = 0
					else
						lastHitEdgeTs = curTs
						lastHitEdgeType = 3
					end
				end
			end
			middleForDoubleHotEdge = false
		elseif revisedPos.y > (curFrame.h - pkg.edgeDeltaShort) and revisedPos.x >= (curFrame.w / 2) and revisedPos.x < (curFrame.w - pkg.edgeDeltaLong) then  -- 下右触发边
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
	return self
end

function pkg:stop()
	mouseMoveWatcher:stop()
	screenWatcher:stop()
	mouseLeftClickWatcher:stop()
	mouseRightClickWatcher:stop()
	--mouseMiddleClickWatcher:stop()
	return self
end

function setCorner(corner, cb)
	assert(cb == nil or type(cb) == "function", functionOrNil)
	corner.cb = cb
end

function pkg:setUpperLeft(cb)
	setCorner(ul, cb)
	return self
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

function pkg:setLowerLeft(cb)
	setCorner(ll, cb)
	return self
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

function pkg:setUpperRight(cb)
	setCorner(ur, cb)
	return self
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

function pkg:setLowerRight(cb)
	setCorner(lr, cb)
	return self
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

return pkg
