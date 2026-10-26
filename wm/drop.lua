-- wm/drop.lua: Dragging a tile onto another to move it in the layout.

local M = {}
package.loaded["wm.drop"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")
local Discover = require("wm.discover")
local Layout = require("wm.layout")

-- ---------------------------------------------------------------------------
-- BSP tiling: drag and drop
-- ---------------------------------------------------------------------------
--
-- Drop a tiled window onto another tile to split that tile and insert it on
-- the side nearest the cursor, like Hyprland's dwindle layout. A highlight
-- previews where it will land. Dropping on empty space on another display
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

-- The tile under the cursor, the side nearest the cursor, and the half of
-- the tile the dropped window would take.
local function dropTarget(targets, point)
    for _, target in ipairs(targets) do
        local f = target.frame
        if Util.pointInFrame(point, f) then
            local side = Tree.nearestSide(f, point)
            return target, side, sideRect(f, side)
        end
    end
    return nil
end

local function beginDrag(win)
    dropState = nil

    local _, _, key = Layout.locate(win)
    if not key then return end

    -- Tiles don't move during a drag, so snapshot their frames once.
    local targets = {}
    local byScreen = Discover.windowsByScreen()
    for _, s in ipairs(hs.screen.allScreens()) do
        local sKey = Tree.keyForScreen(s)
        for _, w in ipairs(not S.untiled[sKey] and byScreen[s:getUUID()] or {}) do
            if w:id() ~= win:id() then
                table.insert(targets, { win = w, frame = Tree.rectFor(w:id()) or w:frame(), key = sKey })
            end
        end
    end

    dropState = { key = key, targets = targets }
end

local dropShown = false
local dropRect = nil

local function hideDropPreview()
    if dropPreview and dropShown then dropPreview:hide() end
    dropShown = false
    dropRect = nil
end

local function updateDrag(point)
    if not dropState then return end

    local _, _, rect = dropTarget(dropState.targets, point)
    if not rect then
        hideDropPreview()
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

-- Returns true when the drop was handled by the tiling layout.
local function finishDrag(win, point)
    hideDropPreview()

    local state = dropState
    dropState = nil
    if not state or not S.tilingEnabled then return false end

    local id = win:id()
    local target, side = dropTarget(state.targets, point)
    -- The tile may have closed mid-drag.
    if target and not Tree.treeContains(S.trees[target.key], target.win:id()) then
        target = nil
    end
    S.keyIndex = {}
    S.applied = {}

    if target then
        S.trees[state.key] = Tree.removeID(S.trees[state.key], id)
        S.trees[target.key] = select(1,
            Tree.insertBeside(S.trees[target.key], target.win:id(), id, side))
        -- Park it on the target's display so the retile keeps it there.
        win:setFrame(target.frame, 0)
    else
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
M.highlight = highlight
M.beginDrag = beginDrag
M.updateDrag = updateDrag
M.finishDrag = finishDrag

return M
