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
local FULL, DESKTOP = 2070, 1

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
                Spaces = { { ManagedSpaceID = DESKTOP, type = 0 }, { ManagedSpaceID = FULL, type = 4 } },
            } }
        end,
    },
    window = { list = function() return {} end },
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
hs.window.list = function()
    local out = {}
    for _, w in ipairs(visible) do out[#out + 1] = { kCGWindowNumber = w:id() } end
    return out
end

local noop = function() end
package.loaded["hyprspoon.util"] = {
    focusHistory = {}, winByID = {},
    managedWindows = function() return visible end,
    rulesFor = function() return {} end,
    setFrame = function(w, frame) moved[w:id()] = frame end,
}
package.loaded["hyprspoon.tree"] = { bootTime = 0, rectFor = noop, findByID = function() return true end }
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
    for _, ws in ipairs(Spaces.overview()) do
        for _, w in ipairs(ws.windows) do
            if w.id == id then return ws.n end
        end
    end
end

-- Started on the full-screen Space: the full-screen window has left the
-- workspaces, and the desktop's windows aren't in sight.
Spaces.start()
assert(Spaces.keyForUUID("LAPTOP") == "ws2", "the display still shows workspace 2")

-- Back on the desktop: its windows arrive (Spaces.place from the window
-- events), then the layout claims those showing.
onFullScreen = false
visible = wins
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

-- With the desktop showing, a switch brings 1 back and still forgets the
-- window that closed unseen.
Spaces.gotoWorkspace(1)
assert(not Spaces.isHidden(11) and Spaces.isHidden(12) and Spaces.isHidden(13))
Spaces.stop()
assert(written and written.of["18"] == nil and written.parked["18"] == nil, "a dead window is forgotten")
assert(written.of["14"] == 3 and written.parked["14"] and written.of["17"] == 101, "the saved state keeps the rest")
assert(written.active.LAPTOP == 1 and written.parked["11"] == nil and written.parked["12"])

print("Reload tests passed")
