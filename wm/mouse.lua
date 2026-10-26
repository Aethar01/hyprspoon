-- wm/mouse.lua: Modifier + drag anywhere on a window to move or resize it.

local M = {}
package.loaded["wm.mouse"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Focus = require("wm.focus")
local Resize = require("wm.resize")
local Drop = require("wm.drop")
local Border = require("wm.border")

-- ---------------------------------------------------------------------------
-- Mouse: modifier + drag anywhere on a window
-- ---------------------------------------------------------------------------

local mouseTypes = hs.eventtap.event.types

local function modsMatch(flags, mods)
    return mods and flags:containExactly(mods)
end

-- Drag events reach Lua only during one of our drags that wm.native.frames
-- isn't following (it isn't built, or its tap couldn't be made).
local dragTap = nil
local onMouseEvent

local function followInLua(on)
    if on and not dragTap then
        dragTap = hs.eventtap.new({ mouseTypes.leftMouseDragged, mouseTypes.rightMouseDragged },
            function(event) return onMouseEvent(event) end):start()
    elseif not on and dragTap then
        dragTap:stop()
        dragTap = nil
    end
end

local function beginMouseDrag(mode, point)
    local win = Focus.windowUnderPoint(point, true)
    if not win then return false end

    Util.focusWindow(win)
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

    -- wm.native.frames follows the pointer from here, off the main thread;
    -- the drags below are then never seen here.
    local frames = Util.native("frames")
    if frames then
        local f = S.dragState.frame
        local xBranch, yBranch = Resize.resizeBranches()
        S.dragState.native = frames.dragBegin({
            pid = win:pid(),
            wid = win:id(),
            mode = mode,
            frame = { x = f.x, y = f.y, w = f.w, h = f.h },
            point = { x = point.x, y = point.y },
            xBranch = xBranch,
            yBranch = yBranch,
            minW = S.cfg.minWidth,
            minH = S.cfg.minHeight,
            onMove = mode == "move" and function(x, y) Drop.updateDrag({ x = x, y = y }) end or nil,
            -- The ring keeps up with the pointer; the app fills it in as
            -- fast as it can.
            preview = Border.previewer(),
            interval = S.dragState.interval,
        })
        -- The window's own reports of each frame would only keep the main
        -- thread busy mid-drag; it's looked at once when the drag ends.
        if S.dragState.native and S.running.events then S.running.events.mute(win:id()) end
    end
    if not S.dragState.native then followInLua(true) end
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

function onMouseEvent(event)
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
        if S.dragState.native then return true end
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
        if S.dragState.native then
            -- Waits for the app to take the last frame.
            Util.native("frames").dragEnd(point.x, point.y)
            if S.running.events then S.running.events.mute(nil) end
        else
            if S.dragState.trailing then S.dragState.trailing:stop() end
            applyDrag(point)  -- the pacing may have held back the last movement
        end
        S.dragState = nil
        followInLua(false)
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

-- Stops following a drag in Lua (reload, shutdown).
function M.stop()
    followInLua(false)
end

M.mouseTypes = mouseTypes
M.onMouseEvent = onMouseEvent

return M
