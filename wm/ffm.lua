-- wm/ffm.lua: Focus follows mouse.

local M = {}
package.loaded["wm.ffm"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Focus = require("wm.focus")

-- ---------------------------------------------------------------------------
-- Focus follows mouse
-- ---------------------------------------------------------------------------
--
-- Focus changes as soon as the pointer crosses into another standard window.
-- The last hovered window is remembered so ordinary movement inside one
-- window doesn't repeatedly walk the full window list or call :focus().

-- The window the pointer is waiting to focus; one reusable delayed timer
-- (restarted on each crossing) rather than a new timer per crossing.
local ffmPending = nil

-- Set while the screen is locked: the pointer still moves under the lock
-- screen, and focusing windows behind it leaves our record of focus wrong.
local locked = false

local function ffmFocusPending()
    local entry = ffmPending
    ffmPending = nil
    if not entry or S.dragState or locked
       or not Util.pointInFrame(hs.mouse.absolutePosition(), entry.frame)
       or Focus.snapshotEntryAt(hs.mouse.absolutePosition()) ~= entry then
        return
    end
    if S.ffmFocusedID ~= entry.id then
        -- The pointer is the user's say: it overrides any request of ours.
        S.intent = nil
        entry.win:focus()
    end
end

local function onMouseMoved(event)
    -- Keyboard warps already chose their target; the hover notification must
    -- not start a competing focus-follows-mouse request.
    if event:getProperty(hs.eventtap.event.properties.eventSourceUserData) == Util.WARP_MOUSE_EVENT then
        return false
    end
    if not S.cfg.focusFollowsMouse or S.dragState or locked then
        return false
    end

    local point = event:location()

    -- Fast path: still inside the same window (no accessibility calls).
    if S.ffmLastWindow and S.ffmSnapshot and Util.pointInFrame(point, S.ffmLastWindow.frame)
       and Focus.snapshotEntryAt(point) == S.ffmLastWindow then
        return false
    end

    local entry = Focus.snapshotEntryAt(point)
    S.ffmLastWindow = entry
    if not entry then
        return false
    end

    if S.ffmFocusedID ~= entry.id then
        -- Only focus once the pointer has settled, so skimming across
        -- windows doesn't flicker focus through each of them.
        ffmPending = entry
        S.running.ffmTimer:start()
    end

    return false
end

-- macOS restores focus as it likes on unlock, often without a focus event
-- for the window we last recorded. A stale record makes hover skip the
-- window that really needs focus, so read the real one back once it settles.
local resync = hs.timer.delayed.new(0.5, function()
    local actual = Util.focusedWindow()
    S.ffmFocusedID = actual and actual:id() or nil
    S.ffmLastWindow = nil
    Focus.invalidateWindowCache()
end)

local function onSessionEvent(event)
    local w = hs.caffeinate.watcher
    if event == w.screensDidLock or event == w.sessionDidResignActive then
        locked = true
        ffmPending = nil
        resync:stop()
    elseif event == w.screensDidUnlock or event == w.sessionDidBecomeActive then
        locked = false
        resync:start()
    end
end

-- Forgets the window waiting for the hover timer (reload, shutdown).
local function stop()
    ffmPending = nil
    locked = false
    resync:stop()
end

M.stop = stop
M.onSessionEvent = onSessionEvent
M.ffmFocusPending = ffmFocusPending
M.onMouseMoved = onMouseMoved

return M
