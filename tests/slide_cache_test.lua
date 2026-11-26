-- Run with: lua tests/slide_cache_test.lua
-- Verifies per-monitor window picture caches and wallpaper refresh behavior in
-- hyprspoon/slide.lua (and that overview passes display UUIDs to native).
package.path = "./?.lua;" .. package.path

local function makeScreen(uuid, f, ff, scale, wallpaperURL)
    return {
        getUUID = function() return uuid end,
        frame = function() return { x = f.x, y = f.y, w = f.w, h = f.h } end,
        fullFrame = function() return { x = ff.x, y = ff.y, w = ff.w, h = ff.h } end,
        currentMode = function() return { scale = scale or 2 } end,
        desktopImageURL = function() return wallpaperURL end,
    }
end

local noop = function() end
local captures, runs, forgets, wallpapers, retiles = {}, {}, {}, {}, {}
local timers = {}
local screens = {}

local nativeMod = {
    onChange = noop,
    onReady = noop,
    stop = noop,
    capture = function(key, ids, monitor, fullFrame)
        captures[#captures + 1] = { key = key, ids = ids, monitor = monitor, fullFrame = fullFrame }
        return true
    end,
    run = function(spec)
        runs[#runs + 1] = spec
    end,
    begin = function(spec)
        runs[#runs + 1] = spec
        return true
    end,
    track = noop,
    finish = noop,
    forget = function(key, monitor)
        forgets[#forgets + 1] = { key = key, monitor = monitor }
    end,
    wallpaper = function(frame, monitor, path, force)
        wallpapers[#wallpapers + 1] = { frame = frame, monitor = monitor, path = path, force = force }
    end,
    retile = function(spec)
        retiles[#retiles + 1] = spec
        return 1
    end,
}

hs = {
    settings = { get = function() return nil end },
    screen = { allScreens = function() return screens end },
    timer = {
        secondsSinceEpoch = function() return 100 end,
        doAfter = function(delay, fn)
            local t = { delay = delay, fn = fn, stopped = false }
            t.stop = function() t.stopped = true end
            timers[#timers + 1] = t
            return t
        end,
    },
}

local S = require("hyprspoon.state")
S.cfg = {
    slide = { workspaces = "horizontal", scratchpads = "bottom" },
    experimental = { captureRetile = true },
}
package.loaded["hyprspoon.util"] = { native = function() return nativeMod end }
package.loaded["hyprspoon.anim"] = { get = function() return { curve = "ease", duration = 0.2 } end }
package.loaded["hyprspoon.groupbar"] = { suspend = noop }
package.loaded["hyprspoon.spaces"] = { beneath = function() return {} end }

local Slide = require("hyprspoon.slide")

local mbp = makeScreen("MBP",
    { x = 0, y = 38, w = 1800, h = 1131 },
    { x = 0, y = 0, w = 1800, h = 1169 },
    2, "file:///Library/Desktop%20Pictures/MacBook.heic")

local ext = makeScreen("EXT",
    { x = 0, y = 25, w = 2560, h = 1415 },
    { x = 0, y = 0, w = 2560, h = 1440 },
    2, "file:///Library/Desktop%20Pictures/External.png")

-- 1. Start on MacBook: primes MacBook wallpaper with UUID and decoded fallback path,
--    and schedules a settle wallpaper refresh.
screens = { mbp }
Slide.start()
assert(#wallpapers == 1, "start primes connected monitor wallpaper")
assert(wallpapers[1].monitor == "MBP")
assert(wallpapers[1].path == "/Library/Desktop Pictures/MacBook.heic")
assert(wallpapers[1].force == false)
assert(#timers == 1 and timers[1].delay == 1.5, "start schedules settle wallpaper refresh")
timers[1].fn()
assert(#wallpapers == 2 and wallpapers[2].monitor == "MBP" and wallpapers[2].force == true,
    "settle timer refreshes wallpaper with force=true")

-- 2. Switch workspaces on MacBook: captures ws 1 under MBP, then ws 2 under MBP,
--    then switching back to ws 1 hits MBP's cached picture.
assert(Slide.switch(mbp, 1, 2, { 10, 11 }, { 20 }, 1) == true)
assert(captures[#captures].monitor == "MBP" and captures[#captures].key == 1)
assert(runs[#runs].monitor == "MBP" and runs[#runs].out == 1 and runs[#runs].into == nil)
assert(runs[#runs].wallpaperPath == "/Library/Desktop Pictures/MacBook.heic")

assert(Slide.switch(mbp, 2, 1, { 20 }, { 10, 11 }, -1) == true)
assert(runs[#runs].monitor == "MBP" and runs[#runs].out == 2 and runs[#runs].into == 1 and runs[#runs].backdrop == true,
    "returning to ws 1 on MBP uses cached picture")

-- 3. Switch to external monitor (plug in external, close lid) and reset:
--    MacBook's cache MUST NOT be wiped!
screens = { ext }
forgets = {}
Slide.reset()
assert(#forgets == 0, "switching to external screen must not wipe MBP cache")

-- Switch workspaces on external monitor: ws 1 is NOT cached for EXT yet,
-- then capturing ws 1 & ws 2 on EXT does NOT overwrite MBP's ws 1 & ws 2 caches.
assert(Slide.switch(ext, 1, 2, { 10, 11 }, { 20 }, 1) == true)
assert(captures[#captures].monitor == "EXT" and captures[#captures].key == 1)
assert(runs[#runs].monitor == "EXT" and runs[#runs].out == 1 and runs[#runs].into == nil,
    "EXT must not use MBP's picture for ws 2")
assert(Slide.switch(ext, 2, 1, { 20 }, { 10, 11 }, -1) == true)
assert(runs[#runs].monitor == "EXT" and runs[#runs].out == 2 and runs[#runs].into == 1,
    "EXT uses its own cached picture for ws 1")

-- 4. Switch back to MacBook (even with shifted global origin, e.g. external on left):
--    MBP's cached pictures for ws 1 and ws 2 are STILL warm!
local mbpShifted = makeScreen("MBP",
    { x = 2560, y = 309, w = 1800, h = 1131 },
    { x = 2560, y = 271, w = 1800, h = 1169 },
    2, "file:///Library/Desktop%20Pictures/MacBook.heic")
screens = { ext, mbpShifted }
forgets = {}
Slide.reset()
assert(#forgets == 0, "origin shift alone must preserve MBP cache")
assert(Slide.switch(mbpShifted, 1, 2, { 10, 11 }, { 20 }, 1) == true)
assert(runs[#runs].monitor == "MBP" and runs[#runs].into == 2 and runs[#runs].backdrop == true,
    "MBP still has its own cached ws 2 picture after switching back from EXT")

-- 5. Scratchpads keep separate caches per monitor.
assert(Slide.hideScratchpad(mbpShifted, 101, { 50 }) == true)
assert(Slide.hideScratchpad(ext, 101, { 50 }) == true)
assert(Slide.showScratchpad(mbpShifted, 101, { 50 }, { 10, 11 }) == true)
assert(runs[#runs].monitor == "MBP" and runs[#runs].into == 101)
assert(Slide.showScratchpad(ext, 101, { 50 }, { 10, 11 }) == true)
assert(runs[#runs].monitor == "EXT" and runs[#runs].into == 101)

-- 6. Changing resolution/scale on ONE monitor invalidates ONLY that monitor's cache.
local extResized = makeScreen("EXT",
    { x = 0, y = 25, w = 1920, h = 1055 },
    { x = 0, y = 0, w = 1920, h = 1080 },
    1, "file:///Library/Desktop%20Pictures/External.png")
screens = { extResized, mbpShifted }
forgets = {}
Slide.reset()
assert(#forgets == 1 and forgets[1].key == nil and forgets[1].monitor == "EXT",
    "only the resized monitor's cache is forgotten")
assert(Slide.switch(extResized, 1, 2, { 10, 11 }, { 20 }, 1) == true)
assert(runs[#runs].into == nil, "resized EXT does not reuse old resolution picture")
assert(Slide.switch(mbpShifted, 2, 1, { 20 }, { 10, 11 }, -1) == true)
assert(runs[#runs].into == 1, "unchanged MBP still keeps its cached picture")

-- 7. noteCaptured records per monitor, and forget(n) drops workspace n across all monitors.
Slide.noteCaptured(3, { 30 }, extResized)
Slide.noteCaptured(3, { 30 }, mbpShifted)
forgets = {}
Slide.forget(3)
assert(#forgets == 1 and forgets[1].key == 3 and forgets[1].monitor == nil,
    "forget(n) drops workspace n across all monitors")
assert(Slide.switch(mbpShifted, 1, 3, { 10, 11 }, { 30 }, 1) == true)
assert(runs[#runs].into == nil, "forgotten workspace is cleared on MBP")
assert(Slide.switch(extResized, 2, 3, { 20 }, { 30 }, 1) == true)
assert(runs[#runs].into == nil, "forgotten workspace is cleared on EXT")

-- 8. retile passes monitor, fullFrame, and wallpaperPath.
assert(Slide.retile(mbpShifted, { { wid = 10, from = { x = 0, y = 0, w = 100, h = 100 }, to = { x = 0, y = 0, w = 100, h = 100 } } }, noop) == true)
assert(retiles[#retiles].monitor == "MBP")
assert(retiles[#retiles].fullFrame.x == 2560 and retiles[#retiles].fullFrame.w == 1800)
assert(retiles[#retiles].wallpaperPath == "/Library/Desktop Pictures/MacBook.heic")

-- 9. Slide.stop stops pending wallpaper timer and calls native.forget().
forgets = {}
local lastTimer = timers[#timers]
Slide.stop()
assert(lastTimer.stopped == true, "Slide.stop cancels pending settle wallpaper timer")
assert(#forgets == 1 and forgets[1].key == nil and forgets[1].monitor == nil,
    "Slide.stop clears native caches")

print("Slide per-monitor cache tests passed")
