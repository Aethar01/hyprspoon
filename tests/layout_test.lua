-- Run with: lua tests/layout_test.lua
-- Unit tests for hyprspoon/layout.lua's passes over tiles holding several
-- windows (see "Tiles holding several windows" in hyprspoon/tree.lua):
-- Layout.tileNow with the real tree and stand-ins for Hammerspoon and the
-- modules that find, focus and ring the windows.
package.path = "./?.lua;" .. package.path

local settings = {}
local timers = {}
local clock = 1000
hs = {
    execute = function() return "{ sec = 1000, usec = 0 }" end,
    settings = {
        get = function(key) return settings[key] end,
        set = function(key, value) settings[key] = value end,
    },
    json = { encode = function() return tostring({}) end },
    timer = {
        doAfter = function(_, fn)
            local t = { fn = fn, stop = function() end }
            timers[#timers + 1] = t
            return t
        end,
        secondsSinceEpoch = function() return clock end,
    },
    window = { list = function() return {} end },
    mouse = {
        absolutePosition = function() return { x = 0, y = 0 } end,
        getButtons = function() return {} end,
    },
    geometry = {
        rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
        copy = function(r) return { x = r.x, y = r.y, w = r.w, h = r.h } end,
    },
}

-- Displays: A shows workspace 1, B workspace 2, side by side.
local function screen(uuid, x)
    local f = { x = x, y = 0, w = 1000, h = 800 }
    return { getUUID = function() return uuid end, frame = function() return f end }
end
local screens = { screen("A", 0), screen("B", 1000) }
hs.screen = { allScreens = function() return screens end }

-- Windows: an id, an app and a frame that setFrame moves.
local wins = {}
local function window(id, pid)
    local w = { frame_ = { x = 0, y = 0, w = 100, h = 100 }, moves = 0 }
    function w:id() return id end
    function w:pid() return pid or id end
    function w:frame() return { x = self.frame_.x, y = self.frame_.y, w = self.frame_.w, h = self.frame_.h } end
    function w:setFrame(r)
        self.frame_ = { x = r.x, y = r.y, w = r.w, h = r.h }
        self.moves = self.moves + 1
    end
    function w:setTopLeft(p) self:setFrame({ x = p.x, y = p.y, w = self.frame_.w, h = self.frame_.h }) end
    function w:setSize(s) self:setFrame({ x = self.frame_.x, y = self.frame_.y, w = s.w, h = s.h }) end
    wins[id] = w
    return w
end
for id = 1, 9 do window(id) end

local noop = function() end
local Util = {
    forgetManagedWindows = noop, focusHistory = {}, focusTimes = {}, winByID = {}, pidByID = {},
    dlog = noop, idList = function() return "" end,
    native = noop,
    rulesFor = function() return {} end,
    focusedWindow = noop,
    pointInFrame = function(p, f)
        return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
    end,
}
for id, w in pairs(wins) do Util.winByID[id] = w end
package.loaded["hyprspoon.util"] = Util

-- What the next pass finds: windows on show by display, which other
-- windows are still open (parked), and which are background tabs.
local onShow, parked, ghosts = {}, {}, {}
package.loaded["hyprspoon.discover"] = {
    layoutChecks = {},
    cancelLayoutCheck = noop,
    windowsByScreen = function()
        local S = require("hyprspoon.state")
        S.ghosts, S.openIDs = {}, {}
        local byScreen = {}
        for uuid, ids in pairs(onShow) do
            byScreen[uuid] = {}
            for _, id in ipairs(ids) do
                table.insert(byScreen[uuid], wins[id])
                S.openIDs[id] = true
            end
        end
        for _, id in ipairs(parked) do S.openIDs[id] = true end
        for _, id in ipairs(ghosts) do table.insert(S.ghosts, wins[id]) end
        return byScreen
    end,
}
local ring = {}
package.loaded["hyprspoon.border"] = {
    sync = noop,
    handOver = function(from, to) ring[#ring + 1] = { from, to } end,
}
local focused = {}
package.loaded["hyprspoon.focus"] = {
    invalidateWindowCache = noop,
    focus = function(win) focused[#focused + 1] = win:id() end,
    noteFocus = noop,
}
-- Window id -> workspace number, as Spaces keeps it.
local workspaceOf = {}
package.loaded["hyprspoon.spaces"] = {
    workspaceOf = function(id) return workspaceOf[id] end,
    keyForUUID = function(uuid) return uuid == "A" and "ws1" or "ws2" end,
    uuidForKey = function(key) return key == "ws1" and "A" or "B" end,
    layoutScale = noop,
    isHidden = function() return false end,
}
package.loaded["hyprspoon.float"] = { raiseFloating = noop }
package.loaded["hyprspoon.drop"] = {}
package.loaded["hyprspoon.restore"] = { rebuild = function(_, tree) return tree end }
package.loaded["hyprspoon.hooks"] = { fire = noop }

local S = require("hyprspoon.state")
S.cfg = { debug = false, tiling = { innerGap = 0, outerGap = 0, minRatio = 0.2, maxRatio = 0.8,
    animationDuration = 0 } }
S.tilingEnabled = true
S.running = { windowFilter = {} }
S.autoFloat, S.fullscreen, S.offSpace, S.applied, S.windowInfo = {}, {}, {}, {}, {}
S.settleUntil, S.lastMouseTime = 0, 0
local Tree = require("hyprspoon.tree")
local Layout = require("hyprspoon.layout")

local function leaf(id) return Tree.leaf(id) end
local function split(a, b) return { split = "vertical", ratio = 0.5, a = a, b = b } end
local function set(shown, members, kind)
    local l = leaf(shown)
    l.members, l.kind = members, kind or "group"
    return l
end
local function same(list, want)
    if #list ~= #want then return false end
    for i, v in ipairs(want) do
        if list[i] ~= v then return false end
    end
    return true
end

local function test(name, fn)
    -- Every test starts from nothing laid out or focused.
    S.trees, S.setsAway, S.pseudoAway, S.maximized, S.slots = {}, {}, {}, {}, {}
    S.keyIndex, S.applied, S.floatingFrames = {}, {}, {}
    S.fullscreen, S.offSpace = {}, {}
    for i = #Util.focusHistory, 1, -1 do Util.focusHistory[i] = nil end
    ring, focused, onShow, parked, ghosts, workspaceOf = {}, {}, {}, {}, {}, {}
    for _, w in pairs(wins) do w.moves = 0 end
    Tree.kinds.group, Tree.kinds.native = nil, nil
    Layout.scheduleRetile(true) -- forgets the last pass's signatures
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
end

-- One pass, as a window event would run it.
local function pass(show, others, background)
    onShow, parked, ghosts = show, others or {}, background or {}
    Layout.tileNow(false)
end

test("a hidden member isn't a new window, and one on show takes over its tile", function()
    pass({ A = { 1, 2 } })
    local tree = S.trees.ws1
    local tile = tree.b.rect
    tree.b.members, tree.b.kind = { 2, 3 }, "native"
    wins[1].moves, wins[3].moves = 0, 0

    -- The app switched tabs: 3 is on show, 2 is in the background.
    pass({ A = { 1, 3 } }, { 2 })
    tree = S.trees.ws1
    assert(tree.b.windowID == 3 and same(tree.b.members, { 2, 3 }), "the tile shows 3, keeping 2")
    assert(Tree.leaves(tree)[3] == nil, "no tile of its own for 3")
    assert(wins[1].moves == 0, "the other tile stays put")
    local f = wins[3]:frame()
    assert(f.x == tile.x and f.w == tile.w, "3 fills the tile")
    assert(ring[1][1] == 2 and ring[1][2] == 3, "the ring goes over")
end)

test("closing the shown member shows the next one in its tile", function()
    local shows = {}
    Tree.registerKind("group", { show = function(l, key, from, to) shows[#shows + 1] = { l, key, from, to } end })
    pass({ A = { 1, 2 } })
    local tree = S.trees.ws1
    tree.b.members = { 2, 3, 4 }
    tree.b.kind = "group"
    local tile = tree.b.rect
    Util.focusHistory[1], Util.focusHistory[2] = 2, 1
    wins[1].moves = 0

    -- 2 closes; 3 and 4 are parked members.
    pass({ A = { 1 } }, { 3, 4 })
    tree = S.trees.ws1
    assert(tree.b.windowID == 3 and same(tree.b.members, { 3, 4 }), "the next member shows")
    assert(tree.b.rect.x == tile.x and tree.b.rect.w == tile.w, "in the same tile")
    assert(wins[1].moves == 0, "nothing else moves")
    assert(#shows == 1 and shows[1][1] == tree.b and shows[1][2] == "ws1")
    assert(shows[1][3] == 2 and shows[1][4] == 3, "the kind is told to bring 3 out")
    assert(Util.focusHistory[1] == 3, "the tile keeps its place in the focus order")
    assert(focused[#focused] == 3, "and focus")

    -- Once it's on show it's laid out there.
    assert(S.trees.ws1.b.windowID == 3, "the tile waits for it")
    pass({ A = { 1, 3 } }, { 4 })
    local f = wins[3]:frame()
    assert(f.x == tile.x and f.w == tile.w)

    -- The last member closing closes the tile.
    S.trees.ws1.b.members = { 3 }
    pass({ A = { 1 } })
    assert(S.trees.ws1.windowID == 1)
end)

test("a set whose shown window isn't on show yet keeps its tile, for a while", function()
    pass({ A = { 1, 2 } })
    S.trees.ws1.b.members, S.trees.ws1.b.kind = { 2, 3 }, "native"
    workspaceOf[2] = 1
    -- 2 is a background tab for a moment, and nothing else is on show yet.
    pass({ A = { 1 } }, {}, { 2, 3 })
    local b = S.trees.ws1.b
    assert(b and b.windowID == 2 and same(b.members, { 2, 3 }))
    clock = clock + 0.5
    pass({ A = { 1 } }, {}, { 2, 3 })
    assert(S.trees.ws1.b == b)
    -- Nothing came: the set leaves the layout, to come back with its window.
    clock = clock + 0.6
    pass({ A = { 1 } }, {}, { 2, 3 })
    assert(S.trees.ws1.windowID == 1 and S.setsAway[2] and S.setsAway[3])
    pass({ A = { 1, 3 } }, {}, { 2 })
    local _, back = Tree.ancestors(S.trees.ws1, 2)
    assert(back.windowID == 3 and same(back.members, { 2, 3 }))
    S.trees.ws1 = split(leaf(1), set(2, { 2, 3 }, "native"))
    pass({ A = { 1 } }, {}, { 2, 3 })
    b = S.trees.ws1.b
    -- Floated: it goes, set and all.
    S.autoFloat[2] = true
    pass({ A = { 1 } }, { 2, 3 })
    assert(S.trees.ws1.windowID == 1 and S.setsAway[2])
    S.autoFloat[2] = nil
end)

test("a maximized tile stays maximized for the member shown next", function()
    pass({ A = { 1, 2 } })
    S.trees.ws1.b.members, S.trees.ws1.b.kind = { 2, 3 }, "group"
    S.maximized.ws1 = 2
    pass({ A = { 1 } }, { 3 })
    assert(S.trees.ws1.b.windowID == 3 and S.maximized.ws1 == 3)
    pass({ A = { 1, 3 } })
    assert(S.maximized.ws1 == 3 and S.trees.ws1.b.fullRect, "and fills the area once it's on show")
    -- The last one closing: nothing is maximized.
    S.trees.ws1.b.members = { 3, 4 }
    pass({ A = { 1 } })
    assert(S.maximized.ws1 == nil)
end)

test("hidden members stay while open, and leave when they close", function()
    pass({ A = { 1, 2 } })
    S.trees.ws1.b.members, S.trees.ws1.b.kind = { 2, 3, 4 }, "group"
    pass({ A = { 1, 2 } }, { 3 })
    assert(same(S.trees.ws1.b.members, { 2, 3 }))
    pass({ A = { 1, 2 } })
    assert(same(S.trees.ws1.b.members, { 2 }) and S.trees.ws1.b.kind == "group", "a group of one stays")
end)

test("a set sent to another workspace goes whole", function()
    pass({ A = { 1, 2 } })
    S.trees.ws1.b.members, S.trees.ws1.b.kind = { 2, 3 }, "group"
    -- 2 now shows on display B (which gave it workspace 2), 3 is parked.
    workspaceOf[1], workspaceOf[2], workspaceOf[3] = 1, 2, 1
    pass({ A = { 1 }, B = { 2 } }, { 3 })
    assert(S.trees.ws1.windowID == 1)
    local moved = S.trees.ws2
    assert(moved.windowID == 2 and same(moved.members, { 2, 3 }) and moved.kind == "group")
    assert(next(S.setsAway) == nil)

    -- Sent to workspace 2 while that isn't laid out (parked): it waits
    -- away from the trees until it is.
    S.trees.ws2 = nil
    S.trees.ws1 = split(leaf(1), set(2, { 2, 3 }))
    pass({ A = { 1 } }, { 2, 3 })
    assert(S.trees.ws1.windowID == 1 and S.setsAway[3] and S.setsAway[3].windowID == 2)
    assert(S.trees.ws2 == nil)
    pass({ A = { 1 }, B = { 2 } }, { 3 })
    assert(same(S.trees.ws2.members, { 2, 3 }))
end)

test("a native set keeps its shown member through a workspace round trip", function()
    pass({ A = { 1, 2 } })
    local native = S.trees.ws1.b
    native.members, native.kind = { 2, 3, 4 }, "native"
    for _, n in ipairs({ 2, 1 }) do
        for _, id in ipairs(native.members) do workspaceOf[id] = n end
        if n == 2 then pass({ A = { 1 }, B = { 2 } }, {}, { 3, 4 })
        else pass({ A = { 1, 2 } }, {}, { 3, 4 }) end
        local found, key = Tree.setOf(2)
        assert(found and key == "ws" .. n)
        assert(found.windowID == 2 and same(found.members, { 2, 3, 4 }))
    end
    assert(wins[3].moves == 0 and wins[4].moves == 0)
end)

test("a set going full screen keeps its slot and comes back whole", function()
    pass({ A = { 1, 2, 4 } })
    local tree = S.trees.ws1
    local _, two = Tree.ancestors(tree, 2)
    two.members, two.kind = { 2, 3 }, "native"
    S.fullscreen[2] = true
    pass({ A = { 1, 4 } })
    assert(not Tree.treeContains(S.trees.ws1, 3), "it left with its tabs")
    assert(S.slots[2] and S.setsAway[3])
    S.fullscreen[2] = nil
    pass({ A = { 1, 2, 4 } })
    _, two = Tree.ancestors(S.trees.ws1, 3)
    assert(two and two.windowID == 2 and same(two.members, { 2, 3 }))
    assert(S.slots[2] == nil)
end)

test("members found on show go to the kind, which can let them go", function()
    local seen = nil
    Tree.registerKind("native", { strays = function(l, key, ids)
        seen = { key = key, ids = ids }
        for _, id in ipairs(ids) do Tree.removeMember(l, id) end
    end })
    pass({ A = { 1, 2 } })
    S.trees.ws1.b.members, S.trees.ws1.b.kind = { 2, 3 }, "native"
    -- A tab torn off: 3 on show beside 2.
    pass({ A = { 1, 2, 3 } })
    assert(seen.key == "ws1" and same(seen.ids, { 3 }))
    local ids = Tree.shownIDs(S.trees.ws1)
    assert(ids[1] and ids[2] and ids[3], "3 is tiled on its own")
    assert(Tree.setOf(2) == nil, "a native set of one is a plain tile")

    -- With nothing registered they're left in the set.
    Tree.kinds.native = nil
    S.trees.ws1 = split(leaf(1), set(2, { 2, 3 }, "native"))
    pass({ A = { 1, 2, 3 } })
    assert(same(S.trees.ws1.b.members, { 2, 3 }) and not Tree.shownIDs(S.trees.ws1)[3])
end)

test("a native tab taking over a tile in a set takes its place among the members", function()
    pass({ A = { 1, 2 } })
    S.trees.ws1.b.members, S.trees.ws1.b.kind = { 2, 3 }, "group"
    -- 2 closes and the same app shows 5 where it was.
    wins[5].pid = function() return 2 end
    wins[5].frame_ = wins[2]:frame()
    Util.pidByID[2] = 2
    pass({ A = { 1, 5 } }, { 3 })
    local b = S.trees.ws1.b
    assert(b.windowID == 5 and same(b.members, { 5, 3 }))
    wins[5].pid = function() return 5 end
end)

test("a new native tab in a set joins it beside the tab it covers", function()
    pass({ A = { 1, 2 } })
    S.trees.ws1.b.members, S.trees.ws1.b.kind = { 2, 3 }, "group"
    -- A new tab, 5, opens in 2's window: 2 is now a background tab.
    wins[5].pid = function() return 2 end
    wins[5].frame_ = wins[2]:frame()
    Util.pidByID[2] = 2
    pass({ A = { 1, 5 } }, { 3 }, { 2 })
    local b = S.trees.ws1.b
    assert(b.windowID == 5 and same(b.members, { 2, 5, 3 }))
    assert(#b.tabs == 1 and same(b.tabs[1], { 2, 5 }), "the two count as one member of the group")
    wins[5].pid = function() return 5 end
end)

test("groupNext, groupPrev and moveOutOfGroup go to the focused set's kind", function()
    package.loaded["hyprspoon.resize"] = {}
    local Focus = package.loaded["hyprspoon.focus"]
    local Actions = require("hyprspoon.actions")
    S.trees.ws1 = split(leaf(1), set(2, { 2, 3 }, "group"))
    Focus.currentWindow = function() return wins[2] end
    Actions.groupNext() -- nothing registered: nothing happens
    local calls = {}
    Tree.registerKind("group", {
        cycle = function(win, l, key, delta) calls[#calls + 1] = { "cycle", win, l, key, delta } end,
        moveOut = function(win, l, key) calls[#calls + 1] = { "moveOut", win, l, key } end,
    })
    Actions.groupNext()
    Actions.groupPrev()
    Actions.moveOutOfGroup()
    assert(#calls == 3)
    assert(calls[1][1] == "cycle" and calls[1][2] == wins[2] and calls[1][3] == S.trees.ws1.b)
    assert(calls[1][4] == "ws1" and calls[1][5] == 1 and calls[2][5] == -1)
    assert(calls[3][1] == "moveOut" and calls[3][3] == S.trees.ws1.b)

    -- A floating set is away from the trees: no key.
    S.trees.ws1 = Tree.removeID(S.trees.ws1, 2)
    Actions.groupNext()
    assert(calls[4][3].windowID == 2 and calls[4][4] == nil)

    -- A window alone in its tile, or no window: nothing.
    Focus.currentWindow = function() return wins[1] end
    Actions.groupNext()
    Focus.currentWindow = noop
    Actions.moveOutOfGroup()
    assert(#calls == 4)
end)

print("Layout tests passed")

test("an unknown native switch creates a set and hands the ring over in the same pass", function()
    wins[3] = window(3, 2)
    S.trees.ws1 = split(leaf(1), leaf(2))
    Util.pidByID[2] = 2
    Util.focusHistory = { 2, 1 }
    onShow = { A = { 1, 2 } }
    Layout.tileNow()
    local rect = S.trees.ws1.b.rect
    S.nativeBackground = { [2] = { pid = 2 } }
    onShow, ghosts = { A = { 1 } }, { 2 }
    Layout.tileNow()
    assert(S.trees.ws1.b.windowID == 2, "the first switch reserves its tile while AXWindows catches up")
    wins[3].frame_ = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    onShow, ghosts = { A = { 1, 3 } }, { 2 }
    local otherMoves = wins[1].moves
    Layout.tileNow()
    local current = S.trees.ws1.b
    assert(current.windowID == 3 and current.kind == "native")
    assert(Tree.treeContains(S.trees.ws1, 2), "the old tab remains a member")
    assert(ring[#ring][1] == 2 and ring[#ring][2] == 3)
    assert(current.rect.x == rect.x and current.rect.w == rect.w)
    assert(wins[3].moves == 0 and wins[1].moves == otherMoves, "a switch places no windows")
end)
