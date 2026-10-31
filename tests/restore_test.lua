-- Run with: lua tests/restore_test.lua
-- Unit tests for hyprspoon/restore.lua: matching windows after a restart and
-- rebuilding their layout, with a stubbed `hs` holding the last boot's state.
package.path = "./?.lua;" .. package.path

local NOW = 1000000
os.time = function() return NOW end

-- Saved by the boot before (kern.boottime 500; this boot's is 1000).
local settings = {
    ["hyprspoon.treesBoot"] = 500,
    ["hyprspoon.pseudoAway"] = { ["14"] = { w = 300, h = 200 } },
    ["hyprspoon.trees"] = {
        ws1 = { split = "vertical", ratio = 0.3,
            a = { windowID = 11 },
            b = { split = "horizontal", ratio = 0.6, a = { windowID = 12 }, b = { windowID = 13 } } },
        -- A group beside a tile; 33 and 34 are one window's native tabs.
        ws3 = { split = "vertical", ratio = 0.5,
            a = { windowID = 31 },
            b = { windowID = 32, members = { 32, 33, 34 }, kind = "group", tabs = { { 33, 34 } } } },
        ws4 = { windowID = 41, members = { 41, 42 }, kind = "native" },
        ws5 = { split = "vertical", ratio = 0.5,
            a = { windowID = 51, members = { 51, 52 }, kind = "group" },
            b = { windowID = 53 } },
    },
    ["hyprspoon.workspaces"] = {
        boot = 500,
        active = { DISPLAY = 1 },
        home = { ["1"] = "DISPLAY", ["2"] = "DISPLAY" },
        of = { ["11"] = 1, ["12"] = 1, ["13"] = 1, ["14"] = 2, ["31"] = 3, ["32"] = 3, ["33"] = 3,
            ["34"] = 3, ["41"] = 4, ["42"] = 4, ["51"] = 5, ["52"] = 5, ["53"] = 5 },
        info = {
            ["11"] = { app = "term", title = "editor" },
            ["12"] = { app = "term", title = "shell" },
            ["13"] = { app = "browser", title = "docs" },
            ["14"] = { app = "term", title = "logs" },
            ["31"] = { app = "mail", title = "a" },
            ["32"] = { app = "mail", title = "b" },
            ["33"] = { app = "mail", title = "c" },
            ["34"] = { app = "mail", title = "d" },
            ["41"] = { app = "notes", title = "n1" },
            ["42"] = { app = "notes", title = "n2" },
            ["51"] = { app = "chat", title = "x" },
            ["52"] = { app = "chat", title = "y" },
            ["53"] = { app = "chat", title = "z" },
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
package.loaded["hyprspoon.util"] = {}
package.loaded["hyprspoon.spaces"] = {}

local S = require("hyprspoon.state")
S.cfg = { tiling = { innerGap = 0, minRatio = 0.2, maxRatio = 0.8 } }
local Tree = require("hyprspoon.tree")
local Restore = require("hyprspoon.restore")

local function win(id, title)
    return { id = function() return id end, title = function() return title end }
end

assert(next(S.trees) == nil, "the old boot's trees aren't taken as this boot's")
assert(Restore.savedActive().DISPLAY == 1)

-- The browser comes back first, then the terminal's windows with new
-- titles except one: that one matches by title, the rest in old-id order.
assert(Restore.match(win(103, "docs"), "browser") == 1)
assert(Restore.match(win(104, "logs"), "term") == 2, "an exact title wins")
assert(S.pseudoAway[14] == nil, "old boot's IDs aren't reused")
package.loaded["hyprspoon.restore"] = nil
Restore = require("hyprspoon.restore")
local floated = Tree.leaf(104)
assert(floated.pseudo and floated.pseudo.w == 300 and floated.pseudo.h == 200,
    "a matched floating window keeps its pseudotile size, including across grace-period reloads")
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

-- A set comes back with the members that are back, in their old order,
-- showing the first of them until the one it showed is back too.
assert(Restore.match(win(131, "a"), "mail") == 3)
assert(Restore.match(win(134, "d"), "mail") == 3)
assert(Restore.match(win(133, "c"), "mail") == 3)
valid = { [131] = true, [133] = true, [134] = true }
tree = Restore.rebuild("ws3", nil, valid)
local set = tree.b
assert(tree.a.windowID == 131 and set.windowID == 133 and set.kind == "group")
assert(#set.members == 2 and set.members[1] == 133 and set.members[2] == 134)
assert(#set.tabs == 1 and set.tabs[1][1] == 133 and set.tabs[1][2] == 134, "its native tabs too")
assert(Restore.match(win(132, "b"), "mail") == 3)
valid[132] = true
tree = Restore.rebuild("ws3", tree, valid)
set = tree.b
assert(set.windowID == 132 and #set.members == 3 and set.members[1] == 132, "the one it showed shows")

-- A native set with one tab back is just a tile.
assert(Restore.match(win(141, "n1"), "notes") == 4)
tree = Restore.rebuild("ws4", nil, { [141] = true })
assert(tree.windowID == 141 and tree.members == nil and tree.kind == nil)

-- Members hidden since (parked by their group) stay in it as more windows
-- come back, and a set made meanwhile goes back in whole.
local function leafOf(t, id)
    local _, found = Tree.ancestors(t, id)
    return found
end
assert(Restore.match(win(151, "x"), "chat") == 5)
assert(Restore.match(win(152, "y"), "chat") == 5)
tree = Restore.rebuild("ws5", nil, { [151] = true, [152] = true })
assert(tree.windowID == 151 and #tree.members == 2)
local made = Tree.leaf(160)
made.members, made.kind = { 160, 161 }, "group"
tree = { split = "vertical", ratio = 0.5, a = tree, b = made }
assert(Restore.match(win(153, "z"), "chat") == 5)
tree = Restore.rebuild("ws5", tree, { [151] = true, [153] = true, [160] = true })
local group = leafOf(tree, 152)
assert(group.windowID == 151 and #group.members == 2 and group.members[2] == 152, "152 stays hidden in it")
assert(leafOf(tree, 153).windowID == 153 and leafOf(tree, 153) ~= group)
local again = leafOf(tree, 161)
assert(again.windowID == 160 and #again.members == 2 and again.kind == "group", "the new set stays whole")
assert(#Tree.leaves(tree) == 3, "no tile of its own for a hidden member")

-- Time's up: nothing more is matched or rebuilt.
NOW = NOW + 200
assert(Restore.match(win(106, "editor"), "term") == nil)
assert(settings["hyprspoon.restore"] == nil, "the saved state is cleared")

print("Restore tests passed")
