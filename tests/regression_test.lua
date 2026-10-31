-- Run with: lua tests/regression_test.lua
-- Exercise the production helpers with deterministic accessibility/timer mocks.
local sources = {}
local function read(name)
    if not sources[name] then
        local file = assert(io.open("hyprspoon/" .. name .. ".lua"))
        sources[name] = file:read("*a")
        file:close()
        assert(load(sources[name]))
    end
    return sources[name]
end

-- Snippet of hyprspoon/<name>.lua from the line starting `first` up to `last`.
local function extract(name, first, last)
    local source = read(name)
    local start = assert(source:find(first, 1, true))
    local finish = assert(source:find(last, start, true))
    return source:sub(start, finish - 1)
end

local isPiP = assert(load(extract("util", "local PIP_TITLES =", "local MANAGED_ROLES =")
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

-- Stand-ins for the wm modules the snippets refer to (S, Util, Tree, ...).
local S = { autoFloat = {}, tilingEnabled = true, running = { windowFilter = {} },
    applied = {}, settleUntil = 0, lastMouseTime = 0 }
local rules = {}
local Util = { isPictureInPicture = isPiP, windowKind = function() return "standard" end,
    rulesFor = function() return rules end,
    dlog = function() end, setFrame = function(win, rect, duration) win:setFrame(rect, duration) end }
local Tree = {}
local Focus = { invalidateWindowCache = function() end }
local Discover = { layoutChecks = {} }
local hiddenIDs = {}
local Spaces = { isHidden = function(id) return hiddenIDs[id] == true end }
local env = setmetatable({
    S = S, Util = Util, Tree = Tree, Focus = Focus, Discover = Discover, Spaces = Spaces,
    Ffm = { snapshotBuilt = function() end },
    hs = { timer = { doAfter = after, secondsSinceEpoch = function() return now end } },
}, { __index = _G })
local fullScreen, axReads = nil, 0
env.hs.axuielement = { windowElement = function()
    axReads = axReads + 1
    return { isAttributeSettable = function(_, name)
        assert(name == "AXFullScreen", "only full-screen support decides floating")
        return fullScreen
    end }
end }
local title = "test"
local win = { id = function() return 1 end, screen = function() return nil end,
    title = function() return title end,
    application = function() return { name = function() return "test" end } end }
-- savedFloats is a file-local in hyprspoon/float.lua; provide it with a setter.
local shouldFloat, setSavedFloats = assert(load("local savedFloats = {}\n"
    .. extract("float", "local function appName(win)", "local function rememberFloat(win)")
    .. extract("float", "local function placeFloat(win", "local function raiseFloatingNow()")
    .. "return shouldFloat, function(t) savedFloats = t end", "float", "t", env))()
local function classify(value)
    fullScreen, axReads = value, 0
    S.autoFloat = {}
    setSavedFloats({})
    return shouldFloat(win)
end
assert(classify(false) == true and S.autoFloat[1] == true, "windows that can't go full screen float")
assert(classify(true) == false and S.autoFloat[1] == false, "windows that can go full screen tile")
assert(classify(nil) == false and S.autoFloat[1] == nil, "unreadable windows tile and are asked again")
classify(false)
shouldFloat(win)
assert(axReads == 1, "one read decides")
title = "Picture-in-Picture"
assert(classify(false) == false and axReads == 0, "PiP is never classified")
title = "test"
classify(false)
S.autoFloat, axReads = {}, 0
setSavedFloats({ ["1"] = { app = "test", float = false } })
assert(shouldFloat(win) == false and axReads == 0, "manual override survives reload")
setSavedFloats({})
Util.windowKind = function() return "subwindow" end
assert(classify(true) == true and axReads == 0, "dialogs and panels always float")
Util.windowKind = function() return "standard" end
rules = { float = true }
assert(classify(true) == true and axReads == 0, "a float rule overrides full-screen support")
rules = { float = false }
assert(classify(false) == false and S.autoFloat[1] == false and axReads == 0, "a tile rule keeps it tiled")

-- New floats are sized and placed by their rule, in points or fractions of
-- the display; without a position they're centred, dialogs only on request.
local placed, sized
local sf = { x = 100, y = 50, w = 1000, h = 800 }
win.screen = function() return { frame = function() return sf end } end
win.frame = function() return { x = 0, y = 0, w = sized and sized.w or 200, h = sized and sized.h or 100 } end
win.setTopLeft = function(_, p) placed = p end
win.setSize = function(_, s) sized = s end
local function place(rule, canFullScreen)
    rules, placed, sized = rule, nil, nil
    return classify(canFullScreen or false)
end
place({})
assert(placed.x == 500 and placed.y == 400 and sized == nil, "floats are centred")
place({ size = { 0.5, 0.25 } })
assert(sized.w == 500 and sized.h == 200 and placed.x == 350 and placed.y == 350,
    "fractions size against the display, then centre")
place({ size = { w = 640, h = 480 }, position = { 0, 0.5 } })
assert(sized.w == 640 and sized.h == 480 and placed.x == 100 and placed.y == 450,
    "points size, and position is from the display's top left")
place({ position = { 20, 30 }, center = true })
assert(placed.x == 120 and placed.y == 80, "a position wins over centring")
place({ center = false })
assert(placed == nil and sized == nil, "center = false leaves it where the app put it")
place({ size = { 0.5, 0.5 } }, true)
assert(S.autoFloat[1] == false and sized == nil, "tiles aren't sized")
Util.windowKind = function() return "subwindow" end
place({})
assert(placed == nil, "dialogs aren't centred")
place({ center = true })
assert(placed.x == 500 and placed.y == 400, "unless a rule says so")
Util.windowKind = function() return "standard" end
win.screen, win.frame, win.setTopLeft, win.setSize = function() return nil end, nil, nil, nil
rules = {}

-- Rules match on app, title, role and subrole, and merge with later ones
-- winning; the matching fields themselves aren't copied.
local ruleEnv = setmetatable({ S = { cfg = { rules = {} } } }, { __index = _G })
local rulesFor = assert(load(extract("util", "local windowRules = {}",
    "-- The filter's windows minus") .. "return rulesFor", "rules", "t", ruleEnv))()
local nextID, roleReads = 100, 0
local function ruleWin(app, winTitle, role, subrole)
    nextID = nextID + 1
    local id = nextID
    return { id = function() return id end, title = function() return winTitle end,
        role = function() roleReads = roleReads + 1 return role end,
        subrole = function() return subrole end,
        application = function() return { name = function() return app end } end }
end
ruleEnv.S.cfg.rules = {
    { app = "Finder", float = true, opacity = 0.9 },
    { app = "Finder", title = "^Copy", float = false, size = { 0.5, 0.6 } },
    { subrole = "AXDialog", noborder = true, center = true },
    { role = "AXSheet", workspace = 3 },
    { app = "Finder", role = "AXWindow", subrole = "AXDialog", position = { 10, 20 } },
}
local r = rulesFor(ruleWin("Finder", "Copying", "AXWindow", "AXStandardWindow"))
assert(r.float == false and r.size[1] == 0.5 and r.opacity == 0.9, "later matches win")
assert(r.noborder == nil and r.workspace == nil and r.position == nil, "role and subrole must match")
assert(r.app == nil and r.title == nil and r.role == nil and r.subrole == nil,
    "matching fields aren't effects")
r = rulesFor(ruleWin("Finder", "Info", "AXWindow", "AXDialog"))
assert(r.float == true and r.size == nil and r.noborder and r.center and r.position[2] == 20,
    "role, subrole and app together")
r = rulesFor(ruleWin("Safari", "x", "AXSheet", "AXDialog"))
assert(r.workspace == 3 and r.noborder and r.float == nil, "role and subrole alone")
roleReads = 0
ruleEnv.S.cfg.rules = { { app = "Finder", role = "AXWindow", float = true } }
local safari = ruleWin("Safari", "x", "AXWindow")
assert(next(rulesFor(safari)) == nil and roleReads == 0, "role isn't read once the app rules it out")
assert(rulesFor(safari) == rulesFor(safari), "worked out once per window")

-- Windows with a `noborder` rule get no ring.
local ringRules = { {}, { noborder = true }, { noborder = false } }
local ringWins = {}
for id = 1, 3 do ringWins[id] = { id = function() return id end } end
local ringEnv = setmetatable({
    S = { fullscreen = {} },
    Util = { managedWindows = function() return ringWins end,
        rulesFor = function(w) return ringRules[w:id()] end },
    Spaces = { isHidden = function() return false end },
    Tree = { behindMaximized = function() return false end, filling = function() return false end },
}, { __index = _G })
local onShow = assert(load(extract("border", "local suspended = false",
    "-- Window set changes come in bursts.") .. "return onShow", "border", "t", ringEnv))()
local shown = onShow()
assert(#shown == 2 and shown[1] == 1 and shown[2] == 3, "noborder windows get no ring")

-- Dialog/panel roles are managed only when they have a close button, are
-- modal, or have a default or cancel button.
local kindEnv = setmetatable({ hs = {} }, { __index = _G })
local attrs = {}
kindEnv.hs.axuielement = { windowElement = function()
    return { attributeValue = function(_, name)
        assert(name == "AXCloseButton" or name == "AXModal"
            or name == "AXDefaultButton" or name == "AXCancelButton")
        return attrs[name]
    end }
end }
local windowKind = assert(load(extract("util", "local MANAGED_ROLES =",
    "local managedCache = nil") .. "return windowKind", "kind", "t", kindEnv))()
local function kindOf(id, subrole, windowAttrs)
    attrs = windowAttrs or {}
    return windowKind({ id = function() return id end, subrole = function() return subrole end })
end
assert(kindOf(1, "AXStandardWindow") == "standard")
assert(kindOf(2, "AXDialog", { AXCloseButton = {} }) == "subwindow", "titled dialogs are managed")
assert(kindOf(3, "AXDialog", { AXModal = false }) == "ignored", "helper overlays are ignored")
assert(kindOf(2, "AXDialog") == "subwindow", "classified once")
assert(kindOf(4, "AXDialog", { AXModal = true, AXDefaultButton = {} }) == "subwindow",
    "modal dialogs without a close button are managed")
assert(kindOf(5, "AXFloatingWindow", { AXCancelButton = {} }) == "subwindow",
    "dialogs with a cancel button are managed")

local appEnv = setmetatable({
    hs = env.hs, Util = Util,
}, { __index = _G })
local appWindows = assert(load(extract("discover", "local appWindowCache = {}",
    "local function withRecentlyChangedApps") .. "return appWindows", "app windows", "t", appEnv))()
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
S.autoFloat, S.applied, Discover.layoutChecks = {}, {}, {}
S.lastMouseTime, env.BSP_SETTLE = 0, 0.35 -- BSP_SETTLE is a file-local in layout.lua
Tree.findByID = function() return {}, { rect = target }, "screen:1" end
Tree.keyForScreen = function() return "screen:1" end
env.hs.mouse = { getButtons = function() return {} end }
Discover.cancelLayoutCheck = function(id)
    local pending = Discover.layoutChecks[id]
    if pending then pending.timer:stop() Discover.layoutChecks[id] = nil end
end
local verify = assert(load(extract("layout", "local function framesMatch(a, b)",
    "local function applyTree(node") .. "return verifyLayout", "layout", "t", env))()
local function reset()
    queue, writes, accept = {}, 0, false
    actual = { x = 0, y = 0, w = 100, h = 100 }
    S.applied, Discover.layoutChecks = {}, {}
    S.lastMouseTime = 0
end
reset()
verify(win, target, "target")
tick()
assert(writes == 1 and S.applied[1] == nil, "unobserved resize must not be cached")
accept = true
drain()
assert(writes == 2 and S.applied[1] == "target", "late resize should be verified")
reset()
verify(win, target, "target")
drain()
assert(writes == 2 and S.applied[1] == nil, "ignored resizes have bounded retries")
reset()
verify(win, target, "target")
S.lastMouseTime = now + 0.01
drain()
assert(writes == 0, "mouse interaction cancels retries")
reset()
verify(win, target, "target")
Tree.findByID = function() return nil end
drain()
assert(writes == 0, "removed tiles must not be resized")
reset()
Tree.findByID = function() return {}, { rect = target }, "screen:1" end
actual = target
local oldScreen = win.screen
win.screen = function() error("matching frames must not query the screen") end
verify(win, target, "target")
drain()
assert(S.applied[1] == "target")
win.screen = oldScreen

-- Snapshot fast path avoids querying WindowServer for disjoint tiles;
-- overlapping/floating windows retain real front-to-back order.
local second = { id = function() return 2 end }
local tiles = { [1] = target, [2] = { x = 820, y = 10, w = 800, h = 600 } }
local listCalls = 0
S.ffmSnapshot, Util.FFM_SNAPSHOT_TTL = nil, 1
S.running.windowFilter = { getWindows = function() return { win, second } end }
Util.managedWindows = function() return S.running.windowFilter:getWindows() end
Tree.rectFor = function(id) return tiles[id] end
env.hs.geometry = { rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end }
env.hs.window = { list = function()
    listCalls = listCalls + 1
    return {
        { kCGWindowNumber = 2, kCGWindowBounds = { X = 20, Y = 30, Width = 400, Height = 300 } },
        { kCGWindowNumber = 1, kCGWindowBounds = { X = 10, Y = 10, Width = 800, Height = 600 } },
    }
end }
local snapshot = assert(load(extract("focus", "local function windowSnapshot(fresh)",
    "S.ffmPrebuild = hs.timer.delayed.new") .. "return windowSnapshot", "snapshot", "t", env))()
assert(#snapshot(true) == 2 and listCalls == 0, "disjoint tiles need no WindowServer query")
tiles[2] = target
local entries = snapshot(true)
assert(entries[1].id == 2 and listCalls == 1, "overlapping tiles need stacking order")
tiles[2], S.autoFloat[2] = nil, true
entries = snapshot(true)
assert(entries[1].id == 2 and entries[1].frame.x == 20, "floats use live geometry")
snapshot()
assert(listCalls == 2, "cached snapshots need no WindowServer query")
hiddenIDs[2] = true
entries = snapshot(true)
assert(#entries == 1 and entries[1].id == 1, "parked windows are not hover targets")
hiddenIDs[2] = nil
S.running.pipFilter = { getWindows = function()
    return {{ frame = function() return { x = 50, y = 50, w = 100, h = 100 } end }}
end }
env.windowSnapshot = snapshot -- file-local in hyprspoon/focus.lua
Util.pointInFrame = function(p, f)
    return p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h
end
local entryAt = assert(load(extract("focus", "local function snapshotEntryAt(point, fresh)",
    "local function windowUnderPoint") .. "return snapshotEntryAt", "occlusion", "t", env))()
assert(entryAt({ x = 60, y = 60 }, true) == nil, "PiP must block hover focus of underlying windows")
assert(entryAt({ x = 25, y = 35 }) ~= nil, "hover outside PiP must still work")
S.running.pipFilter = nil

-- A float buried under another app's tile still wins hover; one buried under
-- its own app's window (its parent, focused) does not.
local pids = { [1] = 10, [2] = 20 }
win.pid, second.pid = function() return pids[1] end, function() return pids[2] end
env.hs.window.list = function()
    return {
        { kCGWindowNumber = 1, kCGWindowBounds = { X = 10, Y = 10, Width = 800, Height = 600 } },
        { kCGWindowNumber = 2, kCGWindowBounds = { X = 20, Y = 30, Width = 400, Height = 300 } },
    }
end
assert(entryAt({ x = 25, y = 35 }, true).id == 2, "buried floats stay reachable")
pids[2] = 10
assert(entryAt({ x = 25, y = 35 }, true).id == 1, "own app's window above a float wins")

-- BSP navigation returns to the last-used leaf in the adjacent subtree.
local nav = setmetatable({ S = { trees = {}, tilingEnabled = true },
    Util = { winByID = {}, focusHistory = {} }, Tree = {}, Focus = {} }, { __index = _G })
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
nav.Tree.isLeaf = function(node) return node.windowID ~= nil end
nav.Util.winByID, nav.S.trees = windows, { main = root }
nav.Tree.findByID = function(id)
    if id == 12 then return {{ node = root, branch = "b" }}, right, "main" end
    return {{ node = left, branch = id == 10 and "a" or "b" }, { node = root, branch = "a" }},
        id == 10 and top or bottom, "main"
end
nav.Focus.windowSnapshot = function() return {} end
local neighbour = assert(load(extract("actions", "local function nearestInDirection(f, selfID",
    "local function directionalCandidates") .. "return neighbourInDirection", "navigation", "t", nav))()
nav.Util.focusHistory = {12, 11, 10}
assert(neighbour(windows[12], "left", true) == windows[11], "return to bottom-left")
nav.Util.focusHistory = {12, 10, 11}
assert(neighbour(windows[12], "left", true) == windows[10], "return to top-left when it was last used")
assert(neighbour(windows[11], "right", true) == windows[12], "left-bottom to right")
assert(neighbour(windows[11], "up", true) == windows[10], "nearest ancestor chooses upper sibling")
nav.Util.focusHistory = {}
assert(neighbour(windows[12], "left", true) ~= nil, "missing history falls back to geometry")
local frameCalls = 0
windows[10].frame = function() frameCalls = frameCalls + 1 return top.rect end
assert(neighbour(windows[10], "up", true) == nil and frameCalls == 0,
    "a tile at its tree's edge searches from its tile rect, not an AX frame")

local checks = 0
env.tileNow = function() checks = checks + 1 end -- file-local in layout.lua
local recheck = assert(load(extract("layout", "local function scheduleRecheck(step)",
    "local function restoreFloatingFrames") .. "return scheduleRecheck", "discovery", "t", env))()
recheck()
drain()
assert(checks == 3, "discovery retries must continue without a layout change")
-- Swipes fire once per gesture, only with the configured finger count and
-- mostly sideways movement; fingers moving left go to the next workspace.
local switches = {}
local gestures = setmetatable({
    S = { cfg = { swipe = { fingers = 3, distance = 0.12 } } },
    Spaces = { gotoWorkspaceRelative = function(delta) switches[#switches + 1] = delta end },
    hs = { timer = { doAfter = after } },
}, { __index = _G })
local onGesture = assert(load(extract("swipe", "local swipe = nil",
    "-- Forgets a swipe") .. "return onGesture", "swipe", "t", gestures))()
local function touchAt(count, x, y, phase)
    local touches = {}
    for i = 1, count do
        touches[i] = { touching = phase ~= "ended", phase = phase or "moved",
            normalizedPosition = { x = x + i * 0.05, y = y } }
    end
    return { getTouches = function() return touches end }
end
local function gesture(count, points)
    for _, p in ipairs(points) do onGesture(touchAt(count, p[1], p[2])) end
    onGesture(touchAt(count, 0, 0, "ended"))
    drain()
end
gesture(3, { { 0.6, 0.5 }, { 0.55, 0.5 }, { 0.45, 0.5 }, { 0.3, 0.5 } })
assert(#switches == 1 and switches[1] == 1, "three fingers left go to the next workspace once")
gesture(3, { { 0.3, 0.5 }, { 0.5, 0.5 } })
assert(#switches == 2 and switches[2] == -1, "three fingers right go to the previous one")
gesture(2, { { 0.6, 0.5 }, { 0.3, 0.5 } })
gesture(4, { { 0.6, 0.5 }, { 0.3, 0.5 } })
assert(#switches == 2, "other finger counts are left to scrolling and macOS")
gesture(3, { { 0.5, 0.2 }, { 0.4, 0.6 } })
assert(#switches == 2, "mostly vertical movement is not a sideways swipe")
gesture(3, { { 0.5, 0.5 }, { 0.45, 0.5 } })
assert(#switches == 2, "short movements don't switch")
assert(onGesture({ getTouches = function() return nil end }) == false, "non-gesture events pass through")

print("Window classification, rules, layout, snapshots, discovery, PiP, BSP navigation, borders, and swipe regressions passed")
