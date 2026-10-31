-- hyprspoon/tree.lua: BSP trees: structure, persistence and per-Space/display keys.

local M = {}
package.loaded["hyprspoon.tree"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Spaces -- required last: it loads modules that read M.bootTime at load

-- ---------------------------------------------------------------------------
-- BSP tiling: tree
-- ---------------------------------------------------------------------------
--
-- The tree is kept per workspace (see hyprspoon/spaces.lua). New windows are inserted by
-- splitting the most recently focused leaf; split orientation alternates by
-- tree depth. Closing/minimizing/moving windows prunes the tree automatically.
--
-- When tiling is disabled, pre-tiling floating frames are restored when known.

-- Trees persist across config reloads (window IDs survive a reload; stale
-- ones are pruned when the tree is reconciled).
local TREES_KEY = "hyprspoon.trees"
local TREES_BOOT_KEY = "hyprspoon.treesBoot"
local MAXIMIZED_KEY = "hyprspoon.maximized"
local UNTILED_KEY = "hyprspoon.untiled"
local FILLED_KEY = "hyprspoon.filled"
local PSEUDO_AWAY_KEY = "hyprspoon.pseudoAway"
local SETS_AWAY_KEY = "hyprspoon.setsAway"
local bootTime = tonumber(
    (hs.execute("/usr/sbin/sysctl -n kern.boottime") or ""):match("sec = (%d+)")) or 0

-- Window IDs are only meaningful within one boot; after a restart they can be
-- reused by unrelated windows, so saved trees are discarded.
S.trees = {}
-- Tree key -> the window filling that workspace's whole tiling area, over
-- the other tiles (which keep their places underneath).
S.maximized = {}
-- Tree keys whose maximized window fills the whole display instead, gaps
-- and all: full screen without a Space of its own.
S.filled = {}
-- Tree keys of workspaces whose windows float while tiling is on. Their
-- trees are kept (and ignored) for when tiling comes back.
S.untiled = {}
-- A pseudotiled window keeps its own size, centred in its tile: its leaf's
-- `pseudo` is that size, { w =, h = }. It goes with the window, not the
-- tile, so a window leaving its tree while still open (moving, floating,
-- going to another workspace or full screen) leaves it here, window id ->
-- size, for the leaf it gets when it goes back in.
S.pseudoAway = {}

-- ---------------------------------------------------------------------------
-- Tiles holding several windows
-- ---------------------------------------------------------------------------
--
-- A tile can hold a set of windows with one on show: an app's native tabs,
-- which the app switches between (kind "native"), or one of hyprspoon's
-- own groups (kind "group"). Its leaf keeps `windowID`, the window on show,
-- and adds:
--   members  every window in the tile, the one on show included, in order
--   kind     "native" or "group"
--   tabs     groups only, optional: lists of members that are the native
--            tabs of one app window, which joined the group as one member
-- A plain leaf has none of them. The functions below look inside `members`:
-- a hidden member is found, collected, swapped and moved with its tile, and
-- isn't pruned while it's open. Taking the shown window out of a tree takes
-- the whole tile with it (moving it, floating it, sending it elsewhere);
-- taking a hidden one out takes just that window. `windowID`, rectFor and
-- the layout only ever mean the window on show.
--
-- A set whose shown window leaves the trees while still open waits here,
-- each member's id -> the set (a detached leaf), and comes back whole with
-- whichever member next gets a leaf of its own (see bspLeaf), like a
-- pseudotile's size. Its pseudotile size waits with it.
S.setsAway = {}

-- What each kind of set does, registered by the module behind it with
-- registerKind(kind, handler). Every field is optional:
--   cycle(win, leaf, key, delta)  groupNext (delta 1) / groupPrev (-1)
--   moveOut(win, leaf, key)       moveOutOfGroup
--   show(leaf, key, from, to)     Layout.showMember made `to` the shown
--                                 member in place of `from` (which may have
--                                 closed): make it so on screen
--   strays(leaf, key, ids)        a layout pass found members other than the
--                                 shown one on show (`ids`): hide them again,
--                                 or let them go with removeMember to be
--                                 tiled on their own in the same pass
-- `win` is the focused window (the shown member), `leaf` its set, and `key`
-- the set's tree key, nil while the set is away from the trees (floating).
M.kinds = {}

local function registerKind(kind, handler)
    M.kinds[kind] = handler
end

do
    local savedBoot = hs.settings.get(TREES_BOOT_KEY)
    if type(savedBoot) == "number" and math.abs(savedBoot - bootTime) < 120 then
        S.trees = hs.settings.get(TREES_KEY) or {}
        S.maximized = hs.settings.get(MAXIMIZED_KEY) or {}
        S.untiled = hs.settings.get(UNTILED_KEY) or {}
        S.filled = hs.settings.get(FILLED_KEY) or {}
        for id, size in pairs(hs.settings.get(PSEUDO_AWAY_KEY) or {}) do
            S.pseudoAway[tonumber(id)] = size
        end
        for _, set in ipairs(hs.settings.get(SETS_AWAY_KEY) or {}) do
            if type(set) == "table" and type(set.members) == "table" then
                for _, id in ipairs(set.members) do S.setsAway[id] = set end
            end
        end
    end
end

local function copyList(list)
    if not list then return nil end
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
end

-- A leaf as it's saved: the windows and sizes, not where it was laid out.
local function stripLeaf(leaf)
    local tabs = nil
    for i, list in ipairs(leaf.tabs or {}) do
        tabs = tabs or {}
        tabs[i] = copyList(list)
    end
    return { windowID = leaf.windowID, pseudo = leaf.pseudo, members = copyList(leaf.members),
        kind = leaf.kind, tabs = tabs }
end

local function stripTree(node)
    if not node then return nil end
    if node.windowID ~= nil then return stripLeaf(node) end
    return {
        split = node.split,
        ratio = node.ratio,
        a = stripTree(node.a),
        b = stripTree(node.b),
    }
end

local function indexOf(list, value)
    for i, v in ipairs(list or {}) do
        if v == value then return i end
    end
    return nil
end

-- Whether window `id` is in `leaf`: on show, or a hidden member.
local function hasID(leaf, id)
    return leaf.windowID == id or indexOf(leaf.members, id) ~= nil
end

local function isSet(leaf)
    return leaf ~= nil and leaf.members ~= nil
end

-- Window `id` leaves the set `leaf`, whose tile stays. If it was on show,
-- the member after it is now; Layout.showMember tells the rest. A native
-- set down to one window is a plain tile again; a group stays a group down
-- to its last member, which can't leave (take its tile out with removeID).
-- A set away from the trees stays findable by its members (S.setsAway), and
-- one that's no set any more is just a window, keeping its size. Returns
-- whether `id` left.
local function removeMember(leaf, id)
    local members = leaf.members
    local at = indexOf(members, id)
    if not at or #members < 2 then return false end
    local away = S.setsAway[id] == leaf
    if away then S.setsAway[id] = nil end
    table.remove(members, at)
    if leaf.windowID == id then leaf.windowID = members[(at - 1) % #members + 1] end
    for i = #(leaf.tabs or {}), 1, -1 do
        local list = leaf.tabs[i]
        local j = indexOf(list, id)
        if j then table.remove(list, j) end
        if #list < 2 then table.remove(leaf.tabs, i) end
    end
    if leaf.tabs and #leaf.tabs == 0 then leaf.tabs = nil end
    if leaf.kind == "native" and #members == 1 then
        leaf.members, leaf.kind, leaf.tabs = nil, nil, nil
        if away then
            S.setsAway[leaf.windowID] = nil
            if leaf.pseudo then S.pseudoAway[leaf.windowID] = leaf.pseudo end
        end
    end
    return true
end

-- A set leaving the trees with its shown window still open waits whole in
-- S.setsAway; only the windows still open in `open` go with it, if given.
local function setAway(leaf, open)
    local set = stripLeaf(leaf)
    for _, id in ipairs(copyList(set.members)) do
        if open and not open[id] and id ~= set.windowID then removeMember(set, id) end
    end
    if not set.members then
        -- Nothing else of it is open: just a window, keeping its size.
        if set.pseudo then S.pseudoAway[set.windowID] = set.pseudo end
        return
    end
    for _, id in ipairs(set.members) do S.setsAway[id] = set end
end

-- Window `id` closed: it leaves the set it's away with, and a set with
-- nothing left is forgotten.
local function forgetAway(id)
    local set = S.setsAway[id]
    if set and not removeMember(set, id) then S.setsAway[id] = nil end
end

-- Writing settings is a preferences-file write, so saves are debounced and
-- skipped when the serialized trees haven't changed. Flushed on stop/reload.
local savedTrees = nil
local saveTimer = nil

local function saveTreesNow()
    local out = {}
    for key, tree in pairs(S.trees) do
        out[key] = stripTree(tree)
    end
    local maximized, untiled, filled = {}, {}, {}
    for key, id in pairs(S.maximized) do
        maximized[key] = id
        filled[key] = S.filled[key]
    end
    for key in pairs(S.untiled) do untiled[key] = true end
    -- Like workspace state, prune against WindowServer rather than walking
    -- every app's windows over accessibility. The on-screen list leaves out
    -- other Spaces and hidden apps, so a window missing from it is only
    -- dropped once the all-window query confirms it's gone; without that
    -- query it's kept.
    local live, pseudoAway, all = {}, {}, nil
    for _, win in ipairs(hs.window.list(true) or {}) do
        if win.kCGWindowNumber then live[win.kCGWindowNumber] = true end
    end
    local function gone(id)
        if live[id] then return false end
        if all == nil then
            local frames = Util.native("frames")
            all = frames and frames.liveIDs and frames.liveIDs() or false
        end
        return all and not all[id]
    end
    for id, size in pairs(S.pseudoAway) do
        if gone(id) then
            S.pseudoAway[id] = nil
        else
            pseudoAway[tostring(id)] = size
        end
    end
    local awayIDs = {}
    for id in pairs(S.setsAway) do awayIDs[#awayIDs + 1] = id end
    for _, id in ipairs(awayIDs) do
        if gone(id) then forgetAway(id) end
    end
    -- Each set once, in a stable order so an unchanged one isn't saved again.
    local setsAway, seen = {}, {}
    for _, set in pairs(S.setsAway) do
        if not seen[set] then
            seen[set] = true
            setsAway[#setsAway + 1] = stripLeaf(set)
        end
    end
    table.sort(setsAway, function(a, b) return a.windowID < b.windowID end)
    local encoded = hs.json.encode({ trees = out, maximized = maximized, untiled = untiled,
        filled = filled, pseudoAway = pseudoAway, setsAway = setsAway })
    if encoded == savedTrees then return end
    savedTrees = encoded
    hs.settings.set(TREES_KEY, out)
    hs.settings.set(MAXIMIZED_KEY, maximized)
    hs.settings.set(UNTILED_KEY, untiled)
    hs.settings.set(FILLED_KEY, filled)
    hs.settings.set(PSEUDO_AWAY_KEY, pseudoAway)
    hs.settings.set(SETS_AWAY_KEY, setsAway)
    hs.settings.set(TREES_BOOT_KEY, bootTime)
end

local function saveTrees()
    if saveTimer then saveTimer:stop() end
    saveTimer = hs.timer.doAfter(1, function()
        saveTimer = nil
        saveTreesNow()
    end)
end

-- A new leaf for a window going into a tree. One whose set is away brings
-- the whole set back, showing it.
local function bspLeaf(windowID)
    local set = S.setsAway[windowID]
    if set and indexOf(set.members, windowID) then
        for _, id in ipairs(set.members) do S.setsAway[id] = nil end
        set.windowID = windowID
        return set
    end
    S.setsAway[windowID] = nil
    local pseudo = S.pseudoAway[windowID]
    S.pseudoAway[windowID] = nil
    return { windowID = windowID, pseudo = pseudo }
end

-- Where a pseudotiled window goes in its tile `rect`: its own `size`,
-- centred, and no bigger than the tile.
local function pseudoRect(rect, size)
    local w = math.min(size.w, rect.w)
    local h = math.min(size.h, rect.h)
    return {
        x = rect.x + math.floor((rect.w - w) / 2),
        y = rect.y + math.floor((rect.h - h) / 2),
        w = w,
        h = h,
    }
end

local function isLeaf(node)
    return node and node.windowID ~= nil
end

local function treeContains(node, windowID)
    if not node then return false end
    if isLeaf(node) then
        return hasID(node, windowID)
    end
    return treeContains(node.a, windowID)
        or treeContains(node.b, windowID)
end

-- Keeps the tiles whose window on show is in `valid`. A set's hidden
-- members stay while they're in `valid` or still open (`open`, by default
-- S.openIDs: parked, a background tab, on show elsewhere); closed ones
-- leave it. A tile going while its window is still open leaves its
-- pseudotile size, or its whole set, for when the window goes back in.
local function prune(node, valid, open)
    if not node then return nil end
    open = open or S.openIDs or {}

    if isLeaf(node) then
        for _, id in ipairs(copyList(node.members) or {}) do
            if id ~= node.windowID and not valid[id] and not open[id] then removeMember(node, id) end
        end
        if valid[node.windowID] then return node end
        if open[node.windowID] then
            if node.members then
                setAway(node, open)
            elseif node.pseudo then
                S.pseudoAway[node.windowID] = node.pseudo
            end
        end
        return nil
    end

    node.a = prune(node.a, valid, open)
    node.b = prune(node.b, valid, open)

    if not node.a then return node.b end
    if not node.b then return node.a end
    return node
end

-- Every window in the tree, hidden members of sets included, as a set of ids.
local function collectIDs(node, out)
    out = out or {}
    if not node then return out end

    if isLeaf(node) then
        out[node.windowID] = true
        for _, id in ipairs(node.members or {}) do out[id] = true end
        return out
    end

    collectIDs(node.a, out)
    collectIDs(node.b, out)
    return out
end

-- The windows on show in the tree: one per tile.
local function shownIDs(node, out)
    out = out or {}
    if not node then return out end
    if isLeaf(node) then
        out[node.windowID] = true
        return out
    end
    shownIDs(node.a, out)
    shownIDs(node.b, out)
    return out
end

-- Every leaf in the tree, first to last.
local function leaves(node, out)
    out = out or {}
    if not node then return out end
    if isLeaf(node) then
        out[#out + 1] = node
        return out
    end
    leaves(node.a, out)
    leaves(node.b, out)
    return out
end

local function rightmostLeafID(node)
    if not node then return nil end
    if isLeaf(node) then return node.windowID end
    return rightmostLeafID(node.b) or rightmostLeafID(node.a)
end

local function insertAt(node, targetID, newID, depth)
    depth = depth or 0

    if not node then
        return bspLeaf(newID), true
    end

    if isLeaf(node) then
        if not hasID(node, targetID) then
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

    local replaced, inserted = insertAt(node.a, targetID, newID, depth + 1)
    if inserted then
        node.a = replaced
        return node, true
    end

    replaced, inserted = insertAt(node.b, targetID, newID, depth + 1)
    if inserted then
        node.b = replaced
        return node, true
    end

    return node, false
end

local function insertBeside(node, targetID, newID, side)
    if not node then return nil, false end

    if isLeaf(node) then
        if not hasID(node, targetID) then return node, false end

        local newLeaf = bspLeaf(newID)
        local newFirst = side == "left" or side == "top"
        return {
            split = (side == "left" or side == "right") and "vertical" or "horizontal",
            ratio = 0.5,
            a = newFirst and newLeaf or node,
            b = newFirst and node or newLeaf,
        }, true
    end

    local replaced, inserted = insertBeside(node.a, targetID, newID, side)
    if inserted then
        node.a = replaced
        return node, true
    end

    replaced, inserted = insertBeside(node.b, targetID, newID, side)
    if inserted then
        node.b = replaced
    end
    return node, inserted
end

-- The side of `frame` nearest `point`: "left", "right", "top" or "bottom".
local function nearestSide(frame, point)
    local rx = (point.x - frame.x) / frame.w
    local ry = (point.y - frame.y) / frame.h

    local side, dist = "left", rx
    if 1 - rx < dist then side, dist = "right", 1 - rx end
    if ry < dist then side, dist = "top", ry end
    if 1 - ry < dist then side = "bottom" end
    return side
end

-- The leaf whose tile contains `point`, from the last applied layout.
local function leafAtPoint(node, point)
    if not node then return nil end
    if isLeaf(node) then
        if node.rect and Util.pointInFrame(point, node.rect) then return node end
        return nil
    end
    return leafAtPoint(node.a, point) or leafAtPoint(node.b, point)
end

-- The leaf whose tile contains `point`, else the one nearest it (`point`
-- in a gap or past the edge).
local function closestLeaf(node, point)
    local hit = leafAtPoint(node, point)
    if hit then return hit end
    local best, bestDist = nil, nil
    local function walk(n)
        if not n then return end
        if not isLeaf(n) then walk(n.a) walk(n.b) return end
        local r = n.rect
        if not r then return end
        local dx = math.max(r.x - point.x, 0, point.x - (r.x + r.w))
        local dy = math.max(r.y - point.y, 0, point.y - (r.y + r.h))
        local dist = dx * dx + dy * dy
        if not bestDist or dist < bestDist then best, bestDist = n, dist end
    end
    walk(node)
    return best
end

-- Takes window `windowID` out of the tree, closing up the layout. Its
-- tile goes if it's on show there, and the window keeps its pseudotile
-- size, or its set, for its next leaf (see bspLeaf). A hidden member of a
-- set leaves just the set.
local function removeID(node, windowID)
    if not node then return nil end

    if isLeaf(node) then
        if node.windowID == windowID then
            if node.members then
                setAway(node)
            else
                S.pseudoAway[windowID] = node.pseudo
            end
            return nil
        end
        if node.members then removeMember(node, windowID) end
        return node
    end

    node.a = removeID(node.a, windowID)
    node.b = removeID(node.b, windowID)

    if not node.a then return node.b end
    if not node.b then return node.a end
    return node
end

-- Two tiles trade what they hold: their windows, sets and pseudotiling.
local function swapLeaves(a, b)
    for _, field in ipairs({ "windowID", "members", "kind", "tabs", "pseudo" }) do
        a[field], b[field] = b[field], a[field]
    end
end

-- Window `new` takes `old`'s place in its leaf, wherever it is there (a
-- native tab taking over the tile it closed or switched away from).
local function replaceID(leaf, old, new)
    if leaf.windowID == old then leaf.windowID = new end
    for _, list in ipairs({ leaf.members or {}, table.unpack(leaf.tabs or {}) }) do
        for i, id in ipairs(list) do
            if id == old then list[i] = new end
        end
    end
end

-- The two windows trade places, each keeping its own pseudotiling, and a
-- window in a set taking the whole set with it. With only one of them in
-- the tree, the other takes its place.
local function swapIDs(node, idA, idB)
    local leafA, leafB = nil, nil
    local function walk(n)
        if not n then return end
        if isLeaf(n) then
            if hasID(n, idA) then leafA = n end
            if hasID(n, idB) then leafB = n end
            return
        end
        walk(n.a)
        walk(n.b)
    end
    walk(node)

    if leafA and leafB then
        if leafA ~= leafB then swapLeaves(leafA, leafB) end
    elseif leafA then
        replaceID(leafA, idA, idB)
    elseif leafB then
        replaceID(leafB, idB, idA)
    end
end

-- Split nodes above a leaf, nearest first, with the branch the leaf is in.
-- Also returns the leaf itself.
local function ancestors(node, windowID)
    if not node then return nil end

    if isLeaf(node) then
        if hasID(node, windowID) then return {}, node end
        return nil
    end

    for _, branch in ipairs({"a", "b"}) do
        local path, leaf = ancestors(node[branch], windowID)
        if path then
            table.insert(path, { node = node, branch = branch })
            return path, leaf
        end
    end
    return nil
end

-- Where a window sits, for putting it back later with insertSlot: its
-- parent split, the branch it's on and the windows on the other branch.
-- nil when it's alone in the tree (or not in it).
local function slotOf(node, windowID)
    local path = ancestors(node, windowID)
    local step = path and path[1]
    if not step then return nil end
    return {
        split = step.node.split,
        ratio = step.node.ratio,
        branch = step.branch,
        siblings = collectIDs(step.node[step.branch == "a" and "b" or "a"]),
    }
end

-- Puts `newID` back in a slot from slotOf: split against the subtree that
-- holds exactly the slot's siblings still in the tree. Returns the tree and
-- whether it went in (not when those windows have been split up or joined
-- by others since).
local function insertSlot(node, newID, slot)
    local present = collectIDs(node)
    local want, count = {}, 0
    for id in pairs(slot.siblings) do
        if present[id] then want[id], count = true, count + 1 end
    end
    if count == 0 then return node, false end

    local function place(n)
        local ids, size, inside = collectIDs(n), 0, true
        for id in pairs(ids) do
            size = size + 1
            if not want[id] then inside = false end
        end
        if inside and size == count then
            local newLeaf = bspLeaf(newID)
            local first = slot.branch == "a"
            return {
                split = slot.split,
                ratio = slot.ratio,
                a = first and newLeaf or n,
                b = first and n or newLeaf,
            }, true
        end
        if isLeaf(n) then return n, false end
        local replaced, inserted = place(n.a)
        if inserted then n.a = replaced return n, true end
        replaced, inserted = place(n.b)
        if inserted then n.b = replaced end
        return n, inserted
    end
    return place(node)
end

-- The tree key of the workspace showing on a screen ("ws<number>").
local function keyForScreen(screen)
    return Spaces.keyForUUID(screen:getUUID())
end

-- The UUID of the screen a tree's workspace is laid out on.
local function keyUUID(key)
    return Spaces.uuidForKey(key)
end

-- window id -> tree key, so lookups walk one tree instead of all of them. A
-- hit is verified against its tree, and the cache is cleared whenever trees
-- are rebuilt or moved between.
S.keyIndex = {}

-- Where a window sits in the trees, by id (no accessibility calls): the path
-- of splits above it, its leaf and its tree key. If a stale tree still holds
-- it (e.g. an emptied display that was never reconciled), the tree for an
-- active Space wins. Workspaces with tiling off have no tiles.
local function findByID(windowID)
    if not windowID then return nil end
    local cachedKey = S.keyIndex[windowID]
    if cachedKey and S.trees[cachedKey] and not S.untiled[cachedKey] then
        local path, leaf = ancestors(S.trees[cachedKey], windowID)
        if path then return path, leaf, cachedKey end
    end
    local found = {}
    for key, tree in pairs(S.trees) do
        if not S.untiled[key] then
            local path, leaf = ancestors(tree, windowID)
            if path then found[#found + 1] = { path = path, leaf = leaf, key = key } end
        end
    end
    local f = found[1]
    if #found > 1 then
        local active = {}
        for _, screen in ipairs(hs.screen.allScreens()) do
            active[keyForScreen(screen)] = true
        end
        for _, candidate in ipairs(found) do
            if active[candidate.key] then f = candidate break end
        end
    end
    if f then
        S.keyIndex[windowID] = f.key
        return f.path, f.leaf, f.key
    end
    return nil
end

-- Floats are never tiles, even while a tree that hasn't been reconciled
-- since they started floating still holds them, and nor are the hidden
-- members of a set: only the window on show holds the tile.
-- A maximized tile's is the area it fills, and a pseudotiled one's its
-- own size in its tile.
local function rectFor(windowID)
    if not S.tilingEnabled or S.autoFloat[windowID] then return nil end
    local _, leaf = findByID(windowID)
    if not leaf or leaf.windowID ~= windowID then return nil end
    return leaf.fullRect or leaf.pseudoRect or leaf.rect
end

-- Whether a tile is out of sight under its workspace's maximized window.
local function behindMaximized(windowID)
    if not S.tilingEnabled or next(S.maximized) == nil or S.autoFloat[windowID] then return false end
    local _, _, key = findByID(windowID)
    local maxID = key and S.maximized[key]
    return maxID ~= nil and maxID ~= windowID
end

-- Whether a window is filling its whole display (no ring around it).
local function filling(windowID)
    if not S.tilingEnabled or next(S.filled) == nil or S.autoFloat[windowID] then return false end
    local _, _, key = findByID(windowID)
    return key ~= nil and S.filled[key] == true and S.maximized[key] == windowID
end

-- ---------------------------------------------------------------------------
-- Sets: the API for tiles holding several windows (see the top of the file)
-- ---------------------------------------------------------------------------
--
-- These change the tree only. Layout.showMember does the rest of a switch
-- (focus order, the ring, the kind's `show`); a retile lays the tile out.

-- The set holding window `id` and its tree's key, which is nil while the
-- set is away from the trees (floating, full screen, on a workspace not
-- laid out since). nil if `id` isn't in a set.
local function setOf(id)
    local _, leaf, key = findByID(id)
    if leaf and leaf.members then return leaf, key end
    local away = S.setsAway[id]
    if away then return away, nil end
    return nil
end

-- Every window that goes where `id` goes: its set's members, or just `id`.
-- Read only.
local function membersOf(id)
    local leaf = setOf(id)
    return leaf and leaf.members or { id }
end

-- Window `id` joins `leaf`'s set, a plain leaf becoming a set of `kind` (a
-- set keeps its kind), after member `after` (by default the one on show).
-- It stays hidden until setShown. It mustn't be in another leaf: take it
-- out with removeID first.
local function addMember(leaf, id, kind, after)
    if hasID(leaf, id) then return end
    if not leaf.members then leaf.members, leaf.kind = { leaf.windowID }, kind end
    local at = indexOf(leaf.members, after or leaf.windowID) or #leaf.members
    table.insert(leaf.members, at + 1, id)
    if S.setsAway[leaf.windowID] == leaf then S.setsAway[id] = leaf end
end

-- Window `id` is a native tab of the same app window as member `of`: it
-- joins the set after `of`, and in a group the two count as one member
-- (see `tabs`). A plain leaf becomes a native set.
local function addTab(leaf, id, of)
    addMember(leaf, id, "native", of)
    if leaf.kind ~= "group" then return end
    for _, list in ipairs(leaf.tabs or {}) do
        if indexOf(list, of) then
            if not indexOf(list, id) then table.insert(list, indexOf(list, of) + 1, id) end
            return
        end
    end
    leaf.tabs = leaf.tabs or {}
    leaf.tabs[#leaf.tabs + 1] = { of, id }
end

-- Member `id` is the one on show from now on; a maximized tile stays
-- maximized. Returns the member it replaces (itself if nothing changed).
local function setShown(leaf, id)
    local from = leaf.windowID
    if from == id or not indexOf(leaf.members, id) then return from end
    leaf.windowID = id
    for key, maxID in pairs(S.maximized) do
        if maxID == from then S.maximized[key] = id end
    end
    return from
end

-- The member `delta` places on from `id` (back for a negative `delta`),
-- wrapping around; with `accept`, only members it returns true for count.
-- nil if there's no other.
local function memberAfter(leaf, id, delta, accept)
    local members = leaf.members or {}
    local n = #members
    local at = indexOf(members, id)
    if not at or delta == 0 then return nil end
    local step, left = delta < 0 and -1 or 1, math.abs(delta)
    for k = 1, n - 1 do
        local m = members[(at - 1 + step * k) % n + 1]
        if not accept or accept(m) then
            left = left - 1
            if left == 0 then return m end
        end
    end
    return nil
end

-- The member to show in a pass where `valid` holds the windows on show
-- here: the shown one if it's among them, else the one of them focused
-- most recently (`rank`, window id -> place in the focus order), else the
-- first in order. nil if none is on show.
local function memberOnShow(leaf, valid, rank)
    if valid[leaf.windowID] then return leaf.windowID end
    local best, bestRank = nil, math.huge
    for _, id in ipairs(leaf.members or {}) do
        local r = rank[id] or math.huge
        if valid[id] and (not best or r < bestRank) then best, bestRank = id, r end
    end
    return best
end

-- The native tabs window `id` is one of in `leaf`: every member of a native
-- set, or in a group the tabs that joined it as one member. nil if none.
local function tabsOf(leaf, id)
    if leaf.kind == "native" and indexOf(leaf.members, id) then return leaf.members end
    for _, list in ipairs(leaf.tabs or {}) do
        if indexOf(list, id) then return list end
    end
    return nil
end

-- Nearest split of the given orientation with the window on the given
-- branch ("a" = split line after the window, i.e. its right/bottom edge).
local function boundingSplit(path, split, branch)
    for _, step in ipairs(path) do
        if step.node.split == split
           and step.branch == branch
           and step.node.rect then
            return step.node
        end
    end
    return nil
end

local function clampRatio(ratio)
    return math.max(S.cfg.tiling.minRatio, math.min(S.cfg.tiling.maxRatio, ratio))
end

-- `node`'s extent along the moved split's axis becomes `start`..`start +
-- size`: its own splits across that axis stay where they are on screen
-- (their ratios change instead), as far as the ratio limits allow. Splits
-- the other way just pass the extent on. Positions as Layout's applyTree
-- lays them out, from the rects it last gave each node.
local function keepSplits(node, horizontal, start, size)
    if not node or isLeaf(node) or not node.rect then return end
    local gap = S.cfg.tiling.innerGap
    if (node.split == "vertical") ~= horizontal then
        keepSplits(node.a, horizontal, start, size)
        keepSplits(node.b, horizontal, start, size)
        return
    end
    local oldStart = horizontal and node.rect.x or node.rect.y
    local oldSize = horizontal and node.rect.w or node.rect.h
    local line = oldStart + math.floor(math.max(1, oldSize - gap) * clampRatio(node.ratio or 0.5))
    local usable = math.max(1, size - gap)
    -- Half a point over, so the layout's floor lands on the same pixel.
    node.ratio = clampRatio((line - start + 0.5) / usable)
    local first = math.floor(usable * node.ratio)
    keepSplits(node.a, horizontal, start, first)
    keepSplits(node.b, horizontal, start + first + gap, usable - first)
end

-- Move the split bordering `edge` so the tile edge lands at `pos`. Only
-- that edge moves: the splits inside the subtrees on either side stay put.
local function moveSplit(node, edge, pos)
    local horizontal = node.split == "vertical"
    local origin = horizontal and node.rect.x or node.rect.y
    local size = horizontal and node.rect.w or node.rect.h
    local gap = S.cfg.tiling.innerGap
    local usable = math.max(1, size - gap)

    -- The "a" tile ends at the split line; the "b" tile starts one gap later.
    local first = pos - origin
    if edge == "left" or edge == "top" then
        first = first - gap
    end

    node.ratio = clampRatio((first + 0.5) / usable)
    first = math.floor(usable * node.ratio)
    keepSplits(node.a, horizontal, origin, first)
    keepSplits(node.b, horizontal, origin + first + gap, usable - first)
end


-- Every split back to halves.
local function balance(node)
    if not node or isLeaf(node) then return end
    node.ratio = 0.5
    balance(node.a)
    balance(node.b)
end

-- The layout turned a quarter clockwise: left/right splits become
-- top/bottom ones, and top/bottom ones right/left.
local function rotate(node)
    if not node or isLeaf(node) then return end
    if node.split == "vertical" then
        node.split = "horizontal"
    else
        node.split = "vertical"
        node.a, node.b = node.b, node.a
        node.ratio = 1 - (node.ratio or 0.5)
    end
    rotate(node.a)
    rotate(node.b)
end

-- The layout mirrored left to right.
local function mirror(node)
    if not node or isLeaf(node) then return end
    if node.split == "vertical" then
        node.a, node.b = node.b, node.a
        node.ratio = 1 - (node.ratio or 0.5)
    end
    mirror(node.a)
    mirror(node.b)
end

-- Flushes a pending debounced save (reload, shutdown).
local function stop()
    if saveTimer then
        saveTimer:stop()
        saveTimer = nil
        saveTreesNow()
    end
end

M.stop = stop
M.rectFor = rectFor
M.behindMaximized = behindMaximized
M.filling = filling
M.bootTime = bootTime
M.saveTreesNow = saveTreesNow
M.saveTrees = saveTrees
M.leaf = bspLeaf
M.pseudoRect = pseudoRect
M.isLeaf = isLeaf
M.treeContains = treeContains
M.prune = prune
M.collectIDs = collectIDs
M.rightmostLeafID = rightmostLeafID
M.insertAt = insertAt
M.insertBeside = insertBeside
M.nearestSide = nearestSide
M.closestLeaf = closestLeaf
M.removeID = removeID
M.swapIDs = swapIDs
M.ancestors = ancestors
M.slotOf = slotOf
M.insertSlot = insertSlot
M.keyForScreen = keyForScreen
M.keyUUID = keyUUID
M.findByID = findByID
M.boundingSplit = boundingSplit
M.moveSplit = moveSplit
M.balance = balance
M.rotate = rotate
M.mirror = mirror
M.shownIDs = shownIDs
M.leaves = leaves
M.swapLeaves = swapLeaves
M.replaceID = replaceID
M.isSet = isSet
M.setOf = setOf
M.membersOf = membersOf
M.addMember = addMember
M.addTab = addTab
M.removeMember = removeMember
M.setShown = setShown
M.memberAfter = memberAfter
M.memberOnShow = memberOnShow
M.tabsOf = tabsOf
M.forget = forgetAway
M.registerKind = registerKind

Spaces = require("hyprspoon.spaces")

return M
