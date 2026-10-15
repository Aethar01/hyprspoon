-- wm/focus.lua: Internal focus tracking and the window snapshot used for hit testing.

local M = {}
package.loaded["wm.focus"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")

-- ---------------------------------------------------------------------------
-- Internal focus
-- ---------------------------------------------------------------------------
--
-- Focus is recorded when macOS reports it *and* when we ask for it, so the
-- model is right immediately after our own actions. If macOS then moves focus
-- elsewhere within REASSERT_WINDOW of one of our requests (it does this when
-- windows close or open), the request is re-applied.

local REASSERT_WINDOW = 0.4
S.intent = nil -- { id =, time = } for our most recent focus request
S.requestedFocus = nil -- id of our latest win:focus(), until macOS confirms
local focusCheck = nil

-- A snapshot of standard, visible window frames in z-order, shared by focus
-- follows mouse (so mouse movement never makes accessibility calls), hit
-- testing and directional focus. It is dropped whenever windows move, appear,
-- disappear or change focus.
S.ffmLastWindow = nil   -- snapshot entry under the pointer
S.ffmSnapshot = nil
S.ffmFocusedID = nil    -- tracked from windowFocused, avoids an AX query

local function noteFocus(win)
    local id = win:id()
    if not id then return end
    for i = #Util.focusHistory, 1, -1 do
        if Util.focusHistory[i] == id then table.remove(Util.focusHistory, i) end
    end
    table.insert(Util.focusHistory, 1, id)
    local dropped = Util.focusHistory[21]
    Util.focusHistory[21] = nil
    if dropped then Util.focusTimes[dropped] = nil end
    Util.focusTimes[id] = hs.timer.secondsSinceEpoch()
    Util.winByID[id] = Util.winByID[id] or win
    S.ffmFocusedID = id
end

-- Focus a window on our own initiative.
local function focus(win)
    if not win then return end
    -- Nothing to defend if it's already focused (no focus event would clear
    -- the request, and it would then undo the next thing the user does).
    if S.cfg.reassertFocus and S.ffmFocusedID ~= win:id() then
        S.intent = { id = win:id(), time = hs.timer.secondsSinceEpoch() }
    end
    noteFocus(win)
    S.requestedFocus = win:id()
    win:focus()
    -- If macOS never reports the focus (an unresponsive app), our record would
    -- stay wrong and focus-follows-mouse would skip that window. Check once.
    if not focusCheck then
        focusCheck = hs.timer.delayed.new(0.5, function()
            if S.requestedFocus then
                local actual = Util.focusedWindow()
                S.ffmFocusedID = actual and actual:id() or nil
                S.requestedFocus = nil
            end
        end)
    end
    focusCheck:start()
end

-- The window actions apply to: our own record of focus, falling back to
-- macOS's when an app we don't track (ignored apps) is frontmost.
local function currentWindow()
    local actual
    if S.running.pipFilter and #S.running.pipFilter:getWindows() > 0 then
        actual = Util.focusedWindow()
        if Util.isPictureInPicture(actual) then return nil end
    end
    local id = Util.focusHistory[1]
    local win = id and Util.winByID[id]
    if win and win:id() == id then
        local front = hs.application.frontmostApplication()
        local pid = Util.pidByID[id]
        if front and pid and front:pid() == pid then return win end
    end
    return actual or Util.focusedWindow()
end

-- Rebuilds the snapshot shortly after invalidations go quiet, so the next
-- mouse move doesn't pay for several accessibility calls per window.
S.ffmPrebuild = nil

local function invalidateWindowCache()
    S.ffmSnapshot = nil
    S.ffmLastWindow = nil
    if S.ffmPrebuild then S.ffmPrebuild:start() end
end

-- `fresh` rebuilds the snapshot even if it hasn't expired, for callers that
-- run rarely and need to be right (or run just after a Space switch).
local function windowSnapshot(fresh)
    local now = hs.timer.secondsSinceEpoch()
    if fresh or not S.ffmSnapshot or now - S.ffmSnapshot.time > Util.FFM_SNAPSHOT_TTL then
        local entries = {}
        -- PiP is an unmanaged overlay: remember its bounds solely so hover
        -- focus doesn't steal focus for the tile underneath it.
        local unmanaged = {}
        if S.running.pipFilter then
            for _, win in ipairs(S.running.pipFilter:getWindows() or {}) do
                unmanaged[#unmanaged + 1] = win:frame()
            end
        end
        -- orderedWindows() enumerates every app over AX, even though the
        -- filter already tracks our visible, standard windows. WindowServer
        -- supplies live stacking order and floating geometry in one call.
        if S.running.windowFilter then
            local byID, seen = {}, {}
            local disjointTiles = true
            for _, win in ipairs(Util.managedWindows()) do
                local id = win:id()
                if id then
                    byID[id] = win
                    local tile = Tree.rectFor(id)
                    if tile and not S.autoFloat[id] then
                        for _, entry in ipairs(entries) do
                            local f = entry.frame
                            if tile.x < f.x + f.w and f.x < tile.x + tile.w
                               and tile.y < f.y + f.h and f.y < tile.y + tile.h then
                                disjointTiles = false
                            end
                        end
                        entries[#entries + 1] = { win = win, id = id, frame = tile }
                    else
                        disjointTiles = false
                    end
                end
            end
            -- Non-overlapping tiles need no stacking-order query at all.
            if disjointTiles then
                S.ffmSnapshot = { time = now, entries = entries, unmanaged = unmanaged }
                return entries
            end
            entries = {}
            for _, info in ipairs(hs.window.list(true)) do
                local id = info.kCGWindowNumber
                local win = byID[id]
                if win then
                    local b = info.kCGWindowBounds
                    local frame = Tree.rectFor(id) or hs.geometry.rect(b.X, b.Y, b.Width, b.Height)
                    entries[#entries + 1] = { win = win, id = id, frame = frame }
                    seen[id] = true
                end
            end
            -- Some accessory windows don't appear in WindowServer's list.
            for id, win in pairs(byID) do
                if S.autoFloat[id] and not seen[id] then
                    table.insert(entries, { win = win, id = id, frame = win:frame() })
                end
            end
        end
        S.ffmSnapshot = { time = now, entries = entries, unmanaged = unmanaged }
    end
    return S.ffmSnapshot.entries
end

S.ffmPrebuild = hs.timer.delayed.new(0.15, function()
    if S.ffmSnapshot or S.dragState or not S.cfg.focusFollowsMouse then return end
    -- Our own layout is still echoing back; wait for it to go quiet.
    if hs.timer.secondsSinceEpoch() < S.settleUntil then
        S.ffmPrebuild:start()
        return
    end
    windowSnapshot(true)
end)

-- Floats are meant to sit on top, so they win over whatever tile is actually
-- stacked above them (a buried float is still reachable). The exception is
-- a float under a window of its own app: the app ordered them (floats of the
-- focused app aren't re-raised), and the window the user sees wins.
local function snapshotEntryAt(point, fresh)
    local entries = windowSnapshot(fresh)
    for _, frame in ipairs(S.ffmSnapshot.unmanaged or {}) do
        if Util.pointInFrame(point, frame) then return nil end
    end
    local top = nil
    for _, entry in ipairs(entries) do
        if Util.pointInFrame(point, entry.frame) then top = entry break end
    end
    if not top or S.autoFloat[top.id] then return top end
    for _, entry in ipairs(entries) do
        if S.autoFloat[entry.id] and Util.pointInFrame(point, entry.frame)
           and entry.win:pid() ~= top.win:pid() then
            return entry
        end
    end
    return top
end

local function windowUnderPoint(point, fresh)
    local entry = snapshotEntryAt(point, fresh)
    return entry and entry.win
end

-- Stops the delayed timers. The prebuild timer is created once at load, so it
-- is stopped but kept. 
local function stop()
    if S.ffmPrebuild then S.ffmPrebuild:stop() end
    if focusCheck then focusCheck:stop() end
end

M.stop = stop
M.REASSERT_WINDOW = REASSERT_WINDOW
M.noteFocus = noteFocus
M.focus = focus
M.currentWindow = currentWindow
M.invalidateWindowCache = invalidateWindowCache
M.windowSnapshot = windowSnapshot
M.snapshotEntryAt = snapshotEntryAt
M.windowUnderPoint = windowUnderPoint

return M
