-- Run with: lua tests/scroll_test.lua
-- Unit tests for hyprspoon/scroll.lua (the experimental scrolling columns):
-- the strip and viewport maths, where columns go on a display, and
-- arrange's slides and parks, with stand-ins for Hammerspoon and the
-- modules around it.
package.path = "./?.lua;" .. package.path

local clock = 1000
local timers = {}
hs = {
    timer = {
        secondsSinceEpoch = function() return clock end,
        doAfter = function(delay, fn)
            local t = { delay = delay, fn = fn, stopped = false }
            function t:stop() self.stopped = true end
            timers[#timers + 1] = t
            return t
        end,
    },
    geometry = { rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end },
}

local function screen(uuid, x)
    local f = { x = x, y = 0, w = 1000, h = 800 }
    return { getUUID = function() return uuid end, fullFrame = function() return f end, frame = function() return f end }
end
local screens = { screen("A", 0) }
hs.screen = { allScreens = function() return screens end }

-- Stand-ins. The tree is a plain list of leaves.
local S = {
    cfg = { tiling = { innerGap = 10 }, minWidth = 240, experimental = { scrolling = { duration = 0.2 } } },
    tilingEnabled = true, settleUntil = 0, applied = {},
}
package.loaded["hyprspoon.state"] = S
local moves, applied, forgotten = {}, {}, {}
local Util = { focusHistory = {}, winByID = {} }
local macFocused = nil
function Util.focusedWindow() return macFocused end
function Util.setFrame(win, rect, duration, from)
    moves[#moves + 1] = { id = win:id(), rect = rect, duration = duration, from = from }
end
package.loaded["hyprspoon.util"] = Util
local tree = {}
package.loaded["hyprspoon.tree"] = {
    leaves = function(t) return t end,
    setOf = function() return nil end,
    findByID = function(id)
        for _, l in ipairs(tree) do if l.windowID == id then return {}, l, "ws1" end end
    end,
    keyUUID = function() return "A" end,
}
package.loaded["hyprspoon.spaces"] = {
    layoutScale = function() return nil end,
    label = function(n) return tostring(n) end,
    uuidForKey = function() return "A" end,
    parkPoint = function(_, size) return { x = 999, y = 799 } end,
    isHidden = function() return false end,
}
local retiles = 0
package.loaded["hyprspoon.layout"] = {
    BSP_SETTLE = 0.35,
    applyTree = function(leaf, rect, _, _, opts)
        leaf.rect = rect
        applied[#applied + 1] = { id = leaf.windowID, rect = rect, opts = opts }
    end,
    tileNow = function() retiles = retiles + 1 end,
    scheduleRetile = function() end,
}
package.loaded["hyprspoon.border"] = {
    forget = function(id) forgotten[#forgotten + 1] = id end,
    sync = function() end,
}
package.loaded["hyprspoon.discover"] = { cancelLayoutCheck = function() end }

local Scroll = require("hyprspoon.scroll")

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

local starts, total = Scroll.strip({ 100, 200, 300 }, 10)
assert(starts[1] == 0 and starts[2] == 110 and starts[3] == 320 and total == 620, "strip")

local widths = { 400, 400, 400, 400 }
starts, total = Scroll.strip(widths, 10) -- 0, 410, 820, 1230; total 1630
assert(Scroll.viewport(starts, widths, total, 1000, 0, 1) == 0, "first column already in view")
assert(Scroll.viewport(starts, widths, total, 1000, 0, 3) == 220, "scrolls just enough to show the third")
assert(Scroll.viewport(starts, widths, total, 1000, 220, 2) == 220, "the second is still in view")
assert(Scroll.viewport(starts, widths, total, 1000, 630, 1) == 0, "back to the first")
assert(Scroll.viewport(starts, widths, total, 1000, 0, 4) == 630, "the last stops at the strip's end")
assert(Scroll.viewport(starts, widths, total, 1000, 0, 2, true) == 110, "centred")
assert(Scroll.viewport(starts, widths, total, 1000, 0, 4, true) == 630, "centred, but not past the end")
assert(Scroll.viewport({ 0, 410 }, { 400, 400 }, 810, 1000, 300, 2) == 0, "a strip that fits never scrolls")
assert(Scroll.viewport({ 0, 1210 }, { 1200, 1200 }, 2410, 1000, 0, 2) == 1210,
    "a column wider than the view shows its start")

-- Widths count the gaps: two halves (three thirds) fit exactly.
assert(Scroll.px(0.5, 980, 10) == 485 and Scroll.px(1, 980, 10) == 980, "px")
assert(math.abs(Scroll.share(485, 980, 10) - 0.5) < 1e-9, "share")
local w = Scroll.widths({}, 1, 0.5, 980, 10, true)
assert(w[1] == 980, "one column fills the area")
w = Scroll.widths({}, 2, 1 / 3, 980, 10, true)
assert(w[1] == 485 and w[2] == 485, "two share it")
w = Scroll.widths({}, 3, 1 / 3, 980, 10, true)
assert(w[1] + w[2] + w[3] + 20 == 980, "three thirds fit exactly")
w = Scroll.widths({}, 3, 0.5, 980, 10, true)
assert(w[1] == 485 and w[3] == 485, "too many to fit: their width, scrolling")
w = Scroll.widths({ 0.7 }, 2, 0.5, 980, 10, true)
assert(w[1] == 683 and w[2] == 980 - 683 - 10, "the others fill around a width of its own")
w = Scroll.widths({ 0.9 }, 2, 0.5, 980, 10, true, 240)
assert(w[2] == 485, "too little left to fill: their width, scrolling")
w = Scroll.widths({ 0.3, 0.3 }, 2, 0.5, 980, 10, true)
assert(w[1] == 287 and w[2] == 287, "with none to fill, a gap is left")
w = Scroll.widths({}, 1, 0.5, 980, 10, false)
assert(w[1] == 485, "without fill")

local sf = { x = 0, y = 0, w = 1000, h = 800 }
local right = { { x = 1000, y = 0, w = 1000, h = 800 } }
assert(Scroll.classify({ x = 10, y = 10, w = 400, h = 700 }, sf, {}) == "show", "in view")
assert(Scroll.classify({ x = 800, y = 10, w = 400, h = 700 }, sf, {}) == "hang", "over a free edge")
assert(Scroll.classify({ x = 800, y = 10, w = 400, h = 700 }, sf, right) == "right",
    "not over an edge with a display beyond")
assert(Scroll.classify({ x = -300, y = 10, w = 400, h = 700 }, sf, right) == "hang", "the other edge is free")
assert(Scroll.classify({ x = 1100, y = 10, w = 400, h = 700 }, sf, {}) == "right", "out of sight right")
assert(Scroll.classify({ x = -500, y = 10, w = 400, h = 700 }, sf, {}) == "left", "out of sight left")
local area = { x = 15, y = 15, w = 970, h = 770 }
assert(Scroll.classify({ x = 995, y = 15, w = 970, h = 770 }, sf, {}, area) == "right",
    "a full-width column's neighbour, only into the outer gap, doesn't hang")
assert(Scroll.classify({ x = 900, y = 15, w = 970, h = 770 }, sf, {}, area) == "hang", "into the area, it does")
local e = Scroll.edgeRect({ x = 1100, y = 10, w = 400, h = 700 }, "right", sf)
assert(e.x == 999 and e.y == 10 and e.w == 400, "a point of it left on show at the right")
e = Scroll.edgeRect({ x = -500, y = 10, w = 400, h = 700 }, "left", sf)
assert(e.x == -399, "and at the left")

-- ---------------------------------------------------------------------------
-- Arranging
-- ---------------------------------------------------------------------------

local function win(id)
    local w = { id = function() return id end }
    Util.winByID[id] = w
    return w
end
local byID = {}
for id = 1, 5 do
    tree[id] = { windowID = id }
    byID[id] = win(id)
end
-- Tiling area 980 wide (outer gap 10): columns of 485, starting 495 apart.
local area = { x = 10, y = 10, w = 980, h = 780 }
local function arrange()
    moves, applied, forgotten = {}, {}, {}
    Scroll.arrange("ws1", tree, area, screens[1], byID, nil)
end
local function appliedIDs()
    local out = {}
    for _, a in ipairs(applied) do out[#out + 1] = a.id end
    return table.concat(out, ",")
end

Util.focusHistory = { 1 }
arrange()
-- 1 and 2 fit; 3 starts at 1000 (off), so 3..5 are away to the right.
assert(appliedIDs() == "1,2", "the first two columns on show, got " .. appliedIDs())
assert(Scroll.isAway(3) and Scroll.isAway(4) and Scroll.isAway(5) and not Scroll.isAway(1), "the rest away")
assert(Scroll.awayUUID(4) == "A", "away windows stay on their display")
assert(#moves == 3 and moves[1].rect.x == 999 and moves[1].duration == 0.2, "slid to the right edge")
assert(tree[4].rect.x == 10 + 1485, "away columns keep their place on the strip")
assert(#timers == 3, "parked once the slide is over")
for _, t in ipairs(timers) do t.fn() end
timers = {}
assert(Scroll.signature("ws1") == "|scroll 0", "signature carries the scroll")

-- Focusing the third scrolls by one column: 1 leaves on the left, 3 comes in.
Util.focusHistory = { 3, 1 }
Scroll.reveal(3)
assert(retiles == 1, "revealing an away column retiles")
arrange()
assert(appliedIDs() == "2,3", "2 and 3 on show, got " .. appliedIDs())
local three = applied[2]
assert(three.opts.dx and three.rect.x + three.opts.dx == 999, "3 slides in from the right edge")
assert(not Scroll.isAway(3) and Scroll.isAway(1), "1 went away")
assert(moves[1].id == 1 and moves[1].rect.x == -484, "1 slides out at the left")
assert(Scroll.signature("ws1") == "|scroll 495", "scrolled just far enough to show 3")

-- Focus on a column already in view doesn't retile.
Scroll.reveal(3)
Scroll.reveal(2)
assert(retiles == 1, "already in view")

-- A column partly in view hangs over the edge.
S.cfg.experimental.scrolling.center = true
Util.focusHistory = { 3 }
Scroll.reveal(3)
arrange()
assert(appliedIDs() == "2,3,4", "centred, 2 and 4 hang over the edges, got " .. appliedIDs())
S.cfg.experimental.scrolling.center = nil

-- A new window focused before it was in the tree (so reveal couldn't find
-- it), or before macOS said so: shown all the same.
Util.focusHistory = { 1 }
Scroll.reveal(1)
arrange()
assert(Scroll.isAway(4), "4 out of sight")
tree[6] = { windowID = 6 }
byID[6] = win(6)
Util.focusHistory = { 6, 1 }
arrange()
assert(not Scroll.isAway(6), "focused first, then laid out: scrolled to")
table.remove(tree, 6)
arrange()
tree[6] = { windowID = 6 }
Util.focusHistory = { 1 }
macFocused = byID[6]
arrange()
assert(not Scroll.isAway(6) and Scroll.isAway(1), "laid out before its focus event: scrolled to")
macFocused = nil
Util.focusHistory = { 1 }
arrange()
assert(Scroll.isAway(6), "and only while it's new")
table.remove(tree, 6)

-- Resizing gives a column a width of its own.
Util.focusHistory = { 1 }
arrange()
local before = retiles
Scroll.resize(tree[1], "ws1", 20)
assert(tree[1].columnWidth and math.abs(Scroll.px(tree[1].columnWidth, 980, 10) - 582) <= 1,
    "grown by a fifth")
assert(retiles == before + 1, "and laid out again")
arrange()
assert(applied[1].rect.w == Scroll.px(tree[1].columnWidth, 980, 10), "at that width")
assert(not Scroll.adopt(tree[1], "ws1", { w = applied[1].rect.w + 2 }), "a nudge isn't a resize")
assert(Scroll.adopt(tree[1], "ws1", { w = 700 }), "its edges dragged")
assert(Scroll.px(tree[1].columnWidth, 980, 10) == 700, "to 700")
Scroll.resize(tree[1], "ws1", -90)
assert(Scroll.px(tree[1].columnWidth, 980, 10) == 240, "never narrower than minWidth")
Scroll.adopt(tree[1], "ws1", { w = 5000 })
assert(tree[1].columnWidth == 1, "nor wider than the area")
tree[1].columnWidth = nil

-- A window that's closed is forgotten.
table.remove(tree, 5)
arrange()
assert(not Scroll.isAway(5), "gone from the tree, gone from away")

-- Snapping, and a display beyond the edge: straight to the corner.
S.instantLayout = true
screens[2] = screen("B", 1000)
Util.focusHistory = { 1 }
Scroll.reveal(1)
arrange()
for _, m in ipairs(moves) do
    assert(m.duration == 0 and m.rect.x == 999 and m.rect.y == 799, "parked at once")
end
S.instantLayout = nil

print("Scroll tests passed")
