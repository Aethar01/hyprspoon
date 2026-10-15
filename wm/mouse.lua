-- wm/mouse.lua: Modifier + drag anywhere on a window to move or resize it.

local M = {}
package.loaded["wm.mouse"] = M

local S = require("wm.state")
local Focus = require("wm.focus")
local Resize = require("wm.resize")
local Drop = require("wm.drop")

-- ---------------------------------------------------------------------------
-- Mouse: modifier + drag anywhere on a window
-- ---------------------------------------------------------------------------

local mouseTypes = hs.eventtap.event.types

local function modsMatch(flags, mods)
    return mods and flags:containExactly(mods)
end

local function beginMouseDrag(mode, point)
    local win = Focus.windowUnderPoint(point, true)
    if not win then return false end

    win:focus()
    -- Resizes are paced to the display's refresh rate (see onMouseEvent).
    local screen = win:screen()
    local display = screen and screen:currentMode()
    local hz = display and display.freq or 0
    S.dragState = {
        mode = mode,
        win = win,
        mouse = point,
        frame = win:frame(),
        interval = 1 / (hz > 0 and hz or 60),
    }

    if mode == "move" then
        Drop.beginDrag(win)
    else
        Resize.beginResize(win, point)
    end
    return true
end

local function applyDrag(point)
    local dx = point.x - S.dragState.mouse.x
    local dy = point.y - S.dragState.mouse.y

    if S.dragState.mode == "resize" and Resize.resizeDrag(dx, dy) then
        return
    end

    local f = hs.geometry.copy(S.dragState.frame)

    if S.dragState.mode == "move" then
        -- Size is unchanged, so a single position call is enough.
        S.dragState.win:setTopLeft({ x = f.x + dx, y = f.y + dy })
        Drop.updateDrag(point)
    else
        f.w = math.max(S.cfg.minWidth, f.w + dx)
        f.h = math.max(S.cfg.minHeight, f.h + dy)
        S.dragState.win:setFrame(f, 0)
    end
end

local function onMouseEvent(event)
    local eventType = event:getType()
    S.lastMouseTime = hs.timer.secondsSinceEpoch()

    -- A click is the user choosing focus; drop any request of ours.
    S.intent = nil

    -- Drags and releases only matter during one of our own drags; skip the
    -- location and flag lookups for everything else.
    if not S.dragState and eventType ~= mouseTypes.leftMouseDown
       and eventType ~= mouseTypes.rightMouseDown then
        return false
    end

    local point = event:location()
    local flags = event:getFlags()

    if eventType == mouseTypes.leftMouseDown
       and modsMatch(flags, S.cfg.mouse.move) then
        return beginMouseDrag("move", point)
    elseif (eventType == mouseTypes.leftMouseDown
            and modsMatch(flags, S.cfg.mouse.resize))
        or (eventType == mouseTypes.rightMouseDown
            and modsMatch(flags, S.cfg.mouse.rightResize)) then
        return beginMouseDrag("resize", point)
    elseif S.dragState
       and (eventType == mouseTypes.leftMouseDragged
            or eventType == mouseTypes.rightMouseDragged) then
        -- A move is one cheap position call, so it follows every event.
        if S.dragState.mode == "move" then
            applyDrag(point)
            return true
        end
        -- A resize makes the app lay itself out again: at most one per
        -- display frame, with a trailing update so a pause mid-drag never
        -- leaves the window a step behind the pointer.
        S.dragState.point = point
        local now = hs.timer.secondsSinceEpoch()
        local wait = S.dragState.interval - (now - (S.dragState.lastApply or 0))
        if wait > 0 then
            if not S.dragState.trailing then
                S.dragState.trailing = hs.timer.doAfter(wait, function()
                    if not S.dragState then return end
                    S.dragState.trailing = nil
                    S.dragState.lastApply = hs.timer.secondsSinceEpoch()
                    applyDrag(S.dragState.point)
                end)
            end
            return true
        end
        S.dragState.lastApply = now
        applyDrag(point)
        return true
    elseif S.dragState
       and (eventType == mouseTypes.leftMouseUp
            or eventType == mouseTypes.rightMouseUp) then
        local win = S.dragState.win
        local mode = S.dragState.mode
        if S.dragState.trailing then S.dragState.trailing:stop() end
        applyDrag(point)  -- the pacing may have held back the last movement
        S.dragState = nil
        if mode == "move" and win and Drop.finishDrag(win, point) then
            return true
        end
        if mode == "resize" and Resize.finishResize() then
            return true
        end
        if win then
            win:setFrameInScreenBounds(win:frame(), 0)
        end
        return true
    end

    return false
end

M.mouseTypes = mouseTypes
M.onMouseEvent = onMouseEvent

return M
