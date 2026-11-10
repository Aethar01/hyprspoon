-- hyprspoon/mouse.lua: Modifier + drag anywhere on a window to move or resize it.

local M = {}
package.loaded["hyprspoon.mouse"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Focus = require("hyprspoon.focus")
local Resize = require("hyprspoon.resize")
local Drop = require("hyprspoon.drop")
local Border = require("hyprspoon.border")
local Discover = require("hyprspoon.discover")
local Spaces = require("hyprspoon.spaces")
local Slide = require("hyprspoon.slide")

-- ---------------------------------------------------------------------------
-- Mouse: modifier + drag anywhere on a window
-- ---------------------------------------------------------------------------

local mouseTypes = hs.eventtap.event.types

local function modsMatch(flags, mods)
    return mods and flags:containExactly(mods)
end

-- Drag events reach Lua only during one of our drags that hyprspoon.native.frames
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

    -- hyprspoon.native.frames follows the pointer from here, off the main thread;
    -- the drags below are then never seen here.
    -- A picture still on its way back from the last drop: its window is
    -- sent home by this drag's begin.
    Slide.cancelHome()
    local frames = Util.native("frames")
    -- Not Hammerspoon's own windows: see Util.setFrame.
    if frames and win:pid() ~= (hs.processInfo and hs.processInfo.processID) then
        local f = S.dragState.frame
        local xBranch, yBranch = Resize.resizeBranches()
        -- mouse.dragEffect: a move drags a shrunk, see-through picture of
        -- the window once it's up, the window parked where a window on
        -- another workspace waits.
        local lift, liftScale, park = nil, nil, nil
        if mode == "move" then
            lift, liftScale = Slide.lifter()
            local uuid = lift and screen and screen:getUUID()
            park = uuid and Spaces.parkPoint(uuid, f) or nil
            if not park then lift = nil end
        end
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
            lift = lift,
            liftScale = liftScale,
            park = park and { x = park.x, y = park.y } or nil,
        })
        S.dragState.lifted = S.dragState.native and lift ~= nil or nil
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
        local lifted = S.dragState.lifted
        local home = nil
        if S.dragState.native then
            -- Waits for the app to take the last frame (a window parked for
            -- its picture is given it too). A drop that changes nothing
            -- leaves it parked instead, while its picture goes back.
            local stays = lifted and mode == "move" and win ~= nil and Drop.wouldStay(point)
            home = select(2, Util.native("frames").dragEnd(point.x, point.y, stays))
            if S.running.events then S.running.events.mute(nil) end
        else
            if S.dragState.trailing then S.dragState.trailing:stop() end
            applyDrag(point)  -- the pacing may have held back the last movement
        end
        S.dragState = nil
        followInLua(false)
        if home then
            -- The picture glides back to the tile and grows back to its
            -- size; only then does the window come back under it, and the
            -- picture fades. Nothing flashes where it was dropped. The drop
            -- (a retile that leaves it be) waits for it too.
            Drop.preview(nil)
            Slide.home(home, function()
                local frames = Util.native("frames")
                if frames and frames.dragUnpark then frames.dragUnpark() end
                S.windowInfo[win:id()], S.applied[win:id()] = nil, nil
                -- At once: WindowServer may still have it parked, and a
                -- captureRetile would glide it in from there over the
                -- whole display.
                local was = S.instantLayout
                S.instantLayout = true
                Drop.finishDrag(win, point)
                S.instantLayout = was
                Slide.land()
            end)
            return true
        end
        if mode == "move" and win then
            -- Its own move reports were muted (or taken for ours) during the
            -- drag, so which display it's on is looked up afresh.
            S.windowInfo[win:id()], S.applied[win:id()] = nil, nil
            if Drop.finishDrag(win, point) then
                -- The picture fades once the window is in its place.
                if lifted then Slide.land() end
                return true
            end
        end
        if mode == "resize" and Resize.finishResize() then
            return true
        end
        if win then
            win:setFrameInScreenBounds(win:frame(), 0)
            -- A float (or any window, with tiling off) dropped on another
            -- display joins the workspace showing there.
            if mode == "move" then
                local info = Discover.windowInfoFor(win)
                if info.uuid and not info.full then Spaces.claim(win, info.uuid) end
            end
        end
        if lifted then Slide.land() end
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
