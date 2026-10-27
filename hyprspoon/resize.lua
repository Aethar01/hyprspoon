-- hyprspoon/resize.lua: Resizing tiles by keyboard, mouse or native window edges.

local M = {}
package.loaded["hyprspoon.resize"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Tree = require("hyprspoon.tree")
local Layout = require("hyprspoon.layout")

-- ---------------------------------------------------------------------------
-- BSP tiling: resizing
-- ---------------------------------------------------------------------------
--
-- Resizing tiled windows moves the split lines bordering them. Each window
-- edge that moved drags the split on that side of the window to match; edges
-- against the screen have no split and snap back. This covers mouse
-- resizing (applied on release) and native edge dragging.

local BSP_EDGE_TOLERANCE = 4

-- Fold a tiled window's new frame back into its tree and retile. Pure moves
-- (size unchanged) just snap back.
local function adoptFrame(win)
    local path, leaf, key = Layout.locate(win)
    if not path or not leaf.rect then return end

    -- Moved to another display: it joins that display's layout.
    local screen = win:screen()
    if screen and screen:getUUID() ~= Tree.keyUUID(key) then
        S.windowInfo[win:id()] = nil
        S.applied[win:id()] = nil
        Layout.tileNow()
        return
    end

    -- A maximized window isn't in its tile: nothing to adopt.
    if leaf.fullRect then return end

    local f = win:frame()
    local r = leaf.rect
    -- An unreadable frame (a busy app) reads as all zeros, not a resize.
    if f.w <= 0 or f.h <= 0 then return end
    local function differs(a, b) return math.abs(a - b) > BSP_EDGE_TOLERANCE end

    if not (differs(f.x, r.x) or differs(f.y, r.y)
            or differs(f.w, r.w) or differs(f.h, r.h)) then
        return
    end

    -- Going into full screen (the green button counts as mouse activity).
    if S.fullscreen[win:id()] or win:isFullScreen() then return end

    -- Our own retiles also fire windowMoved. A window that can't take its
    -- tile's exact size (e.g. an app minimum) would otherwise retile forever,
    -- so only react once to any given frame.
    local seen = string.format("%.0f,%.0f,%.0f,%.0f", f.x, f.y, f.w, f.h)
    if leaf.lastSeenFrame == seen then return end
    leaf.lastSeenFrame = seen
    S.applied[win:id()] = nil

    print(string.format("hyprspoon: adopting frame of %s: %s (tile %.0f,%.0f,%.0f,%.0f)",
        tostring(win:id()), seen, r.x, r.y, r.w, r.h))
    if differs(f.w, r.w) or differs(f.h, r.h) then
        local edges = {
            { edge = "left",   split = "vertical",   branch = "b", now = f.x,       was = r.x },
            { edge = "right",  split = "vertical",   branch = "a", now = f.x + f.w, was = r.x + r.w },
            { edge = "top",    split = "horizontal", branch = "b", now = f.y,       was = r.y },
            { edge = "bottom", split = "horizontal", branch = "a", now = f.y + f.h, was = r.y + r.h },
        }
        for _, e in ipairs(edges) do
            if differs(e.now, e.was) then
                local node = Tree.boundingSplit(path, e.split, e.branch)
                if node then Tree.moveSplit(node, e.edge, e.now) end
            end
        end
    end

    Layout.tileNow(false, Tree.keyUUID(key))
end

-- Keyboard resize of a tiled window by a percentage of its size. On each
-- axis the nearest split bordering the window moves in the key's direction:
-- a left/top tile grows with right/down, a right/bottom tile shrinks with
-- right/down (its left/top edge follows the split). Returns true when the
-- window is tiled (even if it has no split on that axis to move), so the
-- floating fallback doesn't run.
local function resizePercent(win, xPct, yPct)
    local path, leaf, key = Layout.locate(win)
    if not path or not leaf.rect then return false end

    local r = leaf.rect
    local axes = {
        { pct = xPct, split = "vertical",   pos = r.x, size = r.w, before = "left", after = "right" },
        { pct = yPct, split = "horizontal", pos = r.y, size = r.h, before = "top",  after = "bottom" },
    }

    for _, axis in ipairs(axes) do
        if axis.pct ~= 0 then
            local delta = axis.size * axis.pct / 100
            for _, step in ipairs(path) do
                if step.node.split == axis.split and step.node.rect then
                    if step.branch == "a" then
                        Tree.moveSplit(step.node, axis.after, axis.pos + axis.size + delta)
                    else
                        Tree.moveSplit(step.node, axis.before, axis.pos + delta)
                    end
                    break
                end
            end
        end
    end

    Layout.tileNow(false, Tree.keyUUID(key))
    return true
end

-- Mouse resize while tiling: only the dragged window changes during the
-- drag, growing from the edges nearest the cursor that border a split
-- (falling back to the opposite edge at the screen border). The layout
-- follows on release.
local resizeState = nil

local function beginResize(win, point)
    resizeState = nil

    local f = win:frame()
    local path = Layout.locate(win)
    if not path then
        -- Floating: grow from the corner nearest the cursor.
        resizeState = {
            win = win,
            frame = f,
            floating = true,
            xBranch = point.x > f.x + f.w / 2 and "a" or "b",
            yBranch = point.y > f.y + f.h / 2 and "a" or "b",
        }
        return
    end

    local function pickBranch(split, preferAfter)
        local prefer = preferAfter and "a" or "b"
        local other = preferAfter and "b" or "a"
        if Tree.boundingSplit(path, split, prefer) then return prefer end
        if Tree.boundingSplit(path, split, other) then return other end
        return nil
    end

    resizeState = {
        win = win,
        frame = f,
        xBranch = pickBranch("vertical", point.x > f.x + f.w / 2),
        yBranch = pickBranch("horizontal", point.y > f.y + f.h / 2),
    }
end

-- Returns true when the resize is being handled by the tiling layout.
local function resizeDrag(dx, dy)
    local state = resizeState
    if not state then return false end

    local f = hs.geometry.copy(state.frame)

    if state.xBranch == "a" then
        f.w = math.max(S.cfg.minWidth, f.w + dx)
    elseif state.xBranch == "b" then
        local w = math.max(S.cfg.minWidth, f.w - dx)
        f.x = f.x + f.w - w
        f.w = w
    end

    if state.yBranch == "a" then
        f.h = math.max(S.cfg.minHeight, f.h + dy)
    elseif state.yBranch == "b" then
        local h = math.max(S.cfg.minHeight, f.h - dy)
        f.y = f.y + f.h - h
        f.h = h
    end

    state.win:setFrame(f, 0)
    return true
end

-- The edges the current mouse resize moves on each axis ("a": right or
-- bottom, "b": left or top, nil: neither), for hyprspoon.native.frames to follow.
local function resizeBranches()
    if not resizeState then return nil, nil end
    return resizeState.xBranch, resizeState.yBranch
end

local function finishResize()
    local state = resizeState
    resizeState = nil
    if not state or state.floating then return false end

    S.applied[state.win:id()] = nil
    adoptFrame(state.win)
    return true
end

-- Native edge resizes (and title-bar moves) of tiled windows. windowMoved is
-- debounced by hs.window.filter; wait for the mouse to be released too, and
-- ignore our own modifier-drags, which adopt their result on release.
--
-- While a button is held, a single timer re-checks the most recently moved
-- window every 0.1s instead of each event starting its own polling chain.
local moveWaitTimer = nil
local moveWaitWin = nil

local function onWindowMoved(win)
    if not S.tilingEnabled or S.applyingLayout or S.dragState then return end

    -- Echoes of our own layout: nobody is holding the mouse, so it isn't a
    -- native edge drag.
    local held = hs.mouse.getButtons().left
    local now = hs.timer.secondsSinceEpoch()
    if not held and now < S.settleUntil then return end

    -- Resizing a tile moves its splits, so only the user should do it. An app
    -- resizing itself (closing a sibling, animating, enforcing a minimum
    -- size) with no mouse activity must not drag the whole layout with it.
    if not held and now - S.lastMouseTime > 1.5 then
        Util.dlog("ignored move of %s: no recent mouse activity", tostring(win and win:id()))
        return
    end

    if held then
        moveWaitWin = win
        if not moveWaitTimer then
            moveWaitTimer = hs.timer.doAfter(0.1, function()
                moveWaitTimer = nil
                local waiting = moveWaitWin
                moveWaitWin = nil
                if waiting then onWindowMoved(waiting) end
            end)
        end
        return
    end

    adoptFrame(win)
end

-- Drops the pending native-resize check (reload, shutdown).
local function stop()
    if moveWaitTimer then moveWaitTimer:stop() end
    moveWaitTimer, moveWaitWin = nil, nil
end

M.stop = stop
M.resizePercent = resizePercent
M.beginResize = beginResize
M.resizeDrag = resizeDrag
M.resizeBranches = resizeBranches
M.finishResize = finishResize
M.onWindowMoved = onWindowMoved

return M
