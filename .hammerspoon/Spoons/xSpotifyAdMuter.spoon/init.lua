-----------------------------------------------------------
-- xSpotifyAdMuter
-- Spotify advertisement muter for Hammerspoon
-- Mute all the Thai ads by default
-- `ctrl+shift+option+cmd+A` to add current playing ad
-----------------------------------------------------------

local obj = {}

obj.interval = 0.8
obj.fadeOutDuration = 0.6
obj.fadeInDuration = 0.8

obj.knownAdsFile =
    os.getenv("HOME") .. "/.hammerspoon/Spoons/xSpotifyAdMuter.spoon/spotify_known_ads.lua"

local adActive = false
local originalVolume = 100
local fadeTimer = nil


-----------------------------------------------------------
-- Utility
-----------------------------------------------------------

local function stopFade()
    if fadeTimer then
        fadeTimer:stop()
        fadeTimer = nil
    end
end


local function luaQuote(value)
    value = tostring(value or "")
    return string.format("%q", value)
end


-----------------------------------------------------------
-- Load known advertisements
-----------------------------------------------------------

local function loadKnownAds()
    local file = io.open(obj.knownAdsFile, "r")

    if not file then
        return {}
    end

    local content = file:read("*all")
    file:close()

    local chunk, err = load(content, "spotify_known_ads", "t", {})

    if not chunk then
        hs.alert.show("Failed to load Spotify ad database")
        return {}
    end

    local ok, result = pcall(chunk)

    if not ok or type(result) ~= "table" then
        hs.alert.show("Invalid Spotify ad database")
        return {}
    end

    return result
end


local knownAds = loadKnownAds()


-----------------------------------------------------------
-- Save known advertisements
-----------------------------------------------------------

local function saveKnownAds()
    local file = io.open(obj.knownAdsFile, "w")

    if not file then
        hs.alert.show("Unable to save Spotify ad database")
        return false
    end

    file:write("return {\n")

    for _, ad in ipairs(knownAds) do
        file:write("    {\n")
        file:write("        name = " .. luaQuote(ad.name) .. ",\n")
        file:write("        artist = " .. luaQuote(ad.artist) .. ",\n")
        file:write("        album = " .. luaQuote(ad.album) .. ",\n")
        file:write("    },\n")
    end

    file:write("}\n")
    file:close()

    return true
end


-----------------------------------------------------------
-- Spotify information
-----------------------------------------------------------

local function spotifyInfo()

    local script = [[
        tell application "Spotify"
            if player state is playing then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set currentVolume to sound volume

                return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & currentVolume
            else
                return "NOT_PLAYING"
            end if
        end tell
    ]]

    local ok, result = hs.osascript.applescript(script)

    if not ok or not result or result == "NOT_PLAYING" then
        return nil
    end

    local name, artist, album, volume =
        result:match("^(.-)%|%|%|(.-)%|%|%|(.-)%|%|%|(.+)$")

    if not name then
        return nil
    end

    return {
        name = name,
        artist = artist,
        album = album,
        volume = tonumber(volume) or 0
    }
end


-----------------------------------------------------------
-- Thai detection
-----------------------------------------------------------

local function containsThai(text)

    if not text or text == "" then
        return false
    end

    local i = 1
    local length = #text

    while i <= length do

        local b1 = string.byte(text, i)
        local codepoint

        if b1 < 0x80 then

            codepoint = b1
            i = i + 1

        elseif b1 >= 0xC0 and b1 <= 0xDF then

            local b2 = string.byte(text, i + 1)

            if not b2 then
                break
            end

            codepoint =
                (b1 - 0xC0) * 0x40 +
                (b2 - 0x80)

            i = i + 2

        elseif b1 >= 0xE0 and b1 <= 0xEF then

            local b2 = string.byte(text, i + 1)
            local b3 = string.byte(text, i + 2)

            if not b2 or not b3 then
                break
            end

            codepoint =
                (b1 - 0xE0) * 0x1000 +
                (b2 - 0x80) * 0x40 +
                (b3 - 0x80)

            i = i + 3

        elseif b1 >= 0xF0 and b1 <= 0xF4 then

            local b2 = string.byte(text, i + 1)
            local b3 = string.byte(text, i + 2)
            local b4 = string.byte(text, i + 3)

            if not b2 or not b3 or not b4 then
                break
            end

            codepoint =
                (b1 - 0xF0) * 0x40000 +
                (b2 - 0x80) * 0x1000 +
                (b3 - 0x80) * 0x40 +
                (b4 - 0x80)

            i = i + 4

        else

            i = i + 1

        end

        if codepoint >= 0x0E00 and codepoint <= 0x0E7F then
            return true
        end

    end

    return false
end


-----------------------------------------------------------
-- Known advertisement matching
-----------------------------------------------------------

local function matchesKnownAd(info, ad)

    if ad.name and ad.name ~= "" and info.name ~= ad.name then
        return false
    end

    if ad.artist and ad.artist ~= "" and info.artist ~= ad.artist then
        return false
    end

    if ad.album and ad.album ~= "" and info.album ~= ad.album then
        return false
    end

    return true
end


local function isKnownAd(info)

    for _, ad in ipairs(knownAds) do
        if matchesKnownAd(info, ad) then
            return true
        end
    end

    return false
end


-----------------------------------------------------------
-- Advertisement detection
-----------------------------------------------------------

local function isAdvertisement(info)

    if containsThai(info.name) then
        return true
    end

    if containsThai(info.artist) then
        return true
    end

    if containsThai(info.album) then
        return true
    end

    if isKnownAd(info) then
        return true
    end

    return false
end


-----------------------------------------------------------
-- Spotify volume
-----------------------------------------------------------

local function setSpotifyVolume(volume)

    volume = tonumber(volume) or 0
    volume = math.max(0, math.min(100, math.floor(volume)))

    local script = string.format([[
        tell application "Spotify"
            set sound volume to %d
        end tell
    ]], volume)

    hs.osascript.applescript(script)
end


-----------------------------------------------------------
-- Smooth volume fading
-----------------------------------------------------------

local function fadeSpotifyVolume(fromVolume, toVolume, duration)

    stopFade()

    fromVolume = tonumber(fromVolume) or 0
    toVolume = tonumber(toVolume) or 0

    local steps =
        math.max(1, math.floor(duration / 0.05))

    local stepInterval = duration / steps
    local step = 0

    fadeTimer = hs.timer.doEvery(stepInterval, function()

        step = step + 1

        local progress =
            math.min(1, step / steps)

        local volume =
            fromVolume +
            (toVolume - fromVolume) * progress

        setSpotifyVolume(volume)

        if progress >= 1 then
            stopFade()
        end
    end)
end


-----------------------------------------------------------
-- Mute advertisement
-----------------------------------------------------------

local function muteAdvertisement(info)

    if not adActive then
        originalVolume = info.volume
        adActive = true
    end

    fadeSpotifyVolume(
        info.volume,
        0,
        obj.fadeOutDuration
    )
end


-----------------------------------------------------------
-- Restore Spotify volume
-----------------------------------------------------------

local function restoreSpotifyVolume()

    if not adActive then
        return
    end

    adActive = false

    fadeSpotifyVolume(
        0,
        originalVolume,
        obj.fadeInDuration
    )
end


-----------------------------------------------------------
-- Add current track to advertisement database
-----------------------------------------------------------

local function teachCurrentAdvertisement()

    local info = spotifyInfo()

    if not info then
        hs.alert.show("Spotify is not playing")
        return
    end

    -------------------------------------------------------
    -- Add to memory immediately
    -------------------------------------------------------

    local alreadyKnown = false

    for _, ad in ipairs(knownAds) do
        if matchesKnownAd(info, ad) then
            alreadyKnown = true
            break
        end
    end

    if not alreadyKnown then

        table.insert(knownAds, {
            name = info.name,
            artist = info.artist,
            album = info.album
        })

        saveKnownAds()

    end

    -------------------------------------------------------
    -- Mute immediately
    -------------------------------------------------------

    muteAdvertisement(info)

    -------------------------------------------------------
    -- Notify user
    -------------------------------------------------------

    if alreadyKnown then

        hs.notify.show(
            "xSpotifyAdMuter",
            "Advertisement already known",
            info.name
        )

    else

        hs.notify.show(
            "xSpotifyAdMuter",
            "Advertisement learned",
            info.name
        )

    end
end


-----------------------------------------------------------
-- Shortcut
--
-- Command + Option + A
--
-- Teach current Spotify track as an advertisement
-----------------------------------------------------------

obj.adHotkey =
    hs.hotkey.bind(
        {"cmd", "alt", "ctrl", "shift"},
        "A",
        teachCurrentAdvertisement
    )


-----------------------------------------------------------
-- Main Spotify watcher
-----------------------------------------------------------

local function checkSpotify()

    local info = spotifyInfo()

    if not info then

        if adActive then
            restoreSpotifyVolume()
        end

        return
    end

    local ad = isAdvertisement(info)

    if ad then

        if not adActive then
            muteAdvertisement(info)
        end

    else

        if adActive then
            restoreSpotifyVolume()
        end
    end
end


-----------------------------------------------------------
-- Start watcher automatically
-----------------------------------------------------------

obj.timer =
    hs.timer.doEvery(
        obj.interval,
        checkSpotify
    )


return obj