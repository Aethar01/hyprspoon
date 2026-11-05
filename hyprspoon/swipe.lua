-- hyprspoon/swipe.lua: Trackpad swipes between workspaces.

local M = {}
package.loaded["hyprspoon.swipe"] = M

local S = require("hyprspoon.state")
local Spaces = require("hyprspoon.spaces")
local Slide = require("hyprspoon.slide")
local Scroll = require("hyprspoon.scroll")

-- ---------------------------------------------------------------------------
-- Swipes
-- ---------------------------------------------------------------------------
--
-- Moving `S.cfg.swipe.fingers` fingers sideways goes to the next or previous
-- workspace on the display under the pointer: fingers moving left go to the
-- next one, like macOS's Desktop swipe. Mostly sideways counts; lifting,
-- adding or removing a finger ends the swipe.
--
-- With workspace slides (hyprspoon/slide.lua) and `follow`, the workspaces move
-- with the fingers, `span` of the trackpad's width moving a whole one; on
-- lifting, past halfway or a flick that way switches, else they spring
-- back. Otherwise it switches once the fingers have travelled `distance`.
--
-- macOS sees the same touches, so its own swipe with that many fingers
-- (System Settings > Trackpad > More Gestures > Swipe between full-screen
-- applications) has to use another number of fingers or be off.

-- How far the fingers go, mostly sideways, before a swipe follows them.
local START = 0.015

-- Progress per second that counts as a flick.
local FLICK = 1.5

-- The swipe in progress: where the fingers started, and once it has a
-- direction (`dir`, 1 for the next workspace) where they were then (`x0`),
-- the slide's progress and recent samples of it, whether its slide is up
-- (`ready`), and whether the fingers have lifted (`ended`).
local swipe = nil

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- Progress per second over the last few samples.
local function velocity(s)
    local samples = s.samples
    local last = samples[#samples]
    if not last then return 0 end
    for i = #samples - 1, 1, -1 do
        local dt = last.t - samples[i].t
        if dt >= 0.03 or i == 1 then
            return dt > 0 and (last.p - samples[i].p) / dt or 0
        end
    end
    return 0
end

-- The fingers lifted with the slide up: switch, or spring back.
local function settle(s)
    local v = velocity(s)
    local commit = s.target ~= nil and (s.progress > 0.5 or v > FLICK) and v > -FLICK
    if s.ready then Slide.endPan(commit, v) end
    if commit then Spaces.gotoWorkspace(s.target) end
end

-- Puts the slide up (a capture, so not in the event tap).
local function begin(s)
    local screen, from, to, outIds, inIds = Spaces.neighbor(s.dir)
    s.target = to
    if to then s.ready = Slide.beginPan(screen, from, to, outIds, inIds, s.dir) end
    if s.ended then
        settle(s)
    elseif s.ready then
        Slide.trackPan(s.progress)
    end
end

local function lifted(s)
    if not s or not s.dir or not s.following or s.ended then return end
    s.ended = true
    if s.started then hs.timer.doAfter(0, function() settle(s) end) end
end

-- The axis workspaces are swiped along: `swipe.direction`, else the
-- workspaces' slide's ("vertical": fingers up for the next workspace).
local function axis()
    local d = S.cfg.swipe and S.cfg.swipe.direction
    if d then return d end
    return S.cfg.slide and S.cfg.slide.workspaces == "vertical" and "vertical" or "horizontal"
end

-- How far along the workspace axis fingers at x, y are, increasing
-- towards the next workspace.
local function along(x, y)
    if axis() == "vertical" then return y, x end
    return -x, y
end

-- A swipe scrolling columns (hyprspoon/scroll.lua) lifted.
local function scrollLifted(s)
    local v = velocity(s)
    local key = s.scroll
    hs.timer.doAfter(0, function() Scroll.panEnd(key, v) end)
end

local function onGesture(event)
    local touches = event:getTouches()
    if not touches then return false end

    local n, sumX, sumY = 0, 0, 0
    for _, touch in ipairs(touches) do
        if touch.touching and touch.phase ~= "ended" and touch.phase ~= "cancelled" then
            n = n + 1
            sumX = sumX + touch.normalizedPosition.x
            sumY = sumY + touch.normalizedPosition.y
        end
    end
    local cfg = S.cfg.swipe
    local workspaces = cfg and n == cfg.fingers
    -- Sideways swipes scroll columns, unless they switch workspaces.
    local columns = n == Scroll.swipeFingers() and not (workspaces and axis() == "horizontal")
    if not workspaces and not columns then
        if swipe and swipe.scroll then
            scrollLifted(swipe)
        else
            lifted(swipe)
        end
        swipe = nil
        return false
    end

    local x, y = sumX / n, sumY / n
    if not swipe then
        swipe = { x = x, y = y, fired = false }
        return false
    end
    local s = swipe
    local dx, dy = x - s.x, y - s.y

    if s.scroll then
        local p = s.x0 - x
        s.samples[#s.samples + 1] = { t = hs.timer.secondsSinceEpoch(), p = p / Scroll.swipeSpan() }
        if #s.samples > 8 then table.remove(s.samples, 1) end
        Scroll.panTo(s.scroll, s.view0, p)
        return false
    end
    if s.following then
        local p = clamp((along(x, y) - s.a0) * s.dir / cfg.span, 0, 1)
        s.progress = p
        s.samples[#s.samples + 1] = { t = hs.timer.secondsSinceEpoch(), p = p }
        if #s.samples > 8 then table.remove(s.samples, 1) end
        if s.ready and not s.ended then Slide.trackPan(p) end
        return false
    end
    if s.fired then return false end

    if columns and math.abs(dx) >= START and math.abs(dx) > 2 * math.abs(dy) then
        local key, view0 = Scroll.panBegin(hs.mouse.getCurrentScreen())
        if key then
            -- From where the fingers first touched, so the columns keep up.
            s.scroll, s.view0, s.x0, s.samples = key, view0, s.x, {}
            Scroll.panTo(key, view0, s.x0 - x)
            return false
        end
        if not workspaces then
            s.fired = true
            return false
        end
    end
    if not workspaces then return false end

    local da, db = along(x, y)
    local a0, b0 = along(s.x, s.y)
    da, db = da - a0, db - b0
    if cfg.follow and Slide.canPan() then
        if math.abs(da) >= START and math.abs(da) > 2 * math.abs(db) then
            s.dir = da > 0 and 1 or -1
            s.a0, s.progress, s.samples, s.following = along(x, y), 0, {}, true
            -- Switching makes accessibility calls; a slow app must not hold
            -- up the event tap (macOS disables taps that take too long).
            hs.timer.doAfter(0, function()
                s.started = true
                begin(s)
            end)
        end
    elseif math.abs(da) >= cfg.distance and math.abs(da) > 2 * math.abs(db) then
        s.fired = true
        local delta = da > 0 and 1 or -1
        hs.timer.doAfter(0, function() Spaces.gotoWorkspaceRelative(delta) end)
    end
    return false
end

-- Forgets a swipe in progress (reload, shutdown).
local function stop()
    if swipe and swipe.scroll then Scroll.panEnd(swipe.scroll, 0) end
    swipe = nil
end

M.stop = stop
M.onGesture = onGesture

return M
