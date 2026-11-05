-- Run with: lua tests/scroll_test.lua
-- Unit tests for hyprspoon/scroll.lua (the experimental scrolling columns):
-- columns in the tree, the strip and viewport maths (niri's), where columns
-- go on a display, arrange's slides and parks, and the column actions, with
-- stand-ins for Hammerspoon and the modules around it.
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

-- Stand-ins. Workspace "ws1"'s tree is S.trees.ws1.
local S = {
    cfg = { tiling = { innerGap = 10 }, minWidth = 240, minHeight = 140,
        experimental = { scrolling = { duration = 0.2 } } },
    tilingEnabled = true, settleUntil = 0, applied = {}, trees = {},
}
package.loaded["hyprspoon.state"] = S
local moves, applied, forgotten = {}, {}, {}
local Util = { focusHistory = {}, winByID = {} }
local macFocused = nil
function Util.focusedWindow() return macFocused end
function Util.setFrame(win, rect, duration, from)
    moves[#moves + 1] = { id = win:id(), rect = rect, duration = duration, from = from }
end
function Util.warpToWindow() end
package.loaded["hyprspoon.util"] = Util

local Scroll
local function leaves()
    local out = {}
    for _, col in ipairs(Scroll.columns(S.trees.ws1)) do
        for _, l in ipairs(col) do out[#out + 1] = l end
    end
    return out
end
package.loaded["hyprspoon.tree"] = {
    leaf = function(id) return { windowID = id } end,
    findByID = function(id)
        for _, l in ipairs(leaves()) do if l.windowID == id then return {}, l, "ws1" end end
    end,
    keyUUID = function() return "A" end,
    saveTrees = function() end,
}
package.loaded["hyprspoon.spaces"] = {
    layoutScale = function() return nil end,
    label = function(n) return tostring(n) end,
    uuidForKey = function() return "A" end,
    parkPoint = function(_, size) return { x = 999, y = 799 } end,
    isHidden = function() return false end,
}
local retiles = 0
local focused = {}
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
package.loaded["hyprspoon.focus"] = { focus = function(w) focused[#focused + 1] = w:id() end }

Scroll = require("hyprspoon.scroll")

-- ---------------------------------------------------------------------------
-- Columns in the tree
-- ---------------------------------------------------------------------------

local function L(id) return { windowID = id } end
local function shape(tree)
    local out = {}
    for _, col in ipairs(Scroll.columns(tree)) do
        local ids = {}
        for _, l in ipairs(col) do ids[#ids + 1] = l.windowID end
        out[#out + 1] = table.concat(ids, "+")
    end
    return table.concat(out, ",")
end

local t = Scroll.build({ { L(1) }, { L(2), L(3), width = 0.7 }, { L(4) } })
assert(shape(t) == "1,2+3,4", "columns round trip, got " .. shape(t))
assert(Scroll.columns(t)[2].width == 0.7, "a column keeps its width")
assert(t.split == "vertical" and t.ratio == 1 / 3, "even columns for BSP")
-- A BSP tree: vertical splits separate columns, horizontal ones stack.
t = { split = "vertical", a = L(1), b = { split = "horizontal", a = L(2), b = L(3) } }
assert(shape(t) == "1,2+3", "BSP tree read as columns, got " .. shape(t))
t = { split = "horizontal", a = { split = "vertical", a = L(1), b = L(2) }, b = L(3) }
assert(shape(t) == "1,2,3", "a horizontal split over columns is no column, got " .. shape(t))
t = Scroll.build({ { L(1) }, { L(2), L(3) } })
assert(shape(Scroll.insert(t, 1, 9, "right")) == "1,9,2+3", "a new column right of the focused one")
t = Scroll.build({ { L(1) }, { L(2), L(3) } })
assert(shape(Scroll.insert(t, 2, 9, "right")) == "1,2+3,9", "right of its whole column")
t = Scroll.build({ { L(1) }, { L(2), L(3) } })
assert(shape(Scroll.insert(t, 2, 9, "left")) == "1,9,2+3", "preselected left")
t = Scroll.build({ { L(1) }, { L(2), L(3) } })
assert(shape(Scroll.insert(t, 2, 9, "bottom")) == "1,2+9+3", "preselected down: into the column")

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

local starts, total = Scroll.strip({ 100, 200, 300 }, 10)
assert(starts[1] == 0 and starts[2] == 110 and starts[3] == 320 and total == 620, "strip")

local widths = { 400, 400, 400, 400 }
starts = Scroll.strip(widths, 10) -- 0, 410, 820, 1230
assert(Scroll.viewport(starts, widths, 1000, 0, 1) == 0, "first column already in view")
assert(Scroll.viewport(starts, widths, 1000, 0, 3) == 220, "scrolls just enough to show the third")
assert(Scroll.viewport(starts, widths, 1000, 220, 2) == 220, "the second is still in view")
assert(Scroll.viewport(starts, widths, 1000, 630, 1) == 0, "back to the first")
assert(Scroll.viewport(starts, widths, 1000, 300, 2) == 300, "on show: the view doesn't move")
assert(Scroll.viewport(starts, widths, 1000, 500, 2) == 410, "nearer its start: left aligned")
assert(Scroll.viewport(starts, widths, 1000, 0, 1, "always") == -300, "centred, even the first")
assert(Scroll.viewport(starts, widths, 1000, 0, 3, true) == 520, "true is always")
-- on-overflow: centred only when it and the column focused before don't fit.
assert(Scroll.viewport(starts, widths, 1000, 0, 3, "on-overflow", 2) == 220, "fits beside 2: just shown")
local wide = { 600, 600, 600 }
local ws = Scroll.strip(wide, 10)
assert(Scroll.viewport(ws, wide, 1000, 0, 2, "on-overflow", 1) == 610 + 300 - 500, "doesn't fit: centred")
assert(Scroll.viewport({ 0, 1210 }, { 1200, 1200 }, 1000, 0, 2) == 1210,
    "a column wider than the view shows its start")

-- Widths count the gaps: two halves (three thirds) fit exactly.
assert(Scroll.px(0.5, 980, 10) == 485 and Scroll.px(1, 980, 10) == 980, "px")
assert(math.abs(Scroll.share(485, 980, 10) - 0.5) < 1e-9, "share")
local w = Scroll.widths({}, 1, 0.5, 980, 10, false)
assert(w[1] == 485, "niri: a column keeps its width, alone too")
w = Scroll.widths({}, 1, 0.5, 980, 10, true)
assert(w[1] == 980, "fill: one column fills the area")
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

-- Heights: shared evenly, or a share of their own.
local h = Scroll.heights({}, 2, 780, 10)
assert(h[1] == 385 and h[2] == 385, "two share the column")
h = Scroll.heights({}, 3, 780, 10)
assert(h[1] + h[2] + h[3] + 20 == 780, "three fill it exactly")
h = Scroll.heights({ 0.75 }, 2, 780, 10)
assert(h[1] == 583 and h[2] == 780 - 583 - 10, "one of its own, the other the rest")
h = Scroll.heights({ 0.95 }, 2, 780, 10, 140)
assert(h[2] >= 140 and h[1] + h[2] + 10 == 780, "never less than the least for the rest")
h = Scroll.heights({ 0.25, 0.25 }, 2, 780, 10)
assert(h[1] + h[2] + 10 == 780, "all of their own: scaled to fill")

local sf = { x = 0, y = 0, w = 1000, h = 800 }
local right = { { x = 1000, y = 0, w = 1000, h = 800 } }
assert(Scroll.classify({ x = 10, y = 10, w = 400, h = 700 }, sf, {}) == "show", "in view")
assert(Scroll.classify({ x = 800, y = 10, w = 400, h = 700 }, sf, {}) == "hang", "over the free edge")
assert(Scroll.classify({ x = 800, y = 10, w = 400, h = 700 }, sf, right) == "right",
    "not over the edge with a display beyond")
assert(Scroll.classify({ x = -300, y = 10, w = 400, h = 700 }, sf, right) == "hang", "the other edge is free")
assert(Scroll.classify({ x = 1100, y = 10, w = 400, h = 700 }, sf, {}) == "right", "out of sight right")
assert(Scroll.classify({ x = -500, y = 10, w = 400, h = 700 }, sf, {}) == "left", "out of sight left")
local inner = { x = 15, y = 15, w = 970, h = 770 }
assert(Scroll.classify({ x = 995, y = 15, w = 970, h = 770 }, sf, {}, inner) == "right",
    "a full-width column's neighbour, only into the outer gap, doesn't hang")
assert(Scroll.classify({ x = 900, y = 15, w = 970, h = 770 }, sf, {}, inner) == "hang", "into the area, it does")
local e = Scroll.edgeRect({ x = 1100, y = 10, w = 400, h = 700 }, "right", sf)
assert(e.x == 999 and e.y == 10 and e.w == 400, "a point of it left on show at the right")
e = Scroll.edgeRect({ x = -500, y = 10, w = 400, h = 700 }, "left", sf)
assert(e.x == -399, "a point of it left on show at the left")

-- ---------------------------------------------------------------------------
-- Arranging
-- ---------------------------------------------------------------------------

local function win(id)
    local w = { id = function() return id end }
    Util.winByID[id] = w
    return w
end
local byID = {}
local cols = {}
for id = 1, 5 do
    cols[id] = { L(id) }
    byID[id] = win(id)
end
S.trees.ws1 = Scroll.build(cols)
-- Tiling area 980 wide (outer gap 10): columns of 485, starting 495 apart.
local area = { x = 10, y = 10, w = 980, h = 780 }
local function arrange()
    moves, applied, forgotten = {}, {}, {}
    Scroll.arrange("ws1", S.trees.ws1, area, screens[1], byID, nil)
end
local function appliedIDs()
    local out = {}
    for _, a in ipairs(applied) do out[#out + 1] = a.id end
    return table.concat(out, ",")
end
local function rectOf(id)
    for _, a in ipairs(applied) do if a.id == id then return a.rect end end
end
local function focus(id)
    Util.focusHistory = { id }
    Scroll.reveal(id)
    arrange()
end

Util.focusHistory = { 1 }
arrange()
-- 1 and 2 fit; 3 starts at 1000 (off), so 3..5 are away to the right.
assert(appliedIDs() == "1,2", "the first two columns on show, got " .. appliedIDs())
assert(Scroll.isAway(3) and Scroll.isAway(4) and Scroll.isAway(5) and not Scroll.isAway(1), "the rest away")
assert(Scroll.awayUUID(4) == "A", "away windows stay on their display")
assert(#moves == 3 and moves[1].rect.x == 999 and moves[1].duration == 0.2, "slid to the right edge")
assert(leaves()[4].rect.x == 10 + 1485, "away columns keep their place on the strip")
assert(#timers == 3, "parked once the slide is over")
for _, tm in ipairs(timers) do tm.fn() end
timers = {}
assert(#moves == 6 and moves[4].rect.x == 999 and moves[4].rect.y == 799 and moves[4].rect.w == 485,
    "parked in the corner at the column's size")

-- Focus moves to 3: scrolled just far enough, 1 slides out, 3 slides in.
focus(3)
assert(retiles == 1, "focus on a column out of sight retiles")
assert(appliedIDs() == "2,3", "2 and 3 on show, got " .. appliedIDs())
local three = applied[2]
assert(three.opts.dx and three.rect.x + three.opts.dx == 999, "3 slides in from the right edge")
assert(not Scroll.isAway(3) and Scroll.isAway(1), "1 went away")
assert(moves[1].id == 1 and moves[1].rect.x == -484, "1 slides out at the left")
assert(Scroll.signature("ws1") == "|scroll 495", "scrolled just far enough to show 3")

-- Focus on a column already in view doesn't retile.
Scroll.reveal(2)
Util.focusHistory = { 2 }
assert(retiles == 1, "already in view")
arrange()
assert(Scroll.signature("ws1") == "|scroll 495", "and the view stays")

-- A column partly in view hangs over the edge.
S.cfg.experimental.scrolling.center = "always"
focus(3)
assert(appliedIDs() == "2,3,4", "centred, 2 and 4 hang over the edges, got " .. appliedIDs())
S.cfg.experimental.scrolling.center = nil
focus(1)
assert(Scroll.signature("ws1") == "|scroll 0", "back to the first")

-- ---------------------------------------------------------------------------
-- New windows and closing them (activate_prev_column_on_removal)
-- ---------------------------------------------------------------------------

-- Opened from 2: a column right of it, focused, scrolled to.
focus(2)
S.trees.ws1 = Scroll.insert(S.trees.ws1, 2, 6, "right")
byID[6] = win(6)
macFocused = byID[6]
arrange()
assert(shape(S.trees.ws1) == "1,2,6,3,4,5", "6 right of 2")
assert(rectOf(6) and rectOf(6).x == 10 + 495, "6 on show, at the right")
assert(Scroll.signature("ws1") == "|scroll 495", "scrolled just enough")
macFocused = nil
Util.focusHistory = { 6, 2 }
-- Closed again: focus goes back to 2, and the view as it was.
local valid = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
assert(Scroll.afterClose("ws1", S.trees.ws1, 6, valid) == 2, "back to the column it opened from")
S.trees.ws1 = Scroll.build((function()
    local c = Scroll.columns(S.trees.ws1)
    table.remove(c, 3)
    return c
end)())
Util.focusHistory = { 2 }
arrange()
assert(Scroll.signature("ws1") == "|scroll 0", "the view back as it was")

-- Otherwise the column to the right takes focus, the last one's left.
focus(3)
assert(Scroll.afterClose("ws1", S.trees.ws1, 3, valid) == 4, "the column to the right")
assert(Scroll.afterClose("ws1", S.trees.ws1, 5, valid) == 4, "the last: its left")

-- A column closing left of the focused one doesn't move it on screen.
focus(4)
local before = rectOf(4).x
local c = Scroll.columns(S.trees.ws1)
local one = table.remove(c, 1)
S.trees.ws1 = Scroll.build(c)
arrange()
assert(rectOf(4).x == before, "4 stays put")
table.insert(c, 1, one)
S.trees.ws1 = Scroll.build(c)
focus(1)

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

-- consume-or-expel: 2 joins 1's column, then leaves it again.
Scroll.consumeOrExpel(byID[2], "left")
assert(shape(S.trees.ws1) == "1+2,3,4,5", "consumed, got " .. shape(S.trees.ws1))
arrange()
assert(rectOf(1).h == 385 and rectOf(2).y == 10 + 385 + 10, "sharing the column's height")
assert(rectOf(1).x == rectOf(2).x and rectOf(2).w == 485, "one column")
-- focus up and down within it, left and right to the column's last focused.
focused = {}
assert(Scroll.focus(byID[2], "up") and focused[1] == 1, "focus up in the column")
assert(not Scroll.focus(byID[1], "up"), "nothing above: falls through")
Util.focusHistory = { 3, 2, 1 }
assert(Scroll.focus(byID[3], "left") and focused[2] == 2, "left: the column's window focused last")
-- move-window-down and up.
Scroll.move(byID[1], "down")
assert(shape(S.trees.ws1) == "2+1,3,4,5", "moved down its column")
Scroll.swap(byID[1], "up")
assert(shape(S.trees.ws1) == "1+2,3,4,5", "and back up")
-- Resize the height within the column.
focus(2)
Scroll.resize(leaves()[2], "ws1", 0, 25)
arrange()
assert(rectOf(2).h > rectOf(1).h, "taller by a quarter")
Scroll.consumeOrExpel(byID[2], "right")
assert(shape(S.trees.ws1) == "1,2,3,4,5", "expelled to the right, got " .. shape(S.trees.ws1))
assert(leaves()[2].windowHeight == nil, "its own height gone with the column")
-- consume-window-into-column / expel-window-from-column.
Scroll.consume(byID[1])
assert(shape(S.trees.ws1) == "1+2,3,4,5", "consume-window-into-column")
Scroll.expel(byID[1])
assert(shape(S.trees.ws1) == "2,1,3,4,5", "expel-window-from-column")
Scroll.move(byID[1], "left")
assert(shape(S.trees.ws1) == "1,2,3,4,5", "move-column-left")
assert(not Scroll.move(byID[1], "left"), "the first column: falls through")
Scroll.moveToEnd(byID[1], true)
assert(shape(S.trees.ws1) == "2,3,4,5,1", "move-column-to-last")
Scroll.moveToEnd(byID[1], false)
assert(shape(S.trees.ws1) == "1,2,3,4,5", "move-column-to-first")
-- swap-window: the windows trade columns, the columns keep their widths.
Scroll.cycleWidth(byID[1])
focus(1)
Scroll.swap(byID[1], "right")
assert(shape(S.trees.ws1) == "2,1,3,4,5", "swap-window-right")
assert(Scroll.columns(S.trees.ws1)[1].width == 2 / 3, "the first column kept its width")
Scroll.swap(byID[1], "left")
for _, l in ipairs(leaves()) do l.columnWidth = nil end

-- Widths: presets, niri's "+10%", full width, edges.
focus(1)
Scroll.cycleWidth(byID[1])
assert(leaves()[1].columnWidth == 2 / 3, "a half to two thirds")
arrange()
Scroll.cycleWidth(byID[1])
assert(leaves()[1].columnWidth == 1 / 3, "wraps round to a third")
arrange()
Scroll.cycleWidth(byID[1], true)
assert(leaves()[1].columnWidth == 2 / 3, "back: wraps round to two thirds")
arrange()
Scroll.resize(leaves()[1], "ws1", -10, 0)
assert(math.abs(leaves()[1].columnWidth - (Scroll.share(Scroll.px(2 / 3, 980, 10), 980, 10) - 0.1)) < 1e-9,
    "-10% of the area")
arrange()
assert(Scroll.adopt(leaves()[1], "ws1", { w = 700, h = 780 }), "its edges dragged")
assert(Scroll.px(leaves()[1].columnWidth, 980, 10) == 700, "to 700")
arrange()
assert(not Scroll.adopt(leaves()[1], "ws1", { w = 702, h = 780 }), "a nudge isn't a resize")
Scroll.resize(leaves()[1], "ws1", -90, 0)
assert(Scroll.px(leaves()[1].columnWidth, 980, 10) == 240, "never narrower than minWidth")
assert(Scroll.toggleFullWidth(byID[1]), "maximize-column")
arrange()
assert(rectOf(1).w == 980 and appliedIDs() == "1", "full width, alone in view")
Scroll.toggleFullWidth(byID[1])
arrange()
assert(rectOf(1).w == 240, "back to its width")
-- expand-column-to-available-width: 1 (240) and 2 (485) in view.
Scroll.expand(byID[1])
arrange()
assert(rectOf(1).w == 980 - 485 - 10 and rectOf(2).x + rectOf(2).w == 990, "fills what 2 leaves")
for _, l in ipairs(leaves()) do l.columnWidth = nil end
arrange()

-- center-column.
focus(2)
Scroll.center(byID[2])
arrange()
assert(math.abs(rectOf(2).x - (10 + (980 - 485) / 2)) <= 1, "centred")
focus(1)

-- A new window focused before it was in the tree (so reveal couldn't find
-- it), or before macOS said so: shown all the same.
assert(Scroll.isAway(4), "4 out of sight")
c = Scroll.columns(S.trees.ws1)
c[#c + 1] = { L(6) }
S.trees.ws1 = Scroll.build(c)
byID[6] = win(6)
macFocused = byID[6]
arrange()
assert(not Scroll.isAway(6) and Scroll.isAway(1), "laid out before its focus event: scrolled to")
macFocused = nil
c = Scroll.columns(S.trees.ws1)
table.remove(c)
S.trees.ws1 = Scroll.build(c)

-- A window that's closed is forgotten.
focus(1)
c = Scroll.columns(S.trees.ws1)
table.remove(c)
S.trees.ws1 = Scroll.build(c)
arrange()
assert(not Scroll.isAway(5), "gone from the tree, gone from away")

-- Snapping, and a display beyond the edge: straight to the corner.
S.instantLayout = true
screens[2] = screen("B", 1000)
focus(1)
for _, m in ipairs(moves) do
    assert(m.duration == 0 and m.rect.x == 999 and m.rect.y == 799, "parked at once")
end
S.instantLayout = nil

print("Scroll tests passed")
