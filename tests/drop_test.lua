-- Run with: lua tests/drop_test.lua
-- Where a dragged tile lands: beside a tile, or into a group's.
package.path = "./?.lua;" .. package.path

hs = { geometry = { copy = function(r) return { x = r.x, y = r.y, w = r.w, h = r.h } end } }
package.loaded["hyprspoon.util"] = {
    pointInFrame = function(p, f) return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h end,
}
package.loaded["hyprspoon.state"] = {}
package.loaded["hyprspoon.discover"] = {}
package.loaded["hyprspoon.layout"] = {}
-- Tree.nearestSide as in hyprspoon/tree.lua.
package.loaded["hyprspoon.tree"] = { nearestSide = function(f, p)
    local rx, ry = (p.x - f.x) / f.w, (p.y - f.y) / f.h
    local side, dist = "left", rx
    if 1 - rx < dist then side, dist = "right", 1 - rx end
    if ry < dist then side, dist = "top", ry end
    if 1 - ry < dist then side = "bottom" end
    return side
end }
local Drop = require("hyprspoon.drop")

local tile = { frame = { x = 0, y = 0, w = 400, h = 400 } }
local group = { frame = { x = 400, y = 0, w = 400, h = 400 }, bar = 24 }
local targets = { tile, group }
local function at(x, y)
    local target, side, rect = Drop.dropTarget(targets, { x = x, y = y })
    return target, side, rect
end

-- A plain tile always splits, even dropped in its middle.
local target, side, rect = at(200, 200)
assert(target == tile and side ~= "group" and rect.w == 200)
-- A group's middle and its bar join it, previewing the whole tile.
target, side, rect = at(600, 200)
assert(target == group and side == "group" and rect.w == 400 and rect.h == 400)
assert(select(2, at(420, 10)) == "group", "the bar joins, even at its end")
-- Near a group's edges, the drop still splits beside it.
assert(select(2, at(420, 200)) == "left")
assert(select(2, at(600, 390)) == "bottom")
-- Without a bar (group.bar off), only the middle joins.
group.bar = 0
assert(select(2, at(600, 10)) == "top")
assert(select(2, at(600, 200)) == "group")
print("Drop tests passed")
