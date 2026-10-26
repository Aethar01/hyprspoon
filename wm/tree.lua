-- wm/tree.lua: BSP trees: structure, persistence and per-Space/display keys.

local M = {}
package.loaded["wm.tree"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Spaces -- required last: it loads modules that read M.bootTime at load

-- ---------------------------------------------------------------------------
-- BSP tiling: tree
-- ---------------------------------------------------------------------------
--
-- The tree is kept per workspace (see wm/spaces.lua). New windows are inserted by
-- splitting the most recently focused leaf; split orientation alternates by
-- tree depth. Closing/minimizing/moving windows prunes the tree automatically.
--
-- When tiling is disabled, pre-tiling floating frames are restored when known.

-- Trees persist across config reloads (window IDs survive a reload; stale
-- ones are pruned when the tree is reconciled).
local TREES_KEY = "bspTrees"
local TREES_BOOT_KEY = "bspTreesBoot"
local MAXIMIZED_KEY = "bspMaximized"
local UNTILED_KEY = "bspUntiledWorkspaces"
local bootTime = tonumber(
    (hs.execute("/usr/sbin/sysctl -n kern.boottime") or ""):match("sec = (%d+)")) or 0

-- Window IDs are only meaningful within one boot; after a restart they can be
-- reused by unrelated windows, so saved trees are discarded. So are trees
-- from before workspaces were our own (keyed by display and macOS Space).
S.trees = {}
-- Tree key -> the window filling that workspace's whole tiling area, over
-- the other tiles (which keep their places underneath).
S.maximized = {}
-- Tree keys of workspaces whose windows float while tiling is on. Their
-- trees are kept (and ignored) for when tiling comes back.
S.untiled = {}
do
    local savedBoot = hs.settings.get(TREES_BOOT_KEY)
    if type(savedBoot) == "number" and math.abs(savedBoot - bootTime) < 120 then
        for key, tree in pairs(hs.settings.get(TREES_KEY) or {}) do
            if key:match("^ws%d+$") then S.trees[key] = tree end
        end
        for key, id in pairs(hs.settings.get(MAXIMIZED_KEY) or {}) do
            if key:match("^ws%d+$") then S.maximized[key] = id end
        end
        for key in pairs(hs.settings.get(UNTILED_KEY) or {}) do
            if key:match("^ws%d+$") then S.untiled[key] = true end
        end
    end
end

local function stripTree(node)
    if not node then return nil end
    if node.windowID ~= nil then return { windowID = node.windowID } end
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
    local maximized, untiled = {}, {}
    for key, id in pairs(S.maximized) do maximized[key] = id end
    for key in pairs(S.untiled) do untiled[key] = true end
    local encoded = hs.json.encode({ trees = out, maximized = maximized, untiled = untiled })
    if encoded == savedTrees then return end
    savedTrees = encoded
    hs.settings.set(TREES_KEY, out)
    hs.settings.set(MAXIMIZED_KEY, maximized)
    hs.settings.set(UNTILED_KEY, untiled)
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
    return { windowID = windowID }
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

local function removeID(node, windowID)
    if not node then return nil end

    if isLeaf(node) then
        if node.windowID == windowID then return nil end
        return node
    end

    node.a = removeID(node.a, windowID)
    node.b = removeID(node.b, windowID)

    if not node.a then return node.b end
    if not node.b then return node.a end
    return node
end

local function swapIDs(node, idA, idB)
    if not node then return end

    if isLeaf(node) then
        if node.windowID == idA then
            node.windowID = idB
        elseif node.windowID == idB then
            node.windowID = idA
        end
        return
    end

    swapIDs(node.a, idA, idB)
    swapIDs(node.b, idA, idB)
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
-- A maximized tile's is the area it fills.
local function rectFor(windowID)
    if not S.tilingEnabled or S.autoFloat[windowID] then return nil end
    local _, leaf = findByID(windowID)
    return leaf and (leaf.fullRect or leaf.rect)
end

-- Whether a tile is out of sight under its workspace's maximized window.
local function behindMaximized(windowID)
    if not S.tilingEnabled or next(S.maximized) == nil or S.autoFloat[windowID] then return false end
    local _, _, key = findByID(windowID)
    local maxID = key and S.maximized[key]
    return maxID ~= nil and maxID ~= windowID
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
M.bootTime = bootTime
M.saveTreesNow = saveTreesNow
M.saveTrees = saveTrees
M.leaf = bspLeaf
M.isLeaf = isLeaf
M.treeContains = treeContains
M.prune = prune
M.collectIDs = collectIDs
M.rightmostLeafID = rightmostLeafID
M.insertAt = insertAt
M.insertBeside = insertBeside
M.nearestSide = nearestSide
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

Spaces = require("wm.spaces")

return M
