-- Run with: lua tests/drag_effect_test.lua
-- mouse.dragEffect (#26): the option, the lifter handed to frames.dragBegin,
-- and the drop landing the picture. Off, drags are exactly as before.
package.path = "./?.lua;" .. package.path

local screens = {}
local function screen(uuid, scale)
    return {
        getUUID = function() return uuid end,
        currentMode = function() return { scale = scale, freq = 60 } end,
    }
end
local now = 0
hs = {
    geometry = { copy = function(r) return { x = r.x, y = r.y, w = r.w, h = r.h } end },
    screen = { allScreens = function() return screens end },
    timer = { secondsSinceEpoch = function() return now end },
    eventtap = {
        -- The Lua fallback's tap, for drags the native module couldn't follow.
        new = function()
            local tap = {}
            function tap:start() return self end
            function tap:stop() end
            return tap
        end,
        event = { types = { leftMouseDown = 1, leftMouseUp = 2, leftMouseDragged = 3,
                            rightMouseDown = 4, rightMouseUp = 5, rightMouseDragged = 6 } },
    },
    processInfo = { processID = 1 },
}

local S = { cfg = { mouse = {} }, windowInfo = {}, applied = {}, running = {} }
package.loaded["hyprspoon.state"] = S
local natives = {}
local Util = { native = function(name) return natives[name] end, focusWindow = function() end }
package.loaded["hyprspoon.util"] = Util
package.loaded["hyprspoon.anim"] = { get = function() return {} end }

-- ---------------------------------------------------------------------------
-- The option
-- ---------------------------------------------------------------------------

local Slide = require("hyprspoon.slide")
local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

assert(Slide.dragEffect(nil) == nil and Slide.dragEffect(false) == nil, "off by default")
assert(same(Slide.dragEffect(true), { scale = 0.95, opacity = 0.8, duration = 0.15 }), "true: the defaults")
assert(same(Slide.dragEffect({ scale = 0.9 }), { scale = 0.9, opacity = 0.8, duration = 0.15 }),
    "a table keeps the defaults it leaves out")
assert(same(Slide.dragEffect({ scale = 3, opacity = -1, duration = "x" }), { scale = 1, opacity = 0.05, duration = 0.15 }),
    "numbers out of range are brought in; others are the defaults")

-- Off, or without the native module, there's no lifter (and the native
-- module isn't even looked for when off).
S.cfg.mouse.dragEffect = false
natives.slide = { lifter = function() error("asked for a lifter while off") end }
assert(Slide.lifter() == nil)
S.cfg.mouse.dragEffect = { scale = 0.9 }
natives.slide = nil
assert(Slide.lifter() == nil, "no native module, no lifter")
natives.slide = {}
assert(Slide.lifter() == nil, "an older native module without lifter()")

-- On, the native module gets the look and the finest display resolution.
local styled, landed = nil, 0
natives.slide = {
    lifter = function(style) styled = style return "LIFTER" end,
    land = function() landed = landed + 1 end,
}
screens = { screen("A", 1), screen("B", 2) }
local lift, scale = Slide.lifter()
assert(lift == "LIFTER" and scale == 0.9)
assert(styled.scale == 0.9 and styled.opacity == 0.8 and styled.duration == 0.15 and styled.resolution == 2)
-- Without Screen Recording permission the native module gives none.
natives.slide.lifter = function() return nil end
assert(Slide.lifter() == nil)
Slide.land()
assert(landed == 1)

-- ---------------------------------------------------------------------------
-- The drag (hyprspoon/mouse.lua)
-- ---------------------------------------------------------------------------

local calls = {}
local homeTo, homeDone
local function log(what) calls[#calls + 1] = what end
local liftOffered = "LIFTER"
package.loaded["hyprspoon.slide"] = {
    lifter = function() log("lifter") if liftOffered then return liftOffered, 0.9 end end,
    land = function() log("land") end,
    cancelHome = function() log("cancelHome") end,
    home = function(frame, done) log("home") homeTo = frame homeDone = done end,
}
local parkAt = { x = 1919, y = 1079 }
package.loaded["hyprspoon.spaces"] = {
    parkPoint = function(uuid, size)
        assert(uuid == "A" and size.w == 400 and size.h == 300)
        return parkAt
    end,
    claim = function() log("claim") end,
}
local win = {
    id = function() return 7 end,
    pid = function() return 42 end,
    frame = function() return { x = 10, y = 20, w = 400, h = 300 } end,
    screen = function() return screens[1] end,
    setFrameInScreenBounds = function() log("inBounds") end,
}
package.loaded["hyprspoon.focus"] = { windowUnderPoint = function() return win end }
package.loaded["hyprspoon.resize"] = {
    resizeBranches = function() return "a", "a" end,
    beginResize = function() end,
    finishResize = function() log("finishResize") return true end,
}
local dropped = true
local stays = false
package.loaded["hyprspoon.drop"] = {
    beginDrag = function() end,
    updateDrag = function() end,
    wouldStay = function() return stays end,
    preview = function() log("preview") end,
    finishDrag = function() log("finishDrag") return dropped end,
}
package.loaded["hyprspoon.border"] = { previewer = function() return "RING" end }
package.loaded["hyprspoon.discover"] = { windowInfoFor = function() return { uuid = "A" } end }

local began
natives.frames = {
    dragBegin = function(t) began = t log("dragBegin") return true end,
    dragEnd = function(_, _, home) log(home and "dragEnd(home)" or "dragEnd") end,
}
S.cfg.mouse = { move = { "alt" }, resize = { "alt", "cmd" }, rightResize = { "alt" } }
S.cfg.minWidth, S.cfg.minHeight = 240, 140
local Mouse = require("hyprspoon.mouse")

local function event(kind, mods)
    return {
        getType = function() return hs.eventtap.event.types[kind] end,
        location = function() return { x = 100, y = 100 } end,
        getFlags = function()
            return { containExactly = function(_, want)
                if #want ~= #mods then return false end
                for i, m in ipairs(mods) do if want[i] ~= m then return false end end
                return true
            end }
        end,
    }
end
local function drag(down, up, mods)
    calls, began = {}, nil
    assert(Mouse.onMouseEvent(event(down, mods)))
    assert(Mouse.onMouseEvent(event(up, mods)))
    return began
end
local function index(what)
    for i, c in ipairs(calls) do if c == what then return i end end
end

-- Off: frames.dragBegin is given nothing new, and nothing lands.
liftOffered = nil
local t = drag("leftMouseDown", "leftMouseUp", { "alt" })
assert(t.mode == "move" and t.lift == nil and t.liftScale == nil and t.park == nil)
assert(not index("land"), "off, nothing lands")

-- On: a move hands over the lifter, how much it shrinks, and where the
-- window waits; the picture lands once the drop has put the window in place.
liftOffered = "LIFTER"
t = drag("leftMouseDown", "leftMouseUp", { "alt" })
assert(t.lift == "LIFTER" and t.liftScale == 0.9 and t.park.x == 1919 and t.park.y == 1079)
assert(t.preview == "RING", "the ring still follows the drag")
assert(index("dragEnd") < index("finishDrag") and index("finishDrag") < index("land"))
-- Dropped outside the layout: it lands after the window is kept on screen.
dropped = false
drag("leftMouseDown", "leftMouseUp", { "alt" })
assert(index("inBounds") < index("land") and index("claim") < index("land"))
dropped = true

-- A drop that changes nothing: the window stays parked while the picture
-- goes home, then comes back under it (and the drop retiles) before the
-- picture fades.
stays = true
natives.frames.dragEnd = function(_, _, home)
    log(home and "dragEnd(home)" or "dragEnd")
    if home then return nil, { x = 10, y = 20, w = 400, h = 300 } end
end
natives.frames.dragUnpark = function() log("dragUnpark") return true end
drag("leftMouseDown", "leftMouseUp", { "alt" })
assert(index("cancelHome") < index("dragBegin"), "a picture going home is left to the next drag")
assert(index("dragEnd(home)") and index("home") and not index("finishDrag") and not index("land"))
assert(homeTo.x == 10 and homeTo.w == 400)
homeDone()
assert(index("dragUnpark") < index("finishDrag") and index("finishDrag") < index("land"),
    "the window is back, and retiled, before the picture fades")
-- The native side kept nothing parked (the picture wasn't up yet): as before.
natives.frames.dragEnd = function(_, _, home) log(home and "dragEnd(home)" or "dragEnd") end
drag("leftMouseDown", "leftMouseUp", { "alt" })
assert(index("dragEnd(home)") < index("finishDrag") and index("finishDrag") < index("land"))
stays = false
natives.frames.dragEnd = function() log("dragEnd") end

-- Without a place to park the window (its display gone), no picture.
parkAt = nil
t = drag("leftMouseDown", "leftMouseUp", { "alt" })
assert(t.lift == nil and t.park == nil and not index("land"))
parkAt = { x = 1919, y = 1079 }

-- The native drag couldn't start: nothing lands.
natives.frames.dragBegin = function(t2) began = t2 return false end
natives.frames.dragEnd = function() error("no native drag to end") end
calls = {}
assert(Mouse.onMouseEvent(event("leftMouseDown", { "alt" })))
assert(S.dragState and not S.dragState.lifted)
Mouse.stop()
S.dragState = nil
natives.frames.dragBegin = function(t2) began = t2 log("dragBegin") return true end
natives.frames.dragEnd = function() log("dragEnd") end

-- Resizes always drag the window: no lifter is even asked for.
t = drag("leftMouseDown", "leftMouseUp", { "alt", "cmd" })
assert(t.mode == "resize" and t.lift == nil and not index("lifter") and not index("land"))
t = drag("rightMouseDown", "rightMouseUp", { "alt" })
assert(t.mode == "resize" and t.lift == nil and not index("land"))

print("Drag effect tests passed")
