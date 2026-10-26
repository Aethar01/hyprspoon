-- Run with: lua tests/tree_test.lua
-- Unit tests for wm/tree.lua, loaded as a module with a stubbed `hs` and
-- stand-ins for the modules it reaches at runtime (util, spaces).
package.path = "./?.lua;" .. package.path

local settings = {}
hs = {
    execute = function() return "{ sec = 1000, usec = 0 }" end,
    settings = {
        get = function(key) return settings[key] end,
        set = function(key, value) settings[key] = value end,
    },
    json = { encode = function() return tostring({}) end },
    timer = { doAfter = function() return { stop = function() end } end },
    screen = { allScreens = function() return {} end },
}

package.loaded["wm.util"] = {
    pointInFrame = function(p, f)
        return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
    end,
}
package.loaded["wm.spaces"] = {
    keyForUUID = function(uuid) return "ws" .. uuid end,
    uuidForKey = function(key) return key:match("%d+") end,
}

local S = require("wm.state")
S.cfg = { tiling = { innerGap = 0, minRatio = 0.2, maxRatio = 0.8 } }
S.autoFloat = {}
S.tilingEnabled = true
local Tree = require("wm.tree")

local function leaf(id) return Tree.leaf(id) end
local function split(dir, a, b, ratio) return { split = dir, a = a, b = b, ratio = ratio or 0.5 } end

-- Each leaf's rect, laid out like Layout's applyTree (no gaps).
local function layout(node, rect, out)
    out = out or {}
    node.rect = rect
    if Tree.isLeaf(node) then
        out[node.windowID] = rect
        return out
    end
    local r = node.ratio or 0.5
    if node.split == "vertical" then
        local w = math.floor(rect.w * r)
        layout(node.a, { x = rect.x, y = rect.y, w = w, h = rect.h }, out)
        layout(node.b, { x = rect.x + w, y = rect.y, w = rect.w - w, h = rect.h }, out)
    else
        local h = math.floor(rect.h * r)
        layout(node.a, { x = rect.x, y = rect.y, w = rect.w, h = h }, out)
        layout(node.b, { x = rect.x, y = rect.y + h, w = rect.w, h = rect.h - h }, out)
    end
    return out
end

local function centre(r) return r.x + r.w / 2, r.y + r.h / 2 end

local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
end

local SQUARE = { x = 0, y = 0, w = 400, h = 400 }

test("insertAt splits the target, alternating by depth", function()
    local tree = Tree.insertAt(nil, nil, 1)
    tree = Tree.insertAt(tree, 1, 2)
    assert(tree.split == "vertical" and tree.a.windowID == 1 and tree.b.windowID == 2)
    tree = Tree.insertAt(tree, 2, 3)
    assert(tree.b.split == "horizontal" and tree.b.a.windowID == 2 and tree.b.b.windowID == 3)
    local _, inserted = Tree.insertAt(tree, 99, 4)
    assert(not inserted, "a missing target inserts nothing")
end)

test("insertBeside puts the new window on the given side", function()
    for side, expect in pairs({
        left = { "vertical", 2, 1 }, right = { "vertical", 1, 2 },
        top = { "horizontal", 2, 1 }, bottom = { "horizontal", 1, 2 },
    }) do
        local tree, inserted = Tree.insertBeside(leaf(1), 1, 2, side)
        assert(inserted and tree.split == expect[1], side)
        assert(tree.a.windowID == expect[2] and tree.b.windowID == expect[3], side)
    end
end)

test("prune and removeID collapse emptied splits", function()
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3)))
    tree = Tree.prune(tree, { [1] = true, [3] = true })
    assert(tree.split == "vertical" and tree.b.windowID == 3)
    tree = Tree.removeID(tree, 1)
    assert(tree.windowID == 3)
    assert(Tree.removeID(tree, 3) == nil)
end)

test("swapIDs and collectIDs", function()
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3)))
    Tree.swapIDs(tree, 1, 3)
    assert(tree.a.windowID == 3 and tree.b.b.windowID == 1)
    local ids = Tree.collectIDs(tree)
    assert(ids[1] and ids[2] and ids[3])
    assert(Tree.rightmostLeafID(tree) == 1)
end)

test("ancestors lists splits nearest first, with the branch taken", function()
    local inner = split("horizontal", leaf(2), leaf(3))
    local tree = split("vertical", leaf(1), inner)
    local path, found = Tree.ancestors(tree, 3)
    assert(found.windowID == 3 and #path == 2)
    assert(path[1].node == inner and path[1].branch == "b")
    assert(path[2].node == tree and path[2].branch == "b")
end)

test("moveSplit keeps the splits inside each side where they are", function()
    local inner = split("vertical", leaf(2), leaf(3))
    local tree = split("vertical", leaf(1), inner)
    local before = layout(tree, SQUARE)
    local innerLine = before[3].x
    Tree.moveSplit(tree, "right", 150) -- tile 1's right edge to x = 150
    local after = layout(tree, SQUARE)
    assert(after[1].w == 150, "the edge lands where asked")
    assert(math.abs(after[3].x - innerLine) <= 1, "the inner split stays put on screen")
end)

test("balance halves every split", function()
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3), 0.7), 0.3)
    Tree.balance(tree)
    assert(tree.ratio == 0.5 and tree.b.ratio == 0.5)
end)

test("rotate turns the layout a quarter clockwise", function()
    -- 1 | 2 over 3, with uneven ratios.
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3), 0.25), 0.25)
    local before = layout(tree, SQUARE)
    Tree.rotate(tree)
    local after = layout(tree, SQUARE)
    for id, r in pairs(before) do
        -- Clockwise about the square's centre: (x, y) -> (400 - y, x).
        local cx, cy = centre(r)
        local ax, ay = centre(after[id])
        assert(math.abs(ax - (400 - cy)) <= 1 and math.abs(ay - cx) <= 1, "window " .. id)
    end
    Tree.rotate(tree)
    Tree.rotate(tree)
    Tree.rotate(tree)
    local back = layout(tree, SQUARE)
    for id, r in pairs(before) do
        assert(back[id].x == r.x and back[id].y == r.y and back[id].w == r.w, "four turns are none")
    end
end)

test("mirror flips the layout left to right", function()
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3)), 0.25)
    local before = layout(tree, SQUARE)
    Tree.mirror(tree)
    local after = layout(tree, SQUARE)
    for id, r in pairs(before) do
        local cx, cy = centre(r)
        local ax, ay = centre(after[id])
        assert(math.abs(ax - (400 - cx)) <= 1 and ay == cy, "window " .. id)
    end
end)

test("findByID, rectFor and maximized tiles", function()
    local tree = split("vertical", leaf(1), leaf(2))
    layout(tree, SQUARE)
    S.trees = { ws1 = tree, ws2 = leaf(3) }
    S.keyIndex = {}
    local _, found, key = Tree.findByID(2)
    assert(found.windowID == 2 and key == "ws1")
    assert(Tree.rectFor(1).w == 200)
    tree.a.fullRect = SQUARE
    S.maximized = { ws1 = 1 }
    assert(Tree.rectFor(1) == SQUARE, "a maximized tile's rect is the area it fills")
    assert(Tree.behindMaximized(2) and not Tree.behindMaximized(1) and not Tree.behindMaximized(3))
    S.autoFloat[1] = true
    assert(Tree.rectFor(1) == nil, "floats are never tiles")
    S.autoFloat[1] = nil
    S.maximized = {}
    tree.a.fullRect = nil
end)

test("a window set aside goes back to its slot", function()
    -- 1 | (2 over 3): 2 leaves, then comes back on top of 3.
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3), 0.3), 0.6)
    local slot = Tree.slotOf(tree, 2)
    assert(slot.split == "horizontal" and slot.branch == "a" and slot.ratio == 0.3)
    tree = Tree.removeID(tree, 2)
    local inserted
    tree, inserted = Tree.insertSlot(tree, 2, slot)
    assert(inserted and tree.ratio == 0.6 and tree.a.windowID == 1)
    assert(tree.b.split == "horizontal" and tree.b.ratio == 0.3)
    assert(tree.b.a.windowID == 2 and tree.b.b.windowID == 3)

    -- Beside a whole subtree: 1 | (2 over 3), 1 leaves.
    tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3)), 0.4)
    slot = Tree.slotOf(tree, 1)
    tree = Tree.removeID(tree, 1)
    tree = Tree.insertSlot(tree, 1, slot)
    assert(tree.split == "vertical" and tree.ratio == 0.4 and tree.a.windowID == 1)
    assert(tree.b.a.windowID == 2 and tree.b.b.windowID == 3)

    assert(Tree.slotOf(leaf(1), 1) == nil, "alone, there's no slot")
end)

test("slots taken in turn go back in reverse", function()
    -- 1 | (2 over 3): 2 leaves, then 3; back in the other order.
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3), 0.3), 0.6)
    local slot2 = Tree.slotOf(tree, 2)
    tree = Tree.removeID(tree, 2)
    local slot3 = Tree.slotOf(tree, 3)
    tree = Tree.removeID(tree, 3)
    tree = Tree.insertSlot(tree, 3, slot3)
    tree = Tree.insertSlot(tree, 2, slot2)
    assert(tree.ratio == 0.6 and tree.a.windowID == 1 and tree.b.ratio == 0.3)
    assert(tree.b.a.windowID == 2 and tree.b.b.windowID == 3)
end)

test("no slot once its neighbours have been rearranged", function()
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3)))
    local slot = Tree.slotOf(tree, 1)
    -- 2 and 3 now each sit beside a newcomer, 4.
    tree = split("vertical", split("horizontal", leaf(2), leaf(4)), leaf(3))
    local _, inserted = Tree.insertSlot(tree, 1, slot)
    assert(not inserted)
    -- Its sibling gone altogether.
    _, inserted = Tree.insertSlot(leaf(5), 1, slot)
    assert(not inserted)
    _, inserted = Tree.insertSlot(nil, 1, slot)
    assert(not inserted)
end)

test("workspaces with tiling off have no tiles", function()
    S.trees = { ws1 = split("vertical", leaf(1), leaf(2)), ws2 = leaf(3) }
    S.keyIndex = {}
    assert(Tree.findByID(3))
    S.untiled = { ws2 = true }
    assert(Tree.findByID(3) == nil and Tree.rectFor(3) == nil)
    assert(Tree.findByID(1), "other workspaces still tile")
    S.untiled = {}
end)

print("Tree tests passed")
