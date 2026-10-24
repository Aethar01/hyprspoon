-- wm/swipe.lua: Trackpad swipes between workspaces.

local M = {}
package.loaded["wm.swipe"] = M

local S = require("wm.state")
local Spaces = require("wm.spaces")

-- ---------------------------------------------------------------------------
-- Swipes
-- ---------------------------------------------------------------------------
--
-- Moving `S.cfg.swipe.fingers` fingers sideways goes to the next or previous
-- workspace on the display under the pointer: fingers moving left go to the
-- next one, like macOS's Desktop swipe. It fires once per swipe, as soon as
-- the fingers have travelled `distance` of the trackpad's width, mostly
-- sideways; lifting, adding or removing a finger starts over.
--
-- macOS sees the same touches, so its own swipe with that many fingers
-- (System Settings > Trackpad > More Gestures > Swipe between full-screen
-- applications) has to use another number of fingers or be off.

-- Where the fingers were when the swipe started, and whether it has fired.
local swipe = nil

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
    if n ~= S.cfg.swipe.fingers then
        swipe = nil
        return false
    end

    local x, y = sumX / n, sumY / n
    if not swipe then
        swipe = { x = x, y = y, fired = false }
        return false
    end
    if swipe.fired then return false end

    local dx, dy = x - swipe.x, y - swipe.y
    if math.abs(dx) >= S.cfg.swipe.distance and math.abs(dx) > 2 * math.abs(dy) then
        swipe.fired = true
        -- Switching makes accessibility calls; a slow app must not hold up
        -- the event tap (macOS disables taps that take too long).
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
