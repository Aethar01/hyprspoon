-- hyprspoon/drop.lua: Dragging a tile onto another to move it in the layout.

local M = {}
package.loaded["hyprspoon.drop"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Tree = require("hyprspoon.tree")
local Discover = require("hyprspoon.discover")
local Layout = require("hyprspoon.layout")

-- ---------------------------------------------------------------------------
-- BSP tiling: drag and drop
-- ---------------------------------------------------------------------------
--
-- Drop a tiled window onto another tile to split that tile and insert it on
-- the side nearest the cursor, like Hyprland's dwindle layout. A highlight
-- previews where it will land. Dropping on a group's bar, or the middle of
-- its tile, joins the group instead, like Hyprland's drag_into_group; near
-- its edges it splits as before. Dropping on empty space on another display
-- moves it into that display's layout; anywhere else snaps it back.

local dropState = nil
local dropPreview = nil

local function screenAt(point)
    for _, screen in ipairs(hs.screen.allScreens()) do
        if Util.pointInFrame(point, screen:fullFrame()) then return screen end
    end
    return nil
end

-- The half of tile `f` a window put on its `side` would take.
local function sideRect(f, side)
    local r = hs.geometry.copy(f)
    if side == "left" or side == "right" then
        r.w = f.w / 2
    else
        r.h = f.h / 2
    end
    if side == "right" then r.x = f.x + f.w / 2 end
    if side == "bottom" then r.y = f.y + f.h / 2 end
    return r
end

-- A highlight over `rect` showing where a window will land.
local function highlight(rect)
    local c = S.cfg.tiling.dropColor
    local canvas = hs.canvas.new(rect)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas[1] = {
        type = "rectangle",
        action = "strokeAndFill",
        fillColor = { red = c.red, green = c.green, blue = c.blue, alpha = 0.25 },
        strokeColor = { red = c.red, green = c.green, blue = c.blue, alpha = 0.9 },
        strokeWidth = 3,
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
    }
    return canvas
end

-- Whether `point` over a group's tile `target` joins the group: on its bar
-- (the top `bar` points of the tile), or in the middle half of the tile
-- both ways. Nearer the edges, the drop splits beside the group.
local function joinsGroup(target, point)
    if not target.bar then return false end
    local f = target.frame
    if point.y < f.y + target.bar then return true end
    local rx = (point.x - f.x) / f.w
    local ry = (point.y - f.y) / f.h
    return rx >= 0.25 and rx <= 0.75 and ry >= 0.25 and ry <= 0.75
end

-- The tile under the cursor, the side nearest the cursor ("group" to join
-- its group), and the part of the tile the dropped window would take. Over
-- a group's bar, the gap it would join at (see Group.moveTo), marked there.
local function dropTarget(targets, point)
    local Groupbar = package.loaded["hyprspoon.groupbar"]
    for _, target in ipairs(targets) do
        if target.bar and Groupbar and Groupbar.slotAt then
            local slot, marker = Groupbar.slotAt(target.win:id(), point)
            if slot then return target, "group", marker, slot end
        end
        local f = target.frame
        if Util.pointInFrame(point, f) then
            if joinsGroup(target, point) then return target, "group", f end
            local side = Tree.nearestSide(f, point)
            return target, side, sideRect(f, side)
        end
    end
    return nil
end

-- Starts a drag of tiled window `win`. With `member`, it's a group member
-- dragged off its group's bar (hyprspoon/groupbar.lua): only it leaves, and
-- its own group's tile is a place to split beside like any other.
local function beginDrag(win, member)
    dropState = nil

    local _, _, key = Layout.locate(win)
    if not key then return end

    -- Tiles don't move during a drag, so snapshot their frames once.
    local targets = {}
    local own = member and Tree.setOf(win:id()) or nil
    local byScreen = Discover.windowsByScreen()
    for _, s in ipairs(hs.screen.allScreens()) do
        local sKey = Tree.keyForScreen(s)
        for _, w in ipairs(not S.untiled[sKey] and byScreen[s:getUUID()] or {}) do
            local set = Tree.setOf(w:id())
            local frame = Tree.rectFor(w:id()) or w:frame()
            if own and set == own then
                table.insert(targets, { win = w, frame = frame, key = sKey, own = true })
            elseif w:id() ~= win:id() then
                -- A group's shown window stands for the group; `bar` is the
                -- height of its bar (0 without one), and marks it a group.
                local bar = set and set.kind == "group" and (set.groupInset or 0) or nil
                table.insert(targets, { win = w, frame = frame, key = sKey, bar = bar })
            end
        end
    end

    dropState = { key = key, targets = targets, member = member }
end

local dropShown = false
local dropRect = nil

-- Shows the highlight over `rect`, or hides it for nil.
local function preview(rect)
    if not rect then
        if dropPreview and dropShown then dropPreview:hide() end
        dropShown = false
        dropRect = nil
        return
    end

    -- Drag events arrive at 60Hz; only touch the canvas when the target changes.
    if dropShown and dropRect
       and dropRect.x == rect.x and dropRect.y == rect.y
       and dropRect.w == rect.w and dropRect.h == rect.h then
        return
    end
    dropRect = rect

    if not dropPreview then
        dropPreview = highlight(rect)
    else
        dropPreview:frame(rect)
    end
    dropPreview:show()
    dropShown = true
end

local function updateDrag(point)
    if not dropState then return end
    local _, _, rect = dropTarget(dropState.targets, point)
    preview(rect)
end

-- Forgets a drag without dropping (a bar drag back over its own bar).
local function cancelDrag()
    preview(nil)
    dropState = nil
end

-- Returns true when the drop was handled by the tiling layout.
local function finishDrag(win, point)
    preview(nil)

    local state = dropState
    dropState = nil
    if not state or not S.tilingEnabled then return false end

    local id = win:id()
    local target, side, _, slot = dropTarget(state.targets, point)
    -- The tile may have closed mid-drag.
    if target and not Tree.treeContains(S.trees[target.key], target.win:id()) then
        target = nil
    end
    S.keyIndex = {}
    S.applied = {}

    -- These lay out, show and focus it themselves; if a join can't happen,
    -- the retile below snaps it back.
    local Group = require("hyprspoon.group")
    if target and side == "group" then
        if Group.join(win, target.win, slot) then return true end
    elseif state.member and target then
        if Group.split(win, target.win, side) then return true end
        -- It's its group's only member: beside its own tile nothing changes;
        -- beside another, the whole tile moves, as below.
        if target.own then return true end
    end

    if target and side ~= "group" then
        S.trees[state.key] = Tree.removeID(S.trees[state.key], id)
        S.trees[target.key] = select(1,
            Tree.insertBeside(S.trees[target.key], target.win:id(), id, side))
        -- Park it on the target's display so the retile keeps it there.
        win:setFrame(target.frame, 0)
    elseif not target and not state.member then
        local dropScreen = screenAt(point)
        if dropScreen and Tree.keyForScreen(dropScreen) ~= state.key then
            S.trees[state.key] = Tree.removeID(S.trees[state.key], id)
            win:setFrame(dropScreen:frame(), 0)
        end
    end

    Layout.tileNow()
    return true
end

M.sideRect = sideRect
M.dropTarget = dropTarget
M.highlight = highlight
M.preview = preview
M.beginDrag = beginDrag
M.updateDrag = updateDrag
M.cancelDrag = cancelDrag
M.finishDrag = finishDrag

return M
