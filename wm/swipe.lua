-- wm/swipe.lua: Trackpad swipes between workspaces.

local M = {}
package.loaded["wm.swipe"] = M

local S = require("wm.state")
local Spaces = require("wm.spaces")
local Slide = require("wm.slide")

-- ---------------------------------------------------------------------------
-- Swipes
-- ---------------------------------------------------------------------------
--
-- Moving `S.cfg.swipe.fingers` fingers sideways goes to the next or previous
-- workspace on the display under the pointer: fingers moving left go to the
-- next one, like macOS's Desktop swipe. Mostly sideways counts; lifting,
-- adding or removing a finger ends the swipe.
--
-- With workspace slides (wm/slide.lua) and `follow`, the workspaces move
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
    if n ~= cfg.fingers then
        lifted(swipe)
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

    if s.following then
        local p = clamp((s.x0 - x) * s.dir / cfg.span, 0, 1)
        s.progress = p
        s.samples[#s.samples + 1] = { t = hs.timer.secondsSinceEpoch(), p = p }
        if #s.samples > 8 then table.remove(s.samples, 1) end
        if s.ready and not s.ended then Slide.trackPan(p) end
        return false
    end
    if s.fired then return false end

    if cfg.follow and Slide.canPan() then
        if math.abs(dx) >= START and math.abs(dx) > 2 * math.abs(dy) then
            s.dir = dx < 0 and 1 or -1
            s.x0, s.progress, s.samples, s.following = x, 0, {}, true
            -- Switching makes accessibility calls; a slow app must not hold
            -- up the event tap (macOS disables taps that take too long).
            hs.timer.doAfter(0, function()
                s.started = true
                begin(s)
            end)
        end
    elseif math.abs(dx) >= cfg.distance and math.abs(dx) > 2 * math.abs(dy) then
        s.fired = true
        local delta = dx < 0 and 1 or -1
        hs.timer.doAfter(0, function() Spaces.gotoWorkspaceRelative(delta) end)
    end
    return false
end

-- Forgets a swipe in progress (reload, shutdown).
local function stop()
    swipe = nil
end

M.stop = stop
M.onGesture = onGesture

return M
