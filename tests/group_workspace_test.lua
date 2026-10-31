-- Workspace moves with real Spaces, Tree, Layout and Group; no Hammerspoon required.
package.path = "./?.lua;" .. package.path

local settings = {}
local clock = 1000
hs = {
    focus = function() end,
    execute = function() return "{ sec = 1000, usec = 0 }" end,
    settings = {
        get = function(key) return settings[key] end,
        set = function(key, value) settings[key] = value end,
    },
    json = { encode = function() return tostring({}) end },
    timer = {
        doAfter = function() return { stop = function() end } end,
        secondsSinceEpoch = function() return clock end,
    },
    window = { list = function() return {} end },
    mouse = {
        absolutePosition = function() return { x = 0, y = 0 } end,
        getButtons = function() return {} end,
    },
    geometry = {
        rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
        copy = function(r) return { x = r.x, y = r.y, w = r.w, h = r.h } end,
    },
}

-- Start with one display, then add another for cross-display moves.
local function screen(uuid, x)
    local f = { x = x, y = 0, w = 1000, h = 800 }
    return { getUUID = function() return uuid end, frame = function() return f end }
end
local screens = { screen("A", 0) }
hs.screen = { allScreens = function() return screens end }

-- Windows: an id, an app and a frame that setFrame moves.
local wins = {}
local function window(id, pid)
    local w = { frame_ = { x = 0, y = 0, w = 100, h = 100 }, moves = 0 }
    function w:id() return id end
    function w:pid() return pid or id end
    function w:frame() return { x = self.frame_.x, y = self.frame_.y, w = self.frame_.w, h = self.frame_.h } end
    function w:setFrame(r)
        self.frame_ = { x = r.x, y = r.y, w = r.w, h = r.h }
        self.moves = self.moves + 1
    end
    function w:setTopLeft(p) self:setFrame({ x = p.x, y = p.y, w = self.frame_.w, h = self.frame_.h }) end
    function w:setSize(s) self:setFrame({ x = self.frame_.x, y = self.frame_.y, w = s.w, h = s.h }) end
    wins[id] = w
    return w
end
for id = 1, 4 do window(id) end

local noop = function() end
local Util = {
    focusHistory = {}, focusTimes = {}, winByID = {}, pidByID = {},
    dlog = noop, idList = function() return "" end,
    native = noop, warpToWindow = noop,
    rulesFor = function() return {} end,
    focusedWindow = noop,
    pointInFrame = function(p, f)
        return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
    end,
}
for id, w in pairs(wins) do Util.winByID[id] = w end
package.loaded["hyprspoon.util"] = Util

package.loaded["hyprspoon.discover"] = { layoutChecks = {}, cancelLayoutCheck = noop }
local ring = {}
package.loaded["hyprspoon.border"] = {
    sync = noop,
    handOver = function(from, to) ring[#ring + 1] = { from, to } end,
}
local focused = {}
package.loaded["hyprspoon.focus"] = {
    invalidateWindowCache = noop,
    focus = function(win) focused[#focused + 1] = win:id() end,
    noteFocus = noop,
}
-- Layout captures this table during circular module loading.
package.loaded["hyprspoon.spaces"] = {}
package.loaded["hyprspoon.float"] = { raiseFloating = noop }
package.loaded["hyprspoon.drop"] = {}
package.loaded["hyprspoon.restore"] = { rebuild = function(_, tree) return tree end }
package.loaded["hyprspoon.hooks"] = { fire = noop }

local S = require("hyprspoon.state")
S.cfg = { debug = false, tiling = { innerGap = 0, outerGap = 0, minRatio = 0.2, maxRatio = 0.8,
    animationDuration = 0 } }
S.tilingEnabled = true
S.running = { windowFilter = {} }
S.autoFloat, S.fullscreen, S.offSpace, S.applied, S.windowInfo = {}, {}, {}, {}, {}
S.settleUntil, S.lastMouseTime = 0, 0
local Tree = require("hyprspoon.tree")
local Layout = require("hyprspoon.layout")


-- Drive workspace actions with the real Spaces, Tree, Layout and Group modules.
local bridge = package.loaded["hyprspoon.spaces"]
package.loaded["hyprspoon.spaces"] = nil
package.loaded["hyprspoon.bar"] = { update = noop }
package.loaded["hyprspoon.hud"] = { update = noop, switched = noop }
package.loaded["hyprspoon.slide"] = { reset = noop, forget = noop, switch = function() return false end }
local Restore = package.loaded["hyprspoon.restore"]
Restore.savedActive, Restore.match = function() return {} end, noop
local Border = package.loaded["hyprspoon.border"]
Border.forget = noop
local scr = screens[1]
scr.id, scr.name, scr.fullFrame = scr.getUUID, scr.getUUID, scr.frame
hs.screen.primaryScreen = function() return scr end
hs.mouse.getCurrentScreen = function() return scr end
S.cfg.displays = { A = { 7, 8 } }
S.cfg.namedWorkspaces = {}
local managed = { wins[1], wins[2], wins[3], wins[4] }
Util.managedWindows = function() return managed end
Util.windowFor = function(id) return wins[id] end
Util.setFrame = function(w, f) w:setFrame(f) end
for _, w in ipairs(managed) do
    w.application = noop
    w.screen = function() return scr end
    w.raise = noop
end
local Spaces = require("hyprspoon.spaces")
for k, v in pairs(Spaces) do bridge[k] = v end
local Focus = package.loaded["hyprspoon.focus"]
Focus.currentWindow = function() return wins[4] end
Focus.focus = noop
local Discover = package.loaded["hyprspoon.discover"]
Discover.windowInfoFor = function() return {} end
Discover.windowsByScreen = function()
    S.openIDs, S.ghosts = {}, {}
    local visible = {}
    -- Parked windows still have a WindowServer sliver, as in live discovery.
    for _, w in ipairs(managed) do
        local id = w:id()
        S.openIDs[id] = true
        if not Spaces.isHidden(id) then visible[#visible + 1] = w end
    end
    return { A = visible }
end
local Group = require("hyprspoon.group")
Spaces.start()
for _, w in ipairs(managed) do Spaces.claim(w, "A") end
Layout.tileNow(false)
Group.toggle(wins[3])
Group.join(wins[4], wins[3])
local function intact(n, hiddenWorkspace)
    local group, key = Tree.setOf(4)
    assert(group and group.kind == "group" and group.windowID == 4, "shown member survives move")
    assert(#group.members == 2 and Tree.setOf(3) == group, "members stay together")
    assert(key == "ws" .. n or (hiddenWorkspace and key == nil), "group arrives on target workspace")
    assert(Spaces.workspaceOf(3) == n and Spaces.workspaceOf(4) == n)
    assert(Spaces.isHidden(3) and (hiddenWorkspace or not Spaces.isHidden(4)), "hidden member stays parked")
end
intact(7)
Spaces.moveToWorkspace(8)
intact(8)
Spaces.moveToWorkspace(7)
intact(7)
assert(#Tree.leaves(S.trees.ws7) == 3, "round trip preserves the two ordinary neighbours")
-- Silent moves leave the source visible, then arrive whole when visited.
Spaces.moveToWorkspaceSilent(8)
intact(8, true)
Spaces.gotoWorkspace(8)
intact(8)
Spaces.moveToWorkspaceSilent(7)
intact(7, true)
Spaces.gotoWorkspace(7)
intact(7)

-- The slide path also syncs before discovery, so it needs the same retention.
package.loaded["hyprspoon.slide"].switch = function() return true end
Spaces.moveToWorkspace(8)
intact(8)
Spaces.moveToWorkspace(7)
intact(7)

-- On another display, hidden members must be re-parked in its corner.
local other = screen("B", 1000)
other.id, other.name, other.fullFrame = other.getUUID, other.getUUID, other.frame
screens[2] = other
S.cfg.displays.B = { 9 }
Spaces.screensChanged()
for _, w in ipairs(managed) do
    w.moveToScreen = function(self, target)
        self:setTopLeft({ x = target:frame().x, y = 0 })
    end
end
-- Discovery assigns visible windows by their claimed workspace display.
Discover.windowsByScreen = function()
    S.openIDs, S.ghosts = {}, {}
    local visible = { A = {}, B = {} }
    for _, w in ipairs(managed) do
        S.openIDs[w:id()] = true
        if not Spaces.isHidden(w:id()) then
            local uuid = Spaces.uuidForKey("ws" .. Spaces.workspaceOf(w:id()))
            visible[uuid][#visible[uuid] + 1] = w
        end
    end
    return visible
end
Spaces.moveToWorkspace(9)
intact(9)
assert(wins[3]:frame().x >= 1000, "hidden member is parked on the destination display")
Spaces.moveToWorkspaceSilent(7)
intact(7)
assert(wins[3]:frame().x < 1000, "hidden member returns to the source display corner")
print("Group workspace tests passed")
