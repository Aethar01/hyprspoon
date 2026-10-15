-- wm/tree.lua: BSP trees: structure, persistence and per-Space/display keys.

local M = {}
package.loaded["wm.tree"] = M

local S = require("wm.state")
local Util = require("wm.util")

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
local TREES_BOOT_KEY = "bspTreesBoot"
local bootTime = tonumber(
    (hs.execute("/usr/sbin/sysctl -n kern.boottime") or ""):match("sec = (%d+)")) or 0

-- Window IDs are only meaningful within one boot; after a restart they can be
-- reused by unrelated windows, so saved trees are discarded.
S.trees = {}
do
    local savedBoot = hs.settings.get(TREES_BOOT_KEY)
    if type(savedBoot) == "number" and math.abs(savedBoot - bootTime) < 120 then
        S.trees = hs.settings.get(TREES_KEY) or {}
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
    local encoded = hs.json.encode(out)
    if encoded == savedTrees then return end
    savedTrees = encoded
    hs.settings.set(TREES_KEY, out)
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

-- The tree key of a screen's active Space; defined below, with the cache of
-- active Spaces it reads.
local keyForScreen

-- The screen UUID part of a tree key ("<uuid>:<space>").
local function keyUUID(key)
    return key and key:match("^(.-):")
end

-- window id -> tree key, so lookups walk one tree instead of all of them. A
-- hit is verified against its tree, and the cache is cleared whenever trees
-- are rebuilt or moved between.
S.keyIndex = {}

-- Where a window sits in the trees, by id (no accessibility calls): the path
-- of splits above it, its leaf and its tree key. If a stale tree still holds
-- it (e.g. an emptied display that was never reconciled), the tree for an
-- active Space wins.
local function findByID(windowID)
    if not windowID then return nil end
    local cachedKey = S.keyIndex[windowID]
    if cachedKey and S.trees[cachedKey] then
        local path, leaf = ancestors(S.trees[cachedKey], windowID)
        if path then return path, leaf, cachedKey end
    end
    local found = {}
    for key, tree in pairs(S.trees) do
        local path, leaf = ancestors(tree, windowID)
        if path then found[#found + 1] = { path = path, leaf = leaf, key = key } end
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
local function rectFor(windowID)
    if not S.tilingEnabled or S.autoFloat[windowID] then return nil end
    local _, leaf = findByID(windowID)
    return leaf and leaf.rect
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

-- Move the split bordering `edge` so the tile edge lands at `pos`.
local function moveSplit(node, edge, pos)
    local horizontal = node.split == "vertical"
    local origin = horizontal and node.rect.x or node.rect.y
    local size = horizontal and node.rect.w or node.rect.h
    local usable = math.max(1, size - S.cfg.tiling.innerGap)

    -- The "a" tile ends at the split line; the "b" tile starts one gap later.
    local first = pos - origin
    if edge == "left" or edge == "top" then
        first = first - S.cfg.tiling.innerGap
    end

    node.ratio = math.max(S.cfg.tiling.minRatio,
        math.min(S.cfg.tiling.maxRatio, first / usable))
end


-- Each screen's active Space, kept until a Space or display change: the
-- Space watcher, the filter's Space events and the screen watcher all drop
-- it, whichever arrives first.
local keyCache = {}

local function forgetActiveSpaces()
    keyCache = {}
end

keyForScreen = function(screen)
    local uuid = screen:getUUID()
    if keyCache[uuid] then return keyCache[uuid] end

    local spaceID = hs.spaces.activeSpaceOnScreen(screen)
    local key = uuid .. ":" .. tostring(spaceID or "unknown")
    if spaceID then keyCache[uuid] = key end
    return key
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
M.keyForScreen = keyForScreen
M.keyUUID = keyUUID
M.findByID = findByID
M.boundingSplit = boundingSplit
M.moveSplit = moveSplit
M.forgetActiveSpaces = forgetActiveSpaces

return M
