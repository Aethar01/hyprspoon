-- Run with: lua tests/restore_test.lua
-- Unit tests for wm/restore.lua: matching windows after a restart and
-- rebuilding their layout, with a stubbed `hs` holding the last boot's state.
package.path = "./?.lua;" .. package.path

local NOW = 1000000
os.time = function() return NOW end

-- Saved by the boot before (kern.boottime 500; this boot's is 1000).
local settings = {
    bspTreesBoot = 500,
    bspTrees = {
        ws1 = { split = "vertical", ratio = 0.3,
            a = { windowID = 11 },
            b = { split = "horizontal", ratio = 0.6, a = { windowID = 12 }, b = { windowID = 13 } } },
    },
    wmWorkspaces = {
        boot = 500,
        active = { DISPLAY = 1 },
        home = { ["1"] = "DISPLAY", ["2"] = "DISPLAY" },
        of = { ["11"] = 1, ["12"] = 1, ["13"] = 1, ["14"] = 2 },
        info = {
            ["11"] = { app = "term", title = "editor" },
            ["12"] = { app = "term", title = "shell" },
            ["13"] = { app = "browser", title = "docs" },
            ["14"] = { app = "term", title = "logs" },
        },
    },
}
hs = {
    execute = function() return "{ sec = 1000, usec = 0 }" end,
    settings = {
        get = function(key) return settings[key] end,
        set = function(key, value) settings[key] = value end,
    },
    json = { encode = function() return tostring({}) end },
    timer = { doAfter = function() return { stop = function() end } end },
    screen = { allScreens = function() return {} end },
}
package.loaded["wm.util"] = {}
package.loaded["wm.spaces"] = {}

local S = require("wm.state")
S.cfg = { tiling = { innerGap = 0, minRatio = 0.2, maxRatio = 0.8 } }
local Tree = require("wm.tree")
local Restore = require("wm.restore")

local function win(id, title)
    return { id = function() return id end, title = function() return title end }
end

assert(next(S.trees) == nil, "the old boot's trees aren't taken as this boot's")
assert(Restore.savedActive().DISPLAY == 1 and Restore.savedHome(2) == "DISPLAY")

-- The browser comes back first, then the terminal's windows with new
-- titles except one: that one matches by title, the rest in old-id order.
assert(Restore.match(win(103, "docs"), "browser") == 1)
assert(Restore.match(win(104, "logs"), "term") == 2, "an exact title wins")
assert(Restore.match(win(101, "zsh"), "term") == 1, "else the oldest unmatched window")
assert(Restore.match(win(105, "new"), "other") == nil, "unknown apps aren't matched")

-- Only 103 and 101 are open so far: the layout keeps their old places.
local valid = { [101] = true, [103] = true }
local tree = Restore.rebuild("ws1", nil, valid)
assert(tree.split == "vertical" and tree.ratio == 0.3)
assert(tree.a.windowID == 101 and tree.b.windowID == 103, "missing windows are left out")

-- 102 matches the last old window of its app and slots back in between;
-- a window that wasn't there before keeps a place too.
assert(Restore.match(win(102, "zsh"), "term") == 1)
valid[102], valid[200] = true, true
tree = Restore.rebuild("ws1", Tree.insertAt(tree, 103, 200), valid)
assert(tree.a.windowID == 101 and tree.b.split == "horizontal" and tree.b.ratio == 0.6)
assert(tree.b.a.windowID == 102, "the old place comes back")
assert(Tree.collectIDs(tree)[200], "windows that weren't there before stay")

-- Nothing new arrived: the tree is left as it is (the user's changes stay).
local same = Restore.rebuild("ws1", tree, valid)
assert(same == tree)

-- Time's up: nothing more is matched or rebuilt.
NOW = NOW + 200
assert(Restore.match(win(106, "editor"), "term") == nil)
assert(settings.wmRestore == nil, "the saved state is cleared")

print("Restore tests passed")
