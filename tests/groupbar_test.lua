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
        c.level, c.behavior, c.canvasMouseEvents, c.show = noop, noop, noop, noop
        canvases[#canvases + 1] = c
        return c
    end },
    drawing = { getTextDrawingSize = function() return { h = 14 } end },
    styledtext = { defaultFonts = { menuBar = { name = "System" } } },
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
local cells = Bar.segments(info, S.cfg.group.bar, { [1] = "", [3] = "Selected tab" }, 3)
assert(#cells == 2 and cells[1].label == "Untitled" and cells[2].label == "Selected tab")
assert(cells[1].x == 0 and cells[1].w == 50.5 and cells[2].x == 50.5)
assert(cells[1].w + cells[2].w == rect.w and cells[2].id == 3)
assert(not cells[1].active and cells[2].active)
assert(Bar.memberAt(cells, 0, 0) == 1 and Bar.memberAt(cells, 50.5, 23) == 3)
assert(Bar.memberAt(cells, -1, 0) == nil and Bar.memberAt(cells, 101, 0) == nil)
assert(Bar.memberAt(cells, 20, 24) == nil and Bar.memberAt(cells, 0, -1) == nil)
assert(Bar.height({ h = 10 }, { height = 24 }) == 9)
assert(Bar.height(rect, { height = -1 }) == 0)
assert(#Bar.segments({ rect = rect, members = {} }, { height = 24 }, {}, nil) == 0)
Bar.start()
Bar.prepare(leaf, rect)
assert(leaf.groupInset == 24 and #canvases == 1)
local canvas = canvases[1]
assert(canvas.frame_.x == -100 and #canvas.elements == 4)
assert(canvas.elements[4].text == "Window 3")
canvas.click(canvas, "mouseDown", nil, 80, 10)
assert(selected == 3)
Bar.update()
assert(#canvases == 1 and canvas.draws == 1, "unchanged refresh keeps the canvas contents")
rect.w = 200
Bar.update()
assert(canvas.frame_.w == 200 and canvas.elements[3].frame.x == 100)
info.shown, leaf.windowID = 1, 1
Bar.focus(1)
assert(canvas.elements[1].fillColor.hex == S.cfg.border.active)
Bar.unfocused(wins[1])
assert(canvas.elements[1].fillColor == S.cfg.border.inactive)
local function disappears(set, reset)
    local last = canvases[#canvases]
    set()
    Bar.update()
    assert(last.deleted)
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
-- Membership and title changes redraw without keeping stale click targets.
info.members = { { 1 } }
Bar.update()
local last = canvases[#canvases]
assert(#last.elements == 2)
wins[1].title = function() return "Changed title" end
Bar.update()
assert(last.elements[2].text == "Changed title")
last.click(last, "mouseDown", nil, 180, 10)
assert(selected == 1)
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
assert(canvases[#canvases].deleted and leaf.groupInset == nil)
assert(restored == rect, "stop restores the window synchronously without a timer")
count = #canvases
Bar.update()
assert(#canvases == count)
print("Group bar tests passed")
