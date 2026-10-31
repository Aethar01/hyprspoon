-- Run with: lua tests/tabs_test.lua
-- Unit tests for hyprspoon/tabs.lua: how native tabs are told apart from
-- separate windows, and how a tile is handed from a closed tab to the next.
-- Everything is plain tables; no Hammerspoon and no other module is loaded.
-- They pin down today's behaviour, quirks included.
package.path = "./?.lua;" .. package.path

local Tabs = require("hyprspoon.tabs")

local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
end

local APP, OTHER = 100, 200
local FRAME = { x = 10, y = 10, w = 800, h = 600 }

-- A window as Discover gathers it, plus the accessibility facts the rules
-- ask for on demand: `frame`, and `listed` (the app's own list holds it).
local function win(id, fields)
    local w = { id = id, pid = APP, frame = FRAME, listed = false, tiled = false, inTree = false }
    for k, v in pairs(fields or {}) do w[k] = v end
    return w
end

-- Runs Tabs.background over `windows`, counting the accessibility calls.
local function background(windows)
    local calls = { frames = 0, lists = 0 }
    local result = Tabs.background(windows,
        function(w) calls.frames = calls.frames + 1 return w.frame end,
        function(pid)
            calls.lists = calls.lists + 1
            local set = {}
            for _, w in ipairs(windows) do
                if w.pid == pid and w.listed then set[w.id] = true end
            end
            return set
        end)
    return result, calls
end

local function ids(set)
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return table.concat(out, ",")
end

test("a window alone is never a background tab", function()
    local bg = background({ win(1) })
    assert(ids(bg) == "")
    -- Even unlisted: the app's list lags behind events.
    bg = background({ win(1, { listed = false, tiled = true, inTree = true }) })
    assert(ids(bg) == "")
end)

test("opening a tab: the new tab is live, the old one goes to the background", function()
    -- Tab 1 holds the tile; the app lists only the tab now showing.
    local bg = background({
        win(1, { tiled = true, inTree = true }),
        win(2, { listed = true }),
    })
    assert(ids(bg) == "1", ids(bg))
end)

test("opening a tab before the app lists it: the tiled window stays live", function()
    -- Neither is listed yet, so the one already tiled wins over the new one.
    local bg = background({
        win(1, { tiled = true, inTree = true }),
        win(2),
    })
    assert(ids(bg) == "2", ids(bg))
end)

test("with none tiled or listed, the oldest window is the live one", function()
    local bg = background({ win(7), win(3), win(5) })
    assert(ids(bg) == "5,7", ids(bg))
end)

test("switching tabs: the tab the app lists is live, the tiled one is not", function()
    -- Tab 2 was in the background and is now shown; tab 1 still holds the tile.
    local bg = background({
        win(1, { tiled = true, inTree = true }),
        win(2, { listed = true }),
        win(3),
    })
    assert(ids(bg) == "1,3", ids(bg))
    -- Switching back swaps them again.
    bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { inTree = true }),
        win(3),
    })
    assert(ids(bg) == "2,3", ids(bg))
end)

test("closing the shown tab: the survivor alone at the frame is live, listed or not", function()
    -- Tab 1 is gone from the window list; tab 2 hasn't been listed yet.
    local bg, calls = background({ win(2) })
    assert(ids(bg) == "")
    assert(calls.frames == 0 and calls.lists == 0, "a lone window needs no app queries")
    -- While the closed tab still lingers in the filter, the listed one wins.
    bg = background({ win(1, { tiled = true, inTree = true }), win(2, { listed = true }) })
    assert(ids(bg) == "1", ids(bg))
end)

test("closing a background tab changes nothing for the tabs left", function()
    local before = background({
        win(1, { tiled = true, inTree = true, listed = true }), win(2), win(3),
    })
    assert(ids(before) == "2,3", ids(before))
    local after = background({
        win(1, { tiled = true, inTree = true, listed = true }), win(2),
    })
    assert(ids(after) == "2", ids(after))
end)

test("tearing a tab off: a window at its own frame is live", function()
    -- Tab 2 dragged out lands elsewhere; the rest stay together.
    local bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { frame = { x = 400, y = 300, w = 800, h = 600 } }),
        win(3),
    })
    assert(ids(bg) == "3", ids(bg))
    -- With only two tabs, neither shares a frame with the other any more.
    bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { frame = { x = 400, y = 300, w = 800, h = 600 } }),
    })
    assert(ids(bg) == "")
end)

test("tearing off the shown tab leaves the survivor live at the tile's frame", function()
    local bg = background({
        win(1, { tiled = true, inTree = true, listed = true, frame = { x = 400, y = 300, w = 800, h = 600 } }),
        win(2, { listed = true }),
    })
    assert(ids(bg) == "")
end)

test("frames are compared rounded to whole pixels", function()
    local bg = background({
        win(1, { tiled = true, inTree = true, listed = true, frame = { x = 10.2, y = 9.8, w = 800.4, h = 599.6 } }),
        win(2, { frame = FRAME }),
    })
    assert(ids(bg) == "2", ids(bg))
    -- A whole pixel apart is a separate window.
    bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { frame = { x = 11, y = 10, w = 800, h = 600 } }),
    })
    assert(ids(bg) == "")
end)

test("Merge All Windows: windows that still hold their own tiles are not touched", function()
    -- All three have merged into one frame, but every one still has a tile
    -- until the next reconcile prunes them, so none is called a background
    -- tab and the app isn't even asked for frames.
    local bg, calls = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { tiled = true, inTree = true }),
        win(3, { tiled = true, inTree = true }),
    })
    assert(ids(bg) == "")
    assert(calls.frames == 0 and calls.lists == 0)
end)

test("Merge All Windows: with an untiled window among them, the unlisted tabs go to the background", function()
    local bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { tiled = true, inTree = true }),
        win(3),
    })
    assert(ids(bg) == "2,3", ids(bg))
end)

test("Ghostty: separate windows at the same frame, all listed, are all live", function()
    local bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { listed = true }),
        win(3, { listed = true }),
    })
    assert(ids(bg) == "")
end)

test("Ghostty: a new window the app hasn't listed yet is held back until it is", function()
    local bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2),
    })
    assert(ids(bg) == "2", ids(bg))
    bg = background({
        win(1, { tiled = true, inTree = true, listed = true }),
        win(2, { listed = true }),
    })
    assert(ids(bg) == "")
end)

test("windows of different apps at one frame are not tabs of each other", function()
    local bg = background({
        win(1, { tiled = true, inTree = true }),
        win(2, { pid = OTHER }),
    })
    assert(ids(bg) == "")
end)

test("each app is judged and asked on its own", function()
    local bg, calls = background({
        win(1, { tiled = true, inTree = true, listed = true }), win(2),
        win(3, { pid = OTHER, tiled = true, inTree = true }),
        win(4, { pid = OTHER, tiled = true, inTree = true }),
        win(5, { pid = 300, frame = { x = 0, y = 0, w = 50, h = 50 } }),
    })
    assert(ids(bg) == "2", ids(bg))
    -- One list query for the one app with a shared frame.
    assert(calls.lists == 1, calls.lists)
end)

-- Tile handoff. A tile is a rect; candidates are { id =, pid = } with a frame
-- looked up by `frames[id]`.
local TILE = { x = 0, y = 0, w = 400, h = 600 }
local TILE_FRAME = { x = 0, y = 0, w = 400, h = 600 }
local frames = {}
local function candidate(id, frame, pid)
    frames[id] = frame or TILE_FRAME
    return { id = id, pid = pid or APP }
end
local function frameOf(c) return frames[c.id] end
local function successor(oldPid, rect, candidates, known, visit)
    local c = Tabs.successor(oldPid, rect, candidates, known, frameOf, visit)
    return c and c.id
end

test("opening a tab: the new tab takes the tile of the one it replaced", function()
    -- Tab 1 held the tile and is now a background tab (a ghost); tab 2 is
    -- the live window at the same frame.
    local known = { [1] = true }
    assert(successor(APP, TILE, { candidate(2) }, known) == 2)
end)

test("switching tabs: the tab now showing takes the tile, the other tab is a ghost", function()
    local known = { [1] = true }
    assert(successor(APP, TILE, { candidate(2), candidate(1) }, known) == 2)
end)

test("closing the shown tab: the survivor takes the tile", function()
    local known = { [1] = true }
    assert(successor(APP, TILE, { candidate(2) }, known) == 2)
end)

test("a ghost can take the tile while the app's list lags", function()
    -- Candidates are the present windows then the ghosts; the survivor is
    -- still counted as a background tab.
    local known = { [1] = true }
    assert(successor(APP, TILE, { candidate(5, { x = 900, y = 0, w = 400, h = 600 }), candidate(2) }, known) == 2)
end)

test("closing a background tab hands nothing over: nothing tiled vanished", function()
    -- Only tiled windows that vanish look for a successor; with none, there
    -- are no calls. A candidate with no vanished tile to take is just a window.
    local calls = 0
    local function frame(c) calls = calls + 1 return c.frame end
    assert(Tabs.successor(APP, TILE, {}, { [1] = true }, frame) == nil)
    assert(calls == 0)
end)

test("tearing a tab off: the new window outside the tile is not a successor", function()
    local known = { [1] = true }
    local torn = candidate(2, { x = 500, y = 300, w = 400, h = 300 })
    assert(successor(APP, TILE, { torn }, known) == nil)
end)

test("Merge All Windows: tabs that were tiled already are not successors of each other", function()
    -- Tiles 2 and 3 vanish into the merged window 1, which already holds its
    -- own tile; every candidate is known, so no tile is handed over.
    local known = { [1] = true, [2] = true, [3] = true }
    local cands = { candidate(1), candidate(2), candidate(3) }
    assert(successor(APP, TILE, cands, known) == nil)
end)

test("Ghostty: another window of the app centred in the tile takes it over", function()
    -- Pins today's behaviour: a window that closes and a new one opening at
    -- the same frame can't be told from a tab swap.
    local known = { [1] = true }
    assert(successor(APP, TILE, { candidate(2, { x = 50, y = 50, w = 300, h = 500 }) }, known) == 2)
end)

test("a window of another app never takes the tile", function()
    local known = { [1] = true }
    local c = candidate(2, nil, OTHER)
    local asked = false
    assert(Tabs.successor(APP, TILE, { c }, known, function() asked = true end) == nil)
    assert(not asked, "frames are only read for the same app")
    -- Nor does an unknown pid (a window never seen before) match one.
    assert(successor(nil, TILE, { candidate(3) }, known) == nil)
end)

test("a window the tree already knew never takes the tile", function()
    assert(successor(APP, TILE, { candidate(2) }, { [1] = true, [2] = true }) == nil)
end)

test("the centre decides, not the whole frame", function()
    local known = {}
    -- Bigger than the tile, with its centre inside.
    assert(successor(APP, TILE, { candidate(2, { x = -100, y = -100, w = 600, h = 800 }) }, known) == 2)
    -- Centre just outside the right edge (the edge itself is outside).
    assert(successor(APP, TILE, { candidate(3, { x = 300, y = 0, w = 200, h = 600 }) }, known) == nil)
    -- Centre on the left edge is inside.
    assert(successor(APP, TILE, { candidate(4, { x = -100, y = 0, w = 200, h = 600 }) }, known) == 4)
end)

test("the first candidate in order takes the tile", function()
    local known = {}
    assert(successor(APP, TILE, { candidate(4), candidate(2) }, known) == 4)
end)

test("two vanished tiles of an app don't take the same window", function()
    -- Reconcile adds each successor to `known` before the next vanished tile
    -- looks, so a second tab swap in one pass finds the next window.
    local known = { [1] = true, [9] = true }
    local cands = { candidate(2), candidate(3) }
    local first = Tabs.successor(APP, TILE, cands, known, frameOf)
    assert(first.id == 2)
    known[first.id] = true
    assert(successor(APP, TILE, cands, known) == 3)
end)

test("visit is told of each same-app candidate looked at, with its frame", function()
    local seen = {}
    local known = { [1] = true }
    local cands = { candidate(5, { x = 900, y = 0, w = 10, h = 10 }), candidate(6, nil, OTHER), candidate(2) }
    successor(APP, TILE, cands, known, function(c, f) seen[#seen + 1] = c.id .. ":" .. f.x end)
    assert(table.concat(seen, ",") == "5:900,2:0", table.concat(seen, ","))
end)

test("centredIn uses a half-open rect like the pointer test", function()
    assert(Tabs.centredIn({ x = 0, y = 0, w = 10, h = 10 }, { x = 0, y = 0, w = 10, h = 10 }))
    assert(not Tabs.centredIn({ x = 10, y = 0, w = 0, h = 10 }, { x = 0, y = 0, w = 10, h = 10 }))
end)
