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

-- True while the session is behind the lock screen (or another user's).
-- Asked of the system rather than tracked from events: after sleeping while
-- locked the unlock notification isn't reliably delivered, and a missed one
-- would leave hover focus paused for good.
local function sessionLocked()
    local props = hs.caffeinate.sessionProperties()
    if not props then return false end
    return props.CGSSessionScreenIsLocked == true or props.kCGSSessionOnConsoleKey == false
end

-- macOS restores focus as it likes on unlock, often without a focus event
-- for the window we last recorded. A stale record makes hover skip the
-- window that really needs focus, so read the real one back. After a wake
-- apps are reactivated and windows moved back onto displays for seconds
-- afterwards, so look again a few times.
local resyncTimers = {}

local function stopResync()
    for _, t in ipairs(resyncTimers) do t:stop() end
    resyncTimers = {}
end

local function resyncFocus()
    local actual = Util.focusedWindow()
    S.ffmFocusedID = actual and actual:id() or nil
    S.ffmLastWindow = nil
    Focus.invalidateWindowCache()
end

local function unlock()
    locked = false
    stopResync()
    for i, delay in ipairs({ 0.5, 1.5, 3 }) do
        resyncTimers[i] = hs.timer.doAfter(delay, resyncFocus)
    end
end

local function ffmFocusPending()
    local entry = ffmPending
    ffmPending = nil
    if not entry or S.dragState or locked or S.spaceFocusPending
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
    -- Mid Space switch the snapshot still holds the old Space's windows.
    if not S.cfg.focusFollowsMouse or S.dragState or S.spaceFocusPending then
        return false
    end
    -- The pointer moving is the surest sign the lock screen has gone, even
    -- when no unlock notification came.
    if locked then
        if sessionLocked() then return false end
        unlock()
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

local function onSessionEvent(event)
    local w = hs.caffeinate.watcher
    if event == w.screensDidLock or event == w.sessionDidResignActive
       or event == w.systemWillSleep or event == w.screensDidSleep then
        locked = true
        ffmPending = nil
        stopResync()
    elseif event == w.screensDidUnlock or event == w.sessionDidBecomeActive
       or event == w.systemDidWake or event == w.screensDidWake then
        -- Waking shows the lock screen first; stay paused until it's gone.
        if not sessionLocked() then unlock() end
    end
end

-- Forgets the window waiting for the hover timer (reload, shutdown).
local function stop()
    ffmPending = nil
    locked = false
    stopResync()
end

M.stop = stop
M.onSessionEvent = onSessionEvent
M.ffmFocusPending = ffmFocusPending
M.onMouseMoved = onMouseMoved

return M
