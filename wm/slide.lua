-- wm/slide.lua: Workspaces sliding in and out as they switch, like Hyprland's.
--
-- The windows switch at once, as without this; a picture of the switch
-- slides over them and goes (wm.native.slide, wm/native/slide.m). Each
-- capture costs WindowServer about 40ms, so there's one per switch: the
-- windows of the workspace being left, kept to slide in with when it comes
-- back, if it still has the same windows then. Without a picture to slide
-- in, the one leaving slides off over the windows already in place.
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

local function signature(ids)
    local list = {}
    for i, id in ipairs(ids) do list[i] = id end
    table.sort(list)
    return table.concat(list, ",")
end

local function rect(f)
    return { x = f.x, y = f.y, w = f.w, h = f.h }
end

-- Display `screen` goes from workspace `from` (showing `outIds`) to `to`
-- (with `inIds`), `dx` 1 if `to` comes in from the right, -1 from the left.
-- Call before the windows move: it waits for the capture.
function M.switch(screen, from, to, outIds, inIds, dx)
    if not native or not screen then return end
    local took = from and #outIds > 0 and native.capture(from, outIds)
    if from then kept[from] = took and signature(outIds) or nil end
    local into = kept[to] and kept[to] == signature(inIds) and to or nil
    if not took and not into then return end
    local cfg = S.cfg.slide
    local mode = screen:currentMode()
    native.run({
        frame = rect(screen:frame()),
        scale = mode and mode.scale or 1,
        out = took and from or nil,
        into = into,
        dx = dx,
        dy = 0,
        -- Over the wallpaper when sliding a picture in: the windows it
        -- shows are already in place beneath.
        backdrop = into ~= nil,
        mass = cfg.mass,
        stiffness = cfg.stiffness,
        damping = cfg.damping,
    })
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
