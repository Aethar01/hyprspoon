-- Run with: lua tests/reload_test.lua
-- Unit test for hyprspoon/spaces.lua: Hammerspoon reloaded while a native
-- full-screen window's Space shows, then the desktop comes back. The
-- windows keep the workspaces from the saved state, with a stubbed `hs`.
package.path = "./?.lua;" .. package.path

local f = { x = 0, y = 0, w = 1000, h = 800 }
local LAPTOP = {
    getUUID = function() return "LAPTOP" end,
    name = function() return "Built-in Retina Display" end,
    id = function() return "LAPTOP" end,
    fullFrame = function() return f end,
    frame = function() return f end,
}

-- Workspace 2 shows. 1, 3 and 6 and the scratchpad S (101) are parked; 13
-- and 16 float. 18 closed while Hammerspoon missed it.
local CORNER = { x = 999, y = 770, w = 400, h = 300 }
local TILE = { x = 100, y = 100, w = 400, h = 300 }
local saved = {
    boot = 0,
    active = { LAPTOP = 2 },
    under = {},
    home = { ["1"] = "LAPTOP", ["2"] = "LAPTOP", ["3"] = "LAPTOP", ["6"] = "LAPTOP", ["101"] = "LAPTOP" },
    of = { ["11"] = 1, ["12"] = 2, ["13"] = 2, ["14"] = 3, ["16"] = 6, ["17"] = 101, ["18"] = 3 },
    parked = { ["11"] = TILE, ["14"] = TILE, ["16"] = TILE, ["17"] = TILE, ["18"] = TILE },
    info = {},
}
local written = nil

-- On the full-screen Space only its window (99) is on screen.
local onFullScreen = true
local FULL, DESKTOP, SECOND = 2070, 1, 2
local twoDesktops = false

hs = {
    settings = { get = function() return saved end, set = function(_, v) written = v end },
    timer = {
        doAfter = function() return { stop = function() end } end,
        secondsSinceEpoch = function() return 1000 end,
    },
    screen = {
        allScreens = function() return { LAPTOP } end,
        primaryScreen = function() return LAPTOP end,
    },
    mouse = {
        getCurrentScreen = function() return LAPTOP end,
        absolutePosition = function() end,
    },
    spaces = {
        data_managedDisplaySpaces = function()
            return { {
                ["Current Space"] = { ManagedSpaceID = onFullScreen and FULL or DESKTOP },
                Spaces = {
                    { ManagedSpaceID = DESKTOP, type = 0 },
                    { ManagedSpaceID = FULL, type = 4 },
                    twoDesktops and { ManagedSpaceID = SECOND, type = 0 } or nil,
                },
            } }
        end,
    },
    focus = function() end,
    reload = function() end,
}

local wins, moved = {}, {}
local function win(id)
    local frame = saved.parked[tostring(id)] and CORNER or TILE
    wins[#wins + 1] = {
        id = function() return id end,
        application = function() return nil end,
        frame = function() return frame end,
        moveToScreen = function() end,
    }
    return wins[#wins]
end
for _, id in ipairs({ 11, 12, 13, 14, 16, 17 }) do win(id) end
local fullWin = {
    id = function() return 99 end,
    application = function() return nil end,
    frame = function() return f end,
}

local visible = { fullWin }
hs.window = {}
hs.window.list = function()
    local out = {}
    for _, w in ipairs(visible) do out[#out + 1] = { kCGWindowNumber = w:id() } end
    return out
end

local queries = 0
local Frames = {}
local function liveIDs()
    queries = queries + 1
    local out = { [99] = true }
    for _, w in ipairs(wins) do out[w:id()] = true end
    return out
end
Frames.liveIDs = liveIDs

local noop = function() end
package.loaded["hyprspoon.util"] = {
    focusHistory = {}, winByID = {},
    managedWindows = function() return visible end,
    rulesFor = function(w) return w:id() >= 21 and { workspace = 3 } or {} end,
    native = function(name) assert(name == "frames") return Frames end,
    setFrame = function(w, frame) moved[w:id()] = frame end,
}
package.loaded["hyprspoon.tree"] = { bootTime = 0, setOf = noop, rectFor = noop, findByID = function() return true end }
package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop, focus = noop, currentWindow = noop }
package.loaded["hyprspoon.discover"] = {
    cancelLayoutCheck = noop,
    windowInfoFor = function() return { uuid = "LAPTOP" } end,
}
package.loaded["hyprspoon.layout"] = { tileNow = noop, scheduleRetile = noop, BSP_SETTLE = 0 }
package.loaded["hyprspoon.bar"] = { update = noop }
package.loaded["hyprspoon.hud"] = { update = noop, switched = noop }
package.loaded["hyprspoon.border"] = { forget = noop, sync = noop }
package.loaded["hyprspoon.restore"] = { savedActive = function() return {} end, match = noop }
package.loaded["hyprspoon.slide"] = { reset = noop, forget = noop, switch = noop }

local S = require("hyprspoon.state")
S.cfg = { namedWorkspaces = { "S" }, displays = {} }
S.trees, S.maximized, S.untiled, S.windowInfo, S.applied = {}, {}, {}, {}, {}
S.autoFloat = { [13] = true, [16] = true }
S.tilingEnabled = true
S.settleUntil = 0

local Spaces = require("hyprspoon.spaces")

local function workspaceOf(id)
    Spaces.stop()
    return written.of[tostring(id)]
end

-- Started on the full-screen Space: the full-screen window has left the
-- workspaces, and the desktop's windows aren't in sight.
Spaces.start()
assert(Spaces.keyForUUID("LAPTOP") == "ws2", "the display still shows workspace 2")
assert(queries == 1, "one liveness query checks every missing ID")
assert(workspaceOf(18) == nil, "a closed window is pruned even on a full-screen Space")

-- During a swipe back the Desktop can be current before its windows are
-- listed. A hidden app's window (16) also stays off screen after the swipe.
onFullScreen = false
Spaces.start()
assert(workspaceOf(14) == 3 and workspaceOf(16) == 6, "off-screen windows survive the transition")

-- Back on the desktop: its windows arrive (Spaces.place from the window
-- events), then the layout claims those showing.
visible = {}
for _, w in ipairs(wins) do
    if w:id() ~= 16 then visible[#visible + 1] = w end
end
for _, w in ipairs(wins) do Spaces.place(w) end
for _, w in ipairs(wins) do
    if not Spaces.isHidden(w:id()) then Spaces.claim(w, "LAPTOP") end
end
local expected = { [11] = 1, [12] = 2, [13] = 2, [14] = 3, [16] = 6, [17] = 101 }
for id, n in pairs(expected) do
    assert(workspaceOf(id) == n, "window " .. id .. " keeps workspace " .. n .. ", not " .. tostring(workspaceOf(id)))
end
for _, id in ipairs({ 11, 14, 16, 17 }) do
    assert(Spaces.isHidden(id) and moved[id] == nil, "window " .. id .. " stays parked")
end
assert(Spaces.keyForUUID("LAPTOP") == "ws2", "the display shows workspace 2")

-- A window opening now is new and joins the workspace showing.
Spaces.claim(win(20), "LAPTOP")
assert(workspaceOf(20) == 2, "a new window joins the workspace showing")

-- With two Desktops, a window closing unseen is still pruned, while the
-- hidden app keeps its workspace and parked frame.
twoDesktops = true
Spaces.claim(win(21), "LAPTOP")
table.remove(wins)
Spaces.start()
assert(workspaceOf(21) == nil and not Spaces.isHidden(21), "two Desktops do not prevent pruning")
assert(workspaceOf(16) == 6 and Spaces.isHidden(16), "a hidden app stays assigned and parked")

-- A switch brings workspace 1 back.
Spaces.gotoWorkspace(1)
assert(not Spaces.isHidden(11) and Spaces.isHidden(12) and Spaces.isHidden(13))
Spaces.stop()
assert(written and written.of["18"] == nil and written.parked["18"] == nil, "a dead window is forgotten")
assert(written.of["14"] == 3 and written.parked["14"] and written.of["17"] == 101, "the saved state keeps the rest")
assert(written.active.LAPTOP == 1 and written.parked["11"] == nil and written.parked["12"])

-- Old or absent native modules cannot confirm closure. A failed query
-- must also preserve saved IDs, even if the on-screen list is empty.
Spaces.claim(win(22), "LAPTOP")
table.remove(wins)
visible = {}
local function checkFallback(message)
    Spaces.start()
    Spaces.stop()
    assert(written.of["22"] == 3 and written.parked["22"], message)
end
Frames.liveIDs = nil
checkFallback("an old native module keeps uncertain IDs")
Frames.liveIDs = function() return nil end
checkFallback("a failed query keeps uncertain IDs")
local native = Frames
Frames = nil
checkFallback("Lua works without the native module")
Frames = native
Frames.liveIDs = liveIDs
Spaces.start()
Spaces.stop()
assert(written.of["22"] == nil and written.parked["22"] == nil, "an empty on-screen list still prunes dead IDs")

-- All tracked windows on screen need no further liveness query.
visible = wins
local before = queries
Spaces.start()
Spaces.stop()
assert(queries == before, "no all-window query when every tracked ID is on screen")

print("Reload tests passed")
