-- wm/actions.lua: Hotkey actions: focus, swap, float, split, resize.

local M = {}
package.loaded["wm.actions"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")
local Float = require("wm.float")
local Focus = require("wm.focus")
local Layout = require("wm.layout")
local Resize = require("wm.resize")
local Spaces = require("wm.spaces")

-- ---------------------------------------------------------------------------
-- Actions (bind these to hotkeys)
-- ---------------------------------------------------------------------------

M.warpToWindow = Util.warpToWindow
M.warpToFocusedWindow = Util.warpToFocusedWindow

function M.isTiling()
    return S.tilingEnabled
end

function M.toggleTiling()
    S.tilingEnabled = not S.tilingEnabled
    hs.settings.set(S.SETTINGS_KEY, S.tilingEnabled)

    if S.tilingEnabled then
        -- Trees are kept while tiling is off, so the old layout comes back;
        -- reconciling prunes windows that closed in the meantime.
        S.floatingFrames = {}
        Layout.scheduleRetile(true)
        hs.alert.show("BSP tiling on")
    else
        Layout.restoreFloatingFrames()
        hs.alert.show("BSP tiling off")
    end
end

function M.closeWindow()
    local win = Focus.currentWindow()
    if win then win:close() end
end

-- Native macOS fullscreen (its own Space).
function M.toggleFullScreen()
    local win = Focus.currentWindow()
    if win then win:toggleFullScreen() end
end

-- Floating windows' frames from before they were maximized.
local unmaximizedFrames = {}

-- Fill the screen without creating a fullscreen Space, or go back. A tiled
-- window covers the other tiles until it's toggled back or another tile
-- takes focus (see Layout.toggleMaximized); a float fills the tiling area.
function M.toggleMaximize()
    local win = Focus.currentWindow()
    if not win or Layout.toggleMaximized(win) then return end

    local id, screen = win:id(), win:screen()
    if not id or not screen then return end
    local gap = S.cfg.tiling.outerGap
    local sf = screen:frame()
    local full = { x = sf.x + gap, y = sf.y + gap, w = sf.w - 2 * gap, h = sf.h - 2 * gap }
    local f = win:frame()
    local before = unmaximizedFrames[id]
    if before and math.abs(f.x - full.x) <= 1 and math.abs(f.y - full.y) <= 1
       and math.abs(f.w - full.w) <= 1 and math.abs(f.h - full.h) <= 1 then
        unmaximizedFrames[id] = nil
        Util.setFrame(win, before, S.cfg.tiling.animationDuration)
    else
        unmaximizedFrames[id] = { x = f.x, y = f.y, w = f.w, h = f.h }
        Util.setFrame(win, full, S.cfg.tiling.animationDuration)
    end
end

local focusMethods = {
    left = "focusWindowWest",
    right = "focusWindowEast",
    up = "focusWindowNorth",
    down = "focusWindowSouth",
}

local windowListMethods = {
    left = "windowsToWest",
    right = "windowsToEast",
    up = "windowsToNorth",
    down = "windowsToSouth",
}

-- The nearest candidate strictly in a direction that overlaps the focused
-- frame `f` along the other axis. Hammerspoon's focusWindowWest etc. weigh
-- diagonal neighbours too, so "left" can land on a window above.
-- `candidates` are { win =, id =, frame = }.
local function nearestInDirection(f, selfID, candidates, direction)
    local horizontal = direction == "left" or direction == "right"
    local tol = 4
    local cx, cy = f.x + f.w / 2, f.y + f.h / 2

    local best, bestKey = nil, nil
    for _, entry in ipairs(candidates) do
        if entry.id ~= selfID then
            local o = entry.frame
            local gap, overlap, offset
            if horizontal then
                gap = direction == "left" and (f.x - (o.x + o.w)) or (o.x - (f.x + f.w))
                overlap = math.min(f.y + f.h, o.y + o.h) - math.max(f.y, o.y)
                offset = math.abs((o.y + o.h / 2) - cy)
            else
                gap = direction == "up" and (f.y - (o.y + o.h)) or (o.y - (f.y + f.h))
                overlap = math.min(f.x + f.w, o.x + o.w) - math.max(f.x, o.x)
                offset = math.abs((o.x + o.w / 2) - cx)
            end

            if gap >= -tol and overlap > tol then
                -- Closest first, then the one lined up best with the centre.
                local key = math.floor(math.max(gap, 0) / 8) * 1e6 + offset
                if not bestKey or key < bestKey then best, bestKey = entry.win, key end
            end
        end
    end
    return best
end

-- Every tile in a tree: { win =, id =, frame = }.
local function tiles(node, out)
    out = out or {}
    if not node then return out end
    if Tree.isLeaf(node) then
        local win = Util.winByID[node.windowID]
        if node.rect and win then
            out[#out + 1] = { win = win, id = node.windowID, frame = node.rect }
        end
        return out
    end
    tiles(node.a, out)
    tiles(node.b, out)
    return out
end

-- For a tiled window the neighbour comes from the tree's own tile rects (no
-- accessibility calls). Otherwise (floats, other displays) it falls back to
-- the live window snapshot.
local function neighbourInDirection(win, direction, preferHistory)
    local id = win:id()
    local path, leaf, key = Tree.findByID(S.tilingEnabled and id or nil)
    if leaf and leaf.rect then
        if preferHistory then
            local split = (direction == "left" or direction == "right") and "vertical" or "horizontal"
            local from = (direction == "right" or direction == "down") and "a" or "b"
            -- Walk outward to the first split with a sibling in this
            -- direction. Return to the last-used leaf of that section.
            for _, step in ipairs(path) do
                if step.node.split == split and step.branch == from then
                    local sibling = step.node[from == "a" and "b" or "a"]
                    local candidates = tiles(sibling)
                    local byID = {}
                    for _, entry in ipairs(candidates) do byID[entry.id] = entry.win end
                    for _, fid in ipairs(Util.focusHistory) do
                        if byID[fid] then return byID[fid] end
                    end
                    local closest = nearestInDirection(leaf.rect, id, candidates, direction)
                    if closest then return closest end
                    if candidates[1] then return candidates[1].win end
                end
            end
        end
        local found = nearestInDirection(leaf.rect, id, tiles(S.trees[key]), direction)
        if found then return found end
    end
    -- A tile at the edge of its tree already knows its frame.
    local frame = leaf and leaf.rect or win:frame()
    return nearestInDirection(frame, id, Focus.windowSnapshot(), direction)
end

local function directionalCandidates()
    local windows = {}
    for _, entry in ipairs(Focus.windowSnapshot()) do windows[#windows + 1] = entry.win end
    return windows
end

-- Focus the nearest window in a direction ("left"/"right"/"up"/"down") and
-- warp the cursor to it.
function M.focus(direction)
    local win = Focus.currentWindow()
    if not win then return end

    local target = neighbourInDirection(win, direction, true)
    if target then
        Focus.focus(target)
        Util.warpToWindow(target)
    elseif win[focusMethods[direction]](win, directionalCandidates(), true, false) then
        -- Nothing directly beside it (e.g. another display): Hammerspoon
        -- picked. Focus change can finish one event-loop tick after the call.
        Util.warpToFocusedWindow(0.01)
    end
end

-- Swap the focused window with its neighbour in a direction. Tiled windows
-- swap places in the tree; floating windows swap frames.
function M.swap(direction)
    local win = Focus.currentWindow()
    if not win then return end

    local other = neighbourInDirection(win, direction)
    if not other then
        local candidates = win[windowListMethods[direction]](win, directionalCandidates(), true, false)
        other = candidates and candidates[1]
    end
    if not other then return end

    local _, _, keyA = Layout.locate(win)
    local _, _, keyB = Layout.locate(other)
    if keyA or keyB then
        -- Only swap within one layout; frame swaps would be undone by the
        -- next retile.
        if keyA == keyB then
            Tree.swapIDs(S.trees[keyA], win:id(), other:id())
            -- Apply the swapped positions immediately.
            Layout.tileNow(false, Tree.keyUUID(keyA))
        end
    else
        local a = win:frame()
        local b = other:frame()
        local duration = S.cfg.tiling.animationDuration
        Util.setFrame(other, a, duration)
        Util.setFrame(win, b, duration)
    end

    Focus.focus(win)
end

-- Toggle floating for the focused window (overrides the automatic choice).
-- Floating windows are centred and kept above the tiles.
function M.toggleFloat()
    local win = Focus.currentWindow()
    if not win or not S.tilingEnabled then return end

    local id = win:id()
    Float.shouldFloat(win) -- load any saved decision before overriding it
    S.autoFloat[id] = not S.autoFloat[id]
    Float.rememberFloat(win)

    if S.autoFloat[id] then
        local screen, f = win:screen(), win:frame()
        local sf = screen:frame()
        win:setTopLeft({ x = sf.x + (sf.w - f.w) / 2, y = sf.y + (sf.h - f.h) / 2 })
        win:raise()
    end

    Focus.invalidateWindowCache()
    Layout.tileNow()
end

-- Cycle focus through the floating windows. Works however they're stacked
-- (even fully covered by tiles), since it goes by window rather than by
-- direction or mouse position.
function M.focusFloat()
    if not S.running.windowFilter then return end
    local floats = {}
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        if S.autoFloat[id] and not Spaces.isHidden(id) then floats[#floats + 1] = win end
    end
    if #floats == 0 then return end
    table.sort(floats, function(a, b) return a:id() < b:id() end)

    local current = S.ffmFocusedID
    local target = floats[1]
    for i, win in ipairs(floats) do
        if win:id() == current then
            target = floats[i % #floats + 1]
            break
        end
    end
    Focus.focus(target)
    Util.warpToWindow(target)
end

-- Flip the split containing the focused window between vertical and
-- horizontal. Deepest ancestor first, so it's the window's own sibling split.
function M.toggleSplit()
    local win = Focus.currentWindow()
    local path, _, key = Layout.locate(win)
    local parent = path and path[1] and path[1].node
    if not parent then return end

    parent.split = (parent.split == "vertical") and "horizontal" or "vertical"
    Layout.tileNow(false, Tree.keyUUID(key))
end

-- Resize the focused window by a percentage of its own size, e.g.
-- resize(10, 0) grows width by 10%. Tiled windows move the split bordering
-- them in the key's direction instead (see Resize.resizePercent).
function M.resize(xPct, yPct)
    local win = Focus.currentWindow()
    if not win then return end

    if Resize.resizePercent(win, xPct, yPct) then return end

    local f = win:frame()
    if xPct ~= 0 then
        f.w = math.max(S.cfg.minWidth, f.w + f.w * xPct / 100)
    end
    if yPct ~= 0 then
        f.h = math.max(S.cfg.minHeight, f.h + f.h * yPct / 100)
    end

    win:setFrameInScreenBounds(f, 0)
end

return M
