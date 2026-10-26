-- wm/slide.lua: Workspaces sliding in and out as they switch, like Hyprland's.
--
-- The windows switch at once, as without this; a picture of the switch
-- slides over them and goes (wm.native.slide, wm/native/slide.m). Each
-- capture costs WindowServer about 40ms, so there's one per switch: the
-- windows of the workspace being left, kept to slide in with when it comes
-- back, if it still has the same windows then. Without a picture to slide
-- in, the one leaving slides off over the windows already in place.
--
-- Scratchpads come up from the bottom and go back down, like Hyprland's
-- "slide bottom": going, one capture of their windows, kept for the next
-- time; coming, one of the workspace they cover, to slide over (their own
-- windows are already in place beneath).
--
-- Needs Screen Recording permission for Hammerspoon.

local M = {}
package.loaded["wm.slide"] = M

local S = require("wm.state")
local Util = require("wm.util")

-- The native module, loaded by M.start(); false if unavailable or off.
local native = false

-- Workspace number -> its windows when its picture was taken.
local kept = {}

-- The key the picture of the workspace beneath a scratchpad is kept under.
local STILL = -1

local function signature(ids)
    local list = {}
    for i, id in ipairs(ids) do list[i] = id end
    table.sort(list)
    return table.concat(list, ",")
end

local function rect(f)
    return { x = f.x, y = f.y, w = f.w, h = f.h }
end

-- Whether workspace `n`'s picture shows it with the windows `ids`.
local function current(n, ids)
    return kept[n] ~= nil and kept[n] == signature(ids)
end

-- Runs a slide over `screen`'s usable area, with the configured spring.
local function play(screen, slide)
    local cfg = S.cfg.slide
    local mode = screen:currentMode()
    slide.frame = rect(screen:frame())
    slide.scale = mode and mode.scale or 1
    slide.mass, slide.stiffness, slide.damping = cfg.mass, cfg.stiffness, cfg.damping
    native.run(slide)
end

-- Display `screen` goes from workspace `from` (showing `outIds`) to `to`
-- (with `inIds`), `dx` 1 if `to` comes in from the right, -1 from the left.
-- Call before the windows move: it waits for the capture.
function M.switch(screen, from, to, outIds, inIds, dx)
    if not native or not screen then return end
    local took = from and #outIds > 0 and native.capture(from, outIds)
    if from then kept[from] = took and signature(outIds) or nil end
    local into = current(to, inIds) and to or nil
    if not took and not into then return end
    play(screen, {
        out = took and from or nil,
        into = into,
        dx = dx,
        -- Over the wallpaper when sliding a picture in: the windows it
        -- shows are already in place beneath.
        backdrop = into ~= nil,
    })
end

-- Scratchpad `n` (with `ids`) comes up over the workspace showing on
-- `screen` (with `baseIds`). Call before its windows move.
function M.showScratchpad(screen, n, ids, baseIds)
    if not native or not screen or not current(n, ids) then return end
    local still = #baseIds > 0 and native.capture(STILL, baseIds)
    play(screen, { into = n, still = still and STILL or nil, dy = 1, backdrop = true })
end

-- Scratchpad `n` (with `ids`) goes back down off `screen`, over the
-- workspace beneath. Call before its windows move.
function M.hideScratchpad(screen, n, ids)
    if not native or not screen then return end
    local took = #ids > 0 and native.capture(n, ids)
    kept[n] = took and signature(ids) or nil
    if took then play(screen, { out = n, dy = -1 }) end
end

-- Workspace `n` is gone: its picture with it.
function M.forget(n)
    if native and kept[n] then
        kept[n] = nil
        native.forget(n)
    end
end

-- Displays changed: every picture is out of place.
function M.reset()
    if not native then return end
    kept = {}
    native.forget()
    for _, screen in ipairs(hs.screen.allScreens()) do native.wallpaper(rect(screen:fullFrame())) end
end

function M.start()
    if not S.cfg.slide then return end
    native = Util.native("slide") or false
    M.reset()
end

return M
