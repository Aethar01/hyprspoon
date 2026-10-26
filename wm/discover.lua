-- wm/discover.lua: Finding the manageable windows on each screen.

local M = {}
package.loaded["wm.discover"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")
local Float = require("wm.float")
local Spaces = require("wm.spaces")

-- Each window's screen and fullscreen state, cached per window id: both are
-- accessibility calls and change only when the window moves or goes
-- fullscreen (events drop the entry), or on a forced retile (Space/display
-- changes drop everything).
S.windowInfo = {}

-- Windows known to be full screen (window id -> true), from the filter's
-- events and these lookups: by the time the filter reports a window leaving
-- its full-screen Space, the window no longer says it's full screen.
S.fullscreen = {}

-- Windows the filter last reported as off the current macOS Space.
S.offSpace = {}

-- The rect each window was last laid out to ("x,y,w,h"). A window known to be
-- in place isn't asked for its frame again; entries are dropped when the
-- window moves on its own (windowMoved outside our settle period), when the
-- user adjusts it, and on forced retiles.
S.applied = {}
local layoutChecks = {} -- window id -> pending frame verification

local function cancelLayoutCheck(id)
    local pending = layoutChecks[id]
    if pending then pending.timer:stop() layoutChecks[id] = nil end
end

-- Apps that recently had windows come or go. The window filter can miss a
-- window that comes back without an event of its own (the surviving native
-- tab after the selected one closes), so for these apps the app's own window
-- list is consulted as well.
local dirtyPids = {}
local BSP_DIRTY_FOR = 3

local function markDirty(win)
    local pid = win and win:pid()
    if pid then dirtyPids[pid] = hs.timer.secondsSinceEpoch() + BSP_DIRTY_FOR end
end

-- pid -> { time =, wins = } : an app's standard, visible windows, reused for
-- a moment so a burst of retiles asks each app once.
local appWindowCache = {}
local BSP_APP_CACHE_TTL = 0.1

local function appWindows(pid, app)
    local now = hs.timer.secondsSinceEpoch()
    local cached = appWindowCache[pid]
    if cached and now - cached.time < BSP_APP_CACHE_TTL then return cached.wins end
    local wins = {}
    for _, win in ipairs(app:allWindows()) do
        if win:id() and win:isStandard() and win:isVisible() and not Util.isPictureInPicture(win) then
            wins[#wins + 1] = win
        end
    end
    appWindowCache[pid] = { time = now, wins = wins }
    return wins
end

local function withRecentlyChangedApps(windows)
    local now = hs.timer.secondsSinceEpoch()
    local seen = {}
    for _, win in ipairs(windows) do seen[win:id()] = true end

    local ignored = {}
    for _, name in ipairs(S.cfg.ignoreApps or {}) do ignored[name] = true end

    local out = {}
    for _, win in ipairs(windows) do out[#out + 1] = win end
    for pid, expires in pairs(dirtyPids) do
        if expires < now then
            dirtyPids[pid] = nil
            appWindowCache[pid] = nil
        else
            local app = hs.application.applicationForPID(pid)
            if app and not ignored[app:name()] then
                for _, win in ipairs(appWindows(pid, app)) do
                    local id = win:id()
                    if id and not seen[id] then
                        seen[id] = true
                        out[#out + 1] = win
                        Util.dlog("added from app list: %s", tostring(id))
                    end
                end
            end
        end
    end
    return out
end

local function windowInfoFor(win)
    local id = win:id()
    local info = S.windowInfo[id]
    if info then return info end
    local screen = win:screen()
    info = { uuid = screen and screen:getUUID(), full = win:isFullScreen() }
    S.fullscreen[id] = info.full or nil
    -- A window with no screen yet (still being created) isn't cached.
    if info.uuid then S.windowInfo[id] = info end
    return info
end

-- Native tabs: the filter reports every tab of a tabbed window as a window,
-- all "visible" and at the same frame, but only one is the live tab. Separate
-- windows can also open at identical frames (e.g. Ghostty), so keep every
-- window the app itself lists and only suppress unlisted duplicates. If none
-- are listed yet, prefer the one already tiled, else the oldest.
-- A window alone at its frame is always
-- live: the app's own list can lag behind events (e.g. right after the
-- selected tab closes), so it's only used to choose within a group.
local function backgroundTabs(windows)
    local perPid = {}
    for _, win in ipairs(windows) do
        local pid = win:pid()
        perPid[pid] = perPid[pid] or {}
        table.insert(perPid[pid], win)
    end

    local background = {}
    for pid, wins in pairs(perPid) do
        -- Tiles never share a frame, so if every window of the app already
        -- holds its own tile there are no background tabs to find (and no
        -- reason to ask the app for frames).
        local allTiled = #wins >= 2
        for _, win in ipairs(wins) do
            if not Tree.rectFor(win:id()) then allTiled = false break end
        end
        if #wins >= 2 and not allTiled then
            local groups = {}
            for _, win in ipairs(wins) do
                local f = win:frame()
                local gk = string.format("%d,%d,%d,%d",
                    math.floor(f.x + 0.5), math.floor(f.y + 0.5),
                    math.floor(f.w + 0.5), math.floor(f.h + 0.5))
                groups[gk] = groups[gk] or {}
                table.insert(groups[gk], win)
            end

            local listed = nil
            for _, group in pairs(groups) do
                if #group >= 2 then
                    if not listed then
                        listed = {}
                        local app = hs.application.applicationForPID(pid)
                        for _, w in ipairs(app and app:allWindows() or {}) do
                            listed[w:id()] = true
                        end
                    end
                    local function rank(win)
                        local id = win:id()
                        return (listed[id] and 0 or 2) + (Tree.findByID(id) and 0 or 1), id
                    end
                    table.sort(group, function(a, b)
                        local ra, ia = rank(a)
                        local rb, ib = rank(b)
                        if ra ~= rb then return ra < rb end
                        return ia < ib
                    end)
                    for i = 2, #group do
                        local id = group[i]:id()
                        if not listed[id] then background[id] = true end
                    end
                end
            end
        end
    end
    return function(win) return background[win:id()] == true end
end

-- Windows skipped as background tabs in the latest pass. When a tab closes,
-- its replacement can still look like one for a moment (the app's window
-- list lags), so the tile handoff considers these too.
S.ghosts = {}

-- Every window seen in the latest pass, on any screen. A window that leaves
-- a tree but is still open (moved to another display or workspace, gone
-- fullscreen) keeps its focus.
S.openIDs = {}

-- Manageable windows of the showing workspaces grouped by screen UUID, in a
-- single pass (each window's screen and state are accessibility calls, so
-- don't repeat them per screen). Windows get their workspace here. With
-- `onlyUUID`, windows on other screens skip the remaining checks.
local function windowsByScreen(onlyUUID)
    local byScreen = {}
    S.ghosts = {}
    S.openIDs = {}

    -- Parked windows are only counted as open.
    local allWindows = {}
    for _, win in ipairs(withRecentlyChangedApps(Util.managedWindows())) do
        if Spaces.isHidden(win:id()) then
            S.openIDs[win:id()] = true
        else
            allWindows[#allWindows + 1] = win
        end
    end
    local isBackgroundTab = backgroundTabs(allWindows)

    for _, win in ipairs(allWindows) do
        if isBackgroundTab(win) then
            S.ghosts[#S.ghosts + 1] = win
            goto continue
        end
        S.openIDs[win:id()] = true
        local info = windowInfoFor(win)
        -- The filter only passes visible, manageable windows.
        local uuid = info.uuid and not info.full and Spaces.claim(win, info.uuid)
        if uuid and (not onlyUUID or uuid == onlyUUID) and not Float.shouldFloat(win) then
            byScreen[uuid] = byScreen[uuid] or {}
            table.insert(byScreen[uuid], win)
        end
        ::continue::
    end

    -- Stable order for initial tree construction.
    for _, list in pairs(byScreen) do
        table.sort(list, function(a, b)
            return a:id() < b:id()
        end)
    end

    return byScreen
end

-- Cancels every pending frame verification (reload, shutdown).
local function stop()
    for id in pairs(layoutChecks) do cancelLayoutCheck(id) end
end

M.stop = stop
M.layoutChecks = layoutChecks
M.cancelLayoutCheck = cancelLayoutCheck
M.markDirty = markDirty
M.windowInfoFor = windowInfoFor
M.windowsByScreen = windowsByScreen

return M
