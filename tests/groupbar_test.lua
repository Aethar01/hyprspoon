-- Plain Lua geometry and canvas lifecycle tests; no live windows.
package.path = "./?.lua;" .. package.path
local noop = function() end
local canvases = {}
hs = {
    settings = { get = noop },
    canvas = { windowLevels = { normal = 0 }, new = function(frame)
        local c = { frame_ = frame }
        function c:frame(f) self.frame_ = f end
        function c:replaceElements(...)
            self.elements = { ... }
            self.draws = (self.draws or 0) + 1
        end
        function c:mouseCallback(fn) self.click = fn end
        function c:delete() self.deleted = true end
        c.level, c.behavior, c.canvasMouseEvents, c.show, c.clickActivating = noop, noop, noop, noop, noop
        canvases[#canvases + 1] = c
        return c
    end },
    drawing = { color = { asRGB = function(c) return { red = 1, green = 1, blue = 1, alpha = 1, from = c } end } },
}
-- Border.bar's calls: the spec drawn above each window, nil once removed.
local drawn, drawCalls = {}, 0
package.loaded["hyprspoon.border"] = {
    bar = function(id, spec) drawn[id] = spec drawCalls = drawCalls + 1 return true end,
    title = function(id, n, text) drawn[id].titles[n] = text titleCalls = (titleCalls or 0) + 1 end,
}
local S = require("hyprspoon.state")
S.cfg = { group = { bar = S.defaults.group.bar }, border = S.defaults.border }
S.tilingEnabled, S.ffmFocusedID = true, 3
S.untiled, S.fullscreen, S.offSpace, S.autoFloat, S.applied = {}, {}, {}, {}, {}
local rect = { x = -100, y = 20, w = 101, h = 60 }
local leaf = { kind = "group", windowID = 3 }
local info = { rect = rect, key = "ws1", shown = 3, members = { { 1 }, { 2, 3 } } }
local hidden, behind, selected, restored = false, false, nil, nil
local wins = {}
for id = 1, 3 do
    wins[id] = { id = function() return id end, title = function() return "Window " .. id end }
end
package.loaded["hyprspoon.util"] = {
    managedWindows = function() return { wins[1], wins[3] } end,
    windowFor = function(id) return wins[id] end,
    setFrame = function(_, frame, duration) restored = frame assert(duration == 0) end,
}
package.loaded["hyprspoon.tree"] = {
    setOf = function() return leaf end,
    behindMaximized = function() return behind end,
    leaves = function() return { leaf } end,
}
package.loaded["hyprspoon.spaces"] = { isHidden = function() return hidden end }
package.loaded["hyprspoon.group"] = {
    info = function() return info end,
    selectMember = function(id) selected = id end,
}
S.trees = { ws1 = leaf }
local Bar = require("hyprspoon.groupbar")
local cells = Bar.segments(info, S.cfg.group.bar, { [1] = "", [3] = "Selected tab" })
assert(#cells == 2 and cells[1].label == "Untitled" and cells[2].label == "Selected tab")
assert(cells[1].x == 0 and cells[1].w == 50.5 and cells[2].x == 50.5)
assert(cells[1].w + cells[2].w == rect.w and cells[2].id == 3)
assert(not cells[1].shown and cells[2].shown)
assert(Bar.memberAt(cells, 0, 0) == 1 and Bar.memberAt(cells, 50.5, 23) == 3)
assert(Bar.memberAt(cells, -1, 0) == nil and Bar.memberAt(cells, 101, 0) == nil)
assert(Bar.memberAt(cells, 20, 24) == nil and Bar.memberAt(cells, 0, -1) == nil)
assert(Bar.height({ h = 10 }, { height = 24 }) == 9)
assert(Bar.height(rect, { height = -1 }) == 0)
assert(#Bar.segments({ rect = rect, members = {} }, { height = 24 }, {}) == 0)
Bar.start()
Bar.prepare(leaf, rect)
assert(leaf.groupInset == 24 and #canvases == 1)
local canvas = canvases[1]
assert(canvas.frame_.x == -100 and #canvas.elements == 2)
assert(drawn[3].titles[2] == "Window 3" and drawn[3].shown == 2 and drawn[3].above == 24)
canvas.click(canvas, "mouseUp", nil, 80, 10)
assert(selected == 3)
Bar.update()
assert(#canvases == 1 and canvas.draws == 1 and drawCalls == 1, "unchanged refresh keeps the bar")
rect.w = 200
Bar.update()
assert(canvas.frame_.w == 200 and canvas.elements[2].frame.x == 100)
info.shown, leaf.windowID = 1, 1
info.selected = { 1, 3 }
Bar.update()
assert(drawn[3] == nil and drawn[1].shown == 1, "the bar moves to the window on show")
assert(drawn[1].titles[2] == "Window 3", "hidden units use their remembered tab's title")
canvas.click(canvas, "mouseUp", nil, 180, 10)
assert(selected == 3, "bar selects the remembered native tab instead of members[1]")
local function disappears(set, reset)
    local last = canvases[#canvases]
    set()
    Bar.update()
    assert(last.deleted and drawn[1] == nil)
    local count = #canvases
    reset()
    Bar.update()
    assert(#canvases == count + 1)
end
disappears(function() hidden = true end, function() hidden = false end)
disappears(function() S.fullscreen[1] = true end, function() S.fullscreen[1] = nil end)
disappears(function() S.offSpace[1] = true end, function() S.offSpace[1] = nil end)
disappears(function() behind = true end, function() behind = false end)
disappears(function() S.autoFloat[1] = true end, function() S.autoFloat[1] = nil end)
disappears(function() S.untiled.ws1 = true end, function() S.untiled.ws1 = nil end)
disappears(function() S.tilingEnabled = false end, function() S.tilingEnabled = true end)
disappears(function() info.key = nil end, function() info.key = "ws1" end)
disappears(function() S.cfg.group.bar = false end, function() S.cfg.group.bar = S.defaults.group.bar end)
-- A group moved in the tree comes back as a new leaf: its bar stays.
local moved = { kind = "group", windowID = 1 }
local before = leaf
leaf = moved
Bar.update()
assert(drawn[1] and canvases[#canvases - 1].deleted, "moving a group keeps its bar")
leaf = before
Bar.update()
assert(drawn[1], "and moving it back too")
-- Showing another member: the bar is on the new window before the swap,
-- and the old one's goes on the next update.
Bar.handOver(1, 3)
assert(drawn[3] and drawn[3].shown == 2 and drawn[1], "the new window has the bar before the swap")
info.shown, leaf.windowID = 3, 3
Bar.update()
assert(drawn[3] and drawn[1] == nil, "the old window's bar goes once the new one has it")
info.shown, leaf.windowID = 1, 1
Bar.update()
assert(drawn[1] and drawn[3] == nil)
-- Membership and title changes redraw without keeping stale click targets.
info.members = { { 1 } }
Bar.update()
local last = canvases[#canvases]
assert(#last.elements == 1)
local managed = package.loaded["hyprspoon.util"].managedWindows
package.loaded["hyprspoon.util"].managedWindows = function()
    error("title notifications must not enumerate other groups")
end
local draws, canvasDraws = drawCalls, last.draws
Bar.titleChanged(wins[1])
assert(drawCalls == draws and not titleCalls, "unchanged labels do not redraw")
wins[1].title = function() return "Changed title" end
Bar.titleChanged(wins[1])
assert(drawCalls == draws and titleCalls == 1, "a title change only retitles")
assert(last.draws == canvasDraws, "a title change leaves the click canvas alone")
package.loaded["hyprspoon.util"].managedWindows = managed
assert(drawn[1].titles[1] == "Changed title")
-- A title seen by a full update is only retitled too.
wins[1].title = function() return "Again" end
Bar.update()
assert(drawCalls == draws and titleCalls == 2 and drawn[1].titles[1] == "Again")
last.click(last, "mouseUp", nil, 180, 10)
assert(selected == 1)
-- Gaps between segments, for reordering and for drops into the group.
info.members, info.selected = { { 1 }, { 2, 3 } }, { 1, 3 }
Bar.update()
local slot, mark = Bar.slotAt(1, { x = -90, y = 25 })
assert(slot == 1 and mark.x == -103 and mark.y == 20 and mark.w == 6)
slot, mark = Bar.slotAt(1, { x = -40, y = 25 })
assert(slot == 2 and mark.x == -3)
assert(Bar.slotAt(1, { x = 95, y = 25 }) == 3, "past the last segment's middle: after it")
assert(Bar.slotAt(1, { x = 0, y = 60 }) == nil and Bar.slotAt(1, { x = 101, y = 25 }) == nil)
assert(Bar.slotAt(1, { x = 0, y = 10 }, 12) == 2, "slack reaches above the bar")
-- Dragging a segment: along the bar it moves; off it, Drop takes over.
local taps, previews, drops, moves = {}, {}, {}, {}
hs.eventtap = { event = { types = { leftMouseDragged = 1, leftMouseUp = 2 } },
    new = function(_, fn)
        local tap = { fn = fn, stop = function(self) self.stopped = true end }
        function tap:start() return self end
        taps[#taps + 1] = tap
        return tap
    end }
hs.timer = { doAfter = function(_, fn) fn() end }
local pointer = { x = 50, y = 25 }
hs.mouse = { absolutePosition = function() return pointer end }
package.loaded["hyprspoon.drop"] = {
    preview = function(r) previews[#previews + 1] = r or false end,
    cancelDrag = function() drops[#drops + 1] = "cancel" end,
    beginDrag = function(w, member) drops[#drops + 1] = { "begin", w:id(), member } end,
    updateDrag = function() drops[#drops + 1] = "update" end,
    finishDrag = function(w) drops[#drops + 1] = { "finish", w:id() } end,
}
package.loaded["hyprspoon.group"].moveTo = function(id, s) moves[#moves + 1] = { id, s } end
local function event(kind, x, y)
    return { getType = function() return kind end, location = function() return { x = x, y = y } end }
end
local refocused = {}
package.loaded["hyprspoon.focus"] = { focus = function(w) refocused[#refocused + 1] = w:id() end }
local bar = canvases[#canvases]
selected = nil
bar.click(bar, "mouseDown", nil, 150, 5)
taps[#taps].fn(event(1, 52, 25))
assert(#previews == 0, "a few points' travel is still a click")
taps[#taps].fn(event(1, 0, 25))
assert(#previews == 1 and previews[1] == false, "the gaps beside it leave it where it is")
taps[#taps].fn(event(1, -90, 25))
assert(previews[2] and previews[2].x == -103, "the gap is marked")
taps[#taps].fn(event(2, -90, 25))
bar.click(bar, "mouseUp", nil, 10, 5)
assert(moves[1][1] == 3 and moves[1][2] == 1 and previews[3] == false)
assert(selected == nil and taps[#taps].stopped, "a drag doesn't select, and its tap stops")
-- Once by the fallback (timers run at once here), once on the canvas's mouse up.
assert(#refocused == 2 and refocused[1] == 1 and refocused[2] == 1, "the group keeps focus")
pointer = { x = -90, y = 25 }
bar.click(bar, "mouseDown", nil, 10, 5)
taps[#taps].fn(event(1, -90, 300))
assert(drops[1][1] == "begin" and drops[1][2] == 1 and drops[1][3] == true and drops[2] == "update")
taps[#taps].fn(event(1, -90, 25))
assert(drops[3] == "cancel", "back over the bar, the drop is called off")
taps[#taps].fn(event(1, -90, 300))
taps[#taps].fn(event(2, -90, 300))
assert(drops[6][1] == "finish" and drops[6][2] == 1 and #moves == 1)
assert(refocused[3] == S.ffmFocusedID, "after a drop, the window it focused")
-- A plain click still selects on mouse up.
bar.click(bar, "mouseDown", nil, 150, 5)
taps[#taps].fn(event(2, -90, 25))
bar.click(bar, "mouseUp", nil, 150, 5)
assert(selected == 3)
-- Separate reasons cannot accidentally bring a strip back during the overview.
Bar.suspend("slide", true)
local count = #canvases
Bar.suspend("overview", true)
Bar.suspend("slide", false)
assert(#canvases == count)
Bar.suspend("overview", false)
assert(#canvases == count + 1)
-- Closing/dissolving the last group removes the canvas.
local original = info
info = nil
Bar.update()
assert(canvases[#canvases].deleted)
info = original
Bar.update()
leaf.rect, leaf.groupInset = rect, 24
Bar.stop()
assert(canvases[#canvases].deleted and drawn[1] == nil and leaf.groupInset == nil)
assert(restored == rect, "stop restores the window synchronously without a timer")
count = #canvases
Bar.update()
assert(#canvases == count)
print("Group bar tests passed")
