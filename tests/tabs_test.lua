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
