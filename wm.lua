-- ~/.hammerspoon/wm.lua
--
-- Hyprland-inspired window manager for Hammerspoon:
--   * toggleable BSP tiling (per Space + display), with drag-and-drop and
--     split resizing by mouse, keyboard, or native window edges
--   * modifier + drag anywhere on a window to move/resize it
--   * focus follows mouse, with cursor warping on keyboard focus changes
--   * directional focus/swap/resize and numbered workspaces (macOS Spaces)
--
-- Usage (init.lua):
--
--   local wm = require("wm")
--   wm.setup({ ...options, see `defaults` below... })
--   hs.hotkey.bind({"alt"}, "b", wm.toggleTiling)
--   hs.hotkey.bind({"alt"}, "h", function() wm.focus("left") end)
--
-- Nothing happens on require; wm.setup() starts the event taps and watchers.
-- Keybindings are left to the caller; mouse bindings are configured here
-- because they're eventtaps rather than hotkeys.

local M = {}

local defaults = {
    -- Focus the window under the pointer as it moves.
    focusFollowsMouse = true,
    reassertFocus = true, -- undo macOS moving focus right after we set it

    -- Seconds to wait on an unresponsive app's accessibility API before
    -- giving up on a call.
    axTimeout = 1,

    -- Smallest size the mouse/keyboard resizes will shrink a window to.
    minWidth = 240,
    minHeight = 140,

    -- Modifiers held while dragging anywhere on a window. Set any to false
    -- to disable that binding.
    mouse = {
        move = {"alt"},          -- + left-drag: move (drops into tiling layout)
        resize = {"alt", "cmd"}, -- + left-drag: resize
        rightResize = {"alt"},   -- + right-drag: resize
    },

    -- App names whose windows are never watched or tiled (palettes, overlays,
    -- anything noisy). Fewer watched windows means fewer events to process.
    ignoreApps = {},

    tiling = {
        outerGap = 10,  -- gap between tiles and the screen edge
        innerGap = 5,   -- gap between tiles
        minRatio = 0.20, -- how far a split can be dragged towards either side
        maxRatio = 0.80,
        -- Drag-and-drop landing highlight.
        dropColor = { red = 0.35, green = 0.6, blue = 1 },
    },
}

local cfg = nil

-- Tiling on/off persists across reloads.
local SETTINGS_KEY = "bspTilingEnabled"
local bspTilingEnabled = hs.settings.get(SETTINGS_KEY) == true

-- Long-lived objects (taps, watchers, filters). Kept here so they're
-- reachable from the module and never garbage collected.
local running = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function deepMerge(base, override)
    local out = {}
    for k, v in pairs(base) do
        if type(v) == "table" and type(override[k]) == "table" and v[1] == nil then
            out[k] = deepMerge(v, override[k])
        elseif override[k] ~= nil then
            out[k] = override[k]
        else
            out[k] = v
        end
    end
    for k, v in pairs(override) do
        if out[k] == nil then out[k] = v end
    end
    return out
end

cfg = deepMerge(defaults, {})

-- Our own record of focus, kept in step with the BSP tree. macOS's idea of
-- the focused window lags our actions and can be moved by the system (e.g. on
-- close), so actions read this; macOS is only asked to *do* things.
local bspFocusHistory = {} -- most recent first
local bspFocusTimes = {}   -- window id -> when it last gained focus
local bspWinByID = {}      -- window id -> hs.window, for every tiled window

-- macOS's view of focus (an accessibility query). Use currentWindow() for
-- actions; this is for checking what macOS actually did.
local function focusedWindow()
    return hs.window.focusedWindow()
end

-- Assigned in the tree section: the tile rectangle of a tiled window, or nil.
local bspRectFor

local function warpToWindow(win)
    if not win then return end
    -- Tiled windows warp to where their tile is, not where the app currently
    -- reports the window (which lags while it resizes).
    local f = bspRectFor and bspRectFor(win:id()) or win:frame()
    hs.mouse.absolutePosition({
        x = f.x + f.w / 2,
        y = f.y + f.h / 2,
    })
end

local function warpToFocusedWindow(delay)
    if delay and delay > 0 then
        hs.timer.doAfter(delay, function()
            warpToWindow(focusedWindow())
        end)
    else
        warpToWindow(focusedWindow())
    end
end

local function pointInFrame(point, frame)
    return point.x >= frame.x and point.x < (frame.x + frame.w)
       and point.y >= frame.y and point.y < (frame.y + frame.h)
end

-- Set by the mouse tap while a modifier-drag is in progress.
local dragState = nil

-- A snapshot of standard, visible window frames in z-order, shared by focus
-- follows mouse (so mouse movement never makes accessibility calls), hit
-- testing and directional focus. It is dropped whenever windows move, appear,
-- disappear or change focus.
local ffmLastWindow = nil   -- snapshot entry under the pointer
local ffmSnapshot = nil
local bspAutoFloat   -- window id -> floating? (assigned in the float section)
local ffmFocusedID = nil    -- tracked from windowFocused, avoids an AX query
local FFM_SNAPSHOT_TTL = 1.0
local FFM_HOVER_DELAY = 0.03

-- ---------------------------------------------------------------------------
-- Internal focus
-- ---------------------------------------------------------------------------
--
-- Focus is recorded when macOS reports it *and* when we ask for it, so the
-- model is right immediately after our own actions. If macOS then moves focus
-- elsewhere within REASSERT_WINDOW of one of our requests (it does this when
-- windows close or open), the request is re-applied.

local REASSERT_WINDOW = 0.4
local bspIntent = nil -- { id =, time = } for our most recent focus request

local function bspNoteFocus(win)
    local id = win:id()
    if not id then return end
    for i = #bspFocusHistory, 1, -1 do
        if bspFocusHistory[i] == id then table.remove(bspFocusHistory, i) end
    end
    table.insert(bspFocusHistory, 1, id)
    local dropped = bspFocusHistory[21]
    bspFocusHistory[21] = nil
    if dropped then bspFocusTimes[dropped] = nil end
    bspFocusTimes[id] = hs.timer.secondsSinceEpoch()
    bspWinByID[id] = bspWinByID[id] or win
    ffmFocusedID = id
end

-- Focus a window on our own initiative.
local function bspFocus(win)
    if not win then return end
    if cfg.reassertFocus then
        bspIntent = { id = win:id(), time = hs.timer.secondsSinceEpoch() }
    end
    bspNoteFocus(win)
    win:focus()
end

-- The window actions apply to: our own record of focus, falling back to
-- macOS's when an app we don't track (ignored apps) is frontmost.
local function currentWindow()
    local id = bspFocusHistory[1]
    local win = id and bspWinByID[id]
    if win and win:id() == id then
        local front = hs.application.frontmostApplication()
        local app = win:application()
        if front and app and front:pid() == app:pid() then return win end
    end
    return focusedWindow()
end

-- Rebuilds the snapshot shortly after invalidations go quiet, so the next
-- mouse move doesn't pay for several accessibility calls per window.
local ffmPrebuild = nil

local function invalidateWindowCache()
    ffmSnapshot = nil
    ffmLastWindow = nil
    if ffmPrebuild then ffmPrebuild:start() end
end

-- `fresh` rebuilds the snapshot even if it hasn't expired, for callers that
-- run rarely and need to be right (or run just after a Space switch).
local function windowSnapshot(fresh)
    local now = hs.timer.secondsSinceEpoch()
    if fresh or not ffmSnapshot or now - ffmSnapshot.time > FFM_SNAPSHOT_TTL then
        local entries = {}
        for _, win in ipairs(hs.window.orderedWindows()) do
            local id = win:id()
            -- A tiled window is already known to be standard and visible, and
            -- its tile is where it is: no need to ask the app.
            local tile = bspRectFor(id)
            if tile then
                table.insert(entries, { win = win, id = id, frame = tile })
            elseif win:isStandard() and win:isVisible() then
                table.insert(entries, { win = win, id = id, frame = win:frame() })
            end
        end
        -- orderedWindows() omits windows of accessory apps (e.g. LinearMouse
        -- settings), so add any floats the window filter knows about.
        if running.windowFilter then
            local seen = {}
            for _, e in ipairs(entries) do seen[e.id] = true end
            for _, win in ipairs(running.windowFilter:getWindows() or {}) do
                local id = win:id()
                if id and bspAutoFloat[id] and not seen[id] then
                    table.insert(entries, { win = win, id = id, frame = win:frame() })
                end
            end
        end
        ffmSnapshot = { time = now, entries = entries }
    end
    return ffmSnapshot.entries
end

ffmPrebuild = hs.timer.delayed.new(0.15, function()
    if ffmSnapshot or dragState or not cfg.focusFollowsMouse then return end
    windowSnapshot(true)
end)

-- Floats are meant to sit on top, so they win over whatever tile is actually
-- stacked above them (a buried float is still reachable).
local function snapshotEntryAt(point, fresh)
    local entries = windowSnapshot(fresh)
    for _, entry in ipairs(entries) do
        if bspAutoFloat[entry.id] and pointInFrame(point, entry.frame) then
            return entry
        end
    end
    for _, entry in ipairs(entries) do
        if pointInFrame(point, entry.frame) then return entry end
    end
    return nil
end

local function windowUnderPoint(point, fresh)
    local entry = snapshotEntryAt(point, fresh)
    return entry and entry.win
end

-- ---------------------------------------------------------------------------
-- BSP tiling: tree
-- ---------------------------------------------------------------------------
--
-- The tree is kept per active Space + display. New windows are inserted by
-- splitting the most recently focused leaf; split orientation alternates by
-- tree depth. Closing/minimizing/moving windows prunes the tree automatically.
--
-- When tiling is disabled, pre-tiling floating frames are restored when known.

-- Trees persist across config reloads (window IDs survive a reload; stale
-- ones are pruned when the tree is reconciled).
local TREES_KEY = "bspTrees"
local bspTrees = hs.settings.get(TREES_KEY) or {}

local function bspStripTree(node)
    if not node then return nil end
    if node.windowID ~= nil then return { windowID = node.windowID } end
    return {
        split = node.split,
        ratio = node.ratio,
        a = bspStripTree(node.a),
        b = bspStripTree(node.b),
    }
end

-- Writing settings is a preferences-file write, so saves are debounced and
-- skipped when the serialized trees haven't changed. Flushed on stop/reload.
local bspSavedTrees = nil
local bspSaveTimer = nil

local function bspSaveTreesNow()
    local out = {}
    for key, tree in pairs(bspTrees) do
        out[key] = bspStripTree(tree)
    end
    local encoded = hs.json.encode(out)
    if encoded == bspSavedTrees then return end
    bspSavedTrees = encoded
    hs.settings.set(TREES_KEY, out)
end

local function bspSaveTrees()
    if bspSaveTimer then bspSaveTimer:stop() end
    bspSaveTimer = hs.timer.doAfter(1, function()
        bspSaveTimer = nil
        bspSaveTreesNow()
    end)
end

local bspFloatingFrames = {}
local bspRetileTimer = nil
local bspPendingRefocus = nil -- window id to focus once the next retile is done
local bspApplyingLayout = false

local function bspLeaf(windowID)
    return { windowID = windowID }
end

local function bspIsLeaf(node)
    return node and node.windowID ~= nil
end

local function bspTreeContains(node, windowID)
    if not node then return false end
    if bspIsLeaf(node) then
        return node.windowID == windowID
    end
    return bspTreeContains(node.a, windowID)
        or bspTreeContains(node.b, windowID)
end

local function bspPrune(node, valid)
    if not node then return nil end

    if bspIsLeaf(node) then
        if valid[node.windowID] then return node end
        return nil
    end

    node.a = bspPrune(node.a, valid)
    node.b = bspPrune(node.b, valid)

    if not node.a then return node.b end
    if not node.b then return node.a end
    return node
end

local function bspCollectIDs(node, out)
    out = out or {}
    if not node then return out end

    if bspIsLeaf(node) then
        out[node.windowID] = true
        return out
    end

    bspCollectIDs(node.a, out)
    bspCollectIDs(node.b, out)
    return out
end

local function bspRightmostLeafID(node)
    if not node then return nil end
    if bspIsLeaf(node) then return node.windowID end
    return bspRightmostLeafID(node.b) or bspRightmostLeafID(node.a)
end

local function bspInsertAt(node, targetID, newID, depth)
    depth = depth or 0

    if not node then
        return bspLeaf(newID), true
    end

    if bspIsLeaf(node) then
        if node.windowID ~= targetID then
            return node, false
        end

        local split = (depth % 2 == 0) and "vertical" or "horizontal"
        return {
            split = split,
            ratio = 0.5,
            a = node,
            b = bspLeaf(newID),
        }, true
    end

    local replaced, inserted = bspInsertAt(node.a, targetID, newID, depth + 1)
    if inserted then
        node.a = replaced
        return node, true
    end

    replaced, inserted = bspInsertAt(node.b, targetID, newID, depth + 1)
    if inserted then
        node.b = replaced
        return node, true
    end

    return node, false
end

local function bspInsertBeside(node, targetID, newID, side)
    if not node then return nil, false end

    if bspIsLeaf(node) then
        if node.windowID ~= targetID then return node, false end

        local newLeaf = bspLeaf(newID)
        local newFirst = side == "left" or side == "top"
        return {
            split = (side == "left" or side == "right") and "vertical" or "horizontal",
            ratio = 0.5,
            a = newFirst and newLeaf or node,
            b = newFirst and node or newLeaf,
        }, true
    end

    local replaced, inserted = bspInsertBeside(node.a, targetID, newID, side)
    if inserted then
        node.a = replaced
        return node, true
    end

    replaced, inserted = bspInsertBeside(node.b, targetID, newID, side)
    if inserted then
        node.b = replaced
    end
    return node, inserted
end

-- The side of `frame` nearest `point`: "left", "right", "top" or "bottom".
local function bspNearestSide(frame, point)
    local rx = (point.x - frame.x) / frame.w
    local ry = (point.y - frame.y) / frame.h

    local side, dist = "left", rx
    if 1 - rx < dist then side, dist = "right", 1 - rx end
    if ry < dist then side, dist = "top", ry end
    if 1 - ry < dist then side = "bottom" end
    return side
end

-- The leaf whose tile contains `point`, from the last applied layout.
local function bspLeafAtPoint(node, point)
    if not node then return nil end
    if bspIsLeaf(node) then
        if node.rect and pointInFrame(point, node.rect) then return node end
        return nil
    end
    return bspLeafAtPoint(node.a, point) or bspLeafAtPoint(node.b, point)
end

local function bspRemoveID(node, windowID)
    if not node then return nil end

    if bspIsLeaf(node) then
        if node.windowID == windowID then return nil end
        return node
    end

    node.a = bspRemoveID(node.a, windowID)
    node.b = bspRemoveID(node.b, windowID)

    if not node.a then return node.b end
    if not node.b then return node.a end
    return node
end

local function bspSwapIDs(node, idA, idB)
    if not node then return end

    if bspIsLeaf(node) then
        if node.windowID == idA then
            node.windowID = idB
        elseif node.windowID == idB then
            node.windowID = idA
        end
        return
    end

    bspSwapIDs(node.a, idA, idB)
    bspSwapIDs(node.b, idA, idB)
end

-- Split nodes above a leaf, nearest first, with the branch the leaf is in.
-- Also returns the leaf itself.
local function bspAncestors(node, windowID)
    if not node then return nil end

    if bspIsLeaf(node) then
        if node.windowID == windowID then return {}, node end
        return nil
    end

    for _, branch in ipairs({"a", "b"}) do
        local path, leaf = bspAncestors(node[branch], windowID)
        if path then
            table.insert(path, { node = node, branch = branch })
            return path, leaf
        end
    end
    return nil
end

-- Where a window sits in the trees, by id (no accessibility calls): the path
-- of splits above it, its leaf and its tree key. If a stale tree still holds
-- it (e.g. an emptied display that was never reconciled), the tree for an
-- active Space wins.
local bspKeyForScreen -- defined with the layout code below

local function bspFindByID(windowID)
    if not windowID then return nil end
    local found = {}
    for key, tree in pairs(bspTrees) do
        local path, leaf = bspAncestors(tree, windowID)
        if path then found[#found + 1] = { path = path, leaf = leaf, key = key } end
    end
    if #found > 1 then
        local active = {}
        for _, screen in ipairs(hs.screen.allScreens()) do
            active[bspKeyForScreen(screen)] = true
        end
        for _, f in ipairs(found) do
            if active[f.key] then return f.path, f.leaf, f.key end
        end
    end
    local f = found[1]
    if f then return f.path, f.leaf, f.key end
    return nil
end

bspRectFor = function(windowID)
    if not bspTilingEnabled then return nil end
    local _, leaf = bspFindByID(windowID)
    return leaf and leaf.rect
end

-- Nearest split of the given orientation with the window on the given
-- branch ("a" = split line after the window, i.e. its right/bottom edge).
local function bspBoundingSplit(path, split, branch)
    for _, step in ipairs(path) do
        if step.node.split == split
           and step.branch == branch
           and step.node.rect then
            return step.node
        end
    end
    return nil
end

-- Move the split bordering `edge` so the tile edge lands at `pos`.
local function bspMoveSplit(node, edge, pos)
    local horizontal = node.split == "vertical"
    local origin = horizontal and node.rect.x or node.rect.y
    local size = horizontal and node.rect.w or node.rect.h
    local usable = math.max(1, size - cfg.tiling.innerGap)

    -- The "a" tile ends at the split line; the "b" tile starts one gap later.
    local first = pos - origin
    if edge == "left" or edge == "top" then
        first = first - cfg.tiling.innerGap
    end

    node.ratio = math.max(cfg.tiling.minRatio,
        math.min(cfg.tiling.maxRatio, first / usable))
end

-- ---------------------------------------------------------------------------
-- BSP tiling: layout
-- ---------------------------------------------------------------------------

-- Space lookups are cached for the duration of one layout pass.
local bspKeyCache = nil

bspKeyForScreen = function(screen)
    local uuid = screen:getUUID()
    if bspKeyCache and bspKeyCache[uuid] then return bspKeyCache[uuid] end

    local spaceID = hs.spaces.activeSpaceOnScreen(screen)
    local key = uuid .. ":" .. tostring(spaceID or "unknown")
    if bspKeyCache then bspKeyCache[uuid] = key end
    return key
end

-- Moves we caused ourselves fire windowMoved shortly after; see onWindowMoved.
local bspSettleUntil = 0
local BSP_SETTLE = 0.35

-- Windows that can't be resized (popups, settings panes) float, centred on
-- their screen, instead of being tiled. Decided once per window and cached;
-- entries are dropped when the window is destroyed.
bspAutoFloat = {}

-- The decisions persist across reloads (the probe below visibly shrinks and
-- restores a window, so it shouldn't rerun on every save of the config).
-- Window IDs can be reused after a reboot, so entries also record the app and
-- are discarded if the machine has restarted since.
local FLOATS_KEY = "bspAutoFloat"
local bootTime = tonumber(
    (hs.execute("/usr/sbin/sysctl -n kern.boottime") or ""):match("sec = (%d+)")) or 0
local bspSavedFloats = {}
do
    local saved = hs.settings.get(FLOATS_KEY)
    if type(saved) == "table" and type(saved.boot) == "number"
       and math.abs(saved.boot - bootTime) < 120 and type(saved.entries) == "table" then
        bspSavedFloats = saved.entries
    end
end

local bspFloatsTimer = nil

local function bspSaveFloatsNow()
    hs.settings.set(FLOATS_KEY, { boot = bootTime, entries = bspSavedFloats })
end

local function bspSaveFloats()
    if bspFloatsTimer then bspFloatsTimer:stop() end
    bspFloatsTimer = hs.timer.doAfter(1, function()
        bspFloatsTimer = nil
        bspSaveFloatsNow()
    end)
end

local function bspAppName(win)
    local app = win:application()
    return app and app:name() or ""
end

local function bspRememberFloat(win)
    local id = win:id()
    bspSavedFloats[tostring(id)] = { float = bspAutoFloat[id] and true or false, app = bspAppName(win) }
    bspSaveFloats()
end

local function bspForgetFloat(id)
    bspAutoFloat[id] = nil
    if bspSavedFloats[tostring(id)] ~= nil then
        bspSavedFloats[tostring(id)] = nil
        bspSaveFloats()
    end
end

local function bspHasFloating()
    for _, float in pairs(bspAutoFloat) do
        if float then return true end
    end
    return false
end

local function bspShouldFloat(win)
    local id = win:id()
    if bspAutoFloat[id] ~= nil then return bspAutoFloat[id] end

    local saved = bspSavedFloats[tostring(id)]
    if saved and saved.app == bspAppName(win) then
        bspAutoFloat[id] = saved.float
        return saved.float
    end

    local float = false
    local ax = hs.axuielement.windowElement(win)
    if ax then
        local okSize, sizeSettable = pcall(ax.isAttributeSettable, ax, "AXSize")
        local zoom = ax:attributeValue("AXZoomButton")
        local zoomEnabled = zoom and zoom:attributeValue("AXEnabled")
        float = (okSize and sizeSettable == false) or not zoomEnabled
    end

    -- Attributes can lie (System Settings claims to be resizable but has a
    -- fixed width), so probe: try shrinking and see whether each axis moves.
    if not float then
        local f = win:frame()
        win:setFrame({ x = f.x, y = f.y, w = f.w - 40, h = f.h - 40 }, 0)
        local g = win:frame()
        win:setFrame(f, 0)
        float = math.abs(g.w - f.w) < 1 or math.abs(g.h - f.h) < 1
        -- The probe's own moves echo back as windowMoved events.
        bspSettleUntil = hs.timer.secondsSinceEpoch() + BSP_SETTLE
    end

    bspAutoFloat[id] = float
    bspRememberFloat(win)
    if float then
        local screen = win:screen()
        if screen then
            local sf, f = screen:frame(), win:frame()
            win:setTopLeft({
                x = sf.x + (sf.w - f.w) / 2,
                y = sf.y + (sf.h - f.h) / 2,
            })
        end
    end
    return float
end

-- Floating windows stay above the tiles. Hammerspoon can't set a window
-- level, so we re-raise them after layout/focus changes instead.
local function bspRaiseFloatingNow()
    if not running.windowFilter or not bspHasFloating() then return end
    local focusedID = ffmFocusedID
    local focusedFloat = nil
    for _, win in ipairs(running.windowFilter:getWindows() or {}) do
        local id = win:id()
        if bspAutoFloat[id] then
            -- The focused float goes last so it stays on top of the others.
            if id == focusedID then focusedFloat = win else win:raise() end
        end
    end
    if focusedFloat then focusedFloat:raise() end
end

-- Debounced, with a second pass: the first can run before a tile that has
-- just been focused or moved has finished coming to the front.
local bspRaiseTimers = {}
local function bspRaiseFloating()
    for _, t in ipairs(bspRaiseTimers) do t:stop() end
    bspRaiseTimers = {}
    if not bspHasFloating() then return end
    bspRaiseTimers = {
        hs.timer.doAfter(0.03, bspRaiseFloatingNow),
        hs.timer.doAfter(0.25, bspRaiseFloatingNow),
    }
end

-- Manageable windows grouped by screen UUID, in a single pass (each window's
-- screen and state are accessibility calls, so don't repeat them per screen).
-- With `onlyUUID`, windows on other screens skip the remaining checks.
-- Each window's screen and fullscreen state, cached per window id: both are
-- accessibility calls and change only when the window moves or goes
-- fullscreen (events drop the entry), or on a forced retile (Space/display
-- changes drop everything).
local bspWindowInfo = {}

local function bspWindowInfoFor(win)
    local id = win:id()
    local info = bspWindowInfo[id]
    if info then return info end
    local screen = win:screen()
    info = { uuid = screen and screen:getUUID(), full = win:isFullScreen() }
    -- A window with no screen yet (still being created) isn't cached.
    if info.uuid then bspWindowInfo[id] = info end
    return info
end

local function bspWindowsByScreen(onlyUUID)
    local byScreen = {}

    for _, win in ipairs(running.windowFilter:getWindows() or {}) do
        local info = bspWindowInfoFor(win)
        local uuid = info.uuid
        -- The filter only passes visible, standard windows.
        if uuid and (not onlyUUID or uuid == onlyUUID)
           and not info.full and not bspShouldFloat(win) then
            byScreen[uuid] = byScreen[uuid] or {}
            table.insert(byScreen[uuid], win)
        end
    end

    -- Stable order for initial tree construction.
    for _, list in pairs(byScreen) do
        table.sort(list, function(a, b)
            return a:id() < b:id()
        end)
    end

    return byScreen
end

-- Where a new window goes relative to a tile: wide tiles split left/right,
-- tall ones top/bottom. The pointer's position along that axis picks the
-- side; in the middle third (or outside the tile) it's right/bottom.
local function bspSplitSide(rect, point)
    local horizontal = rect.w >= rect.h
    local t = horizontal and (point.x - rect.x) / rect.w
                         or (point.y - rect.y) / rect.h
    if pointInFrame(point, rect) then
        if t < 1 / 3 then return horizontal and "left" or "top" end
    end
    return horizontal and "right" or "bottom"
end

-- When a window goes away, focus returns to its sibling in the tree: the
-- tile it was split from, or the most recently used surviving window in that
-- subtree. Climbs to the parent's sibling if a whole subtree is gone too.
-- Returns that window's id.
local function bspSiblingToFocus(tree, windowID, valid)
    local path = bspAncestors(tree, windowID)
    for _, step in ipairs(path or {}) do
        local sibling = step.node[step.branch == "a" and "b" or "a"]
        local ids = bspCollectIDs(sibling)
        for _, fid in ipairs(bspFocusHistory) do
            if ids[fid] and valid[fid] then return fid end
        end
        for fid in pairs(ids) do
            if valid[fid] then return fid end
        end
    end
end

-- Whether a window that has just vanished was the one we consider focused.
-- Judged from our own focus record, not macOS's current focus: if macOS has
-- already moved focus elsewhere in the last moment (stealing it on close),
-- the vanished window is the one before that.
local BSP_STEAL_WINDOW = 0.5
local function bspWasFocused(windowID)
    if bspFocusHistory[1] == windowID then return true end
    local stolen = bspFocusHistory[1]
    return bspFocusHistory[2] == windowID and stolen ~= nil
        and hs.timer.secondsSinceEpoch() - (bspFocusTimes[stolen] or 0) < BSP_STEAL_WINDOW
end

local function bspReconcileTree(key, windows)
    local valid = {}
    local byID = {}

    for _, win in ipairs(windows) do
        local id = win:id()
        valid[id] = true
        byID[id] = win
        bspWinByID[id] = win

        if not bspFloatingFrames[id] then
            bspFloatingFrames[id] = win:frame()
        end
    end

    -- Windows in the tree that are no longer present: if one was focused,
    -- remember its surviving sibling so the retile can hand focus back.
    local previous = bspTrees[key]
    for id in pairs(bspCollectIDs(previous)) do
        if not valid[id] and bspWasFocused(id) then
            bspPendingRefocus = bspSiblingToFocus(previous, id, valid) or bspPendingRefocus
            break
        end
    end

    local tree = bspPrune(previous, valid)
    local present = bspCollectIDs(tree)

    for _, win in ipairs(windows) do
        local id = win:id()

        if not present[id] then
            if not tree then
                tree = bspLeaf(id)
            else
                -- A new window is usually focused before we retile, so walk
                -- the focus history for the most recent window already tiled.
                local target = nil

                for _, fid in ipairs(bspFocusHistory) do
                    if fid ~= id and bspTreeContains(tree, fid) then
                        target = fid
                        break
                    end
                end

                target = target or bspRightmostLeafID(tree)

                -- Split the previously focused tile along its longer axis;
                -- the mouse picks which side the new window goes on.
                local inserted = false
                local _, targetLeaf = bspAncestors(tree, target)
                if targetLeaf and targetLeaf.rect then
                    tree, inserted = bspInsertBeside(tree, target, id,
                        bspSplitSide(targetLeaf.rect, hs.mouse.absolutePosition()))
                end

                if not inserted then
                    tree, inserted = bspInsertAt(tree, target, id, 0)
                end

                -- Defensive fallback; target should always be in the tree.
                if not inserted then
                    local fallback = bspRightmostLeafID(tree)
                    tree = select(1, bspInsertAt(tree, fallback, id, 0))
                end
            end

            present[id] = true
        end
    end

    bspTrees[key] = tree
    return tree, byID
end

local function bspInset(rect, amount)
    return hs.geometry.rect(
        rect.x + amount,
        rect.y + amount,
        math.max(1, rect.w - amount * 2),
        math.max(1, rect.h - amount * 2)
    )
end

local function bspApplyTree(node, rect, byID)
    if not node then return end

    -- Remembered so resizing knows each split's and tile's size.
    node.rect = rect

    if bspIsLeaf(node) then
        local win = byID[node.windowID]
        if win then
            -- setFrame is several accessibility calls and fires windowMoved,
            -- so leave windows that are already in place alone.
            local f = win:frame()
            local moved = math.abs(f.x - rect.x) > 1 or math.abs(f.y - rect.y) > 1
            local resized = math.abs(f.w - rect.w) > 1 or math.abs(f.h - rect.h) > 1
            -- setFrame is size, position, size; one call is enough when only
            -- one of them changes.
            if moved and resized then
                win:setFrame(rect, 0)
            elseif moved then
                win:setTopLeft(rect)
            elseif resized then
                win:setSize(rect)
            end
        end
        return
    end

    local gap = cfg.tiling.innerGap
    local ratio = math.max(cfg.tiling.minRatio,
        math.min(cfg.tiling.maxRatio, node.ratio or 0.5))
    node.ratio = ratio

    if node.split == "vertical" then
        local usable = math.max(1, rect.w - gap)
        local first = math.floor(usable * ratio)

        local aRect = hs.geometry.rect(rect.x, rect.y, first, rect.h)
        local bRect = hs.geometry.rect(
            rect.x + first + gap,
            rect.y,
            usable - first,
            rect.h
        )

        bspApplyTree(node.a, aRect, byID)
        bspApplyTree(node.b, bRect, byID)
    else
        local usable = math.max(1, rect.h - gap)
        local first = math.floor(usable * ratio)

        local aRect = hs.geometry.rect(rect.x, rect.y, rect.w, first)
        local bRect = hs.geometry.rect(
            rect.x,
            rect.y + first + gap,
            rect.w,
            usable - first
        )

        bspApplyTree(node.a, aRect, byID)
        bspApplyTree(node.b, bRect, byID)
    end
end

-- What each screen last laid out (window IDs + screen frame). Retiles caused
-- by window set changes are skipped for screens whose signature is unchanged.
local bspSignatures = {}

-- `onlyScreenUUID` limits the pass to one screen (resizes, swaps and split
-- flips only ever affect the layout of the window's own screen).
local function bspTileNow(onlyIfChanged, onlyScreenUUID)
    if not bspTilingEnabled or bspApplyingLayout or not running.windowFilter then
        return
    end

    bspApplyingLayout = true
    bspKeyCache = {}

    local byScreen = bspWindowsByScreen(onlyScreenUUID)

    for _, screen in ipairs(hs.screen.allScreens()) do
        local windows = byScreen[screen:getUUID()] or {}

        if #windows > 0 then
            local key = bspKeyForScreen(screen)
            local usableFrame = bspInset(screen:frame(), cfg.tiling.outerGap)

            local ids = {}
            for i, win in ipairs(windows) do ids[i] = win:id() end
            local signature = key .. "|" .. table.concat(ids, ",") .. "|"
                .. string.format("%.0f,%.0f,%.0f,%.0f",
                    usableFrame.x, usableFrame.y, usableFrame.w, usableFrame.h)

            if not (onlyIfChanged and bspSignatures[key] == signature) then
                bspSignatures[key] = signature
                local tree, byID = bspReconcileTree(key, windows)
                bspApplyTree(tree, usableFrame, byID)
            end
        end
    end

    bspKeyCache = nil
    bspApplyingLayout = false
    bspSaveTrees()
    bspRaiseFloating()
    bspSettleUntil = hs.timer.secondsSinceEpoch() + BSP_SETTLE
    invalidateWindowCache()

    -- A closed window hands focus back to its tree sibling. This runs last,
    -- after the layout, so the cursor warps to the sibling's final frame.
    -- Re-checked shortly after in case macOS focuses its own pick late.
    local pick = bspPendingRefocus
    bspPendingRefocus = nil
    if pick then
        local function refocus()
            local win = bspWinByID[pick]
            if not win or win:id() ~= pick then return end
            local cur = focusedWindow()
            if not cur or cur:id() ~= pick then bspFocus(win) else bspNoteFocus(win) end
            warpToWindow(win)
        end
        refocus()
        hs.timer.doAfter(0.1, refocus)
    end
end

local BSP_RETILE_DELAY = 0.06
local bspRetilePending = false
local bspRetileForce = false

local function bspRetileFlush()
    bspRetileTimer = nil
    if not bspRetilePending then return end
    local force = bspRetileForce
    bspRetilePending, bspRetileForce = false, false
    bspTileNow(not force)
end

-- `force` drops the unchanged-screen shortcut (Space/display changes, where
-- the same windows may need re-laying out).
--
-- Events are normally coalesced behind a short delay: a new window is usually
-- focused just after it appears, and placing it needs that focus. With
-- `immediate` (windows going away, which need no placement decision) the
-- first event retiles straight away and any burst after it is coalesced.
local function scheduleBSPRetile(force, immediate)
    if not bspTilingEnabled then return end

    if force then
        bspSignatures = {}
        bspWindowInfo = {}
    end

    if immediate and not force and not bspRetileTimer then
        bspTileNow(true)
    else
        bspRetilePending = true
        bspRetileForce = bspRetileForce or force or false
        if bspRetileTimer then bspRetileTimer:stop() end
    end

    bspRetileTimer = hs.timer.doAfter(BSP_RETILE_DELAY, bspRetileFlush)
end

local function bspRestoreFloatingFrames()
    local current = {}

    for _, win in ipairs(hs.window.allWindows()) do
        current[win:id()] = win
    end

    for id, frame in pairs(bspFloatingFrames) do
        local win = current[id]
        if win and win:isStandard() then
            win:setFrame(frame, 0)
        end
    end

    bspFloatingFrames = {}
end

-- The tree path and leaf for a tiled window, or nil if it isn't tiled.
local function bspLocate(win)
    if not bspTilingEnabled or not win then return nil end
    local path, leaf, key = bspFindByID(win:id())
    if not path then return nil end
    return path, leaf, key
end

-- The screen UUID part of a tree key ("<uuid>:<space>").
local function bspKeyUUID(key)
    return key and key:match("^(.-):")
end


-- ---------------------------------------------------------------------------
-- BSP tiling: resizing
-- ---------------------------------------------------------------------------
--
-- Resizing tiled windows moves the split lines bordering them. Each window
-- edge that moved drags the split on that side of the window to match; edges
-- against the screen have no split and snap back. This covers mouse
-- resizing (applied on release) and native edge dragging.

local BSP_EDGE_TOLERANCE = 4

-- Fold a tiled window's new frame back into its tree and retile. Pure moves
-- (size unchanged) just snap back.
local function bspAdoptFrame(win)
    local path, leaf, key = bspLocate(win)
    if not path or not leaf.rect then return end

    local f = win:frame()
    local r = leaf.rect
    local function differs(a, b) return math.abs(a - b) > BSP_EDGE_TOLERANCE end

    if not (differs(f.x, r.x) or differs(f.y, r.y)
            or differs(f.w, r.w) or differs(f.h, r.h)) then
        return
    end

    -- Our own retiles also fire windowMoved. A window that can't take its
    -- tile's exact size (e.g. an app minimum) would otherwise retile forever,
    -- so only react once to any given frame.
    local seen = string.format("%.0f,%.0f,%.0f,%.0f", f.x, f.y, f.w, f.h)
    if leaf.lastSeenFrame == seen then return end
    leaf.lastSeenFrame = seen

    if differs(f.w, r.w) or differs(f.h, r.h) then
        local edges = {
            { edge = "left",   split = "vertical",   branch = "b", now = f.x,       was = r.x },
            { edge = "right",  split = "vertical",   branch = "a", now = f.x + f.w, was = r.x + r.w },
            { edge = "top",    split = "horizontal", branch = "b", now = f.y,       was = r.y },
            { edge = "bottom", split = "horizontal", branch = "a", now = f.y + f.h, was = r.y + r.h },
        }
        for _, e in ipairs(edges) do
            if differs(e.now, e.was) then
                local node = bspBoundingSplit(path, e.split, e.branch)
                if node then bspMoveSplit(node, e.edge, e.now) end
            end
        end
    end

    bspTileNow(false, bspKeyUUID(key))
end

-- Keyboard resize of a tiled window by a percentage of its size. On each
-- axis the nearest split bordering the window moves in the key's direction:
-- a left/top tile grows with right/down, a right/bottom tile shrinks with
-- right/down (its left/top edge follows the split). Returns true when the
-- window is tiled (even if it has no split on that axis to move), so the
-- floating fallback doesn't run.
local function bspResizePercent(win, xPct, yPct)
    local path, leaf, key = bspLocate(win)
    if not path or not leaf.rect then return false end

    local r = leaf.rect
    local axes = {
        { pct = xPct, split = "vertical",   pos = r.x, size = r.w, before = "left", after = "right" },
        { pct = yPct, split = "horizontal", pos = r.y, size = r.h, before = "top",  after = "bottom" },
    }

    for _, axis in ipairs(axes) do
        if axis.pct ~= 0 then
            local delta = axis.size * axis.pct / 100
            for _, step in ipairs(path) do
                if step.node.split == axis.split and step.node.rect then
                    if step.branch == "a" then
                        bspMoveSplit(step.node, axis.after, axis.pos + axis.size + delta)
                    else
                        bspMoveSplit(step.node, axis.before, axis.pos + delta)
                    end
                    break
                end
            end
        end
    end

    bspTileNow(false, bspKeyUUID(key))
    return true
end

-- Mouse resize while tiling: only the dragged window changes during the
-- drag, growing from the edges nearest the cursor that border a split
-- (falling back to the opposite edge at the screen border). The layout
-- follows on release.
local bspResizeState = nil

local function bspBeginResize(win, point)
    bspResizeState = nil

    local f = win:frame()
    local path = bspLocate(win)
    if not path then
        -- Floating: grow from the corner nearest the cursor.
        bspResizeState = {
            win = win,
            frame = f,
            floating = true,
            xBranch = point.x > f.x + f.w / 2 and "a" or "b",
            yBranch = point.y > f.y + f.h / 2 and "a" or "b",
        }
        return
    end

    local function pickBranch(split, preferAfter)
        local prefer = preferAfter and "a" or "b"
        local other = preferAfter and "b" or "a"
        if bspBoundingSplit(path, split, prefer) then return prefer end
        if bspBoundingSplit(path, split, other) then return other end
        return nil
    end

    bspResizeState = {
        win = win,
        frame = f,
        xBranch = pickBranch("vertical", point.x > f.x + f.w / 2),
        yBranch = pickBranch("horizontal", point.y > f.y + f.h / 2),
    }
end

-- Returns true when the resize is being handled by the tiling layout.
local function bspResizeDrag(dx, dy)
    local state = bspResizeState
    if not state then return false end

    local f = hs.geometry.copy(state.frame)

    if state.xBranch == "a" then
        f.w = math.max(cfg.minWidth, f.w + dx)
    elseif state.xBranch == "b" then
        local w = math.max(cfg.minWidth, f.w - dx)
        f.x = f.x + f.w - w
        f.w = w
    end

    if state.yBranch == "a" then
        f.h = math.max(cfg.minHeight, f.h + dy)
    elseif state.yBranch == "b" then
        local h = math.max(cfg.minHeight, f.h - dy)
        f.y = f.y + f.h - h
        f.h = h
    end

    state.win:setFrame(f, 0)
    return true
end

local function bspFinishResize()
    local state = bspResizeState
    bspResizeState = nil
    if not state or state.floating then return false end

    bspAdoptFrame(state.win)
    return true
end

-- ---------------------------------------------------------------------------
-- BSP tiling: drag and drop
-- ---------------------------------------------------------------------------
--
-- Drop a tiled window onto another tile to split that tile and insert it on
-- the side nearest the cursor, like Hyprland's dwindle layout. A highlight
-- previews where it will land. Dropping on empty space on another display
-- moves it into that display's layout; anywhere else snaps it back.

local bspDropState = nil
local bspDropPreview = nil

local function bspScreenAt(point)
    for _, screen in ipairs(hs.screen.allScreens()) do
        if pointInFrame(point, screen:fullFrame()) then return screen end
    end
    return nil
end

-- The tile under the cursor, the side nearest the cursor, and the half of
-- the tile the dropped window would take.
local function bspDropTarget(targets, point)
    for _, target in ipairs(targets) do
        local f = target.frame
        if pointInFrame(point, f) then
            local side = bspNearestSide(f, point)

            local r = hs.geometry.copy(f)
            if side == "left" or side == "right" then
                r.w = f.w / 2
            else
                r.h = f.h / 2
            end
            if side == "right" then r.x = f.x + f.w / 2 end
            if side == "bottom" then r.y = f.y + f.h / 2 end

            return target, side, r
        end
    end
    return nil
end

local function bspBeginDrag(win)
    bspDropState = nil

    local _, _, key = bspLocate(win)
    if not key then return end

    -- Tiles don't move during a drag, so snapshot their frames once.
    local targets = {}
    local byScreen = bspWindowsByScreen()
    for _, s in ipairs(hs.screen.allScreens()) do
        local sKey = bspKeyForScreen(s)
        for _, w in ipairs(byScreen[s:getUUID()] or {}) do
            if w:id() ~= win:id() then
                table.insert(targets, { win = w, frame = w:frame(), key = sKey })
            end
        end
    end

    bspDropState = { key = key, targets = targets }
end

local bspDropShown = false
local bspDropRect = nil

local function bspHideDropPreview()
    if bspDropPreview and bspDropShown then bspDropPreview:hide() end
    bspDropShown = false
    bspDropRect = nil
end

local function bspUpdateDrag(point)
    if not bspDropState then return end

    local _, _, rect = bspDropTarget(bspDropState.targets, point)
    if not rect then
        bspHideDropPreview()
        return
    end

    -- Drag events arrive at 60Hz; only touch the canvas when the target changes.
    if bspDropShown and bspDropRect
       and bspDropRect.x == rect.x and bspDropRect.y == rect.y
       and bspDropRect.w == rect.w and bspDropRect.h == rect.h then
        return
    end
    bspDropRect = rect

    if not bspDropPreview then
        local c = cfg.tiling.dropColor
        bspDropPreview = hs.canvas.new(rect)
        bspDropPreview:level(hs.canvas.windowLevels.overlay)
        bspDropPreview[1] = {
            type = "rectangle",
            action = "strokeAndFill",
            fillColor = { red = c.red, green = c.green, blue = c.blue, alpha = 0.25 },
            strokeColor = { red = c.red, green = c.green, blue = c.blue, alpha = 0.9 },
            strokeWidth = 3,
            roundedRectRadii = { xRadius = 8, yRadius = 8 },
        }
    else
        bspDropPreview:frame(rect)
    end
    bspDropPreview:show()
    bspDropShown = true
end

-- Returns true when the drop was handled by the tiling layout.
local function bspFinishDrag(win, point)
    bspHideDropPreview()

    local state = bspDropState
    bspDropState = nil
    if not state or not bspTilingEnabled then return false end

    local id = win:id()
    local target, side = bspDropTarget(state.targets, point)

    if target then
        bspTrees[state.key] = bspRemoveID(bspTrees[state.key], id)
        bspTrees[target.key] = select(1,
            bspInsertBeside(bspTrees[target.key], target.win:id(), id, side))
        -- Park it on the target's display so the retile keeps it there.
        win:setFrame(target.frame, 0)
    else
        local dropScreen = bspScreenAt(point)
        if dropScreen and bspKeyForScreen(dropScreen) ~= state.key then
            bspTrees[state.key] = bspRemoveID(bspTrees[state.key], id)
            win:setFrame(dropScreen:frame(), 0)
        end
    end

    bspTileNow()
    return true
end

-- ---------------------------------------------------------------------------
-- Actions (bind these to hotkeys)
-- ---------------------------------------------------------------------------

M.warpToWindow = warpToWindow
M.warpToFocusedWindow = warpToFocusedWindow

function M.isTiling()
    return bspTilingEnabled
end

function M.toggleTiling()
    bspTilingEnabled = not bspTilingEnabled
    hs.settings.set(SETTINGS_KEY, bspTilingEnabled)

    if bspTilingEnabled then
        -- Trees are kept while tiling is off, so the old layout comes back;
        -- reconciling prunes windows that closed in the meantime.
        bspFloatingFrames = {}
        scheduleBSPRetile(true)
        hs.alert.show("BSP tiling on")
    else
        bspRestoreFloatingFrames()
        hs.alert.show("BSP tiling off")
    end
end

function M.closeWindow()
    local win = currentWindow()
    if win then win:close() end
end

-- Native macOS fullscreen (its own Space).
function M.toggleFullScreen()
    local win = currentWindow()
    if win then win:toggleFullScreen() end
end

-- Fill the screen without creating a fullscreen Space.
function M.maximize()
    local win = currentWindow()
    if win then
        win:maximize(0)
        warpToWindow(win)
    end
end

local focusMethods = {
    left = "focusWindowWest",
    right = "focusWindowEast",
    up = "focusWindowNorth",
    down = "focusWindowSouth",
}

local windowListMethods = {
    left = "windowsToWest",
    right = "windowsToEast",
    up = "windowsToNorth",
    down = "windowsToSouth",
}

-- The nearest candidate strictly in a direction that overlaps the focused
-- frame `f` along the other axis. Hammerspoon's focusWindowWest etc. weigh
-- diagonal neighbours too, so "left" can land on a window above.
-- `candidates` are { win =, id =, frame = }.
local function nearestInDirection(f, selfID, candidates, direction)
    local horizontal = direction == "left" or direction == "right"
    local tol = 4
    local cx, cy = f.x + f.w / 2, f.y + f.h / 2

    local best, bestKey = nil, nil
    for _, entry in ipairs(candidates) do
        if entry.id ~= selfID then
            local o = entry.frame
            local gap, overlap, offset
            if horizontal then
                gap = direction == "left" and (f.x - (o.x + o.w)) or (o.x - (f.x + f.w))
                overlap = math.min(f.y + f.h, o.y + o.h) - math.max(f.y, o.y)
                offset = math.abs((o.y + o.h / 2) - cy)
            else
                gap = direction == "up" and (f.y - (o.y + o.h)) or (o.y - (f.y + f.h))
                overlap = math.min(f.x + f.w, o.x + o.w) - math.max(f.x, o.x)
                offset = math.abs((o.x + o.w / 2) - cx)
            end

            if gap >= -tol and overlap > tol then
                -- Closest first, then the one lined up best with the centre.
                local key = math.floor(math.max(gap, 0) / 8) * 1e6 + offset
                if not bestKey or key < bestKey then best, bestKey = entry.win, key end
            end
        end
    end
    return best
end

-- Every tile in a tree: { win =, id =, frame = }.
local function bspTiles(node, out)
    out = out or {}
    if not node then return out end
    if bspIsLeaf(node) then
        local win = bspWinByID[node.windowID]
        if node.rect and win then
            out[#out + 1] = { win = win, id = node.windowID, frame = node.rect }
        end
        return out
    end
    bspTiles(node.a, out)
    bspTiles(node.b, out)
    return out
end

-- For a tiled window the neighbour comes from the tree's own tile rects (no
-- accessibility calls). Otherwise (floats, other displays) it falls back to
-- the live window snapshot.
local function neighbourInDirection(win, direction)
    local id = win:id()
    local _, leaf, key = bspFindByID(bspTilingEnabled and id or nil)
    if leaf and leaf.rect then
        local found = nearestInDirection(leaf.rect, id, bspTiles(bspTrees[key]), direction)
        if found then return found end
    end
    return nearestInDirection(win:frame(), id, windowSnapshot(), direction)
end

-- Focus the nearest window in a direction ("left"/"right"/"up"/"down") and
-- warp the cursor to it.
function M.focus(direction)
    local win = currentWindow()
    if not win then return end

    local target = neighbourInDirection(win, direction)
    if target then
        bspFocus(target)
        warpToWindow(target)
    elseif win[focusMethods[direction]](win, nil, true, false) then
        -- Nothing directly beside it (e.g. another display): Hammerspoon
        -- picked. Focus change can finish one event-loop tick after the call.
        warpToFocusedWindow(0.01)
    end
end

-- Swap the focused window with its neighbour in a direction. Tiled windows
-- swap places in the tree; floating windows swap frames.
function M.swap(direction)
    local win = currentWindow()
    if not win then return end

    local other = neighbourInDirection(win, direction)
    if not other then
        local candidates = win[windowListMethods[direction]](win, nil, true, false)
        other = candidates and candidates[1]
    end
    if not other then return end

    local _, _, keyA = bspLocate(win)
    local _, _, keyB = bspLocate(other)
    if keyA or keyB then
        -- Only swap within one layout; frame swaps would be undone by the
        -- next retile.
        if keyA == keyB then
            bspSwapIDs(bspTrees[keyA], win:id(), other:id())
            -- Retile synchronously so the cursor warp sees the new frames.
            bspTileNow(false, bspKeyUUID(keyA))
        end
    else
        local a = win:frame()
        local b = other:frame()
        other:setFrame(a, 0)
        win:setFrame(b, 0)
    end

    bspFocus(win)
    warpToWindow(win)
end

-- Toggle floating for the focused window (overrides the automatic choice).
-- Floating windows are centred and kept above the tiles.
function M.toggleFloat()
    local win = currentWindow()
    if not win or not bspTilingEnabled then return end

    local id = win:id()
    bspShouldFloat(win) -- make sure it's classified (may centre it)
    bspAutoFloat[id] = not bspAutoFloat[id]
    bspRememberFloat(win)

    if bspAutoFloat[id] then
        local screen, f = win:screen(), win:frame()
        local sf = screen:frame()
        win:setTopLeft({ x = sf.x + (sf.w - f.w) / 2, y = sf.y + (sf.h - f.h) / 2 })
        win:raise()
    end

    invalidateWindowCache()
    bspTileNow()
    warpToWindow(win)
end

-- Cycle focus through the floating windows. Works however they're stacked
-- (even fully covered by tiles), since it goes by window rather than by
-- direction or mouse position.
function M.focusFloat()
    if not running.windowFilter then return end
    local floats = {}
    for _, win in ipairs(running.windowFilter:getWindows() or {}) do
        if bspAutoFloat[win:id()] then floats[#floats + 1] = win end
    end
    if #floats == 0 then return end
    table.sort(floats, function(a, b) return a:id() < b:id() end)

    local current = ffmFocusedID
    local target = floats[1]
    for i, win in ipairs(floats) do
        if win:id() == current then
            target = floats[i % #floats + 1]
            break
        end
    end
    bspFocus(target)
    warpToWindow(target)
end

-- Flip the split containing the focused window between vertical and
-- horizontal. Deepest ancestor first, so it's the window's own sibling split.
function M.toggleSplit()
    local win = currentWindow()
    local path, _, key = bspLocate(win)
    local parent = path and path[1] and path[1].node
    if not parent then return end

    parent.split = (parent.split == "vertical") and "horizontal" or "vertical"
    bspTileNow(false, bspKeyUUID(key))
    warpToWindow(win)
end

-- Resize the focused window by a percentage of its own size, e.g.
-- resize(10, 0) grows width by 10%. Tiled windows move the split bordering
-- them in the key's direction instead (see bspResizePercent).
function M.resize(xPct, yPct)
    local win = currentWindow()
    if not win then return end

    if bspResizePercent(win, xPct, yPct) then return end

    local f = win:frame()
    if xPct ~= 0 then
        f.w = math.max(cfg.minWidth, f.w + f.w * xPct / 100)
    end
    if yPct ~= 0 then
        f.h = math.max(cfg.minHeight, f.h + f.h * yPct / 100)
    end

    win:setFrameInScreenBounds(f, 0)
end

-- ---------------------------------------------------------------------------
-- Workspaces (macOS Spaces)
-- ---------------------------------------------------------------------------
--
-- Workspaces are dynamically numbered:
--   1. user Spaces on the primary display
--   2. user Spaces on the other displays, ordered left-to-right/top-to-bottom
--
-- Fullscreen/tiled-app Spaces are excluded from numbering.

local function orderedScreens()
    local all = hs.screen.allScreens()
    local primary = hs.screen.primaryScreen()
    local result = {}

    if primary then
        table.insert(result, primary)
    end

    local rest = {}
    for _, screen in ipairs(all) do
        if not primary or screen:id() ~= primary:id() then
            table.insert(rest, screen)
        end
    end

    table.sort(rest, function(a, b)
        local af = a:fullFrame()
        local bf = b:fullFrame()
        if af.x == bf.x then
            return af.y < bf.y
        end
        return af.x < bf.x
    end)

    for _, screen in ipairs(rest) do
        table.insert(result, screen)
    end

    return result
end

local function userSpaces()
    local result = {}

    for _, screen in ipairs(orderedScreens()) do
        local spaces = hs.spaces.spacesForScreen(screen) or {}
        for _, spaceID in ipairs(spaces) do
            if hs.spaces.spaceType(spaceID) == "user" then
                table.insert(result, spaceID)
            end
        end
    end

    return result
end

local function spaceAt(index)
    return userSpaces()[index]
end

-- After a Space switch macOS often leaves no window focused until the mouse
-- moves. Once the switch has settled, focus the window under the pointer,
-- else the topmost one on the new Space, and put the cursor on it. The
-- switch animation length varies, so this waits for the Space-changed event
-- (with a timer as a fallback) and retries while the window list is empty.
local spaceFocusPending = false
-- Timers are kept in variables so they can't be garbage collected early.
local spaceRetryTimer, spaceSettleTimer, spaceFallbackTimer

local function focusCurrentSpaceWindow(attempt)
    -- The window we last used in this Space, from our own tree and focus
    -- record; only when there's none do we ask what is under the pointer.
    local win = nil
    local screen = hs.mouse.getCurrentScreen()
    local tree = bspTilingEnabled and screen and bspTrees[bspKeyForScreen(screen)]
    if tree then
        local ids = bspCollectIDs(tree)
        for _, fid in ipairs(bspFocusHistory) do
            if ids[fid] and bspWinByID[fid] and bspWinByID[fid]:id() == fid then
                win = bspWinByID[fid]
                break
            end
        end
    end

    if not win then
        -- Fresh each attempt: the Space has just changed, and a snapshot
        -- taken mid-switch would otherwise be reused by the retries.
        win = windowUnderPoint(hs.mouse.absolutePosition(), true)
    end
    if not win then
        local entry = windowSnapshot()[1]
        win = entry and entry.win
    end

    if win then
        bspFocus(win)
        warpToWindow(win)
    elseif attempt < 6 then
        spaceRetryTimer = hs.timer.doAfter(0.15, function() focusCurrentSpaceWindow(attempt + 1) end)
    end
end

local function settleSpaceFocus()
    if not spaceFocusPending then return end
    spaceFocusPending = false
    spaceSettleTimer = hs.timer.doAfter(0.1, function() focusCurrentSpaceWindow(1) end)
end

local function switchToSpace(target)
    local ok, err = hs.spaces.gotoSpace(target)
    if not ok then
        hs.alert.show("Could not switch Space: " .. tostring(err))
        return false
    end

    spaceFocusPending = true
    spaceFallbackTimer = hs.timer.doAfter(1.0, settleSpaceFocus)
    return true
end

function M.gotoWorkspace(index)
    local target = spaceAt(index)
    if not target then
        hs.alert.show("No macOS Space " .. tostring(index))
        return
    end

    switchToSpace(target)
end

-- Previous/next Space on the screen the pointer is on (no wrap-around).
function M.gotoWorkspaceRelative(delta)
    local screen = hs.mouse.getCurrentScreen()
    if not screen then return end

    local current = hs.spaces.activeSpaceOnScreen(screen)
    local spaces = {}
    for _, id in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
        if hs.spaces.spaceType(id) == "user" then table.insert(spaces, id) end
    end

    for i, id in ipairs(spaces) do
        if id == current then
            local target = spaces[i + delta]
            if target then switchToSpace(target) end
            return
        end
    end
end

-- Move the focused window to a workspace and follow it there, like
-- Hyprland's movetoworkspace (not movetoworkspacesilent).
function M.moveToWorkspace(index)
    local win = currentWindow()
    if not win then return end

    local target = spaceAt(index)
    if not target then
        hs.alert.show("No macOS Space " .. tostring(index))
        return
    end

    local ok, err = hs.spaces.moveWindowToSpace(win, target, true)
    if not ok then
        hs.alert.show("Could not move window: " .. tostring(err))
        return
    end

    hs.spaces.gotoSpace(target)

    hs.timer.doAfter((hs.spaces.MCwaitTime or 0.3) + 0.15, function()
        win:focus()
        warpToWindow(win)
    end)
end

-- ---------------------------------------------------------------------------
-- Mouse: modifier + drag anywhere on a window
-- ---------------------------------------------------------------------------

local mouseTypes = hs.eventtap.event.types

local function modsMatch(flags, mods)
    return mods and flags:containExactly(mods)
end

local function beginMouseDrag(mode, point)
    local win = windowUnderPoint(point, true)
    if not win then return false end

    win:focus()
    dragState = {
        mode = mode,
        win = win,
        mouse = point,
        frame = win:frame(),
    }

    if mode == "move" then
        bspBeginDrag(win)
    else
        bspBeginResize(win, point)
    end
    return true
end

local DRAG_INTERVAL = 1 / 60

local function applyDrag(point)
    local dx = point.x - dragState.mouse.x
    local dy = point.y - dragState.mouse.y

    if dragState.mode == "resize" and bspResizeDrag(dx, dy) then
        return
    end

    local f = hs.geometry.copy(dragState.frame)

    if dragState.mode == "move" then
        -- Size is unchanged, so a single position call is enough.
        dragState.win:setTopLeft({ x = f.x + dx, y = f.y + dy })
        bspUpdateDrag(point)
    else
        f.w = math.max(cfg.minWidth, f.w + dx)
        f.h = math.max(cfg.minHeight, f.h + dy)
        dragState.win:setFrame(f, 0)
    end
end

local function onMouseEvent(event)
    local eventType = event:getType()

    -- Drags and releases only matter during one of our own drags; skip the
    -- location and flag lookups for everything else.
    if not dragState and eventType ~= mouseTypes.leftMouseDown
       and eventType ~= mouseTypes.rightMouseDown then
        return false
    end

    local point = event:location()
    local flags = event:getFlags()

    if eventType == mouseTypes.leftMouseDown
       and modsMatch(flags, cfg.mouse.move) then
        return beginMouseDrag("move", point)
    elseif (eventType == mouseTypes.leftMouseDown
            and modsMatch(flags, cfg.mouse.resize))
        or (eventType == mouseTypes.rightMouseDown
            and modsMatch(flags, cfg.mouse.rightResize)) then
        return beginMouseDrag("resize", point)
    elseif dragState
       and (eventType == mouseTypes.leftMouseDragged
            or eventType == mouseTypes.rightMouseDragged) then
        -- Window updates are several accessibility calls; cap them at ~60/s.
        local now = hs.timer.secondsSinceEpoch()
        if now - (dragState.lastApply or 0) < DRAG_INTERVAL then
            return true
        end
        dragState.lastApply = now
        applyDrag(point)
        return true
    elseif dragState
       and (eventType == mouseTypes.leftMouseUp
            or eventType == mouseTypes.rightMouseUp) then
        local win = dragState.win
        local mode = dragState.mode
        applyDrag(point)  -- the throttle may have skipped the last movement
        dragState = nil
        if mode == "move" and win and bspFinishDrag(win, point) then
            return true
        end
        if mode == "resize" and bspFinishResize() then
            return true
        end
        if win then
            win:setFrameInScreenBounds(win:frame(), 0)
        end
        return true
    end

    return false
end

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

local function ffmFocusPending()
    local entry = ffmPending
    ffmPending = nil
    if not entry or dragState
       or not pointInFrame(hs.mouse.absolutePosition(), entry.frame) then
        return
    end
    if ffmFocusedID ~= entry.id then entry.win:focus() end
end

local function onMouseMoved(event)
    if not cfg.focusFollowsMouse or dragState then
        return false
    end

    local point = event:location()

    -- Fast path: still inside the same window (no accessibility calls).
    if ffmLastWindow and ffmSnapshot and pointInFrame(point, ffmLastWindow.frame)
       and (bspAutoFloat[ffmLastWindow.id] or snapshotEntryAt(point) == ffmLastWindow) then
        return false
    end

    local entry = snapshotEntryAt(point)
    ffmLastWindow = entry
    if not entry then
        return false
    end

    if ffmFocusedID ~= entry.id then
        -- Only focus once the pointer has settled, so skimming across
        -- windows doesn't flicker focus through each of them.
        ffmPending = entry
        running.ffmTimer:start()
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

-- Native edge resizes (and title-bar moves) of tiled windows. windowMoved is
-- debounced by hs.window.filter; wait for the mouse to be released too, and
-- ignore our own modifier-drags, which adopt their result on release.
--
-- While a button is held, a single timer re-checks the most recently moved
-- window every 0.1s instead of each event starting its own polling chain.
local moveWaitTimer = nil
local moveWaitWin = nil

local function onWindowMoved(win)
    if not bspTilingEnabled or bspApplyingLayout or dragState then return end

    -- Echoes of our own layout: nobody is holding the mouse, so it isn't a
    -- native edge drag.
    local held = hs.mouse.getButtons().left
    if not held and hs.timer.secondsSinceEpoch() < bspSettleUntil then return end

    if held then
        moveWaitWin = win
        if not moveWaitTimer then
            moveWaitTimer = hs.timer.doAfter(0.1, function()
                moveWaitTimer = nil
                local waiting = moveWaitWin
                moveWaitWin = nil
                if waiting then onWindowMoved(waiting) end
            end)
        end
        return
    end

    bspAdoptFrame(win)
end

local shutdownHooked = false

function M.stop()
    if running.mouseTap then running.mouseTap:stop() end
    if running.moveTap then running.moveTap:stop() end
    if running.windowFilter then running.windowFilter:unsubscribeAll() end
    if running.spaceWatcher then running.spaceWatcher:stop() end
    if running.screenWatcher then running.screenWatcher:stop() end
    if bspRetileTimer then bspRetileTimer:stop() end
    if running.ffmTimer then running.ffmTimer:stop() end
    if moveWaitTimer then moveWaitTimer:stop() end
    if ffmPrebuild then ffmPrebuild:stop() end
    bspRetileTimer, bspRetilePending, bspRetileForce = nil, false, false
    moveWaitTimer, moveWaitWin, ffmPending = nil, nil, nil
    if bspFloatsTimer then
        bspFloatsTimer:stop()
        bspFloatsTimer = nil
        bspSaveFloatsNow()
    end
    if bspSaveTimer then
        bspSaveTimer:stop()
        bspSaveTimer = nil
        bspSaveTreesNow()
    end
    running = {}
end

function M.setup(opts)
    M.stop()
    cfg = deepMerge(defaults, opts or {})

    hs.window.animationDuration = 0

    -- A hung app would otherwise block every accessibility call (and so the
    -- whole layout) for the system default of several seconds.
    hs.window.timeout(cfg.axTimeout)

    -- Debounced tree saves must not be lost when Hammerspoon reloads or quits.
    if not shutdownHooked then
        shutdownHooked = true
        local previous = hs.shutdownCallback
        hs.shutdownCallback = function()
            M.stop()
            if previous then previous() end
        end
    end

    running.ffmTimer = hs.timer.delayed.new(FFM_HOVER_DELAY, ffmFocusPending)

    running.mouseTap = hs.eventtap.new({
        mouseTypes.leftMouseDown,
        mouseTypes.leftMouseDragged,
        mouseTypes.leftMouseUp,
        mouseTypes.rightMouseDown,
        mouseTypes.rightMouseDragged,
        mouseTypes.rightMouseUp,
    }, onMouseEvent):start()

    running.moveTap = hs.eventtap.new({ mouseTypes.mouseMoved }, onMouseMoved):start()

    local filter = hs.window.filter.new()
    filter:setDefaultFilter({ allowRoles = "AXStandardWindow", visible = true })
    for _, app in ipairs(cfg.ignoreApps or {}) do
        filter:rejectApp(app)
    end
    filter:setCurrentSpace(true)
    running.windowFilter = filter

    -- Track the last focused leaf so a newly-created window splits next to it.
    filter:subscribe(hs.window.filter.windowFocused, function(win)
        if win then
            local id = win:id()
            local intent = bspIntent
            if intent and id == intent.id then
                bspIntent = nil
            elseif intent and hs.timer.secondsSinceEpoch() - intent.time < REASSERT_WINDOW then
                -- macOS moved focus right after our request: put it back.
                bspIntent = nil
                local wanted = bspWinByID[intent.id]
                if wanted and wanted:id() == intent.id then
                    wanted:focus()
                    invalidateWindowCache()
                    return
                end
            end
            bspRaiseFloating()
            bspNoteFocus(win)
        end
        invalidateWindowCache()
    end)

    filter:subscribe(hs.window.filter.windowMoved, function(win)
        -- Our own layout moves echo back here; only other moves (e.g. to
        -- another display) can change which screen a window is on.
        if win and hs.timer.secondsSinceEpoch() > bspSettleUntil then
            bspWindowInfo[win:id()] = nil
        end
        invalidateWindowCache()
        bspRaiseFloating()
        onWindowMoved(win)
    end)

    -- Forget per-window state once a window is gone.
    filter:subscribe(hs.window.filter.windowDestroyed, function(win)
        local id = win and win:id()
        if id then
            bspForgetFloat(id)
            bspFloatingFrames[id] = nil
            bspWinByID[id] = nil
            bspWindowInfo[id] = nil
            -- Kept briefly: the retile that notices the close still needs it
            -- to tell whether this was the focused window.
            hs.timer.doAfter(1, function()
                for i = #bspFocusHistory, 1, -1 do
                    if bspFocusHistory[i] == id then table.remove(bspFocusHistory, i) end
                end
                bspFocusTimes[id] = nil
            end)
        end
    end)

    -- Retile when the set of manageable windows changes.
    filter:subscribe({
        hs.window.filter.windowCreated,
        hs.window.filter.windowVisible,
        hs.window.filter.windowUnminimized,
        hs.window.filter.windowUnfullscreened,
        hs.window.filter.windowInCurrentSpace,
    }, function(win)
        if win then bspWindowInfo[win:id()] = nil end
        invalidateWindowCache()
        scheduleBSPRetile()
    end)

    -- Windows going away: the remaining tiles can grow straight away.
    filter:subscribe({
        hs.window.filter.windowDestroyed,
        hs.window.filter.windowHidden,
        hs.window.filter.windowMinimized,
        hs.window.filter.windowFullscreened,
        hs.window.filter.windowNotInCurrentSpace,
    }, function(win)
        if win then bspWindowInfo[win:id()] = nil end
        invalidateWindowCache()
        scheduleBSPRetile(false, true)
    end)

    running.spaceWatcher = hs.spaces.watcher.new(function()
        settleSpaceFocus()
        invalidateWindowCache()
        scheduleBSPRetile(true)
    end):start()

    running.screenWatcher = hs.screen.watcher.new(function()
        invalidateWindowCache()
        scheduleBSPRetile(true)
    end):start()

    scheduleBSPRetile(true)
    return M
end

return M
