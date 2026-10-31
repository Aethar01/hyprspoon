-- hyprspoon/slide.lua: Workspaces sliding in and out as they switch, like Hyprland's.
--
-- The windows switch at once, as without this; a picture of the switch
-- slides over them and goes (hyprspoon.native.slide, hyprspoon/native/slide.m). Each
-- capture costs WindowServer about 40ms, so there's one per switch: the
-- windows of the workspace being left, kept to slide in with when it comes
-- back, if it still has the same windows on the same display then. Without
-- a picture to slide in, the one leaving slides off over the windows
-- already in place.
--
-- Scratchpads come up from an edge and go back to it, like Hyprland's
-- "slide bottom": going, one capture of their windows, kept for the next
-- time; coming, one of the workspace they cover, to slide over (their own
-- windows are already in place beneath).
--
-- A swipe (hyprspoon/swipe.lua) drags the slide with the fingers: one capture as
-- it starts, and the switch itself only once the fingers lift past halfway
-- (or flick), the spring carrying on from their speed.
--
-- Needs Screen Recording permission for Hammerspoon.

local M = {}
package.loaded["hyprspoon.slide"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")

-- The native module, loaded by M.start(); false if unavailable or off.
local native = false

-- Workspace number -> { ids = its windows, uuid = the display } when its
-- picture was taken.
local kept = {}

-- The key the picture of the workspace beneath a scratchpad is kept under.
local STILL = -1

-- The direction pictures come in from, per configured edge or axis
-- (1 along an axis: the next workspace comes from the right, or below).
local EDGES = {
    bottom = { 0, 1 }, top = { 0, -1 }, right = { 1, 0 }, left = { -1, 0 },
    horizontal = { 1, 0 }, vertical = { 0, 1 },
}

-- A swipe's slide while the fingers are down, and until when the switch
-- it ends in is already shown.
local pan = nil
local panShownUntil = 0

local function signature(ids)
    local list = {}
    for i, id in ipairs(ids) do list[i] = id end
    table.sort(list)
    return table.concat(list, ",")
end

local function rect(f)
    return { x = f.x, y = f.y, w = f.w, h = f.h }
end

-- Takes workspace `n`'s windows `ids` on `screen` into its kept picture
-- (key `key`, `n` by default); true if there was anything to take.
local function take(n, ids, screen, key)
    local took = #ids > 0 and native.capture(key or n, ids)
    if not key then kept[n] = took and { ids = signature(ids), uuid = screen:getUUID() } or nil end
    return took
end

-- Whether workspace `n`'s picture shows it with the windows `ids`, on `screen`.
local function current(n, ids, screen)
    local k = kept[n]
    return k ~= nil and k.ids == signature(ids) and k.uuid == screen:getUUID()
end

-- The slide over `screen`'s usable area, with the configured spring.
local function slide(screen, t)
    local cfg = S.cfg.slide
    local mode = screen:currentMode()
    t.frame = rect(screen:frame())
    t.scale = mode and mode.scale or 1
    t.mass, t.stiffness, t.damping = cfg.mass, cfg.stiffness, cfg.damping
    t.wallpaperAge = cfg.wallpaperRefresh or 0
    return t
end

-- The direction for edge or axis `name`, times `sign`; nil when off.
local function toward(name, sign)
    local e = name and EDGES[name]
    if not e then return nil end
    return e[1] * sign, e[2] * sign
end

-- Display `screen` goes from workspace `from` (showing `outIds`) to `to`
-- (with `inIds`), `dir` 1 if `to` comes after `from`, -1 before. Call
-- before the windows move: it waits for the capture. True if a slide
-- covers the switch (this one, or the swipe's that just showed it).
function M.switch(screen, from, to, outIds, inIds, dir)
    if not native or not screen then return false end
    if hs.timer.secondsSinceEpoch() < panShownUntil then
        panShownUntil = 0
        return true
    end
    local dx, dy = toward(S.cfg.slide.workspaces, dir)
    if not dx then return false end
    local took = from and take(from, outIds, screen)
    local into = current(to, inIds, screen) and to or nil
    if not took and not into then return false end
    native.run(slide(screen, {
        out = took and from or nil,
        into = into,
        dx = dx,
        dy = dy,
        -- Over the wallpaper when sliding a picture in: the windows it
        -- shows are already in place beneath.
        backdrop = into ~= nil,
    }))
    return true
end

-- Scratchpad `n` (with `ids`) comes up over the workspace showing on
-- `screen` (with `baseIds`). Call before its windows move.
function M.showScratchpad(screen, n, ids, baseIds)
    if not native or not screen or not current(n, ids, screen) then return end
    local dx, dy = toward(S.cfg.slide.scratchpads, 1)
    if not dx then return end
    local still = take(nil, baseIds, screen, STILL)
    native.run(slide(screen, { into = n, still = still and STILL or nil, dx = dx, dy = dy, backdrop = true }))
end

-- Scratchpad `n` (with `ids`) goes back off `screen`, over the workspace
-- beneath. Call before its windows move.
function M.hideScratchpad(screen, n, ids)
    if not native or not screen then return end
    local dx, dy = toward(S.cfg.slide.scratchpads, -1)
    if not dx then return end
    if take(n, ids, screen) then native.run(slide(screen, { out = n, dx = dx, dy = dy })) end
end

-- Whether swipes can drag a slide.
function M.canPan()
    return native and toward(S.cfg.slide.workspaces, 1) ~= nil
end

-- A swipe on `screen` starts from workspace `from` (showing `outIds`)
-- towards `to` (with `inIds`), `dir` as for M.switch: the slide goes up,
-- unmoved. True if it shows anything.
function M.beginPan(screen, from, to, outIds, inIds, dir)
    pan = nil
    if not M.canPan() or not screen then return false end
    local dx, dy = toward(S.cfg.slide.workspaces, dir)
    local took = take(from, outIds, screen)
    local into = current(to, inIds, screen) and to or nil
    if not took and not into then return false end
    -- Always over the wallpaper: the windows leaving are still beneath.
    if native.begin(slide(screen, { out = took and from or nil, into = into, dx = dx, dy = dy, backdrop = true })) then
        pan = true
    end
    return pan == true
end

-- The swipe's slide is `progress` of the way along (0 to 1).
function M.trackPan(progress)
    if pan then native.track(progress) end
end

-- The fingers lifted: the slide springs on and the switch follows straight
-- after (`commit`), or it springs back. `velocity` is in progress per second.
function M.endPan(commit, velocity)
    if not pan then return end
    pan = nil
    native.finish(commit and 1 or 0, velocity or 0)
    if commit then panShownUntil = hs.timer.secondsSinceEpoch() + 0.5 end
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
