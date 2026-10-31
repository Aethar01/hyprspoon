-- Plain Lua tests for group actions with the real shared tree model.
package.path = "./?.lua;" .. package.path
local settings = {}
local noop = function() end
hs = {
    execute = function() return "{ sec = 1000, usec = 0 }" end,
    settings = { get = function(k) return settings[k] end, set = function(k, v) settings[k] = v end },
    json = { encode = function() return tostring({}) end },
    timer = { doAfter = function() return { stop = noop } end },
    screen = { allScreens = function() return {} end },
    window = { list = function() return {} end },
}
local wins, parked, focus = {}, {}, nil
for id = 1, 8 do wins[id] = { id = function() return id end } end
package.loaded["hyprspoon.util"] = { windowFor = function(id) return wins[id] end,
    native = noop }
package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop, focus = function(w) focus = w:id() end }
package.loaded["hyprspoon.spaces"] = {
    workspaceOf = function() return 1 end,
    park = function(w) parked[w:id()] = true end,
    unpark = function(w) parked[w:id()] = nil end,
}
local S = require("hyprspoon.state")
S.cfg = { tiling = { minRatio = 0.2, maxRatio = 0.8 } }
S.autoFloat, S.applied = {}, {}
local Tree = require("hyprspoon.tree")
local Layout = { tileNow = noop, scheduleRetile = noop }
function Layout.showMember(leaf, id, key)
    local from = Tree.setShown(leaf, id)
    if from ~= id then Tree.kinds[leaf.kind].show(leaf, key, from, id) end
end
package.loaded["hyprspoon.layout"] = Layout
local Group = require("hyprspoon.group")
local function leaf(id) local _, l = Tree.findByID(id) return l end
S.trees.ws1 = Tree.insertBeside(Tree.leaf(1), 1, 2, "right")
Group.join(wins[1], wins[2])
assert(#Tree.leaves(S.trees.ws1) == 2, "only existing groups can be joined")
Group.toggle(wins[2])
assert(leaf(2).kind == "group" and #leaf(2).members == 1)
Group.join(wins[1], wins[2])
local group = leaf(1)
assert(group == leaf(2) and group.windowID == 1 and parked[2] and not parked[1])
Group.cycle(wins[1], group, "ws1", 1)
assert(group.windowID == 2 and parked[1] and not parked[2] and focus == 2)
Group.cycle(wins[2], group, "ws1", -1)
assert(group.windowID == 1 and parked[2])
Group.moveOut(wins[1], group, "ws1")
assert(leaf(1) ~= leaf(2) and leaf(2).kind == "group" and #leaf(2).members == 1)
assert(not parked[1] and not parked[2])
Group.join(wins[1], wins[2])
Group.toggle(wins[1])
assert(leaf(1).kind == nil and leaf(2).kind == nil and not parked[2])

-- A native set is one logical member and leaves intact.
local native = leaf(1)
Tree.addTab(native, 3, 1)
Group.toggle(wins[2])
Group.join(wins[1], wins[2])
group = leaf(1)
assert(#group.members == 3 and #Tree.tabsOf(group, 1) == 2)
assert(not S.setsAway[3], "joining consumes the detached source set")
local info = Group.info(1)
assert(#info.members == 2 and info.shown == 1 and info.key == "ws1")
Group.cycle(wins[1], group, "ws1", 1)
assert(group.windowID == 2, "cycling skips the current member's native tabs")
Group.cycle(wins[2], group, "ws1", -1)
Group.moveOut(wins[group.windowID], group, "ws1")
assert(leaf(1) == leaf(3) and leaf(1).kind == "native" and leaf(2).kind == "group")
Group.join(wins[leaf(1).windowID], wins[2])
Group.toggle(wins[leaf(1).windowID])
assert(leaf(1) == leaf(3) and leaf(1).kind == "native", "dissolving preserves native units")

-- Bar selection and insets don't change tile geometry or group membership.
Group.toggle(wins[2])
Group.join(wins[leaf(1).windowID], wins[2])
Group.selectMember(2)
Group.inset(2, 24)
assert(leaf(2).groupInset == 24 and focus == 2)

-- Save/reload retains member order, native units and selected window.
S.openIDs = { [1] = true, [2] = true, [3] = true }
Tree.saveTreesNow()
package.loaded["hyprspoon.tree"] = nil
Tree = require("hyprspoon.tree")
group = select(2, Tree.findByID(2))
assert(group.kind == "group" and group.windowID == 2 and #group.members == 3)
assert(#Tree.tabsOf(group, 1) == 2)
print("Group tests passed")
