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
-- With wm.native.hover that happens outside Lua: its tap resolves the
-- window under the pointer from the snapshot (handed over as Focus builds
-- it) and calls onPointer only when that window changes.

-- The window the pointer is waiting to focus; one reusable delayed timer
-- (restarted on each crossing) rather than a new timer per crossing.
local ffmPending = nil

-- Set while the screen is locked: the pointer still moves under the lock
-- screen, and focusing windows behind it leaves our record of focus wrong.
local locked = false

local hover = nil -- wm.native.hover, once started

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
    if hover then hover.forget() end
    stopResync()
    for i, delay in ipairs({ 0.5, 1.5, 3 }) do
        resyncTimers[i] = hs.timer.doAfter(delay, resyncFocus)
    end
end

-- Whether the pointer is over a menu or popup rather than the window
-- `entry` under it: a context menu reaching past its window, a menu bar
-- menu, a dropdown or anything else kept above the windows, or a window
-- the focused app drew that we don't manage (its own popups). Focusing the
-- window underneath would close it. Asked of WindowServer only as focus is
-- about to change, and only with wm.native.hover.
local function overPopup(point, entry)
    if not hover then return false end
    local id, pid, layer = hover.topAt(point.x, point.y)
    if not id or id == entry.id or Util.windowKinds[id] == "standard"
       or Util.windowKinds[id] == "subwindow" then
        return false
    end
    if layer > 0 then return true end
    local focusedPid = S.ffmFocusedID and Util.pidByID[S.ffmFocusedID]
    return focusedPid ~= nil and pid == focusedPid
end

local function ffmFocusPending()
    local entry = ffmPending
    ffmPending = nil
    if not entry or S.dragState or locked
       or not Util.pointInFrame(hs.mouse.absolutePosition(), entry.frame) then
        return
    end
    -- By id: the snapshot may have been rebuilt since.
    local point = hs.mouse.absolutePosition()
    local under = Focus.snapshotEntryAt(point)
    if not under or under.id ~= entry.id then return end
    if S.ffmFocusedID ~= entry.id and overPopup(point, entry) then
        -- Report the next move even over the same window: once the menu
        -- has gone, it focuses as usual.
        S.ffmLastWindow = nil
        hover.forget()
        return
    end
    if S.ffmFocusedID ~= entry.id then
        -- The pointer is the user's say: it overrides any request of ours.
        S.intent = nil
        Focus.request(entry.win)
    end
end

-- The pointer is at `point`, over a window other than last time (or we
-- can't tell: no snapshot).
local function onPointer(point)
    if not S.cfg.focusFollowsMouse or S.dragState or S.overviewOpen then return end
    -- The pointer moving is the surest sign the lock screen has gone, even
    -- when no unlock notification came.
    if locked then
        if sessionLocked() then return end
        unlock()
    end

    local entry = Focus.snapshotEntryAt(point)
    S.ffmLastWindow = entry
    if entry and S.ffmFocusedID ~= entry.id then
        -- Only focus once the pointer has settled, so skimming across
        -- windows doesn't flicker focus through each of them.
        ffmPending = entry
        S.running.ffmTimer:start()
    end
end

-- Every pointer movement, without wm.native.hover.
local function onMouseMoved(event)
    -- Keyboard warps already chose their target; the hover notification must
    -- not start a competing focus-follows-mouse request.
    if event:getProperty(hs.eventtap.event.properties.eventSourceUserData) == Util.WARP_MOUSE_EVENT then
        return false
    end
    if not S.cfg.focusFollowsMouse or S.dragState then
        return false
    end

    local point = event:location()

    -- Fast path: still inside the same window (no accessibility calls).
    if not locked and S.ffmLastWindow and S.ffmSnapshot and Util.pointInFrame(point, S.ffmLastWindow.frame)
       and Focus.snapshotEntryAt(point) == S.ffmLastWindow then
        return false
    end

    onPointer(point)
    return false
end

-- The snapshot Focus just built, for wm.native.hover to look windows up in.
-- Not while locked: every movement must reach onPointer then.
local function snapshotBuilt(entries, unmanaged)
    if not hover or locked then return end
    local list = {}
    for i, entry in ipairs(entries) do
        local f = entry.frame
        list[i] = {
            id = entry.id,
            pid = Util.pidByID[entry.id] or entry.win:pid(),
            floating = S.autoFloat[entry.id] == true,
            frame = { x = f.x, y = f.y, w = f.w, h = f.h },
        }
    end
    local frames = {}
    for i, f in ipairs(unmanaged or {}) do frames[i] = { x = f.x, y = f.y, w = f.w, h = f.h } end
    hover.snapshot(list, frames, Util.FFM_SNAPSHOT_TTL)
end

-- The snapshot is out of date.
local function snapshotDropped()
    if hover then hover.invalidate() end
end

-- Watches the pointer: natively if wm.native.hover is built, else with an
-- event tap calling onMouseMoved.
local function start()
    local native = Util.native("hover")
    if native and native.start(function(x, y) onPointer({ x = x, y = y }) end, Util.WARP_MOUSE_EVENT) then
        hover = native
        return
    end
    S.running.moveTap = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, onMouseMoved):start()
end

local function onSessionEvent(event)
    local w = hs.caffeinate.watcher
    if event == w.screensDidLock or event == w.sessionDidResignActive
       or event == w.systemWillSleep or event == w.screensDidSleep then
        locked = true
        snapshotDropped()
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
    if hover then hover.stop() end
    hover = nil
end

M.start = start
M.stop = stop
M.snapshotBuilt = snapshotBuilt
M.snapshotDropped = snapshotDropped
M.onSessionEvent = onSessionEvent
M.ffmFocusPending = ffmFocusPending
M.onMouseMoved = onMouseMoved

return M
