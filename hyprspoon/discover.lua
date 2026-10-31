-- hyprspoon/discover.lua: Finding the manageable windows on each screen.

local M = {}
package.loaded["hyprspoon.discover"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Tree = require("hyprspoon.tree")
local Tabs = require("hyprspoon.tabs")
local Float = require("hyprspoon.float")
local Spaces = require("hyprspoon.spaces")
local Border = require("hyprspoon.border")

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
local eventWindows = {}
local BSP_DIRTY_FOR = 3

local function markDirty(win)
    local pid = win and win:pid()
    if pid then
        eventWindows[pid] = eventWindows[pid] or {}
        eventWindows[pid][win:id()] = win
        dirtyPids[pid] = hs.timer.secondsSinceEpoch() + BSP_DIRTY_FOR
        if M.observe then M.observe() end
    end
end

-- AXWindows and tab bars are expensive and can time out. Quiet apps reuse
-- their records; events allow short-lived refreshes and a WindowServer
-- state change bypasses the TTL so switches and merges are seen promptly.
local appCache = {}
local BSP_APP_CACHE_TTL = 0.1
local nativeWindows = {}
local repairBackoff = {}
local snapshot, snapshotPending, stopped = nil, false, false
local generation = 0
S.nativeBackground = {}

local function appWindows(pid, app)
    local ok, windows = pcall(function() return app:allWindows() end)
    if not ok or not windows or #windows == 0 then return nil end
    local out = {}
    for _, win in ipairs(windows) do
        if win:id() and win:isStandard() and win:isVisible() and not Util.isPictureInPicture(win) then
            out[#out + 1] = win
        end
    end
    return out
end

local function stateSignature(states)
    if not states then return "unavailable" end
    local parts = {}
    for id, state in pairs(states) do parts[#parts + 1] = id .. ":" .. state end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function requestSnapshot(frames)
    if stopped or snapshotPending or not (frames and frames.tabSnapshot) then return end
    snapshotPending = true
    local epoch = generation
    frames.tabSnapshot(function(result)
        if stopped or epoch ~= generation then return end
        snapshotPending = false
        if not result then return end
        local changed = snapshot == nil
        for pid, states in pairs(result or {}) do
            if stateSignature(states) ~= stateSignature(snapshot and snapshot[pid]) then changed = true end
        end
        for pid in pairs(snapshot or {}) do if not (result or {})[pid] then changed = true end end
        snapshot = result
        -- A normal coalesced pass is safe during Space arrivals. It does not
        -- lay out the old filter list synchronously inside an arrival event.
        if changed then require("hyprspoon.layout").scheduleRetile(false) end
    end)
end

local function withRecentlyChangedApps(windows)
    local pids, filtered, out, seen = {}, {}, {}, {}
    local now = hs.timer.secondsSinceEpoch()
    -- Focus/visible events can carry the new tab before AXWindows or the
    -- filter lists it. Trust that object as soon as WindowServer shows it.
    local candidates = {}
    for _, win in ipairs(windows) do candidates[#candidates + 1] = win end
    for pid, recent in pairs(eventWindows) do
        if not dirtyPids[pid] or dirtyPids[pid] < now then eventWindows[pid] = nil
        else
            for id, win in pairs(recent) do
                if snapshot and snapshot[pid] and snapshot[pid][id] == "shown" then
                    candidates[#candidates + 1] = win
                end
            end
        end
    end
    local ignored = {}
    for _, name in ipairs(S.cfg.ignoreApps or {}) do ignored[name] = true end
    for _, win in ipairs(candidates) do
        local pid, id = win:pid(), win:id()
        pids[pid], filtered[pid] = true, filtered[pid] or {}
        filtered[pid][#filtered[pid] + 1] = win
        if not nativeWindows[id] and win:isStandard() then
            nativeWindows[id] = { pid = pid, title = win:title() }
        end
    end
    for _, d in pairs(nativeWindows) do pids[d.pid] = true end
    for pid, expires in pairs(dirtyPids) do
        if expires >= now then pids[pid] = true else dirtyPids[pid] = nil end
    end
    local frames = Util.native("frames")
    requestSnapshot(frames)
    local previousBackground = S.nativeBackground
    S.nativeBackground, S.nativeShown = {}, {}
    for pid in pairs(pids) do
        local app = hs.application.applicationForPID(pid)
        if app and not ignored[app:name()] then
            local states = snapshot and (snapshot[pid] or {})
            local signature = stateSignature(states)
            local cached = appCache[pid]
            local changed = not cached or cached.signature ~= signature
            if changed or (dirtyPids[pid] and now - cached.time >= BSP_APP_CACHE_TTL) then
                -- Empty/failed AXWindows is uncertainty, not evidence of closure.
                local listed = appWindows(pid, app)
                local wins, included = {}, {}
                for _, win in ipairs(listed or filtered[pid] or {}) do
                    wins[#wins + 1], included[win:id()] = win, true
                end
                for _, win in ipairs(filtered[pid] or {}) do
                    if states and states[win:id()] == "shown" and not included[win:id()] then
                        wins[#wins + 1], included[win:id()] = win, true
                    end
                end
                cached = { time = now, signature = signature, shown = {}, wins = wins,
                    failed = listed == nil }
                appCache[pid] = cached
                for _, win in ipairs(wins) do
                    local id = win:id()
                    if (not states or states[id] == "shown" or states[id] == "unknown")
                       and win:isStandard() and win:isVisible() and not win:isMinimized() then
                        nativeWindows[id] = { pid = pid, title = win:title() }
                        local titles = frames and frames.tabButtons and frames.tabButtons(pid, id) or {}
                        cached.shown[#cached.shown + 1] = { id = id, pid = pid, win = win,
                            frame = win:frame(), titles = titles, count = math.max(1, #titles) }
                    end
                end
            end
            local known, wanted, windowCount = {}, {}, 0
            for id, d in pairs(nativeWindows) do if d.pid == pid then known[id] = true end end
            for id, state in pairs(states or {}) do
                windowCount = windowCount + 1
                if state == "tab" and not known[id] then wanted[id] = true end
            end
            local background = Tabs.detect(states, known)
            -- A failed Space lookup is uncertainty, including for a known
            -- background member that has no filter/AXWindows object to retain.
            for id, d in pairs(previousBackground) do
                if d.pid == pid and states and states[id] == "unknown" then background[id] = true end
            end
            local count, expected = 0, 0
            for _ in pairs(background) do count = count + 1 end
            for _, w in ipairs(cached.shown) do expected = expected + w.count - 1 end
            local repairKey = tostring(windowCount) .. ":" .. tostring(expected)
            if states and next(wanted) and #cached.shown > 0 and count ~= expected
               and frames and frames.tabWindows and repairBackoff[pid] ~= repairKey then
                -- An unresolved mismatch is retried only when the app's window
                -- count changes, not once a second for a permanent document bar.
                repairBackoff[pid] = repairKey
                local epoch = generation
                frames.tabWindows(pid, wanted, function(found)
                    if stopped or epoch ~= generation then return end
                    for id, title in pairs(found or {}) do nativeWindows[id] = { pid = pid, title = title } end
                    if next(found or {}) then require("hyprspoon.layout").scheduleRetile(false) end
                end)
            end
            for id in pairs(background) do
                S.nativeBackground[id] = nativeWindows[id]
                S.offSpace[id] = nil
            end
            for _, w in ipairs(cached.shown) do S.nativeShown[#S.nativeShown + 1] = w end
            -- Keep the filter's windows when the app list times out or lags.
            -- Only WindowServer evidence can suppress an otherwise valid one.
            for _, list in ipairs({ cached.wins, filtered[pid] or {} }) do
                for _, win in ipairs(list) do
                    local id = win:id()
                    if not seen[id] and (not states or states[id] == "shown"
                       or states[id] == "unknown" or background[id]) then
                        out[#out + 1], seen[id] = win, true
                    end
                end
            end
            for id, d in pairs(nativeWindows) do
                if d.pid == pid and states and not states[id] then nativeWindows[id] = nil end
            end
        elseif not app then
            appCache[pid], repairBackoff[pid] = nil, nil
            for id, d in pairs(nativeWindows) do if d.pid == pid then nativeWindows[id] = nil end end
        end
    end
    return out
end

local function learnTabs()
    local changed = false
    local assignments = Tabs.assign(S.nativeBackground, S.nativeShown or {}, function(id)
        local _, leaf = Tree.findByID(id)
        return leaf or S.setsAway[id]
    end)
    for id, to in pairs(assignments) do
        local _, target = Tree.findByID(to)
        target = target or S.setsAway[to]
        local _, source, key = Tree.findByID(id)
        source = source or S.setsAway[id]
        if not target and source and source.kind == "native" and S.setsAway[id] and S.autoFloat[id] then
            Tree.addMember(source, to, "native")
            S.autoFloat[to] = true
            target, changed = source, true
        end
        if not target then
            for _, w in ipairs(S.nativeShown or {}) do
                if w.id == to and Float.shouldFloat(w.win) then
                    target = { windowID = to, members = { to }, kind = "native" }
                    S.setsAway[to] = target
                    break
                end
            end
        end
        -- Groups own their native-tab sublists; #13 handles their behaviour.
        if target and target.kind ~= "group" and source ~= target and (not source or source.kind ~= "group") then
            if key then S.trees[key] = Tree.removeID(S.trees[key], id) end
            Tree.forget(id)
            Tree.addMember(target, id, "native")
            if S.setsAway[to] then S.autoFloat[id] = S.autoFloat[to] end
            changed = true
        end
    end
    -- Floating sets do not visit Layout.reconcileTree. They still hand off
    -- their shown member and let torn-off windows leave the set.
    local visible, seen = {}, {}
    for _, w in ipairs(S.nativeShown or {}) do visible[w.id] = true end
    for _, leaf in pairs(S.setsAway) do
        if leaf.kind == "native" and not seen[leaf] then
            seen[leaf] = true
            local pick = visible[leaf.windowID] and leaf.windowID
            for _, id in ipairs(leaf.members) do
                if not pick and visible[id] then pick = id end
            end
            if pick and pick ~= leaf.windowID then
                S.autoFloat[pick] = S.autoFloat[leaf.windowID]
                require("hyprspoon.layout").showMember(leaf, pick, nil)
                changed = true
            end
            for _, id in ipairs(Tabs.strays(leaf.members, leaf.windowID, visible)) do
                Tree.removeMember(leaf, id)
                changed = true
            end
        end
    end
    if changed then S.keyIndex = {} Tree.saveTrees() end
end

local function windowInfoFor(win)
    local id = win:id()
    local info = S.windowInfo[id]
    if info then return info end
    local screen = win:screen()
    info = { uuid = screen and screen:getUUID(), full = win:isFullScreen() }
    -- Found to be in or out of full screen without an event (already full
    -- screen when hyprspoon started, or first met on its Space after a
    -- swipe): the rings follow.
    if S.fullscreen[id] ~= (info.full or nil) then
        S.fullscreen[id] = info.full or nil
        Border.sync()
    end
    -- A window with no screen yet (still being created) isn't cached.
    if info.uuid then S.windowInfo[id] = info end
    return info
end

-- Native tabs: the rules are in Tabs.background; the plain facts about each
-- window are gathered here, the frames and the app's own list only if asked.
local function backgroundTabs(windows)
    -- The shared snapshot already distinguishes tabs from other Spaces and
    -- detects absorbed tiled windows. No stale frame guesses are needed.
    if snapshot then return function() return false end end
    local plain = {}
    for _, win in ipairs(windows) do
        local id = win:id()
        -- Failed AXWindows cannot justify even the frame-based suppression.
        if appCache[win:pid()] and appCache[win:pid()].failed then goto continue end
        plain[#plain + 1] = {
            id = id, pid = win:pid(), win = win,
            tiled = Tree.rectFor(id) ~= nil,
            inTree = Tree.findByID(id) ~= nil,
        }
        ::continue::
    end
    local background = Tabs.background(plain,
        function(p) return p.win:frame() end,
        function(pid)
            local listed = {}
            local app = hs.application.applicationForPID(pid)
            for _, w in ipairs(app and appCache[pid] and appCache[pid].wins or {}) do
                listed[w:id()] = true
            end
            return listed
        end)
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
    stopped = false
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
    learnTabs()
    local isBackgroundTab = backgroundTabs(allWindows)
    for id in pairs(S.nativeBackground) do S.openIDs[id] = true end

    for _, win in ipairs(allWindows) do
        if S.nativeBackground[win:id()] or isBackgroundTab(win) then
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

    for id, d in pairs(S.nativeBackground) do
        local leaf = Tree.setOf(id)
        local app = hs.application.applicationForPID(d.pid)
        if app then Spaces.nativeMember(id, leaf and leaf.windowID, app:bundleID(), d.title) end
    end
    return byScreen
end

-- Cancels every pending frame verification (reload, shutdown).
local switchTimers = {}
local function stop()
    stopped = true
    generation = generation + 1
    snapshotPending = false
    for _, timer in pairs(switchTimers) do timer:stop() end
    switchTimers = {}
    for id in pairs(layoutChecks) do cancelLayoutCheck(id) end
end

local function shownSignature(states)
    local ids = {}
    for id, state in pairs(states or {}) do
        if state == "shown" and nativeWindows[id] then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function pollSwitch(pid, remaining, before)
    local frames = Util.native("frames")
    remaining = remaining or 25
    if not before then
        local states = {}
        for _, w in ipairs(S.nativeShown or {}) do if w.pid == pid then states[w.id] = "shown" end end
        before = shownSignature(states)
    end
    if switchTimers[pid] then switchTimers[pid]:stop() end
    switchTimers[pid] = hs.timer.doAfter(0.01, function()
        switchTimers[pid] = nil
        requestSnapshot(frames)
        local states = snapshot and snapshot[pid]
        if not states then
            states = {}
            local app = hs.application.applicationForPID(pid)
            for _, win in ipairs(app and appWindows(pid, app) or {}) do states[win:id()] = "shown" end
        end
        if shownSignature(states) ~= before or remaining == 1 then
            require("hyprspoon.layout").tileNow(true)
        else
            pollSwitch(pid, remaining - 1, before)
        end
    end)
end

Tree.registerKind("native", {
    cycle = function(win, leaf, key, delta)
        local frames = Util.native("frames")
        if frames and frames.tabButtons then
            frames.tabButtons(win:pid(), win:id(), delta)
        else
            -- The standard menu shortcuts remain useful without frames.so.
            local app = win:application()
            app:selectMenuItem({ "Window", delta > 0 and "Show Next Tab" or "Show Previous Tab" })
        end
        pollSwitch(win:pid())
    end,
    moveOut = function(win)
        win:application():selectMenuItem({ "Window", "Move Tab to New Window" })
        pollSwitch(win:pid())
    end,
    show = function(leaf, key, from, to)
        if S.nativeBackground[to] then
            local frames = Util.native("frames")
            local d = S.nativeBackground[to]
            if frames and frames.tabShow then
                frames.tabShow(d.pid, to, from, d.title)
            end
            pollSwitch(d.pid)
        end
    end,
    strays = function(leaf, key, ids)
        S.nativeTornBeside = S.nativeTornBeside or {}
        for _, id in ipairs(ids) do
            S.nativeTornBeside[id] = leaf.windowID
            Tree.removeMember(leaf, id)
        end
    end,
})

function M.isNativeTab(win)
    local states = win and snapshot and snapshot[win:pid()]
    return states and states[win:id()] == "tab"
end

function M.nativePeer(win)
    local pid = win and win:pid()
    for _, d in pairs(S.nativeBackground) do if d.pid == pid then return true end end
    return false
end

function M.observe()
    requestSnapshot(Util.native("frames"))
end

M.nativeWindows = nativeWindows
M.stop = stop
M.layoutChecks = layoutChecks
M.cancelLayoutCheck = cancelLayoutCheck
M.markDirty = markDirty
M.windowInfoFor = windowInfoFor
M.windowsByScreen = windowsByScreen

return M
