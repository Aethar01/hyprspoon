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
    end
end

local function stripTree(node)
    if not node then return nil end
    if node.windowID ~= nil then return { windowID = node.windowID, pseudo = node.pseudo } end
    return {
        split = node.split,
        ratio = node.ratio,
        a = stripTree(node.a),
        b = stripTree(node.b),
    }
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
    for id, size in pairs(S.pseudoAway) do
        if not live[id] and all == nil then
            local frames = Util.native("frames")
            all = frames and frames.liveIDs and frames.liveIDs() or false
        end
        if not live[id] and all and not all[id] then
            S.pseudoAway[id] = nil
        else
            pseudoAway[tostring(id)] = size
        end
    end
    local encoded = hs.json.encode({ trees = out, maximized = maximized, untiled = untiled,
        filled = filled, pseudoAway = pseudoAway })
    if encoded == savedTrees then return end
    savedTrees = encoded
    hs.settings.set(TREES_KEY, out)
    hs.settings.set(MAXIMIZED_KEY, maximized)
    hs.settings.set(UNTILED_KEY, untiled)
    hs.settings.set(FILLED_KEY, filled)
    hs.settings.set(PSEUDO_AWAY_KEY, pseudoAway)
    hs.settings.set(TREES_BOOT_KEY, bootTime)
end

local function saveTrees()
    if saveTimer then saveTimer:stop() end
    saveTimer = hs.timer.doAfter(1, function()
        saveTimer = nil
        saveTreesNow()
    end)
end

local function bspLeaf(windowID)
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
        return node.windowID == windowID
    end
    return treeContains(node.a, windowID)
        or treeContains(node.b, windowID)
end

local function prune(node, valid)
    if not node then return nil end

    if isLeaf(node) then
        if valid[node.windowID] then return node end
        if node.pseudo and S.openIDs and S.openIDs[node.windowID] then
            S.pseudoAway[node.windowID] = node.pseudo
        end
        return nil
    end

    node.a = prune(node.a, valid)
    node.b = prune(node.b, valid)

    if not node.a then return node.b end
    if not node.b then return node.a end
    return node
end

local function collectIDs(node, out)
    out = out or {}
    if not node then return out end

    if isLeaf(node) then
        out[node.windowID] = true
        return out
    end

    collectIDs(node.a, out)
    collectIDs(node.b, out)
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

local function removeID(node, windowID)
    if not node then return nil end

    if isLeaf(node) then
        if node.windowID == windowID then
            S.pseudoAway[windowID] = node.pseudo
            return nil
        end
        return node
    end

    node.a = removeID(node.a, windowID)
    node.b = removeID(node.b, windowID)

    if not node.a then return node.b end
    if not node.b then return node.a end
    return node
end

-- The two windows trade places, each keeping its own pseudotiling.
local function swapIDs(node, idA, idB)
    local leaves = {}
    local function walk(n)
        if not n then return end
        if isLeaf(n) then
            if n.windowID == idA or n.windowID == idB then leaves[#leaves + 1] = n end
            return
        end
        walk(n.a)
        walk(n.b)
    end
    walk(node)

    for _, leaf in ipairs(leaves) do
        leaf.windowID = leaf.windowID == idA and idB or idA
    end
    if #leaves == 2 then
        leaves[1].pseudo, leaves[2].pseudo = leaves[2].pseudo, leaves[1].pseudo
    end
end

-- Split nodes above a leaf, nearest first, with the branch the leaf is in.
-- Also returns the leaf itself.
local function ancestors(node, windowID)
    if not node then return nil end

    if isLeaf(node) then
        if node.windowID == windowID then return {}, node end
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
-- since they started floating still holds them.
-- A maximized tile's is the area it fills, and a pseudotiled one's its
-- own size in its tile.
local function rectFor(windowID)
    if not S.tilingEnabled or S.autoFloat[windowID] then return nil end
    local _, leaf = findByID(windowID)
    return leaf and (leaf.fullRect or leaf.pseudoRect or leaf.rect)
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

Spaces = require("hyprspoon.spaces")

return M
