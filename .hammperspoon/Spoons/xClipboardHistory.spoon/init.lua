local pkg = {}


------------------------ A simple clipboard history implement ------------------------

local hotkey = require "hs.hotkey"
local pasteboard = require "hs.pasteboard"
local pbwatcher = require "hs.pasteboard.watcher"
local chooser = require "hs.chooser"

local text_clipboard_history = {}  -- Array to store the clipboard history for text
local img_clipboard_history = {}  -- Array to store the clipboard history for img
local menuData = {}  -- chooser menu data

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



return pkg