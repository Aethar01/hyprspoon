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
    layoutScale = function() return nil end,
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

-- A cached background tab is not the selected tab of a native unit.
hs.window.list = function() return { { kCGWindowNumber = 3 } } end
Group.cycle(wins[2], leaf(2), "ws1", 1)
assert(leaf(2).windowID == 3 and focus == 3, "cycle picks the on-screen native tab")
Group.cycle(wins[3], leaf(3), "ws1", 1)
hs.window.list = function() return {} end
local selection = Group.info(2)
for i, list in ipairs(selection.members) do
    if #list == 2 then assert(selection.selected[i] == 3, "bar gets the remembered native tab") end
end
Group.cycle(wins[2], leaf(2), "ws1", -1)
assert(leaf(2).windowID == 3, "cycle remembers the unit when its windows are parked")
Group.selectMember(2)

-- A tile on another workspace (a drop onto another display) can join; it
-- takes the group's workspace. A group with tiling off can't be joined.
local adopted = {}
package.loaded["hyprspoon.spaces"].adopt = function(ids, key) adopted[ids[1]] = key end
S.trees.ws2 = Tree.leaf(5)
S.trees.ws3 = Tree.leaf(6)
assert(Group.join(wins[5], wins[2]) == true and adopted[5] == "ws1")
assert(leaf(5) == leaf(2) and leaf(2).windowID == 5 and S.trees.ws2 == nil and focus == 5)
Group.toggle(wins[6])
S.untiled.ws3 = true
assert(Group.join(wins[2], wins[6]) == false and leaf(2) == leaf(5), "untiled groups are left alone")
S.untiled.ws3 = nil
-- Back as it was for the reload test below.
Group.moveOut(wins[5], leaf(5), "ws1")
S.trees.ws1 = Tree.removeID(S.trees.ws1, 5)
S.trees.ws3, S.setsAway[5] = nil, nil
Group.selectMember(2)

-- The bar's order is the members' order; native tabs move together.
S.trees.ws4 = Tree.insertBeside(Tree.insertBeside(Tree.leaf(5), 5, 6, "right"), 6, 7, "right")
Group.toggle(wins[5])
Group.join(wins[6], wins[5])
Group.join(wins[7], wins[5])
local g = leaf(5)
local function order() return table.concat(g.members, ",") end
assert(order() == "5,6,7" and g.windowID == 7)
Group.moveBy(wins[7], g, "ws4", -1)
assert(order() == "5,7,6" and g.windowID == 7, "moving keeps it on show")
Group.moveBy(wins[7], g, "ws4", 1)
Group.moveBy(wins[7], g, "ws4", 1)
assert(order() == "5,6,7", "it stops at the end")
assert(Group.moveTo(5, 4) and order() == "6,7,5", "a gap past the end puts it last")
assert(not Group.moveTo(5, 3), "the gaps beside it leave it be")
assert(Group.moveTo(5, 1) and order() == "5,6,7")
Tree.addTab(g, 8, 6)
assert(order() == "5,6,8,7")
assert(Group.moveTo(8, 1) and order() == "6,8,5,7", "native tabs move as one member")
-- Splitting a member out beside a tile, even its own group's.
assert(Group.split(wins[5], wins[7], "left") and leaf(5) ~= g and not leaf(5).kind)
assert(select(3, Tree.findByID(5)) == "ws4" and not parked[5] and focus == 5)
assert(Group.split(wins[7], wins[7], "right") and leaf(7) ~= g, "the shown member can leave too")
assert(g.windowID == 6 and not parked[6] and not parked[7])
-- Joining at a gap of the bar.
assert(Group.join(wins[7], wins[6], 1) and order() == "7,6,8" and g.windowID == 7)
assert(not Group.split(wins[5], wins[6], "left"), "only group members split out")
S.trees.ws4 = nil
for id = 5, 8 do S.setsAway[id] = nil end

-- Save/reload retains member order, native units and selected window.
S.openIDs = { [1] = true, [2] = true, [3] = true }
Tree.saveTreesNow()
package.loaded["hyprspoon.tree"] = nil
Tree = require("hyprspoon.tree")
group = select(2, Tree.findByID(2))
assert(group.kind == "group" and group.windowID == 2 and #group.members == 3)
assert(#Tree.tabsOf(group, 1) == 2)
print("Group tests passed")
