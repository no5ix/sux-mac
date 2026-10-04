local obj = {}

obj.interval = 1
obj.confirmationTime = 2

local muted = false
local originalVolume = 100
local lastState = nil
local stateSince = nil

-----------------------------------------------------------
-- Get Spotify information
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
        volume = tonumber(volume)
    }
end

-----------------------------------------------------------
-- Detect Thai characters
-----------------------------------------------------------

local function containsThai(text)
    if not text or text == "" then
        return false
    end

    for i = 1, #text do
        local byte = string.byte(text, i)

        if byte >= 0xE0 and byte <= 0xE3 then
            return true
        end
    end

    return false
end

-----------------------------------------------------------
-- Detect advertisement
-----------------------------------------------------------

local function isAdvertisement(info)
    return containsThai(info.name)
        or containsThai(info.artist)
        or containsThai(info.album)
end

-----------------------------------------------------------
-- Set Spotify volume
-----------------------------------------------------------

local function setSpotifyVolume(volume)
    volume = math.max(0, math.min(100, math.floor(volume)))

    local script = string.format([[
        tell application "Spotify"
            set sound volume to %d
        end tell
    ]], volume)

    hs.osascript.applescript(script)
end

-----------------------------------------------------------
-- Check Spotify
-----------------------------------------------------------

local function checkSpotify()

    local info = spotifyInfo()

    if not info then
        if muted then
            setSpotifyVolume(originalVolume)
            muted = false
        end

        lastState = nil
        stateSince = nil

        return
    end

    local currentState =
        isAdvertisement(info) and "AD" or "MUSIC"

    -------------------------------------------------------
    -- State changed
    -------------------------------------------------------

    if currentState ~= lastState then
        lastState = currentState
        stateSince = os.time()
        return
    end

    -------------------------------------------------------
    -- Wait for confirmation
    -------------------------------------------------------

    if not stateSince then
        stateSince = os.time()
        return
    end

    if os.time() - stateSince < obj.confirmationTime then
        return
    end

    -------------------------------------------------------
    -- Confirmed advertisement
    -------------------------------------------------------

    if currentState == "AD" and not muted then
        originalVolume = info.volume or 100
        setSpotifyVolume(0)
        muted = true
        return
    end

    -------------------------------------------------------
    -- Confirmed music
    -------------------------------------------------------

    if currentState == "MUSIC" and muted then
        setSpotifyVolume(originalVolume)
        muted = false
        return
    end
end

-----------------------------------------------------------
-- Automatically start monitoring when the Spoon loads
-----------------------------------------------------------

obj.timer = hs.timer.doEvery(
    obj.interval,
    checkSpotify
)



return obj
