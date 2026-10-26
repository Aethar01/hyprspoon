-- wm/spaces.lua: Numbered workspaces, kept by the window manager itself.

local M = {}
package.loaded["wm.spaces"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")
local Focus = require("wm.focus")
local Discover = require("wm.discover")
local Layout = require("wm.layout")
local Bar = require("wm.bar")
local Hud = require("wm.hud")
local Border = require("wm.border")
local Float = require("wm.float")

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
-- Like Hyprland's: numbered, created on first use on the display under the
-- pointer, and forgotten once empty and no longer showing. Each display
-- shows one workspace; going to one showing on another display moves the
-- pointer there. While a display is disconnected its workspaces live on the
-- primary display.
--
-- Windows join the workspace showing on their display when they first
-- appear, and the one on their new display when they change display. They
-- leave theirs when minimized or made full screen, and join the one showing
-- when they come back.
--
-- Use one macOS Desktop per display: the window filter only sees the
-- current Desktop's windows.
--
-- Workspace 0 is the scratchpad (Hyprland's special workspace): its
-- windows float, and it's shown over the workspace on a display only while
-- toggled on. It's never a display's own workspace, nor listed.

-- Window IDs are only meaningful within one boot, so the saved state is
-- discarded after a restart (see Tree.bootTime).
local STATE_KEY = "wmWorkspaces"

local SCRATCH = 0
local scratchOn = nil -- UUID of the display the scratchpad shows on, if it does

local active = {} -- screen UUID -> workspace number it shows
local home = {}   -- workspace number -> screen UUID it lives on
local of = {}     -- window id -> workspace number
local parked = {} -- window id -> its frame before it was parked
local pins = {}   -- window id -> until when its workspace ignores its display

-- Derived by refresh() from the above and the connected displays.
local connected = {} -- screen UUID -> hs.screen
local shown = {}     -- workspace number -> UUID of the display showing it
local primaryUUID = nil

-- When we last switched, and when a window last went away: macOS focusing a
-- parked window just after either is its own pick, not the user's.
local lastSwitch = 0
S.lastGoneTime = 0

-- The workspace the pointer's display showed before the last switch, for
-- going back to it.
local previous = nil

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
    local out = { boot = Tree.bootTime, active = {}, home = {}, of = {}, parked = {} }
    for uuid, n in pairs(active) do out.active[uuid] = n end
    for n, uuid in pairs(home) do out.home[tostring(n)] = uuid end
    for id, n in pairs(of) do out.of[tostring(id)] = n end
    for id, f in pairs(parked) do out.parked[tostring(id)] = f end
    hs.settings.set(STATE_KEY, out)
end

-- Every change to the workspaces is saved, so this is also where the menu
-- bar and badges hear about them.
local function save()
    if saveTimer then saveTimer:stop() end
    saveTimer = hs.timer.doAfter(1, saveNow)
    Bar.update()
    Hud.update()
end

local function loadState()
    active, home, of, parked, pins = {}, {}, {}, {}, {}
    local saved = hs.settings.get(STATE_KEY)
    if type(saved) ~= "table" or type(saved.boot) ~= "number"
       or math.abs(saved.boot - Tree.bootTime) >= 120 then
        return
    end
    for uuid, n in pairs(saved.active or {}) do active[uuid] = tonumber(n) end
    for n, uuid in pairs(saved.home or {}) do home[tonumber(n)] = uuid end
    for id, n in pairs(saved.of or {}) do of[tonumber(id)] = tonumber(n) end
    for id, f in pairs(saved.parked or {}) do
        parked[tonumber(id)] = { x = f.x, y = f.y, w = f.w, h = f.h, resize = f.resize }
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

local function freeWorkspace()
    local n = 1
    while home[n] do n = n + 1 end
    return n
end

local function refresh()
    connected = {}
    local screens = orderedScreens()
    primaryUUID = screens[1] and screens[1]:getUUID()
    for _, screen in ipairs(screens) do connected[screen:getUUID()] = screen end

    -- Every display shows a workspace of its own. The one a display showed
    -- may have been taken to another display while it was disconnected.
    for _, screen in ipairs(screens) do
        local uuid = screen:getUUID()
        local n = active[uuid]
        if not n or home[n] ~= uuid then
            n = freeWorkspace()
            active[uuid], home[n] = n, uuid
        end
    end

    shown = {}
    for uuid, n in pairs(active) do
        if connected[uuid] and displayOf(n) == uuid then shown[n] = uuid end
    end
    if scratchOn and not connected[scratchOn] then scratchOn = nil end
    shown[SCRATCH] = scratchOn
end

local function pointerUUID()
    local screen = hs.mouse.getCurrentScreen()
    return screen and screen:getUUID() or primaryUUID
end

-- True for a window parked on a workspace that isn't showing.
local function isHidden(id)
    local n = id and of[id]
    return n ~= nil and shown[n] == nil
end

-- Workspaces that are empty and not showing anywhere are forgotten, so the
-- number is free to be created afresh on another display.
local function forgetEmpty()
    local used = {}
    for _, n in pairs(of) do used[n] = true end
    for _, n in pairs(active) do used[n] = true end
    for n in pairs(home) do
        if not used[n] then
            home[n] = nil
            S.trees["ws" .. n] = nil
            S.maximized["ws" .. n] = nil
            S.untiled["ws" .. n] = nil
        end
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

-- Moves a window into its workspace's corner, remembering where it was the
-- first time. Its tile is the frame when it has one (no accessibility read).
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
    win:setTopLeft(parkPoint(displayOf(n), frame))
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
    if frame.resize then win:setFrame(frame, 0) else win:setTopLeft(frame) end
end

-- Parks the windows of workspaces not showing and brings back the rest.
-- Parked windows stay put unless `force` (displays changed, so corners did).
local function sync(force)
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
    -- A rule's workspace (see S.cfg.rules), the first time it's seen.
    local rule = not n and Util.rulesFor(win)
    local wanted = rule and (rule.workspace == "scratchpad" and SCRATCH or math.tointeger(rule.workspace))
    if wanted and wanted >= 0 and wanted ~= active[uuid] then
        of[id] = wanted
        if wanted == SCRATCH then
            S.autoFloat[id] = true
            rule = { silent = true }
        elseif not home[wanted] then
            home[wanted] = uuid
        end
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
        Focus.focus(target)
        if warp then Util.warpToWindow(target) end
    else
        S.intent = nil
        hs.focus()
        local screen = connected[shown[n]]
        if warp and screen then
            local f = screen:frame()
            hs.mouse.absolutePosition({ x = f.x + f.w / 2, y = f.y + f.h / 2 })
        end
    end
end

-- Show workspace `n` on display `uuid` and focus it.
local function switchTo(n, uuid)
    local pointer = pointerUUID()
    if active[pointer] and active[pointer] ~= n then previous = active[pointer] end
    if active[uuid] ~= n then
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

-- Where workspace `n` would show: where it's showing, its own display, or
-- (a new one) `fallback`.
local function targetDisplay(n, fallback)
    return shown[n] or (home[n] and displayOf(n)) or fallback
end

function M.gotoWorkspace(n)
    refresh()
    claimAll()
    local uuid = targetDisplay(n, pointerUUID())
    if active[uuid] == n and uuid == pointerUUID() then return end
    switchTo(n, uuid)
end

-- Previous/next workspace on the display the pointer is on (no wrap-around).
function M.gotoWorkspaceRelative(delta)
    refresh()
    local uuid = pointerUUID()
    local list = {}
    for n in pairs(home) do
        if displayOf(n) == uuid then list[#list + 1] = n end
    end
    table.sort(list)
    for i, n in ipairs(list) do
        if n == active[uuid] then
            local target = list[i + delta]
            if target then M.gotoWorkspace(target) end
            return
        end
    end
end

-- Move the focused window to a workspace and follow it there, like
-- Hyprland's movetoworkspace (not movetoworkspacesilent).
-- A window leaving the scratchpad floats or tiles as it would have.
local function leaveScratchpad(id)
    if of[id] == SCRATCH then Float.forgetFloat(id) end
end

function M.moveToWorkspace(n)
    local win = Focus.currentWindow()
    if not win then return end
    refresh()
    claimAll()

    local id = win:id()
    if of[id] == n then return end
    leaveScratchpad(id)
    local from = (of[id] and shown[of[id]]) or pointerUUID()
    local to = targetDisplay(n, from)
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
    local win = Focus.currentWindow()
    if not win then return end
    refresh()
    claimAll()

    local id = win:id()
    local current = of[id]
    if current == n then return end
    leaveScratchpad(id)
    local from = (current and shown[current]) or pointerUUID()
    if not home[n] then home[n] = from end
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
    focusWorkspace((current ~= SCRATCH and current) or active[from], false, id)
end

-- Put the focused window in the scratchpad, floating, centred on its
-- display. Out of sight unless the scratchpad is showing.
function M.moveToScratchpad()
    local win = Focus.currentWindow()
    if not win then return end
    refresh()
    claimAll()

    local id = win:id()
    local current = of[id]
    if current == SCRATCH then return end
    local from = (current and shown[current]) or pointerUUID()
    local f = win:frame()
    local sf = connected[from]:frame()
    local centred = { x = sf.x + (sf.w - f.w) / 2, y = sf.y + (sf.h - f.h) / 2 }
    of[id] = SCRATCH
    S.autoFloat[id] = true
    if shown[SCRATCH] then
        settle()
        win:setTopLeft(centred)
    else
        parked[id] = { x = centred.x, y = centred.y, w = f.w, h = f.h }
        park(win, SCRATCH)
    end
    save()
    Layout.tileNow()
    if not shown[SCRATCH] then focusWorkspace(current or active[from], false, id) end
end

-- Show the scratchpad over the workspace on the focused display (focusing
-- its last used window, with the pointer on it), or hide it again.
function M.toggleScratchpad()
    refresh()
    lastSwitch = hs.timer.secondsSinceEpoch()
    if shown[SCRATCH] then
        local on = scratchOn
        scratchOn = nil
        refresh()
        sync(false)
        focusWorkspace(active[on], false)
        return
    end
    if not M.hasWindows(SCRATCH) then
        hs.alert.show("Scratchpad is empty")
        return
    end
    local win = Focus.currentWindow()
    local n = win and of[win:id()]
    scratchOn = (n and shown[n]) or pointerUUID()
    refresh()
    sync(false)
    focusWorkspace(SCRATCH, true)
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

-- Send the focused window to the workspace showing on the display `delta`
-- places along, and follow it.
function M.moveToDisplay(delta)
    local _, to = displayStep(delta)
    if to then M.moveToWorkspace(active[to]) end
end

-- Move the workspace showing on the focused display to the display `delta`
-- places along (Hyprland's movecurrentworkspacetomonitor), windows and
-- all. The display left behind shows another of its workspaces, or a new
-- one; the one it goes to keeps its own for later.
function M.moveWorkspaceToDisplay(delta)
    local from, to = displayStep(delta)
    if not to then return end
    claimAll()
    local n = active[from]
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
    if of[win:id()] == SCRATCH then
        M.toggleScratchpad()
    else
        M.gotoWorkspace(of[win:id()])
    end
end

-- Where a parked window goes back to (tiling turned off while it was parked).
function M.setParkedFrame(id, frame)
    if not parked[id] then return end
    parked[id] = { x = frame.x, y = frame.y, w = frame.w, h = frame.h, resize = true }
    save()
end

-- A window closed, or left for a full-screen Space or the Dock.
function M.forget(id)
    if not id or (of[id] == nil and parked[id] == nil) then return end
    of[id], parked[id], pins[id] = nil, nil, nil
    save()
end

-- Displays came or went: workspaces of a missing display move to the
-- primary one, and every parked window goes to its (possibly new) corner.
function M.screensChanged()
    refresh()
    sync(true)
end

-- The tree key of the workspace showing on a display, and back.
function M.keyForUUID(uuid)
    if not connected[uuid] or not active[uuid] then refresh() end
    return "ws" .. tostring(active[uuid])
end

function M.uuidForKey(key)
    local n = key and tonumber(key:match("^ws(%d+)$"))
    return n and displayOf(n)
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
    table.sort(list, function(a, b) return a.n < b.n end)
    return list
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

-- Loaded with the module rather than in start(): if setup fails partway,
-- the window events it already subscribed to still claim windows and save,
-- and doing that over empty state would put every window on one workspace
-- and overwrite the saved one.
loadState()

return M
