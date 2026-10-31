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
local BSP_DIRTY_FOR = 3

local function markDirty(win)
    local pid = win and win:pid()
    if pid then dirtyPids[pid] = hs.timer.secondsSinceEpoch() + BSP_DIRTY_FOR end
end

-- The filter neither drops absorbed windows nor reliably adds torn-off
-- ones. Ask each managed app, including apps whose tabs we already know.
local function appWindows(pid, app)
    local out = {}
    for _, win in ipairs(app:allWindows()) do
        if win:id() and win:isStandard() and win:isVisible() and not Util.isPictureInPicture(win) then
            out[#out + 1] = win
        end
    end
    return out
end

local nativeWindows = {}
local repairedAt = {}
S.nativeBackground = {}
local function withRecentlyChangedApps(windows)
    local pids, out, seen = {}, {}, {}
    local ignored = {}
    for _, name in ipairs(S.cfg.ignoreApps or {}) do ignored[name] = true end
    for _, win in ipairs(windows) do
        pids[win:pid()] = true
        -- Managed dialogs are not native tabs, but must still tile.
        if not win:isStandard() then out[#out + 1], seen[win:id()] = win, true end
        if win:isStandard() then
            nativeWindows[win:id()] = { pid = win:pid(), title = win:title() }
        end
    end
    for _, d in pairs(nativeWindows) do pids[d.pid] = true end
    for pid, expires in pairs(dirtyPids) do
        if expires >= hs.timer.secondsSinceEpoch() then pids[pid] = true
        else dirtyPids[pid] = nil end
    end
    local frames = Util.native("frames")
    S.nativeBackground = {}
    S.nativeShown = {}
    for pid in pairs(pids) do
        local app = hs.application.applicationForPID(pid)
        if app and not ignored[app:name()] then
            local states = frames and frames.tabState and frames.tabState(pid)
            local shown, expected = {}, 0
            -- No TTL here: tab switches change AXWindows without create events.
            for _, win in ipairs(appWindows(pid, app)) do
                local id = win:id()
                if id and (not states or states[id] == "shown")
                   and win:isStandard() and win:isVisible() and not win:isMinimized()
                   and not Util.isPictureInPicture(win) then
                    nativeWindows[id] = { pid = pid, title = win:title() }
                    local titles = frames and frames.tabButtons and frames.tabButtons(pid, id) or {}
                    local record = { id = id, pid = pid, win = win, frame = win:frame(),
                        titles = titles, count = math.max(1, #titles) }
                    shown[#shown + 1] = record
                    expected = expected + record.count - 1
                    if not seen[id] then out[#out + 1], seen[id] = win, true end
                end
            end
            local known = {}
            for id, d in pairs(nativeWindows) do if d.pid == pid then known[id] = true end end
            local background = Tabs.detect(states, known)
            local count = 0
            for _ in pairs(background) do count = count + 1 end
            local now = hs.timer.secondsSinceEpoch()
            if states and count ~= expected and frames.tabWindows and now - (repairedAt[pid] or -math.huge) >= 1 then
                repairedAt[pid] = now
                -- Unknown off-screen windows need AXStandardWindow confirmation.
                -- Repair only a count mismatch, not every layout pass.
                for id, title in pairs(frames.tabWindows(pid)) do
                    nativeWindows[id] = { pid = pid, title = title }
                    known[id] = true
                end
                background = Tabs.detect(states, known)
            end
            for id in pairs(background) do S.nativeBackground[id] = nativeWindows[id] end
            for _, w in ipairs(shown) do S.nativeShown[#S.nativeShown + 1] = w end
            -- Keep filtered background objects solely for the old handoff path.
            -- They must never receive tiles of their own.
            for _, win in ipairs(windows) do
                if win:pid() == pid and (background[win:id()] or not states)
                   and not win:isMinimized() and not seen[win:id()] then
                    out[#out + 1], seen[win:id()] = win, true
                end
            end
            for id, d in pairs(nativeWindows) do
                if d.pid == pid and states and not states[id] then nativeWindows[id] = nil end
            end
        elseif not app then
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
    local plain = {}
    for _, win in ipairs(windows) do
        local id = win:id()
        plain[#plain + 1] = {
            id = id, pid = win:pid(), win = win,
            tiled = Tree.rectFor(id) ~= nil,
            inTree = Tree.findByID(id) ~= nil,
        }
    end
    local background = Tabs.background(plain,
        function(p) return p.win:frame() end,
        function(pid)
            local listed = {}
            local app = hs.application.applicationForPID(pid)
            for _, w in ipairs(app and app:allWindows() or {}) do
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
        local states = frames and frames.tabState and frames.tabState(pid)
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
                local position = 0
                for i, id in ipairs(leaf.members) do if id == to then position = i break end end
                frames.tabShow(d.pid, to, from, d.title, position)
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
    local frames = Util.native("frames")
    local states = win and frames and frames.tabState and frames.tabState(win:pid())
    return states and states[win:id()] == "tab"
end

function M.nativePeer(win)
    local frames = Util.native("frames")
    local states = win and frames and frames.tabState and frames.tabState(win:pid())
    for id, state in pairs(states or {}) do
        if state == "tab" and nativeWindows[id] then return true end
    end
    return false
end

M.nativeWindows = nativeWindows
M.stop = stop
M.layoutChecks = layoutChecks
M.cancelLayoutCheck = cancelLayoutCheck
M.markDirty = markDirty
M.windowInfoFor = windowInfoFor
M.windowsByScreen = windowsByScreen

return M
