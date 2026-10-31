-- Run with: lua tests/tree_test.lua
-- Unit tests for hyprspoon/tree.lua, loaded as a module with a stubbed `hs` and
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
    window = { list = function() return { { kCGWindowNumber = 1 }, { kCGWindowNumber = 2 } } end },
}

-- Every window that still exists, on any Space: 1 and 2 are on screen, 50
-- is on another Space. nil stands for a missing native module.
local allWindows = { [1] = true, [2] = true, [50] = true }
package.loaded["hyprspoon.util"] = {
    pointInFrame = function(p, f)
        return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
    end,
    native = function(name)
        if name == "frames" and allWindows then
            return { liveIDs = function() return allWindows end }
        end
    end,
}
package.loaded["hyprspoon.spaces"] = {
    keyForUUID = function(uuid) return "ws" .. uuid end,
    uuidForKey = function(key) return key:match("%d+") end,
}

local S = require("hyprspoon.state")
S.cfg = { tiling = { innerGap = 0, minRatio = 0.2, maxRatio = 0.8 } }
S.autoFloat = {}
S.tilingEnabled = true
local Tree = require("hyprspoon.tree")

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

test("closestLeaf: the tile under a point, else the nearest", function()
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3)))
    layout(tree, { x = 0, y = 0, w = 200, h = 100 })
    assert(Tree.closestLeaf(tree, { x = 150, y = 80 }).windowID == 3)
    assert(Tree.closestLeaf(tree, { x = -5, y = 10 }).windowID == 1)
    assert(Tree.closestLeaf(tree, { x = 250, y = 20 }).windowID == 2)
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

test("a pseudotiled window is centred in its tile, no bigger than it", function()
    local tile = { x = 100, y = 50, w = 400, h = 300 }
    local r = Tree.pseudoRect(tile, { w = 200, h = 100 })
    assert(r.x == 200 and r.y == 150 and r.w == 200 and r.h == 100)
    r = Tree.pseudoRect(tile, { w = 600, h = 120 })
    assert(r.x == 100 and r.w == 400, "clamped to the tile's width")
    assert(r.y == 140 and r.h == 120)
    r = Tree.pseudoRect(tile, { w = 600, h = 900 })
    assert(r.x == 100 and r.y == 50 and r.w == 400 and r.h == 300, "bigger both ways fills it")
end)

test("rectFor a pseudotiled tile is the window in it", function()
    local tree = split("vertical", leaf(1), leaf(2))
    layout(tree, SQUARE)
    S.trees = { ws1 = tree }
    S.keyIndex = {}
    tree.a.pseudoRect = Tree.pseudoRect(tree.a.rect, { w = 100, h = 100 })
    assert(Tree.rectFor(1) == tree.a.pseudoRect and Tree.rectFor(2) == tree.b.rect)
end)

test("pseudotiling is saved with the tree", function()
    local tree = split("vertical", leaf(1), leaf(2))
    tree.b.pseudo = { w = 300, h = 200 }
    tree.b.pseudoRect = { x = 0, y = 0, w = 1, h = 1 }
    S.trees = { ws1 = tree }
    Tree.saveTreesNow()
    local saved = settings["hyprspoon.trees"].ws1
    assert(saved.a.windowID == 1 and saved.a.pseudo == nil)
    assert(saved.b.windowID == 2 and saved.b.pseudo.w == 300 and saved.b.pseudo.h == 200)
    assert(saved.b.pseudoRect == nil and saved.b.rect == nil, "where it was laid out isn't")
end)

test("pseudotiling outside a tree survives reloads and discards closed windows", function()
    local tree = leaf(1)
    tree.pseudo = { w = 300, h = 200 }
    S.trees = { ws1 = Tree.removeID(tree, 1) }
    S.pseudoAway[99] = { w = 100, h = 100 }
    Tree.saveTreesNow()
    assert(S.pseudoAway[99] == nil, "closed windows are pruned from memory")
    assert(settings["hyprspoon.pseudoAway"]["99"] == nil, "closed windows aren't saved")

    package.loaded["hyprspoon.tree"] = nil
    Tree = require("hyprspoon.tree")
    assert(S.pseudoAway[99] == nil, "closed windows aren't kept")
    local restored = Tree.leaf(1)
    assert(restored.pseudo and restored.pseudo.w == 300 and restored.pseudo.h == 200,
        "a floated pseudotiled window keeps its size after a reload")
    assert(S.pseudoAway[1] == nil, "the leaf takes the saved size")
    Tree.saveTreesNow()
    package.loaded["hyprspoon.tree"] = nil
    Tree = require("hyprspoon.tree")
    assert(S.pseudoAway[1] == nil, "consumed sizes aren't saved again")

    S.pseudoAway[1] = { w = 300, h = 200 }
    Tree.saveTreesNow()
    settings["hyprspoon.treesBoot"] = 500
    package.loaded["hyprspoon.tree"] = nil
    Tree = require("hyprspoon.tree")
    assert(next(S.pseudoAway) == nil, "old boot's IDs aren't reused")
end)

test("pseudotiling of a window off screen is kept until it's known closed", function()
    S.trees = {}
    S.pseudoAway = { [50] = { w = 100, h = 100 }, [99] = { w = 100, h = 100 } }
    local all = allWindows
    allWindows = nil
    Tree.saveTreesNow()
    assert(S.pseudoAway[50] and S.pseudoAway[99], "without the all-window query nothing is dropped")
    allWindows = all
    Tree.saveTreesNow()
    assert(S.pseudoAway[50], "a window on another Space keeps its size")
    assert(S.pseudoAway[99] == nil, "a closed one doesn't")
    S.pseudoAway = {}
end)

test("pseudotiling goes with the window", function()
    S.pseudoAway = {}
    local size = { w = 300, h = 200 }

    -- Swapping places.
    local tree = split("vertical", leaf(1), split("horizontal", leaf(2), leaf(3)))
    tree.a.pseudo = size
    Tree.swapIDs(tree, 1, 3)
    assert(tree.a.windowID == 3 and tree.a.pseudo == nil)
    assert(tree.b.b.windowID == 1 and tree.b.b.pseudo == size)

    -- Moving within the layout (removed, then put in elsewhere).
    tree = Tree.removeID(tree, 1)
    tree = Tree.insertBeside(tree, 2, 1, "left")
    local _, found = Tree.ancestors(tree, 1)
    assert(found.pseudo == size and S.pseudoAway[1] == nil)

    -- Leaving the tree while still open (floated, another workspace),
    -- then coming back.
    S.openIDs = { [1] = true, [2] = true }
    tree = Tree.prune(tree, { [2] = true, [3] = true })
    assert(S.pseudoAway[1] == size)
    tree = Tree.insertAt(tree, 3, 1)
    _, found = Tree.ancestors(tree, 1)
    assert(found.pseudo == size)

    -- Closing: nothing kept.
    S.openIDs = { [2] = true, [3] = true }
    Tree.prune(tree, { [2] = true, [3] = true })
    assert(S.pseudoAway[1] == nil)
    assert(Tree.leaf(1).pseudo == nil)
    S.openIDs = nil
end)

-- A tile holding several windows: `shown` on show, all of `members` in it.
local function set(shown, members, kind, pseudo)
    local l = leaf(shown)
    l.members, l.kind, l.pseudo = members, kind or "group", pseudo
    return l
end

local function same(list, want)
    if #list ~= #want then return false end
    for i, v in ipairs(want) do
        if list[i] ~= v then return false end
    end
    return true
end

test("a set's hidden members are found and collected with its tile", function()
    S.setsAway, S.pseudoAway = {}, {}
    local tree = split("vertical", leaf(1), set(2, { 2, 3, 4 }))
    layout(tree, SQUARE)
    S.trees = { ws1 = tree }
    S.keyIndex = {}
    assert(Tree.treeContains(tree, 3) and not Tree.treeContains(tree, 5))
    local ids = Tree.collectIDs(tree)
    assert(ids[1] and ids[2] and ids[3] and ids[4])
    local shown = Tree.shownIDs(tree)
    assert(shown[1] and shown[2] and not shown[3] and not shown[4], "one window on show per tile")
    local _, found, key = Tree.findByID(3)
    assert(found == tree.b and key == "ws1")
    assert(Tree.rectFor(2) == tree.b.rect)
    assert(Tree.rectFor(3) == nil, "a hidden member doesn't hold the tile")
    assert(#Tree.leaves(tree) == 2 and Tree.leaves(tree)[2] == tree.b)

    -- A new window split in beside a hidden member goes beside its tile.
    local grown, inserted = Tree.insertBeside(tree, 4, 5, "bottom")
    assert(inserted and grown.b.split == "horizontal")
    assert(grown.b.a.windowID == 2 and grown.b.b.windowID == 5)
    assert(Tree.slotOf(grown, 3).siblings[5], "a hidden member's slot is its tile's")
end)

test("the set API: setOf, members, setShown, memberAfter, memberOnShow", function()
    S.setsAway, S.maximized = {}, {}
    local tree = split("vertical", leaf(1), set(2, { 2, 3, 4 }))
    S.trees = { ws1 = tree }
    S.keyIndex = {}
    local found, key = Tree.setOf(4)
    assert(found == tree.b and key == "ws1")
    assert(Tree.setOf(1) == nil and Tree.isSet(tree.b) and not Tree.isSet(tree.a))
    assert(same(Tree.membersOf(3), { 2, 3, 4 }) and same(Tree.membersOf(1), { 1 }))

    assert(Tree.memberAfter(tree.b, 2, 1) == 3 and Tree.memberAfter(tree.b, 4, 1) == 2, "wraps around")
    assert(Tree.memberAfter(tree.b, 2, -1) == 4 and Tree.memberAfter(tree.b, 2, 2) == 4)
    assert(Tree.memberAfter(tree.b, 2, 1, function(id) return id ~= 3 end) == 4, "skips what isn't accepted")
    assert(Tree.memberAfter(tree.b, 2, 1, function() return false end) == nil)

    S.maximized = { ws1 = 2 }
    assert(Tree.setShown(tree.b, 3) == 2 and tree.b.windowID == 3)
    assert(S.maximized.ws1 == 3, "a maximized tile stays maximized")
    assert(Tree.setShown(tree.b, 9) == 3 and tree.b.windowID == 3, "only a member can be shown")
    S.maximized = {}

    assert(Tree.memberOnShow(tree.b, { [3] = true, [4] = true }, {}) == 3, "the shown one if it's on show")
    assert(Tree.memberOnShow(tree.b, { [2] = true, [4] = true }, { [4] = 1, [2] = 5 }) == 4,
        "else the one focused last")
    assert(Tree.memberOnShow(tree.b, { [4] = true, [2] = true }, {}) == 2, "else the first in order")
    assert(Tree.memberOnShow(tree.b, { [1] = true }, {}) == nil)

    Tree.addMember(tree.a, 7, "group")
    assert(tree.a.kind == "group" and same(tree.a.members, { 1, 7 }) and tree.a.windowID == 1)
    Tree.addMember(tree.a, 8)
    assert(same(tree.a.members, { 1, 8, 7 }), "after the shown one")
    Tree.addMember(tree.a, 9, "native", 7)
    assert(same(tree.a.members, { 1, 8, 7, 9 }) and tree.a.kind == "group", "after a given one; a set keeps its kind")
end)

test("a hidden member leaves just its set; a native set of one is a plain tile again", function()
    S.setsAway = {}
    local tree = split("vertical", leaf(1), set(2, { 2, 3, 4 }, "native"))
    tree = Tree.removeID(tree, 3)
    assert(tree.b.windowID == 2 and same(tree.b.members, { 2, 4 }), "the tile stays")
    assert(Tree.removeMember(tree.b, 2) and tree.b.windowID == 4, "the shown one goes: the next shows")
    assert(tree.b.members == nil and tree.b.kind == nil, "one window is just a tile")
    assert(not Tree.removeMember(tree.b, 4))

    local group = set(5, { 5, 6 }, "group")
    assert(Tree.removeMember(group, 6) and same(group.members, { 5 }) and group.kind == "group",
        "a group stays a group down to one")
    assert(not Tree.removeMember(group, 5), "its last member can't leave")

    group = set(6, { 5, 6, 7 }, "group")
    assert(Tree.removeMember(group, 7) and group.windowID == 6)
    assert(Tree.removeMember(group, 6) and group.windowID == 5, "the next one wraps around")
end)

test("native tabs in a group are kept with its members", function()
    local group = set(1, { 1, 2, 3, 4 }, "group")
    group.tabs = { { 2, 3, 4 } }
    assert(Tree.tabsOf(group, 3) == group.tabs[1] and Tree.tabsOf(group, 1) == nil)
    Tree.replaceID(group, 3, 9)
    assert(same(group.members, { 1, 2, 9, 4 }) and same(group.tabs[1], { 2, 9, 4 }))
    Tree.removeMember(group, 9)
    Tree.removeMember(group, 4)
    assert(group.tabs == nil, "one tab left is just a member")
    local native = set(5, { 5, 6 }, "native")
    assert(same(Tree.tabsOf(native, 6), { 5, 6 }))
end)

test("a whole set moves: its tile out, and back in with any of its windows", function()
    S.setsAway, S.pseudoAway, S.trees, S.keyIndex = {}, {}, {}, {}
    local size = { w = 300, h = 200 }
    local tree = split("vertical", leaf(1), split("horizontal", set(2, { 2, 3 }, "group", size), leaf(4)))
    tree = Tree.removeID(tree, 2)
    assert(Tree.collectIDs(tree)[3] == nil, "its hidden member went with it")
    assert(S.setsAway[2] and S.setsAway[2] == S.setsAway[3] and S.pseudoAway[2] == nil)
    local away = Tree.setOf(3)
    assert(away and away.windowID == 2 and select(2, Tree.setOf(3)) == nil, "away from the trees")
    assert(same(Tree.membersOf(2), { 2, 3 }))

    -- Moving within the layout: back in beside 4.
    tree = Tree.insertBeside(tree, 4, 2, "right")
    local _, found = Tree.ancestors(tree, 3)
    assert(found.windowID == 2 and same(found.members, { 2, 3 }) and found.kind == "group")
    assert(found.pseudo == size, "its pseudotile size goes with it")
    assert(next(S.setsAway) == nil)

    -- Seeing a parked member first must not change the group selection.
    tree = Tree.removeID(tree, 2)
    tree = Tree.insertAt(tree, 1, 3)
    _, found = Tree.ancestors(tree, 2)
    assert(found.windowID == 2 and same(found.members, { 2, 3 }))
end)

test("swapping trades whole sets, each with its pseudotiling", function()
    S.setsAway = {}
    local size = { w = 300, h = 200 }
    local tree = split("vertical", leaf(1), set(2, { 2, 3 }, "native", size))
    Tree.swapIDs(tree, 1, 2)
    assert(tree.a.windowID == 2 and same(tree.a.members, { 2, 3 }) and tree.a.kind == "native")
    assert(tree.a.pseudo == size)
    assert(tree.b.windowID == 1 and tree.b.members == nil and tree.b.kind == nil and tree.b.pseudo == nil)
    Tree.swapIDs(tree, 3, 1)
    assert(tree.b.windowID == 2 and tree.a.windowID == 1, "by a hidden member too")
    Tree.swapIDs(tree, 2, 3)
    assert(tree.b.windowID == 2, "within one set nothing moves")
end)

test("prune keeps open hidden members and drops closed ones", function()
    S.setsAway, S.pseudoAway = {}, {}
    local tree = split("vertical", leaf(1), set(2, { 2, 3, 4 }))
    -- 3 is parked or a background tab (open), 4 closed.
    tree = Tree.prune(tree, { [1] = true, [2] = true }, { [1] = true, [2] = true, [3] = true })
    assert(tree.b.windowID == 2 and same(tree.b.members, { 2, 3 }))

    -- Its window gone elsewhere while still open (floated, another workspace):
    -- the set waits, without the members that closed meanwhile.
    tree = split("vertical", leaf(1), set(2, { 2, 3, 4 }))
    tree = Tree.prune(tree, { [1] = true }, { [1] = true, [2] = true, [3] = true })
    assert(tree.windowID == 1)
    assert(S.setsAway[2] and same(S.setsAway[2].members, { 2, 3 }) and S.setsAway[4] == nil)

    -- Closed: nothing kept.
    S.setsAway = {}
    tree = split("vertical", leaf(1), set(2, { 2, 3 }, "native"))
    Tree.prune(tree, { [1] = true }, { [1] = true, [3] = true })
    assert(next(S.setsAway) == nil)

    -- A native set whose only other open window is the one on show leaves
    -- as a plain window, keeping its size.
    tree = split("vertical", leaf(1), set(2, { 2, 3 }, "native", { w = 10, h = 10 }))
    Tree.prune(tree, { [1] = true }, { [1] = true, [2] = true })
    assert(next(S.setsAway) == nil and S.pseudoAway[2].w == 10)
    S.pseudoAway = {}
end)

test("sets are saved with the tree and survive a reload", function()
    S.setsAway, S.pseudoAway, S.maximized, S.filled, S.untiled = {}, {}, {}, {}, {}
    local inTree = set(2, { 1, 2 }, "native", { w = 300, h = 200 })
    inTree.rect = SQUARE
    local group = set(50, { 50, 51 }, "group")
    group.tabs = { { 50, 51 } }
    S.trees = { ws1 = split("vertical", inTree, leaf(99)) }
    Tree.saveTreesNow()
    local saved = settings["hyprspoon.trees"].ws1.a
    assert(saved.windowID == 2 and same(saved.members, { 1, 2 }) and saved.kind == "native")
    assert(saved.pseudo.w == 300 and saved.rect == nil)
    assert(saved.members ~= inTree.members, "saved as a copy")

    -- One away (floating, say), with a member that has since closed.
    S.trees = {}
    local away = set(1, { 1, 50, 99 }, "group")
    away.tabs = { { 50, 99 } }
    Tree.removeID(away, 1)
    Tree.saveTreesNow()
    assert(S.setsAway[99] == nil and same(S.setsAway[1].members, { 1, 50 }), "closed members leave")
    assert(S.setsAway[1].tabs == nil)
    local list = settings["hyprspoon.setsAway"]
    assert(#list == 1 and list[1].windowID == 1 and same(list[1].members, { 1, 50 }))

    S.trees = { ws1 = split("vertical", inTree, group) }
    Tree.saveTreesNow()
    package.loaded["hyprspoon.tree"] = nil
    S.trees, S.setsAway = nil, nil
    Tree = require("hyprspoon.tree")
    local a = S.trees.ws1.a
    assert(a.windowID == 2 and same(a.members, { 1, 2 }) and a.kind == "native" and a.pseudo.h == 200)
    local b = S.trees.ws1.b
    assert(b.windowID == 50 and same(b.members, { 50, 51 }) and same(b.tabs[1], { 50, 51 }))
    assert(S.setsAway[1] and S.setsAway[1] == S.setsAway[50], "away sets come back")
    local back = Tree.leaf(50)
    assert(back.windowID == 1 and same(back.members, { 1, 50 }) and back.kind == "group")
    assert(next(S.setsAway) == nil)

    -- A window that closes forgets its place in a set that's away.
    Tree.removeID(set(1, { 1, 2, 50 }, "group"), 1)
    Tree.forget(2)
    assert(same(S.setsAway[1].members, { 1, 50 }))
    Tree.forget(1)
    assert(S.setsAway[50] and S.setsAway[50].windowID == 50, "the next one shows")
    Tree.forget(50)
    assert(next(S.setsAway) == nil)
    Tree.removeID(set(1, { 1, 2 }, "native"), 1)
    Tree.forget(2)
    assert(next(S.setsAway) == nil, "a native set of one is no set")
    S.trees = {}
end)

test("a set away from the trees stays findable as its members change", function()
    S.setsAway, S.pseudoAway, S.trees, S.keyIndex = {}, {}, {}, {}
    Tree.removeID(set(1, { 1, 2, 3 }, "group"), 1)
    local away = Tree.setOf(2)
    -- A member let go while the set floats (moveOutOfGroup).
    assert(Tree.removeMember(away, 2) and S.setsAway[2] == nil and Tree.setOf(2) == nil)
    assert(Tree.leaf(2).members == nil, "it goes into a tree on its own")
    Tree.addMember(away, 4)
    assert(Tree.setOf(4) == away)
    local back = Tree.leaf(4)
    assert(back == away and back.windowID == 1 and next(S.setsAway) == nil)

    -- Native sets still follow the app-selected tab when they return.
    Tree.removeID(set(7, { 7, 8 }, "native"), 7)
    assert(Tree.leaf(8).windowID == 8)

    -- A native set down to one window while away is just that window.
    Tree.removeID(set(5, { 5, 6 }, "native", { w = 10, h = 10 }), 5)
    Tree.forget(6)
    assert(next(S.setsAway) == nil and S.pseudoAway[5].w == 10, "keeping its size")
    S.pseudoAway = {}
end)

test("addTab: a native tab joins beside its window's other tab", function()
    local group = set(1, { 1, 2 }, "group")
    Tree.addTab(group, 5, 2)
    assert(same(group.members, { 1, 2, 5 }) and same(group.tabs[1], { 2, 5 }))
    Tree.addTab(group, 6, 2)
    assert(same(group.members, { 1, 2, 6, 5 }) and same(group.tabs[1], { 2, 6, 5 }))
    local plain = leaf(7)
    Tree.addTab(plain, 8, 7)
    assert(plain.kind == "native" and same(plain.members, { 7, 8 }) and plain.tabs == nil)
end)

test("registerKind keeps a handler per kind", function()
    local handler = {}
    Tree.registerKind("group", handler)
    assert(Tree.kinds.group == handler and Tree.kinds.native == nil)
    Tree.kinds.group = nil
end)

test("untiled workspaces keep their group membership without tile geometry", function()
    S.trees, S.keyIndex, S.setsAway = {}, {}, {}
    local group = set(1, { 1, 2 }, "group")
    S.trees.ws1, S.untiled.ws1 = group, true
    local found, key = Tree.setOf(2)
    assert(found == group and key == "ws1", "hidden members remain identifiable for parking")
    assert(Tree.findByID(2) == nil, "untiled members have no tile")
    S.untiled.ws1 = nil
    assert(Tree.setOf(2) == group and select(2, Tree.findByID(2)) == group)
end)

print("Tree tests passed")
