-- Run with: lua tests/rescue_test.lua
-- Unit tests for Spaces.rescue() (spoon.hyprspoon:rescue()): bringing parked
-- windows back from the saved state of a run that crashed, with a stubbed
-- `hs` and hyprspoon not started.
package.path = "./?.lua;" .. package.path

local function screen(uuid, x)
    local f = { x = x, y = 0, w = 1000, h = 800 }
    return {
        getUUID = function() return uuid end,
        name = function() return uuid end,
        id = function() return uuid end,
        fullFrame = function() return f end,
        frame = function() return f end,
    }
end

local LAPTOP = screen("LAPTOP", 0)
local screens = { LAPTOP }

-- Saved by a run earlier this boot (Tree.bootTime 1000) that was killed
-- with workspace 1 showing: 11 and 12 parked on 2, 13 on 3, 14 showing.
-- 12 was on a display that has gone since; 15 has closed.
local settings = {
    ["hyprspoon.tiling"] = true,
    ["hyprspoon.workspaces"] = {
        boot = 1000,
        active = { LAPTOP = 1 },
        under = {},
        home = { ["1"] = "LAPTOP", ["2"] = "LAPTOP", ["3"] = "LAPTOP" },
        of = { ["11"] = 2, ["12"] = 2, ["13"] = 3, ["14"] = 1, ["15"] = 3 },
        parked = {
            ["11"] = { x = 10, y = 20, w = 300, h = 200 },
            ["12"] = { x = 2100, y = 20, w = 400, h = 300 },
            ["13"] = { x = 50, y = 60, w = 300, h = 200 },
            ["15"] = { x = 50, y = 60, w = 300, h = 200 },
        },
        info = {},
    },
}

local frames = {}
local function win(id)
    return {
        id = function() return id end,
        setFrame = function(_, f) frames[id] = f end,
    }
end
-- 11 belongs to a hidden app; 13 is on another Desktop, out of
-- hs.window's reach. Neither appears in the on-screen list.
local reachable = { win(11), win(12), win(14) }
local alive = { 11, 12, 13, 14 }
local onScreen = { 12, 14 }

hs = {
    settings = {
        get = function(key) return settings[key] end,
        set = function(key, value) settings[key] = value end,
    },
    timer = {
        doAfter = function() return { stop = function() end } end,
        secondsSinceEpoch = function() return 1000 end,
    },
    screen = {
        allScreens = function() return screens end,
        primaryScreen = function() return screens[1] end,
    },
    window = {
        allWindows = function() return reachable end,
        list = function()
            local out = {}
            for _, id in ipairs(onScreen) do out[#out + 1] = { kCGWindowNumber = id } end
            return out
        end,
    },
    reload = function() end,
}

local queries = 0
local function liveIDs()
    queries = queries + 1
    local out = {}
    for _, id in ipairs(alive) do out[id] = true end
    return out
end
local native = { liveIDs = liveIDs }

local noop = function() end
local forgotten = false
package.loaded["hyprspoon.util"] = {
    focusHistory = {}, winByID = {},
    native = function(name) assert(name == "frames") return native end,
    managedWindows = function() return {} end,
    rulesFor = function() return {} end,
    pointInFrame = function(p, f)
        return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
    end,
}
package.loaded["hyprspoon.tree"] = { bootTime = 1000, rectFor = noop }
package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop }
package.loaded["hyprspoon.discover"] = { cancelLayoutCheck = noop }
package.loaded["hyprspoon.layout"] = { tileNow = noop, scheduleRetile = noop, BSP_SETTLE = 0 }
package.loaded["hyprspoon.bar"] = { update = noop }
package.loaded["hyprspoon.hud"] = { update = noop, switched = noop }
package.loaded["hyprspoon.border"] = { forget = noop, sync = noop }
package.loaded["hyprspoon.restore"] = {
    savedActive = function() return {} end,
    match = noop,
    forget = function() forgotten = true end,
}
package.loaded["hyprspoon.slide"] = { reset = noop, forget = noop, switch = noop }

local S = require("hyprspoon.state")
S.cfg = { namedWorkspaces = {}, displays = {} }
S.trees, S.maximized, S.untiled, S.windowInfo, S.applied = {}, {}, {}, {}, {}
S.settleUntil = 0

local Spaces = require("hyprspoon.spaces")
assert(Spaces.hasWindows(2), "the saved workspaces are loaded with the module")

-- Turning tiling off moved 11's frame since it was saved (not flushed yet).
Spaces.setParkedFrame(11, { x = 30, y = 40, w = 300, h = 200 })

local back, missing = Spaces.rescue()
assert(back == 2 and missing == 1, "two back, one out of reach, the closed one not counted")
assert(queries == 1, "one all-window query confirms every missing ID")
assert(frames[11], "a hidden app's window is rescued despite being off screen")
assert(frames[11].x == 30 and frames[11].y == 40, "this run's frame wins over the saved one")
assert(frames[12].x == 300 and frames[12].y == 250 and frames[12].w == 400,
    "a frame on a display that has gone is centred on the primary")
assert(frames[14] == nil, "windows that weren't parked stay where they are")
assert(forgotten, "windows aren't matched to the old workspaces after a restart")

local saved = settings["hyprspoon.workspaces"]
assert(next(saved.of) == nil and next(saved.home) == nil and next(saved.active) == nil,
    "the workspaces are forgotten, so the next start parks nothing")
assert(saved.parked["13"] and not saved.parked["11"] and not saved.parked["15"],
    "only the window out of reach stays saved as parked")
assert(not Spaces.hasWindows(2) and not Spaces.isHidden(13))

-- Behind a full-screen Space, even an empty on-screen list must keep
-- the unreachable window's saved frame for a later rescue.
onScreen = {}
reachable = {}
back, missing = Spaces.rescue()
assert(back == 0 and missing == 1 and settings["hyprspoon.workspaces"].parked["13"],
    "a full-screen Space does not erase an unreachable window's saved frame")
Spaces.start()
Spaces.stop()
assert(settings["hyprspoon.workspaces"].parked["13"], "sync also keeps the unreachable parked frame")

-- Old/absent native modules and query failures preserve uncertain IDs.
for _, mode in ipairs({ "old", "absent", "failed" }) do
    native = mode == "old" and {} or mode == "failed" and { liveIDs = function() return nil end } or nil
    back, missing = Spaces.rescue()
    assert(back == 0 and missing == 1 and settings["hyprspoon.workspaces"].parked["13"],
        mode .. " native query keeps the saved frame")
end
native = { liveIDs = liveIDs }

-- From 13's Space, again: it comes back too. No all-window query is needed
-- once the only saved ID is on screen.
onScreen = { 11, 13 }
local before = queries
reachable = { win(11), win(13) }
frames = {}
back, missing = Spaces.rescue()
assert(back == 1 and missing == 0 and frames[13].x == 50 and frames[11] == nil)
assert(next(settings["hyprspoon.workspaces"].parked) == nil)
assert(queries == before, "on-screen saved IDs need no all-window query")

-- An authoritative empty all-window result really does forget closed IDs,
-- even when the on-screen list is empty too.
settings["hyprspoon.workspaces"].parked["15"] = { x = 50, y = 60, w = 300, h = 200 }
onScreen, alive, reachable = {}, {}, {}
back, missing = Spaces.rescue()
assert(back == 0 and missing == 0 and next(settings["hyprspoon.workspaces"].parked) == nil,
    "a confirmed closed window is forgotten")

-- A saved state from another boot: its IDs could be anyone's now.
settings["hyprspoon.workspaces"] = { boot = 1, parked = { ["11"] = { x = 0, y = 0, w = 10, h = 10 } } }
frames = {}
back = Spaces.rescue()
assert(back == 0 and frames[11] == nil, "window IDs from another boot are ignored")

print("Rescue tests passed")
