-- Run with: lua tests/wm_regression.lua
-- Exercise the production helpers with deterministic accessibility/timer mocks.
local file = assert(io.open("wm.lua"))
local source = file:read("*a")
file:close()
assert(load(source))

local function extract(first, last)
    local start = assert(source:find(first, 1, true))
    local finish = assert(source:find(last, start, true))
    return source:sub(start, finish - 1)
end

local isPiP = assert(load(extract("local PIP_TITLES =", "-- Assigned in the tree section")
    .. "return isPictureInPicture"))()
for _, title in ipairs({"Picture-in-Picture", "Picture in Picture", "picture-in-picture", "PiP"}) do
    assert(isPiP({ title = function() return title end }), "dedicated PiP title must be excluded")
end
for _, title in ipairs({"How to use Picture-in-Picture - YouTube", "", "Picture-in-Picture settings"}) do
    assert(not isPiP({ title = function() return title end }), "ordinary windows must remain managed")
end

local queue, now = {}, 0
local function after(delay, fn)
    local timer = { fn = fn, delay = delay }
    function timer:stop() self.stopped = true end
    queue[#queue + 1] = timer
    return timer
end
local function tick()
    local timer = assert(table.remove(queue, 1), "expected timer")
    now = now + timer.delay
    if not timer.stopped then timer.fn() end
end
local function drain()
    local count = 0
    while #queue > 0 do
        count = count + 1
        assert(count < 20, "unbounded retries")
        tick()
    end
end

local env = setmetatable({
    bspAutoFloat = {}, bspSavedFloats = {}, bspFloatChecks = {},
    bspTilingEnabled = true, running = { windowFilter = {} },
    bspAppName = function() return "test" end,
    isPictureInPicture = isPiP,
    bspRememberFloat = function() end,
    scheduleBSPRetile = function() end,
    hs = { timer = { doAfter = after, secondsSinceEpoch = function() return now end } },
}, { __index = _G })
local answers, answer = {}, 0
env.hs.axuielement = { windowElement = function()
    return { isAttributeSettable = function()
        answer = answer + 1
        return answers[answer]
    end }
end }
local win = { id = function() return 1 end, screen = function() return nil end,
    title = function() return "test" end }
local shouldFloat = assert(load(extract("local function bspShouldFloat(win)",
    "-- Floating windows stay above" ) .. "return bspShouldFloat", "float", "t", env))()
local function classify(values)
    queue, answers, answer = {}, values, 0
    env.bspAutoFloat, env.bspFloatChecks = {}, {}
    assert(shouldFloat(win) == false)
    drain()
    return env.bspAutoFloat[1]
end
assert(classify({true}) == false, "resizable windows need no zoom button")
assert(classify({false, true}) == false, "startup false must not persist")
assert(classify({false, false, false}) == true, "confirmed fixed-size windows float")
assert(classify({}) == false, "unknown accessibility attributes must not float")
env.bspSavedFloats["1"] = { app = "test", float = true }
assert(classify({true}) == false, "old probe results must expire")
env.bspSavedFloats["1"] = { app = "test", float = true, version = 2, manual = true }
env.bspAutoFloat = {}
assert(shouldFloat(win) == true and #queue == 0, "manual override survives reload")

local appEnv = setmetatable({
    hs = env.hs, isPictureInPicture = isPiP,
}, { __index = _G })
local appWindows = assert(load(extract("local bspAppWindowCache = {}",
    "local function bspWithRecentlyChangedApps") .. "return bspAppWindows", "app windows", "t", appEnv))()
local pip = { id = function() return 99 end, title = function() return "Picture-in-Picture" end,
    isStandard = function() return true end, isVisible = function() return true end }
win.isStandard, win.isVisible = function() return true end, function() return true end
local recovered = appWindows(1, { allWindows = function() return { win, pip } end })
assert(#recovered == 1 and recovered[1] == win, "app-list recovery must not reintroduce PiP")

local target = { x = 10, y = 10, w = 800, h = 600 }
local actual, writes, accept = {}, 0, false
local screen = {}
win.screen = function() return screen end
win.frame = function() return actual end
win.isVisible = function() return true end
win.isFullScreen = function() return false end
win.setFrame = function(_, rect)
    writes = writes + 1
    if accept then actual = rect end
end
env.bspAutoFloat, env.bspApplied, env.bspLayoutChecks = {}, {}, {}
env.bspLastMouseTime, env.BSP_SETTLE = 0, 0.35
env.bspFindByID = function() return {}, { rect = target }, "screen:1" end
env.bspKeyForScreen = function() return "screen:1" end
env.hs.mouse = { getButtons = function() return {} end }
env.invalidateWindowCache, env.dlog = function() end, function() end
env.bspCancelLayoutCheck = function(id)
    local pending = env.bspLayoutChecks[id]
    if pending then pending.timer:stop() env.bspLayoutChecks[id] = nil end
end
local verify = assert(load(extract("local function bspFramesMatch(a, b)",
    "local function bspApplyTree(node") .. "return bspVerifyLayout", "layout", "t", env))()
local function reset()
    queue, writes, accept = {}, 0, false
    actual = { x = 0, y = 0, w = 100, h = 100 }
    env.bspApplied, env.bspLayoutChecks = {}, {}
    env.bspLastMouseTime = 0
end
reset()
verify(win, target, "target")
tick()
assert(writes == 1 and env.bspApplied[1] == nil, "unobserved resize must not be cached")
accept = true
drain()
assert(writes == 2 and env.bspApplied[1] == "target", "late resize should be verified")
reset()
verify(win, target, "target")
drain()
assert(writes == 2 and env.bspApplied[1] == nil, "ignored resizes have bounded retries")
reset()
verify(win, target, "target")
env.bspLastMouseTime = now + 0.01
drain()
assert(writes == 0, "mouse interaction cancels retries")
reset()
verify(win, target, "target")
env.bspFindByID = function() return nil end
drain()
assert(writes == 0, "removed tiles must not be resized")
reset()
env.bspFindByID = function() return {}, { rect = target }, "screen:1" end
actual = target
local oldScreen = win.screen
win.screen = function() error("matching frames must not query the screen") end
verify(win, target, "target")
drain()
assert(env.bspApplied[1] == "target")
win.screen = oldScreen

-- Snapshot fast path avoids querying WindowServer for disjoint tiles;
-- overlapping/floating windows retain real front-to-back order.
local second = { id = function() return 2 end }
local tiles = { [1] = target, [2] = { x = 820, y = 10, w = 800, h = 600 } }
local listCalls = 0
env.ffmSnapshot, env.FFM_SNAPSHOT_TTL = nil, 1
env.running.windowFilter = { getWindows = function() return { win, second } end }
env.bspRectFor = function(id) return tiles[id] end
env.hs.geometry = { rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end }
env.hs.window = { list = function()
    listCalls = listCalls + 1
    return {
        { kCGWindowNumber = 2, kCGWindowBounds = { X = 20, Y = 30, Width = 400, Height = 300 } },
        { kCGWindowNumber = 1, kCGWindowBounds = { X = 10, Y = 10, Width = 800, Height = 600 } },
    }
end }
local snapshot = assert(load(extract("local function windowSnapshot(fresh)",
    "ffmPrebuild = hs.timer.delayed.new") .. "return windowSnapshot", "snapshot", "t", env))()
assert(#snapshot(true) == 2 and listCalls == 0, "disjoint tiles need no WindowServer query")
tiles[2] = target
local entries = snapshot(true)
assert(entries[1].id == 2 and listCalls == 1, "overlapping tiles need stacking order")
tiles[2], env.bspAutoFloat[2] = nil, true
entries = snapshot(true)
assert(entries[1].id == 2 and entries[1].frame.x == 20, "floats use live geometry")
snapshot()
assert(listCalls == 2, "cached snapshots need no WindowServer query")
env.running.pipFilter = { getWindows = function()
    return {{ frame = function() return { x = 50, y = 50, w = 100, h = 100 } end }}
end }
env.windowSnapshot = snapshot
env.pointInFrame = function(p, f)
    return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
end
local entryAt = assert(load(extract("local function snapshotEntryAt(point, fresh)",
    "local function windowUnderPoint") .. "return snapshotEntryAt", "occlusion", "t", env))()
assert(entryAt({ x = 60, y = 60 }, true) == nil, "PiP must block hover focus of underlying windows")
assert(entryAt({ x = 25, y = 35 }) ~= nil, "hover outside PiP must still work")

-- BSP navigation returns to the last-used leaf in the adjacent subtree.
local nav = setmetatable({}, { __index = _G })
nav.nearestInDirection = assert(load(extract("local function nearestInDirection(f, selfID",
    "-- Every tile in a tree") .. "return nearestInDirection", "nearest", "t", nav))()
local top = { windowID = 10, rect = { x = 0, y = 0, w = 400, h = 300 } }
local bottom = { windowID = 11, rect = { x = 0, y = 310, w = 400, h = 300 } }
local right = { windowID = 12, rect = { x = 410, y = 0, w = 400, h = 610 } }
local left = { split = "horizontal", a = top, b = bottom }
local root = { split = "vertical", a = left, b = right }
local windows = {}
for _, leaf in ipairs({top, bottom, right}) do
    windows[leaf.windowID] = { id = function() return leaf.windowID end,
        frame = function() return leaf.rect end }
end
nav.bspIsLeaf = function(node) return node.windowID ~= nil end
nav.bspWinByID, nav.bspTrees, nav.bspTilingEnabled = windows, { main = root }, true
nav.bspTiles = assert(load(extract("local function bspTiles(node, out)",
    "-- For a tiled window") .. "return bspTiles", "tiles", "t", nav))()
nav.bspFindByID = function(id)
    if id == 12 then return {{ node = root, branch = "b" }}, right, "main" end
    return {{ node = left, branch = id == 10 and "a" or "b" }, { node = root, branch = "a" }},
        id == 10 and top or bottom, "main"
end
nav.windowSnapshot = function() return {} end
local neighbour = assert(load(extract("local function neighbourInDirection(win, direction",
    "local function directionalCandidates") .. "return neighbourInDirection", "navigation", "t", nav))()
nav.bspFocusHistory = {12, 11, 10}
assert(neighbour(windows[12], "left", true) == windows[11], "return to bottom-left")
nav.bspFocusHistory = {12, 10, 11}
assert(neighbour(windows[12], "left", true) == windows[10], "return to top-left when it was last used")
assert(neighbour(windows[11], "right", true) == windows[12], "left-bottom to right")
assert(neighbour(windows[11], "up", true) == windows[10], "nearest ancestor chooses upper sibling")
nav.bspFocusHistory = {}
assert(neighbour(windows[12], "left", true) ~= nil, "missing history falls back to geometry")

local checks = 0
env.bspTileNow = function() checks = checks + 1 end
local recheck = assert(load(extract("local bspRecheckTimer = nil",
    "local function bspRestoreFloatingFrames") .. "return bspScheduleRecheck", "discovery", "t", env))()
recheck()
drain()
assert(checks == 3, "discovery retries must continue without a layout change")
print("Window classification, layout, snapshots, discovery, PiP, and BSP navigation regressions passed")
