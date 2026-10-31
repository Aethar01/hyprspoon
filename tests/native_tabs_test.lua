-- Discovery integration: app lists repair stale/missing filter windows.
package.path = "./?.lua;" .. package.path
local S = { cfg = { ignoreApps = {} }, trees = {}, setsAway = {}, autoFloat = {} }
local leaves, filter, listed, states, bars = {}, {}, {}, {}, {}
local repairs, presses, remembered = 0, {}, {}
local function win(id)
    return {
        id = function() return id end, pid = function() return 100 end,
        title = function() return "window " .. id end,
        isStandard = function() return true end, isVisible = function() return true end,
        isMinimized = function() return false end, isFullScreen = function() return false end,
        screen = function() return { getUUID = function() return "display" end } end,
        frame = function() return { x = id * 100, y = 0, w = 100, h = 100 } end,
    }
end
local wins = { win(1), win(2), win(3) }
local app = { allWindows = function() return listed end, name = function() return "Test" end,
    bundleID = function() return "test.app" end }
local native = {
    tabState = function() return states end,
    tabButtons = function(_, id, delta)
        if delta then presses[#presses + 1] = { id, delta } end
        return bars[id] or {}
    end,
    tabWindows = function() repairs = repairs + 1 return { [4] = "verified" } end,
}
local function find(id)
    for _, leaf in ipairs(leaves) do
        for _, member in ipairs(leaf.members or { leaf.windowID }) do
            if member == id then return nil, leaf, "ws1" end
        end
    end
end
local Tree = {
    kinds = {}, findByID = find, saveTrees = function() end,
    rectFor = function(id) local _, leaf = find(id) return leaf and leaf.rect end,
    forget = function() end,
    removeID = function(tree, id)
        for i, leaf in ipairs(leaves) do
            if leaf.windowID == id then table.remove(leaves, i) break end
        end
        return tree
    end,
    addMember = function(leaf, id)
        if S.setsAway[leaf.windowID] then S.setsAway[id] = leaf end
        leaf.members, leaf.kind = leaf.members or { leaf.windowID }, "native"
        leaf.members[#leaf.members + 1] = id
    end,
    setOf = function(id) local _, leaf = find(id) return leaf and leaf.members and leaf end,
}
-- Lua locals aren't in scope in their own initializer.
Tree.registerKind = function(kind, handler) Tree.kinds[kind] = handler end
package.loaded["hyprspoon.state"] = S
package.loaded["hyprspoon.tree"] = Tree
package.loaded["hyprspoon.util"] = {
    native = function() return native end, managedWindows = function() return filter end,
    isPictureInPicture = function() return false end,
}
package.loaded["hyprspoon.float"] = { shouldFloat = function() return false end }
package.loaded["hyprspoon.spaces"] = {
    isHidden = function() return false end, claim = function() return "display" end,
    nativeMember = function(id, shown) remembered[id] = shown end,
}
package.loaded["hyprspoon.border"] = { sync = function() end }
hs = { application = { applicationForPID = function() return app end },
    timer = { secondsSinceEpoch = function() return 1000 end,
        doAfter = function() return { stop = function() end } end } }
local Discover = require("hyprspoon.discover")
leaves = { { windowID = 1 }, { windowID = 2 }, { windowID = 3 } }
filter, listed = wins, { wins[1], wins[3] }
states, bars = { [1] = "shown", [2] = "tab", [3] = "shown" }, { [1] = { "one", "two" } }
local byScreen = Discover.windowsByScreen()
assert(#byScreen.display == 2 and S.openIDs[2])
assert(#leaves == 2 and leaves[1].kind == "native" and leaves[1].members[2] == 2)
assert(remembered[2] == 1 and repairs == 0, "a known standard window needs no AX scan")

-- A never-shown tab is confirmed by AX; the helper with no Space isn't.
states[4], states[5], bars[1] = "tab", "tab", { "one", "two", "verified" }
Discover.windowsByScreen()
assert(repairs == 1 and S.nativeBackground[4] and not S.nativeBackground[5])
assert(leaves[1].members[3] == 4)
Discover.windowsByScreen()
assert(repairs == 1, "a matched count doesn't rescan accessibility")

-- Tear-off: the app lists 2 even though the filter has lost it.
filter, listed = { wins[1], wins[3] }, wins
states[2], states[4], bars[1] = "shown", nil, {}
byScreen = Discover.windowsByScreen()
assert(#byScreen.display == 3, "the torn-off window comes from the app list")
assert(not S.nativeBackground[2])

Tree.kinds.native.cycle(wins[1], leaves[1], "ws1", -1)
assert(presses[1][1] == 1 and presses[1][2] == -1)
Discover.stop()

-- A floating set can be discovered without ever having a tiled leaf.
leaves, S.setsAway, S.autoFloat = {}, {}, { [1] = true, [2] = true }
package.loaded["hyprspoon.float"].shouldFloat = function(w) return S.autoFloat[w:id()] end
filter, listed = { wins[1], wins[2] }, { wins[1] }
states, bars = { [1] = "shown", [2] = "tab" }, { [1] = { "one", "two" } }
Discover.windowsByScreen()
assert(S.setsAway[1] == S.setsAway[2] and S.setsAway[1].kind == "native")
assert(#S.setsAway[1].members == 2)
