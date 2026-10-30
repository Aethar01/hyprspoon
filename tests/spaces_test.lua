-- Run with: lua tests/spaces_test.lua
-- Unit tests for hyprspoon/spaces.lua: which workspaces go on which display
-- (S.cfg.displays) as displays come and go, with a stubbed `hs`.
package.path = "./?.lua;" .. package.path

local function screen(uuid, name, x)
    local f = { x = x, y = 0, w = 1000, h = 800 }
    return {
        getUUID = function() return uuid end,
        name = function() return name end,
        id = function() return uuid end,
        fullFrame = function() return f end,
        frame = function() return f end,
    }
end

local LAPTOP = screen("LAPTOP", "Built-in Retina Display", 0)
local DELL = screen("DELL", "DELL U2723QE", 1000)
local TV = screen("TV", "LG TV", -1000)
local screens = { LAPTOP }
local pointer = LAPTOP

hs = {
    settings = { get = function() return nil end, set = function() end },
    timer = {
        doAfter = function() return { stop = function() end } end,
        secondsSinceEpoch = function() return 1000 end,
    },
    screen = {
        allScreens = function() return screens end,
        primaryScreen = function() return screens[1] end,
    },
    mouse = {
        getCurrentScreen = function() return pointer end,
        absolutePosition = function() end,
    },
    window = { list = function() return {} end },
    focus = function() end,
    reload = function() end,
}

local noop = function() end
package.loaded["hyprspoon.util"] = {
    focusHistory = {}, winByID = {},
    managedWindows = function() return {} end,
    rulesFor = function() return {} end,
}
package.loaded["hyprspoon.tree"] = { bootTime = 0, rectFor = noop }
package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop, focus = noop, currentWindow = noop }
package.loaded["hyprspoon.discover"] = { cancelLayoutCheck = noop }
package.loaded["hyprspoon.layout"] = { tileNow = noop, scheduleRetile = noop, BSP_SETTLE = 0 }
package.loaded["hyprspoon.bar"] = { update = noop }
package.loaded["hyprspoon.hud"] = { update = noop, switched = noop }
package.loaded["hyprspoon.border"] = { forget = noop, sync = noop }
package.loaded["hyprspoon.restore"] = { savedActive = function() return {} end, match = noop }
package.loaded["hyprspoon.slide"] = { reset = noop, forget = noop, switch = noop }

local S = require("hyprspoon.state")
S.cfg = {
    namedWorkspaces = {},
    displays = {
        ["Built-in Retina Display"] = { 1, 2, 3 },
        DELL = { 4, 5, 6 }, -- by UUID
    },
}
S.trees, S.maximized, S.untiled, S.windowInfo, S.applied = {}, {}, {}, {}, {}
S.settleUntil = 0

local Spaces = require("hyprspoon.spaces")

local function showing(uuid)
    return tonumber(Spaces.keyForUUID(uuid):match("^ws(%-?%d+)$"))
end

local moved = {}
local function win(id)
    return {
        id = function() return id end,
        application = function() return nil end,
        moveToScreen = function(_, screen) moved[id] = screen:getUUID() end,
    }
end

-- One display: everything is on it, the Dell's workspaces too.
Spaces.start()
assert(showing("LAPTOP") == 1, "a display shows its first workspace")
Spaces.gotoWorkspace(5)
assert(showing("LAPTOP") == 5, "a missing display's workspace shows on the primary")

-- The Dell arrives: 5, showing on the laptop, goes over to it.
screens = { LAPTOP, DELL }
Spaces.screensChanged()
assert(showing("DELL") == 5, "a workspace showing goes to the display it's given to")
assert(showing("LAPTOP") == 1, "the laptop shows one of its own")

-- Going to the Dell's workspaces from the laptop shows them on the Dell.
Spaces.gotoWorkspace(6)
assert(showing("DELL") == 6 and showing("LAPTOP") == 1)
-- Workspaces no display is given go to the primary, from anywhere.
pointer = DELL
Spaces.gotoWorkspace(8)
assert(showing("LAPTOP") == 8 and showing("DELL") == 6)
pointer = LAPTOP

-- A display not in the config gets one workspace of its own, by name.
screens = { LAPTOP, DELL, TV }
Spaces.screensChanged()
local tv = showing("TV")
assert(tv < 0, "an unlisted display's workspace isn't numbered")
assert(Spaces.label(tv) == "LG TV", "it's shown by the display's name")
assert(showing("LAPTOP") == 8 and showing("DELL") == 6, "the others keep theirs")
pointer = TV
Spaces.gotoWorkspace(2)
assert(showing("LAPTOP") == 2 and showing("TV") == tv, "numbered workspaces don't go to it")
pointer = LAPTOP

-- Focusing left from the laptop's empty workspace lands on the TV's, empty
-- too, and a window opening on the laptop goes there.
assert(Spaces.focusDisplayToward("left"), "an empty display can take focus")
assert(not Spaces.focusDisplayToward("up"), "no display that way")
Spaces.claim(win(42), "LAPTOP")
assert(moved[42] == "TV" and Spaces.hasWindows(tv), "a new window opens on the focused empty display")
Spaces.windowFocused(42)
Spaces.claim(win(44), "LAPTOP")
assert(moved[44] == nil and Spaces.hasWindows(2), "until a window takes focus")

-- Its windows join the primary display's workspace when it goes.
screens = { LAPTOP, DELL }
Spaces.screensChanged()
assert(Spaces.hasWindows(2) and not Spaces.hasWindows(tv), "the projector's windows join the primary's")
for _, ws in ipairs(Spaces.workspaces()) do assert(ws.n > 0, "its workspace is forgotten") end

-- The Dell goes: its workspaces show on the laptop again.
Spaces.claim(win(43), "DELL")
screens = { LAPTOP }
Spaces.screensChanged()
Spaces.gotoWorkspace(6)
assert(showing("LAPTOP") == 6)

-- Unlisted displays and their workspaces come after the numbered ones.
assert(Spaces.before(3, -1) and not Spaces.before(-1, 3) and Spaces.before(-1, -2))

print("Spaces tests passed")
