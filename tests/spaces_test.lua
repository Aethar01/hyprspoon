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

local settings = {}
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
    mouse = {
        getCurrentScreen = function() return pointer end,
        absolutePosition = function() end,
    },
    window = { list = function() return {} end },
    focus = function() end,
    reload = function() end,
}

local noop = function() end
local Util = {
    focusHistory = {}, winByID = {},
    native = noop,
    managedWindows = function() return {} end,
    rulesFor = function() return {} end,
}
package.loaded["hyprspoon.util"] = Util
-- Window id -> the members of its set, for the windows that have one.
local sets = {}
package.loaded["hyprspoon.tree"] = { bootTime = 0, rectFor = noop,
    membersOf = function(id) return sets[id] or { id } end }
package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop, focus = noop, currentWindow = noop }
package.loaded["hyprspoon.discover"] = { cancelLayoutCheck = noop, windowInfoFor = function() return {} end }
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
S.autoFloat = {}
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
        screen = function() return LAPTOP end,
        moveToScreen = function(_, screen) moved[id] = screen:getUUID() end,
        frame = function() return { x = 100, y = 100, w = 300, h = 200 } end,
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
assert(Spaces.focusedWorkspace(nil) == tv, "the empty display's workspace has focus")
local displays = Spaces.displays()
assert(#displays == 3 and displays[1].uuid == "LAPTOP" and displays[1].n == 2
    and displays[2].uuid == "TV" and displays[2].n == tv and displays[3].uuid == "DELL",
    "the primary first, then left to right")
assert(not Spaces.focusDisplayToward("up"), "no display that way")
Spaces.claim(win(42), "LAPTOP")
assert(moved[42] == "TV" and Spaces.hasWindows(tv), "a new window opens on the focused empty display")
Spaces.windowFocused(42)
assert(Spaces.focusedWorkspace(win(42)) == tv, "then the focused window's")
assert(Spaces.focusedWorkspace(nil) == 2, "with none, the pointer's display's")
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

-- A pinned window is never parked: it joins whatever its display shows.
local parkedAt = {}
local free, stuck = win(50), win(51)
Util.managedWindows = function() return { free, stuck } end
Util.setFrame = function(w, f) parkedAt[w:id()] = f end
Util.pointInFrame = function() return true end
Spaces.claim(free, "LAPTOP")
Spaces.claim(stuck, "LAPTOP")
Spaces.setPinned(stuck, true)
Spaces.gotoWorkspace(1)
assert(parkedAt[50] and Spaces.isHidden(50), "an unpinned window parks")
assert(not parkedAt[51] and not Spaces.isHidden(51), "a pinned one stays")
Spaces.gotoWorkspace(6)
assert(not Spaces.isHidden(50) and not Spaces.isHidden(51), "both are on the workspace showing")
assert(not parkedAt[51], "the pinned one was never moved")
Spaces.gotoWorkspace(1)
Spaces.setPinned(stuck, false)
Spaces.gotoWorkspace(6)
assert(parkedAt[51] and Spaces.isHidden(51), "unpinned, it stays behind")

-- A rule can pin a window.
Util.rulesFor = function(w) return w:id() == 52 and { pin = true } or {} end
Spaces.claim(win(52), "LAPTOP")
assert(Spaces.isPinned(52) and not Spaces.isPinned(50))

-- Minimize and full screen forget membership, but a pin rejoins the
-- workspace its display shows on return, with tiling on or off.
screens = { LAPTOP, DELL }
Spaces.screensChanged()
assert(showing("DELL") == 6, "the original rule's workspace shows on another display")
local returning = win(53)
local function workspaceOf(id)
    for _, ws in ipairs(Spaces.overview()) do
        for _, w in ipairs(ws.windows) do
            if w.id == id then return ws.n end
        end
    end
end
Util.managedWindows = function() return { returning } end
for _, tiling in ipairs({ true, false }) do
    S.tilingEnabled = tiling
    for _, event in ipairs({ "minimize", "full screen" }) do
        Spaces.gotoWorkspace(1)
        Util.rulesFor = function() return {} end
        Spaces.claim(returning, "LAPTOP")
        Spaces.setPinned(returning, true)
        Spaces.forget(53)
        assert(Spaces.isPinned(53) and not workspaceOf(53), event .. " keeps only the pin")
        Spaces.gotoWorkspace(3)
        -- A surviving pin must not reapply its original workspace rule.
        Util.rulesFor = function() return { workspace = 6 } end
        Spaces.place(returning)
        assert(workspaceOf(53) == 3 and Spaces.isPinned(53), event .. " restores pinned membership")
        Spaces.gotoWorkspace(1)
        assert(workspaceOf(53) == 1, event .. " keeps following the display")
        assert(not parkedAt[53], event .. " never parks the pin")
        Spaces.forget(53)
    end
end
Util.rulesFor = function() return {} end

-- Cmd-H keeps membership while the window is absent from the managed list.
Spaces.claim(returning, "LAPTOP")
Util.managedWindows = function() return {} end
Spaces.gotoWorkspace(3)
Util.managedWindows = function() return { returning } end
Spaces.place(returning)
assert(workspaceOf(53) == 3, "an unhidden pin follows its display")
assert(Spaces.isPinned(53) and not parkedAt[53], "an unhidden window stays pinned and is never parked")

-- A window sent to another workspace takes its set along: members with a
-- workspace follow it, a parked one to the corner of the new display.
-- One with none (a native tab never on show) is left to its app.
local Focus = package.loaded["hyprspoon.focus"]
local shownWin, hiddenWin = win(60), win(61)
Util.managedWindows = function() return { shownWin, hiddenWin } end
Util.windowFor = function(id) return id == 61 and hiddenWin or nil end
Spaces.gotoWorkspace(3)
Spaces.claim(shownWin, "LAPTOP")
Spaces.claim(hiddenWin, "LAPTOP")
Focus.currentWindow = function() return hiddenWin end
Spaces.moveToWorkspaceSilent(2)
assert(parkedAt[61] and parkedAt[61].x < 1000, "parked in the laptop's corner")
sets[60] = { 60, 61, 62 }
Focus.currentWindow = function() return shownWin end
Spaces.moveToWorkspaceSilent(4)
assert(Spaces.workspaceOf(60) == 4 and Spaces.workspaceOf(61) == 4, "the set goes together")
assert(Spaces.workspaceOf(62) == nil)
assert(parkedAt[60].x > 1000 and parkedAt[61].x > 1000, "both parked on the Dell")
sets[60] = nil
Focus.currentWindow = noop

-- Group parking survives sync even on the visible workspace, and hidden
-- members never become overview/query entries or workspace focus targets.
Spaces.gotoWorkspace(3)
local gshown, ghidden = win(70), win(71)
gshown.title = function() return "group" end
Util.managedWindows = function() return { gshown, ghidden } end
Spaces.claim(gshown, "LAPTOP")
Spaces.claim(ghidden, "LAPTOP")
local group = { windowID = 70, members = { 70, 71 }, kind = "group" }
package.loaded["hyprspoon.tree"].setOf = function(id)
    if id == 70 or id == 71 then return group, "ws3" end
end
package.loaded["hyprspoon.tree"].findByID = noop
Spaces.place(ghidden)
assert(Spaces.isHidden(71) and not Spaces.isHidden(70))
local corner = parkedAt[71]
Spaces.gotoWorkspace(2)
Spaces.unpark(gshown)
assert(Spaces.isHidden(70), "selecting on a hidden workspace waits for its switch")
Spaces.gotoWorkspace(3)
assert(parkedAt[71] == corner, "sync never unparks a hidden group member")
assert(workspaceOf(70) == 3 and workspaceOf(71) == nil, "overview omits hidden members")
Spaces.place(ghidden)
assert(parkedAt[71] == corner, "placement leaves a parked group member alone")
Focus.currentWindow = function() return gshown end
Spaces.focusedWorkspace = function() return 3 end
local query = require("hyprspoon.hooks").query()
assert(#query.windows == 1 and query.windows[1].id == 70, "query ignores hidden group members")
Focus.currentWindow = noop

-- Pins are saved with the rest, and come back on reload.
Spaces.stop()
package.loaded["hyprspoon.spaces"] = nil
Spaces = require("hyprspoon.spaces")
assert(Spaces.isPinned(52) and not Spaces.isPinned(51), "pins survive a reload")

print("Spaces tests passed")
