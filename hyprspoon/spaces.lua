-- hyprspoon/spaces.lua: Numbered workspaces, kept by the window manager itself.

local M = {}
package.loaded["hyprspoon.spaces"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Tree = require("hyprspoon.tree")
local Focus = require("hyprspoon.focus")
local Discover = require("hyprspoon.discover")
local Layout = require("hyprspoon.layout")
local Bar = require("hyprspoon.bar")
local Hud = require("hyprspoon.hud")
local Border = require("hyprspoon.border")
local Restore = require("hyprspoon.restore")
local Slide = require("hyprspoon.slide")
local Hooks = require("hyprspoon.hooks")

-- ---------------------------------------------------------------------------
-- Workspaces
-- ---------------------------------------------------------------------------
--
-- Workspaces are ours rather than macOS Spaces. Every window stays on the
-- one Desktop each display has; switching workspace parks the windows of the
-- workspace being left in a corner of its display (macOS keeps a sliver of
-- each on screen) and brings back the new one's. Nothing waits on Mission
-- Control or the Space switch animation, and moving a window between
-- workspaces is bookkeeping.
--
-- Like Hyprland's: numbered, created on first use, and forgotten once empty
-- and no longer showing. Each display shows one workspace; going to one
-- showing on another display moves the pointer there.
--
-- S.cfg.displays gives displays their workspaces, like Hyprland's
-- workspace rules: those live on that display while it's connected. Every
-- other numbered workspace, and those of displays not connected, live on
-- the primary display. A display not in S.cfg.displays other than the
-- primary (a projector, an AirPlay screen) gets one workspace of its own,
-- unnumbered and shown by the display's name; numbered workspaces don't go
-- there. When that display goes, its windows join the workspace showing
-- on the primary display.
--
-- Windows join the workspace showing on their display when they first
-- appear, and the one on their new display when they change display. They
-- leave theirs when minimized or made full screen, and join the one showing
-- when they come back.
--
-- Use one macOS Desktop per display: the window filter only sees the
-- current Desktop's windows.
--
-- Besides 1 to 10 there are named workspaces (S.cfg.namedWorkspaces):
-- scratchpads, like Hyprland's special workspaces. One shows on the
-- pointer's display, over its numbered workspace rather than in its place,
-- laid out in S.cfg.scratchpadScale of the area, and goes when toggled
-- again, when the display switches workspace, or when a window beneath it
-- gets focus (a click, Cmd-Tab): macOS would raise that window over it. The windows
-- beneath stay where they are but count as hidden while it shows: they
-- aren't laid out, ringed, or focused by the pointer.

-- Window IDs are only meaningful within one boot, so the saved state is
-- discarded after a restart (see Tree.bootTime).
local STATE_KEY = "hyprspoon.workspaces"

-- Named workspaces (S.cfg.namedWorkspaces, e.g. "A") are numbered 101 on,
-- after the numbered ones, and shown by name. A display's own workspace
-- (one not in S.cfg.displays) is numbered -1, -2, ... and shown by the
-- display's name.
local NAMED_BASE = 100

-- A workspace number from a number or a name; nil if it's neither.
local function number(n)
    if type(n) == "string" then
        for i, name in ipairs(S.cfg.namedWorkspaces or {}) do
            if name:lower() == n:lower() then return NAMED_BASE + i end
        end
    end
    return math.tointeger(n)
end

local active = {} -- screen UUID -> workspace number it shows
local home = {}   -- workspace number -> screen UUID it lives on
local of = {}     -- window id -> workspace number
local parked = {} -- window id -> its frame before it was parked
local info = {}   -- window id -> { app = bundle id, title = } for hyprspoon/restore.lua
local pins = {}   -- window id -> until when its workspace ignores its display
local under = {}  -- screen UUID -> numbered workspace beneath the named one it shows

-- Derived by refresh() from the above and the connected displays.
local connected = {} -- screen UUID -> hs.screen
local shown = {}     -- workspace number -> UUID of the display showing it
local behind = {}    -- workspace number -> true while a scratchpad covers it
local primaryUUID = nil
local pinnedTo = {}  -- workspace number -> UUID of the connected display S.cfg.displays gives it
local declared = {}  -- screen UUID -> its workspaces from S.cfg.displays, in order

-- When we last switched, and when a window last went away: macOS focusing a
-- parked window just after either is its own pick, not the user's.
local lastSwitch = 0
S.lastGoneTime = 0

-- A display focused with nothing on it (an empty workspace), until a
-- window takes focus. New windows open there, as Hyprland opens them on
-- the focused monitor.
local focusedEmpty = nil

-- The workspace the pointer's display showed before the last switch, for
-- going back to it, and the last numbered one left, for going back from a
-- named one (however many named ones were visited in between).
local previous = nil
local lastNumbered = nil

-- hs.reload() is how this config reloads; anything else ending Hammerspoon
-- brings the parked windows back (see unparkAll).
local reloading = false
do
    local reload = hs.reload
    hs.reload = function(...)
        reloading = true
        return reload(...)
    end
end

-- Saving rewrites the preferences file, so it's debounced (and flushed on
-- reload and quit).
local saveTimer = nil

local function saveNow()
    if saveTimer then saveTimer:stop() saveTimer = nil end
    local out = { boot = Tree.bootTime, active = {}, under = {}, home = {}, of = {}, parked = {}, info = {} }
    for uuid, n in pairs(active) do out.active[uuid] = n end
    for uuid, n in pairs(under) do out.under[uuid] = n end
    for n, uuid in pairs(home) do out.home[tostring(n)] = uuid end
    for id, n in pairs(of) do
        out.of[tostring(id)] = n
        out.info[tostring(id)] = info[id]
    end
    for id, f in pairs(parked) do out.parked[tostring(id)] = f end
    hs.settings.set(STATE_KEY, out)
end

-- Every change to the workspaces is saved, so this is also where the menu
-- bar, badges and hooks hear about them.
local function save()
    if saveTimer then saveTimer:stop() end
    saveTimer = hs.timer.doAfter(1, saveNow)
    Bar.update()
    Hud.update()
    Hooks.fire("workspace")
end

local function loadState()
    active, under, home, of, parked, pins, info = {}, {}, {}, {}, {}, {}, {}
    local saved = hs.settings.get(STATE_KEY)
    if type(saved) ~= "table" or type(saved.boot) ~= "number"
       or math.abs(saved.boot - Tree.bootTime) >= 120 then
        -- After a restart each display shows the workspace it showed before.
        for uuid, n in pairs(Restore.savedActive()) do
            active[uuid], home[tonumber(n)] = tonumber(n), uuid
        end
        return
    end
    for id, d in pairs(saved.info) do info[tonumber(id)] = d end
    for uuid, n in pairs(saved.active or {}) do active[uuid] = tonumber(n) end
    for uuid, n in pairs(saved.under) do under[uuid] = tonumber(n) end
    for n, uuid in pairs(saved.home or {}) do home[tonumber(n)] = uuid end
    for id, n in pairs(saved.of or {}) do of[tonumber(id)] = tonumber(n) end
    for id, f in pairs(saved.parked or {}) do
        parked[tonumber(id)] = { x = f.x, y = f.y, w = f.w, h = f.h }
    end
end

-- The primary display first, then the others left-to-right/top-to-bottom,
-- so a fresh start numbers the primary display's workspace 1.
local function orderedScreens()
    local primary = hs.screen.primaryScreen()
    local result, rest = {}, {}
    if primary then result[1] = primary end
    for _, screen in ipairs(hs.screen.allScreens()) do
        if not primary or screen:id() ~= primary:id() then rest[#rest + 1] = screen end
    end
    table.sort(rest, function(a, b)
        local af, bf = a:fullFrame(), b:fullFrame()
        if af.x == bf.x then return af.y < bf.y end
        return af.x < bf.x
    end)
    for _, screen in ipairs(rest) do result[#result + 1] = screen end
    return result
end

-- The display a workspace shows on: its own, or the primary display while
-- its own is disconnected.
local function displayOf(n)
    local uuid = n and home[n]
    if uuid and connected[uuid] then return uuid end
    return primaryUUID
end

-- The display a workspace not showing belongs on: the one S.cfg.displays
-- gives it, a display's own workspace's display, else the primary display.
local function homeFor(n)
    if n < 0 and connected[home[n]] then return home[n] end
    return pinnedTo[n] or primaryUUID
end

-- Reads S.cfg.displays (display name or UUID -> workspace numbers) for the
-- connected displays. A number given to two displays goes to the first.
local function readDisplays(screens)
    pinnedTo, declared = {}, {}
    local cfg = S.cfg.displays or {}
    for _, screen in ipairs(screens) do
        local uuid = screen:getUUID()
        local list = cfg[uuid] or cfg[screen:name() or ""]
        if type(list) == "table" then
            declared[uuid] = {}
            for _, n in ipairs(list) do
                n = math.tointeger(n)
                if n and n >= 1 and n <= NAMED_BASE and not pinnedTo[n] then
                    pinnedTo[n] = uuid
                    table.insert(declared[uuid], n)
                end
            end
        end
    end
end

-- A new numbered workspace for display `uuid`: the lowest number neither
-- in use nor given to another display.
local function freeWorkspace(uuid)
    local n = 1
    while home[n] or (pinnedTo[n] and pinnedTo[n] ~= uuid) do n = n + 1 end
    return n
end

-- What display `uuid` shows when what it showed can't stay: the first of
-- its workspaces in S.cfg.displays not showing elsewhere, else another of
-- its own, else a new one. A display other than the primary that isn't in
-- S.cfg.displays gets one of its own, unnumbered.
local function pickFor(uuid)
    local taken = {}
    for other, m in pairs(active) do
        if home[m] == other then taken[m] = true end
    end
    for _, n in ipairs(declared[uuid] or {}) do
        if not taken[n] then return n end
    end
    local best = nil
    for n, h in pairs(home) do
        if h == uuid and n <= NAMED_BASE and not taken[n] and (not best or n < best) then best = n end
    end
    if best then return best end
    if uuid == primaryUUID or declared[uuid] then return freeWorkspace(uuid) end
    local n = -1
    while home[n] do n = n - 1 end
    return n
end

local function forgetWorkspace(n)
    home[n] = nil
    Slide.forget(n)
    S.trees["ws" .. n] = nil
    S.maximized["ws" .. n] = nil
    S.untiled["ws" .. n] = nil
end

local function refresh()
    connected = {}
    local screens = orderedScreens()
    primaryUUID = screens[1] and screens[1]:getUUID()
    for _, screen in ipairs(screens) do connected[screen:getUUID()] = screen end
    readDisplays(screens)

    -- One showing on another display than the one it's given to (which
    -- just connected) goes on showing there.
    local moves = {}
    for uuid, n in pairs(active) do
        local to = connected[uuid] and pinnedTo[n]
        if to and to ~= uuid then moves[to] = n end
    end
    for to, n in pairs(moves) do active[to], under[to] = n, nil end

    -- Numbered workspaces go where they belong: to the display
    -- S.cfg.displays gives them, else (unless showing) to the primary
    -- display. Scratchpads come to the pointer wherever they live.
    if primaryUUID then
        for n, uuid in pairs(home) do
            if n >= 1 and n <= NAMED_BASE then
                local showing = connected[uuid] and (active[uuid] == n or under[uuid] == n)
                home[n] = pinnedTo[n] or (showing and uuid) or primaryUUID
            end
        end
    end

    -- Every display shows a workspace of its own. The one a display showed
    -- may have gone elsewhere while it was disconnected.
    for _, screen in ipairs(screens) do
        local uuid = screen:getUUID()
        local n = active[uuid]
        if not n or home[n] ~= uuid then
            n = pickFor(uuid)
            active[uuid], home[n] = n, uuid
        end
    end

    -- A display's own workspace whose display has gone: its windows, which
    -- macOS brings to the primary display, join the workspace showing there.
    local into = primaryUUID and (under[primaryUUID] or active[primaryUUID])
    local merged = false
    if into then
        for n, uuid in pairs(home) do
            if n < 0 and not connected[uuid] then
                for id, m in pairs(of) do
                    if m == n then of[id], merged = into, true end
                end
                if active[uuid] == n then active[uuid] = nil end
                if under[uuid] == n then under[uuid] = nil end
                forgetWorkspace(n)
            end
        end
    end

    shown, behind = {}, {}
    for uuid, n in pairs(active) do
        if connected[uuid] and displayOf(n) == uuid then shown[n] = uuid end
    end
    for uuid, n in pairs(under) do
        if connected[uuid] and displayOf(n) == uuid and active[uuid] ~= n and shown[active[uuid]] == uuid then
            shown[n], behind[n] = uuid, true
        end
    end
    if merged then save() end
end

local function pointerUUID()
    local screen = hs.mouse.getCurrentScreen()
    return screen and screen:getUUID() or primaryUUID
end

-- True for a window parked on a workspace that isn't showing, or beneath
-- a scratchpad.
local function isHidden(id)
    local n = id and of[id]
    return n ~= nil and (shown[n] == nil or behind[n] == true)
end

-- Workspaces that are empty and not showing anywhere are forgotten, so the
-- number is free to be created afresh on another display.
local function forgetEmpty()
    local used = {}
    for _, n in pairs(of) do used[n] = true end
    for _, n in pairs(active) do used[n] = true end
    for _, n in pairs(under) do used[n] = true end
    for n in pairs(home) do
        if not used[n] then forgetWorkspace(n) end
    end
end

-- ---------------------------------------------------------------------------
-- Parking
-- ---------------------------------------------------------------------------

-- The bottom-right corner of the display, or the bottom-left when less of
-- the window would reach onto the displays beside or below it from there.
-- macOS pulls the window back up far enough to keep its title bar's height
-- on screen.
local function parkPoint(uuid, size)
    local f = connected[uuid]:fullFrame()
    local corners = {
        { x = f.x + f.w - 1, y = f.y + f.h - 1 },
        { x = f.x - size.w + 1, y = f.y + f.h - 1 },
    }
    local best, bestOverlap = nil, nil
    for _, p in ipairs(corners) do
        local overlap = 0
        for other, screen in pairs(connected) do
            local o = screen:fullFrame()
            if other ~= uuid then
                local w = math.min(p.x + size.w, o.x + o.w) - math.max(p.x, o.x)
                local h = math.min(p.y + size.h, o.y + o.h) - math.max(p.y, o.y)
                if w > 0 and h > 0 then overlap = overlap + w * h end
            end
        end
        if not bestOverlap or overlap < bestOverlap then best, bestOverlap = p, overlap end
    end
    return best
end

-- Whether a frame is already in the corner (macOS moves it up from the
-- requested point, but never sideways).
local function inCorner(frame, point, uuid)
    local f = connected[uuid]:fullFrame()
    return math.abs(frame.x - point.x) <= 1 and frame.y > f.y + f.h - 100
end

local function settle()
    S.settleUntil = math.max(S.settleUntil, hs.timer.secondsSinceEpoch() + Layout.BSP_SETTLE)
end

-- Defined with the window events below; sync uses it after pruning dead IDs.
local hideEmptyScratchpads

-- Moves a window into its workspace's corner, remembering where it was the
-- first time. Its tile is the frame when it has one (no accessibility read).
-- Parking and unparking go through Util.setFrame like tiling does, so they
-- replace a tiling animation still running (or queued for a busy app)
-- instead of being undone by it when switching back and forth quickly.
local function park(win, n)
    local id = win:id()
    local frame = parked[id]
    if not frame then
        local f = Tree.rectFor(id) or win:frame()
        frame = { x = f.x, y = f.y, w = f.w, h = f.h }
        parked[id] = frame
    end
    Discover.cancelLayoutCheck(id)
    S.applied[id] = nil
    S.windowInfo[id] = nil
    settle()
    Border.forget(id)
    local p = parkPoint(displayOf(n), frame)
    Util.setFrame(win, { x = p.x, y = p.y, w = frame.w, h = frame.h }, 0)
end

-- Puts a parked window back. Tiles are left to the retile that follows;
-- anything else returns to its frame, centred on its display if that frame
-- is on a display that has gone.
local function unpark(win)
    local id = win:id()
    local frame = parked[id]
    parked[id] = nil
    Border.sync()
    S.applied[id] = nil
    S.windowInfo[id] = nil
    if not frame or (S.tilingEnabled and not S.autoFloat[id] and Tree.findByID(id)) then return end

    local sf = connected[shown[of[id]]]:frame()
    if not Util.pointInFrame({ x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 }, sf) then
        frame.x = sf.x + (sf.w - frame.w) / 2
        frame.y = sf.y + (sf.h - frame.h) / 2
    end
    settle()
    Util.setFrame(win, frame, 0)
end

-- Parks the windows of workspaces not showing and brings back the rest.
-- Parked windows stay put unless `force` (displays changed, so corners did).
local function sync(force)
    -- A missed window-filter event can leave a dead window ID in `of` or
    -- `parked`, keeping its workspace alive. Reconcile those IDs against
    -- WindowServer whenever workspace state is synced. One CGWindowList
    -- query, not hs.window.get per ID: that walks every app's windows over
    -- accessibility each time and stalls the slide animations.
    local live, stale = {}, {}
    for _, w in ipairs(hs.window.list(true) or {}) do
        if w.kCGWindowNumber then live[w.kCGWindowNumber] = true end
    end
    if next(live) then
        for id in pairs(of) do
            if not live[id] then stale[id] = true end
        end
        for id in pairs(parked) do
            if not live[id] then stale[id] = true end
        end
    end
    if next(stale) then
        for id in pairs(stale) do
            of[id], parked[id], pins[id], info[id] = nil, nil, nil, nil
            for key, maxID in pairs(S.maximized) do
                if maxID == id then S.maximized[key] = nil end
            end
        end
        save()
        hideEmptyScratchpads()
    end

    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        local n = of[id]
        if n then
            if shown[n] then
                if parked[id] then unpark(win) end
            elseif force or not parked[id] then
                park(win, n)
            end
        end
    end
    forgetEmpty()
    Focus.invalidateWindowCache()
    save()
end

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------

-- The display a visible window is laid out on, after giving it a workspace:
-- the one showing on its display `uuid` if it has none yet, or if it has
-- since moved to that display. A window we've just sent to another
-- display keeps its workspace while it gets there.
local function claim(win, uuid)
    local id = win:id()
    local n = of[id]
    if not connected[uuid] or not active[uuid] then refresh() end
    -- A rule's workspace (see S.cfg.rules), else the one it had before a
    -- restart (see hyprspoon/restore.lua), the first time it's seen.
    if not info[id] then
        local app = win:application()
        info[id] = { app = app and app:bundleID() }
    end
    local rule, wanted = nil, nil
    if not n then
        rule = Util.rulesFor(win)
        wanted = number(rule.workspace)
        if not wanted then
            wanted = Restore.match(win, info[id].app)
                or (connected[focusedEmpty] and active[focusedEmpty]) or nil
            rule = { silent = true }
        end
    end
    if wanted and wanted ~= 0 and wanted ~= active[uuid] then
        of[id] = wanted
        if not home[wanted] then home[wanted] = homeFor(wanted) end
        local to = shown[wanted]
        if to and to ~= uuid then
            pins[id] = hs.timer.secondsSinceEpoch() + 1
            S.windowInfo[id] = nil
            win:moveToScreen(connected[to], false, true, 0)
        elseif not to then
            park(win, wanted)
        end
        if not rule.silent then
            S.spaceFocusWin = win
            hs.timer.doAfter(0, function() M.gotoWorkspace(wanted) end)
        end
        save()
        return to
    end
    if not n or (shown[n] ~= uuid and (pins[id] or 0) < hs.timer.secondsSinceEpoch()) then
        n = active[uuid]
        of[id] = n
        save()
    end
    return shown[n]
end

-- Claims every visible window still without a workspace, so a switch leaves
-- them behind on the workspace they appeared on (with tiling off, nothing
-- else claims them).
local function claimAll()
    for _, win in ipairs(Util.managedWindows()) do
        if not isHidden(win:id()) then
            local info = Discover.windowInfoFor(win)
            if info.uuid and not info.full then claim(win, info.uuid) end
        end
    end
end

-- Windows `a` and `b` trade workspaces (they're trading places across
-- displays), each keeping its new one while it gets there.
function M.exchange(a, b)
    local until_ = hs.timer.secondsSinceEpoch() + 1
    of[a], of[b] = of[b], of[a]
    pins[a], pins[b] = until_, until_
    S.windowInfo[a], S.windowInfo[b] = nil, nil
    save()
end

-- ---------------------------------------------------------------------------
-- Switching
-- ---------------------------------------------------------------------------

-- Focus a window of workspace `n`: one just sent there, else the one used
-- last, else any, never `skip`. An empty workspace leaves nothing of the
-- old one focused (keys would go to a parked window), so Hammerspoon takes
-- focus.
local function focusWorkspace(n, warp, skip)
    local sent = S.spaceFocusWin
    S.spaceFocusWin = nil
    local target = sent and sent:id() and of[sent:id()] == n and sent or nil
    if not target then
        for _, fid in ipairs(Util.focusHistory) do
            local win = Util.winByID[fid]
            if of[fid] == n and fid ~= skip and win and win:id() == fid then target = win break end
        end
    end
    if not target then
        for _, win in ipairs(Util.managedWindows()) do
            if of[win:id()] == n and win:id() ~= skip then target = win break end
        end
    end

    if target then
        focusedEmpty = nil
        Focus.focus(target)
        if warp then Util.warpToWindow(target) end
    else
        S.intent = nil
        hs.focus()
        focusedEmpty = shown[n]
        Hooks.fire("focus")
        -- Nothing of ours has focus now: the pointer going back onto the
        -- window that had it focuses it again.
        S.ffmFocusedID, S.ffmLastWindow = nil, nil
        local screen = connected[shown[n]]
        if warp and screen then
            local f = screen:frame()
            hs.mouse.absolutePosition({ x = f.x + f.w / 2, y = f.y + f.h / 2 })
        end
    end
end

-- The windows of workspace `n`.
local function windowsOf(n)
    local ids = {}
    for id, m in pairs(of) do
        if m == n then ids[#ids + 1] = id end
    end
    return ids
end

-- Puts away the scratchpad showing on display `uuid`, back to the
-- workspace beneath it (its windows are already in place); with `slide`,
-- sliding it down.
local function hideScratchpad(uuid, slide)
    local base = under[uuid]
    if not base then return end
    if slide then Slide.hideScratchpad(connected[uuid], active[uuid], windowsOf(active[uuid])) end
    under[uuid] = nil
    active[uuid] = base
    refresh()
    lastSwitch = hs.timer.secondsSinceEpoch()
    sync(false)
end

-- Shows scratchpad `n` over the workspace showing on display `uuid` (or
-- in place of another scratchpad), its windows raised above it. One
-- showing on another display comes away from it.
local function showScratchpad(n, uuid)
    for other, m in pairs(active) do
        if m == n and other ~= uuid then hideScratchpad(other) end
    end
    if active[uuid] ~= n then
        -- From another display's corner: its windows keep the scratchpad
        -- while they're laid out here (unpark centres the floats).
        if home[n] and home[n] ~= uuid then
            local until_ = hs.timer.secondsSinceEpoch() + 1
            for id, m in pairs(of) do
                if m == n then
                    pins[id] = until_
                    S.windowInfo[id], S.applied[id] = nil, nil
                end
            end
        end
        local base = under[uuid] or (active[uuid] and active[uuid] <= NAMED_BASE and active[uuid]) or nil
        if base then Slide.showScratchpad(connected[uuid], n, windowsOf(n), windowsOf(base)) end
        under[uuid] = base
        active[uuid] = n
        home[n] = uuid
        refresh()
        lastSwitch = hs.timer.secondsSinceEpoch()
        sync(false)
    end
    Layout.tileNow()
    -- A maximized (or full-screen) window covers the rest: it alone is
    -- raised, and focused. Otherwise least recently used first, so the one
    -- used last ends on top. After focusing: a raise only goes above the
    -- windows of the app in front when it's that app's own.
    local wins, rank = {}, {}
    local top = S.maximized["ws" .. n]
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        if of[id] == n and (not top or id == top) then wins[#wins + 1] = win end
    end
    for i, id in ipairs(Util.focusHistory) do rank[id] = rank[id] or i end
    table.sort(wins, function(a, b) return (rank[a:id()] or math.huge) > (rank[b:id()] or math.huge) end)
    if top and #wins == 1 and not S.spaceFocusWin then S.spaceFocusWin = wins[1] end
    focusWorkspace(n, uuid ~= pointerUUID())
    for _, win in ipairs(wins) do win:raise() end
    Hud.switched(uuid)
end

-- Show workspace `n` on display `uuid` and focus it.
local function switchTo(n, uuid)
    if n > NAMED_BASE then return showScratchpad(n, uuid) end
    local pointer = pointerUUID()
    local current = under[pointer] or active[pointer]
    if current and current ~= n then
        previous = current
        if previous <= NAMED_BASE then lastNumbered = previous end
    end
    -- Hyprland's hide_special_on_workspace_change.
    hideScratchpad(uuid)
    if active[uuid] ~= n then
        local left = active[uuid]
        Slide.switch(connected[uuid], left, n, left and windowsOf(left) or {}, windowsOf(n),
            (left and n < left) and -1 or 1)
        active[uuid] = n
        home[n] = uuid
        refresh()
        lastSwitch = hs.timer.secondsSinceEpoch()
        sync(false)
    end
    -- Not just changed screens: a workspace coming back has the same
    -- windows as when it was last laid out, but they're all parked.
    Layout.tileNow()
    focusWorkspace(n, uuid ~= pointer)
    Hud.switched(uuid)
end

-- Where workspace `n` would show: where it's showing, else where it
-- belongs.
local function targetDisplay(n)
    return shown[n] or homeFor(n)
end

function M.gotoWorkspace(n)
    n = number(n)
    if not n then return end
    refresh()
    claimAll()
    -- Scratchpads come to the pointer, like Hyprland's special workspaces.
    local uuid = n > NAMED_BASE and pointerUUID() or targetDisplay(n)
    if active[uuid] == n and not under[uuid] and uuid == pointerUUID() then return end
    switchTo(n, uuid)
end

-- The display the pointer is on, its numbered workspace, and the one
-- `delta` along from it (no wrap-around: nil past either end).
local function neighbor(delta)
    refresh()
    local uuid = pointerUUID()
    local list = {}
    for n in pairs(home) do
        if displayOf(n) == uuid and n <= NAMED_BASE then list[#list + 1] = n end
    end
    table.sort(list)
    local current = under[uuid] or active[uuid]
    for i, n in ipairs(list) do
        if n == current then return uuid, current, list[i + delta] end
    end
    return uuid, current, nil
end

-- Previous/next workspace on the display the pointer is on.
function M.gotoWorkspaceRelative(delta)
    local _, _, target = neighbor(delta)
    if target then M.gotoWorkspace(target) end
end

-- For a swipe towards the workspace `delta` along on the pointer's
-- display: that display, its workspace, the one along, and each one's
-- windows; nil past either end.
function M.neighbor(delta)
    local uuid, from, to = neighbor(delta)
    if not to then return nil end
    claimAll()
    return connected[uuid], from, to, windowsOf(from), windowsOf(to)
end

-- Move the focused window to a workspace and follow it there, like
-- Hyprland's movetoworkspace (not movetoworkspacesilent).
function M.moveToWorkspace(n)
    n = number(n)
    if not n then return end
    local win = Focus.currentWindow()
    if not win then return end
    refresh()
    claimAll()

    local id = win:id()
    if of[id] == n then return end
    local from = (of[id] and shown[of[id]]) or pointerUUID()
    local to = n > NAMED_BASE and from or targetDisplay(n)
    of[id] = n
    save()
    if to ~= from then
        pins[id] = hs.timer.secondsSinceEpoch() + 1
        S.windowInfo[id] = nil
        settle()
        win:moveToScreen(connected[to], false, true, 0)
    end
    S.spaceFocusWin = win
    switchTo(n, to)
end

-- Move the focused window to a workspace without following it, like
-- Hyprland's movetoworkspacesilent: focus stays on the workspace showing.
function M.moveToWorkspaceSilent(n)
    n = number(n)
    if not n then return end
    local win = Focus.currentWindow()
    if not win then return end
    refresh()
    claimAll()

    local id = win:id()
    local current = of[id]
    if current == n then return end
    local from = (current and shown[current]) or pointerUUID()
    if not home[n] then home[n] = homeFor(n) end
    of[id] = n
    if shown[n] then
        if shown[n] ~= from then
            pins[id] = hs.timer.secondsSinceEpoch() + 1
            S.windowInfo[id] = nil
            settle()
            win:moveToScreen(connected[shown[n]], false, true, 0)
        end
    else
        park(win, n)
    end
    save()
    Layout.tileNow()
    focusWorkspace(current or active[from], false, id)
    hideEmptyScratchpads()
end

-- Workspace `n` (a number or a name) if the pointer's display isn't
-- showing it, else back. A scratchpad goes back to the workspace beneath
-- it, or comes to the pointer's display from another.
function M.toggleWorkspace(n)
    n = number(n)
    if not n then return end
    refresh()
    local at = shown[n]
    if n > NAMED_BASE and at == pointerUUID() and active[at] == n and under[at] then
        hideScratchpad(at, true)
        Layout.tileNow()
        focusWorkspace(active[at], at ~= pointerUUID())
        Hud.switched(at)
        return
    end
    local back = n > NAMED_BASE and lastNumbered or previous
    if active[pointerUUID()] == n and back then
        M.gotoWorkspace(back)
    else
        M.gotoWorkspace(n)
    end
end

-- The name a workspace is shown by.
function M.label(n)
    if n < 0 then
        local screen = connected[home[n]]
        return screen and screen:name() or "?"
    end
    local name = n > NAMED_BASE and (S.cfg.namedWorkspaces or {})[n - NAMED_BASE]
    return name or tostring(n)
end

-- The order workspaces are listed in: by number, displays' own last.
function M.before(a, b)
    if (a < 0) ~= (b < 0) then return b < 0 end
    return math.abs(a) < math.abs(b)
end

-- Back to the workspace shown before the last switch.
function M.gotoPreviousWorkspace()
    if previous then M.gotoWorkspace(previous) end
end

-- The displays left to right (then top to bottom), and where `uuid` is
-- among them.
local function displaysInOrder(uuid)
    local list = {}
    for _, screen in pairs(connected) do list[#list + 1] = screen end
    table.sort(list, function(a, b)
        local af, bf = a:fullFrame(), b:fullFrame()
        if af.x == bf.x then return af.y < bf.y end
        return af.x < bf.x
    end)
    local at = 1
    for i, screen in ipairs(list) do
        list[i] = screen:getUUID()
        if list[i] == uuid then at = i end
    end
    return list, at
end

-- The display of the focused window (else the pointer's), and the one
-- `delta` places from it left to right, wrapping around; nil for that with
-- one display.
local function displayStep(delta)
    refresh()
    local win = Focus.currentWindow()
    local n = win and of[win:id()]
    local from = (n and shown[n]) or pointerUUID()
    local list, at = displaysInOrder(from)
    if #list < 2 then return from, nil end
    return from, list[(at - 1 + delta) % #list + 1]
end

-- Focus the display `delta` places along (Hyprland's focusmonitor): its
-- workspace's last used window, or the middle of an empty one.
function M.focusDisplay(delta)
    local _, to = displayStep(delta)
    if to then focusWorkspace(active[to], true) end
end

-- The display beside display `uuid` in `direction` ("left", "right", "up",
-- "down"): the nearest one past that edge, then the one most in line.
local function displayToward(uuid, direction)
    local f = connected[uuid]:fullFrame()
    local cx, cy = f.x + f.w / 2, f.y + f.h / 2
    local best, bestKey = nil, nil
    for other, screen in pairs(connected) do
        if other ~= uuid then
            local o = screen:fullFrame()
            local gap, offset
            if direction == "left" then gap = f.x - (o.x + o.w)
            elseif direction == "right" then gap = o.x - (f.x + f.w)
            elseif direction == "up" then gap = f.y - (o.y + o.h)
            else gap = o.y - (f.y + f.h) end
            if direction == "left" or direction == "right" then
                offset = math.abs(o.y + o.h / 2 - cy)
            else
                offset = math.abs(o.x + o.w / 2 - cx)
            end
            local key = math.max(gap, 0) * 1e6 + offset
            if gap >= -1 and (not bestKey or key < bestKey) then best, bestKey = other, key end
        end
    end
    return best
end

function M.displayToward(uuid, direction)
    refresh()
    return connected[uuid] and displayToward(uuid, direction) or nil
end

-- Focus the display beside the focused one (else the pointer's) in
-- `direction`, like Hyprland's movefocus past the last window: its
-- workspace's last used window, or the display itself when that's empty.
-- False if there's no display that way.
function M.focusDisplayToward(direction)
    refresh()
    local win = Focus.currentWindow()
    local n = win and of[win:id()]
    local from = (n and shown[n]) or pointerUUID()
    local to = from and displayToward(from, direction)
    if not to then return false end
    focusWorkspace(active[to], true)
    return true
end

-- The pointer is over no window at `point`: a display showing an empty
-- workspace takes focus as the pointer comes onto it (Hyprland focuses the
-- monitor under the pointer).
function M.pointerOverNothing(point)
    -- Not over the menu bar: that shows the menus of the app in front.
    local uuid = nil
    for id, screen in pairs(connected) do
        if Util.pointInFrame(point, screen:frame()) then uuid = id break end
    end
    local n = uuid and active[uuid]
    if not n or focusedEmpty == uuid or M.hasWindows(n) then return end
    focusWorkspace(n, false)
end

-- A window took focus: the empty display that had it doesn't any more. A
-- new window that has no workspace yet is still on its way there.
function M.windowFocused(id)
    if of[id] ~= nil then focusedEmpty = nil end
end

-- Send the focused window to the workspace showing on the display `delta`
-- places along, and follow it.
function M.moveToDisplay(delta)
    local _, to = displayStep(delta)
    if to then M.moveToWorkspace(active[to]) end
end

-- Move the workspace showing on the focused display to the display `delta`
-- places along (Hyprland's movecurrentworkspacetomonitor), windows and
-- all. The display left behind shows another of its workspaces, or a new
-- one; the one it goes to keeps its own for later. Workspaces S.cfg.displays
-- gives a display, and displays' own, stay put.
function M.moveWorkspaceToDisplay(delta)
    local from, to = displayStep(delta)
    if not to then return end
    local n = under[from] or active[from]
    if n < 0 or pinnedTo[n] then return end
    hideScratchpad(from)
    hideScratchpad(to)
    claimAll()
    n = active[from]
    local replacement = nil
    for m, uuid in pairs(home) do
        if uuid == from and m ~= n and not shown[m] and (not replacement or m < replacement) then
            replacement = m
        end
    end
    home[n], active[to], active[from] = to, n, replacement
    refresh()

    local until_ = hs.timer.secondsSinceEpoch() + 1
    settle()
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        if of[id] == n then
            pins[id] = until_
            S.windowInfo[id], S.applied[id] = nil, nil
            win:moveToScreen(connected[to], false, true, 0)
        end
    end
    lastSwitch = hs.timer.secondsSinceEpoch()
    sync(false)
    Layout.scheduleRetile(true)
    focusWorkspace(n, true)
    Hud.switched(to)
    Hud.switched(from)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- A window became visible, or moved on its own: parked windows go (back)
-- into their corner, ones that are showing come out of it. `force` re-parks
-- a window that is already parked (an app moved it back into view).
function M.place(win, force)
    local id = win and win:id()
    local n = id and of[id]
    if not n then
        -- With tiling off nothing else claims a new window straight away;
        -- one a rule sends to a workspace shouldn't wait for a switch.
        if id and not S.tilingEnabled and Util.rulesFor(win).workspace then
            local screen = win:screen()
            if screen then claim(win, screen:getUUID()) end
        end
        return
    end
    if shown[n] then
        if parked[id] then unpark(win) end
    elseif not parked[id] then
        park(win, n)
        save()
    elseif force then
        -- Our own parking echoes back as moves too.
        local f = win:frame()
        local uuid = displayOf(n)
        if not inCorner(f, parkPoint(uuid, f), uuid) then park(win, n) end
    end
end

-- macOS focused a parked window. The user picked it (Cmd-Tab, the Dock, a
-- notification), so go to its workspace. Straight after a window went away
-- or we switched it's macOS choosing a replacement, so focus stays on the
-- workspace showing.
function M.focusedParked(win)
    local now = hs.timer.secondsSinceEpoch()
    local going = Focus.goneBefore(win)
    if going or now - lastSwitch < 0.5 or now - S.lastGoneTime < 1 then
        local n = active[pointerUUID()]
        if n then focusWorkspace(n, false, going) end
        return
    end
    S.spaceFocusWin = win
    local n = of[win:id()]
    -- Beneath a scratchpad: that goes.
    for uuid, base in pairs(under) do
        if base == n and behind[n] then
            hideScratchpad(uuid, true)
            Layout.tileNow()
            focusWorkspace(n, false)
            Hud.switched(uuid)
            return
        end
    end
    M.gotoWorkspace(n)
end

-- Where a parked window goes back to (tiling turned off while it was parked).
function M.setParkedFrame(id, frame)
    if not parked[id] then return end
    parked[id] = { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
    save()
end

-- A scratchpad showing without windows goes, like Hyprland's.
function hideEmptyScratchpads()
    for uuid, base in pairs(under) do
        local n = active[uuid]
        local empty = true
        for _, m in pairs(of) do
            if m == n then empty = false break end
        end
        if empty then
            hideScratchpad(uuid)
            Layout.tileNow()
            focusWorkspace(base, false)
            Hud.switched(uuid)
        end
    end
end

-- A window closed, or left for a full-screen Space or the Dock.
function M.forget(id)
    if not id or (of[id] == nil and parked[id] == nil) then return end
    of[id], parked[id], pins[id], info[id] = nil, nil, nil, nil
    save()
    hideEmptyScratchpads()
end

-- Displays came or went: workspaces of a missing display move to the
-- primary one, and every parked window goes to its (possibly new) corner.
function M.screensChanged()
    Slide.reset()
    refresh()
    sync(true)
end

-- The tree key of the workspace showing on a display, and back.
function M.keyForUUID(uuid)
    if not connected[uuid] or not active[uuid] then refresh() end
    return "ws" .. tostring(active[uuid])
end

-- The share of the area a workspace's tiles are laid out in: less than
-- the whole for a scratchpad, so the workspace beneath shows around it.
function M.layoutScale(key)
    local n = key and tonumber(key:match("^ws(%-?%d+)$"))
    if n and n > NAMED_BASE then return S.cfg.scratchpadScale end
    return nil
end

function M.uuidForKey(key)
    local n = key and tonumber(key:match("^ws(%-?%d+)$"))
    return n and displayOf(n)
end

-- Notes every window's title for matching windows after a restart (see
-- hyprspoon/restore.lua). Accessibility calls, so only on the way out.
function M.rememberTitles()
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        if id and of[id] then
            if not info[id] then
                local app = win:application()
                info[id] = { app = app and app:bundleID() }
            end
            info[id].title = win:title()
        end
    end
    saveNow()
end

-- Brings every parked window back where it was, keeping the workspaces so
-- the next start parks them again. For quitting: nothing would be left to
-- bring them back.
function M.unparkAll()
    if reloading or next(parked) == nil then return end
    -- Windows of hidden apps aren't in the filter's list.
    for _, win in ipairs(hs.window.allWindows()) do
        local f = win:id() and parked[win:id()]
        if f then win:setFrame(f, 0) end
    end
    parked = {}
    saveNow()
end

-- The workspaces in use, by number: { n =, display = UUID showing it or
-- nil } for each.
function M.workspaces()
    local list = {}
    for n in pairs(home) do list[#list + 1] = { n = n, display = shown[n] } end
    table.sort(list, function(a, b) return M.before(a.n, b.n) end)
    return list
end

-- For hyprspoon/overview.lua: each workspace in use, by number, as { n =,
-- display = UUID it shows on, showing =, windows = { { id =, win =,
-- frame = } } }, tiles first, then floats, each with where it is or (when
-- parked) where it goes back to.
function M.overview()
    refresh()
    local byN, list = {}, {}
    for n in pairs(home) do
        byN[n] = { n = n, display = displayOf(n), showing = shown[n] ~= nil, windows = {} }
        list[#list + 1] = byN[n]
    end
    local floats = {}
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        local ws = of[id] and byN[of[id]]
        if ws then
            local frame = Tree.rectFor(id) or parked[id]
            if not frame then
                local f = win:frame()
                frame = { x = f.x, y = f.y, w = f.w, h = f.h }
            end
            local entry = { id = id, win = win, frame = frame }
            if S.autoFloat[id] then floats[#floats + 1] = { ws, entry } else table.insert(ws.windows, entry) end
        end
    end
    for _, f in ipairs(floats) do table.insert(f[1].windows, f[2]) end
    table.sort(list, function(a, b) return M.before(a.n, b.n) end)
    return list
end

-- The connected displays, the primary first and then left to right, as
-- { uuid =, screen =, n = the workspace it shows }.
function M.displays()
    refresh()
    local list = {}
    for _, screen in ipairs(orderedScreens()) do
        local uuid = screen:getUUID()
        list[#list + 1] = { uuid = uuid, screen = screen, n = active[uuid] }
    end
    return list
end

-- The workspace with focus: the empty one whose display took focus, else
-- the focused window `win`'s, else the one showing on its display (an app
-- we don't track) or the pointer's.
function M.focusedWorkspace(win)
    if focusedEmpty and connected[focusedEmpty] and active[focusedEmpty] then
        return active[focusedEmpty]
    end
    local n = win and of[win:id()]
    if n and shown[n] and not behind[n] then return n end
    local screen = win and win:screen()
    return active[screen and screen:getUUID() or pointerUUID()]
end

function M.isScratchpad(n)
    return n > NAMED_BASE
end

function M.hasWindows(n)
    for _, m in pairs(of) do
        if m == n then return true end
    end
    return false
end

function M.start()
    refresh()
    sync(false)
end

-- Flushes a pending save (reload, shutdown).
function M.stop()
    if saveTimer then saveNow() end
end

M.isHidden = isHidden
M.claim = claim
M.displayOf = displayOf

-- Loaded with the module rather than in start(): if start() fails partway,
-- the window events it already subscribed to still claim windows and save,
-- and doing that over empty state would put every window on one workspace
-- and overwrite the saved one.
loadState()

return M
