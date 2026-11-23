-- Run with: lua tests/cleanup_regression_test.lua
-- Regression tests for rough-edge fixes across tabs, config merge, rules,
-- scrolling math, slide/border lifecycle, mouse drags, spaces, restore, and hotkeys.
package.path = "./?.lua;" .. package.path

local function runIsolated(fn)
    local savedLoaded = {}
    for k, v in pairs(package.loaded) do
        if k:match("^hyprspoon") then savedLoaded[k] = v end
    end
    local savedHs = hs
    local ok, err = xpcall(fn, debug.traceback)
    for k in pairs(package.loaded) do
        if k:match("^hyprspoon") then package.loaded[k] = nil end
    end
    for k, v in pairs(savedLoaded) do package.loaded[k] = v end
    hs = savedHs
    if not ok then error(err, 0) end
end

local function clearHyprspoon()
    for k in pairs(package.loaded) do
        if k:match("^hyprspoon") then package.loaded[k] = nil end
    end
end

-- 1. Tabs.assign must never assign a background tab across different apps (PIDs).
runIsolated(function()
    clearHyprspoon()
    local Tabs = require("hyprspoon.tabs")
    local background = {
        [10] = { pid = 100, title = "Untitled" },
    }
    local shown = {
        { id = 20, pid = 200, count = 3, titles = { "Untitled", "Other" }, frame = { x = 0, y = 0, w = 500, h = 500 } },
    }
    local assigned = Tabs.assign(background, shown, function() return nil end)
    assert(assigned[10] == nil, "background tab must not be assigned to a different app's window")

    -- Same app still assigns cleanly.
    shown[2] = { id = 30, pid = 100, count = 2, titles = { "Untitled", "Main" }, frame = { x = 0, y = 0, w = 500, h = 500 } }
    assigned = Tabs.assign(background, shown, function() return nil end)
    assert(assigned[10] == 30, "same-app background tab assigns to its app's bar")
end)

-- 2. Util.deepMerge replaces hs.drawing.color tables whole, and rulesFor handles bad patterns.
runIsolated(function()
    clearHyprspoon()
    hs = {
        settings = { get = function() return nil end, set = function() end },
        timer = { delayed = { new = function() return { start = function() end, stop = function() end } end } },
        processInfo = { processID = 1 },
    }
    package.loaded["hyprspoon.tree"] = {}
    package.loaded["hyprspoon.border"] = { sync = function() end, watch = function() end }
    local S = require("hyprspoon.state")
    local Util = require("hyprspoon.util")

    local merged = Util.deepMerge(S.defaults, {
        border = { inactive = { red = 1, green = 0, blue = 0 } },
        group = { bar = { text = { red = 0, green = 1, blue = 0 } } },
        tiling = { dropColor = { hex = "#ff0000" } },
    })
    assert(merged.border.inactive.red == 1 and merged.border.inactive.hex == nil and merged.border.inactive.alpha == nil,
        "RGB override replaces default hex+alpha color table")
    assert(merged.group.bar.text.green == 1 and merged.group.bar.text.white == nil,
        "RGB override replaces default white color table")
    assert(merged.tiling.dropColor.hex == "#ff0000" and merged.tiling.dropColor.red == nil,
        "hex override replaces default RGB color table")

    -- Malformed Lua pattern in rule.title must not throw.
    S.cfg.rules = { { title = "bad [pattern", float = true }, { app = "Good", noborder = true } }
    local win = {
        id = function() return 42 end,
        application = function() return { name = function() return "Good" end } end,
        title = function() return "Hello" end,
        role = function() return "AXWindow" end,
        subrole = function() return "AXStandardWindow" end,
    }
    local rule = Util.rulesFor(win)
    assert(rule.float == nil and rule.noborder == true, "malformed title pattern is ignored safely")
end)

-- 3. Anim.get handles nil S.cfg and rejects NaN / inf.
runIsolated(function()
    clearHyprspoon()
    hs = { settings = { get = function() return nil end } }
    local S = require("hyprspoon.state")
    S.cfg = nil
    local Anim = require("hyprspoon.anim")
    local m = Anim.get("windows")
    assert(m.curve == "ease" and m.duration == 0, "Anim.get works when S.cfg is nil")
    S.cfg = { animations = { windows = { duration = 0 / 0, mass = math.huge, stiffness = -5 } }, tiling = {} }
    local m2 = Anim.get("windows")
    assert(m2.duration == 0 and m2.mass == 0.6 and m2.stiffness == 800, "NaN, inf, and negative spring values fall back")
end)

-- 4. Scroll.heights never collapses to negative heights, and edge configs don't crash.
runIsolated(function()
    clearHyprspoon()
    local noop = function() end
    hs = {
        settings = { get = function() return nil end },
        timer = { secondsSinceEpoch = function() return 100 end, doAfter = function() return { stop = noop } end },
        mouse = { getCurrentScreen = function() return nil end },
    }
    local S = require("hyprspoon.state")
    S.cfg = {
        tiling = { innerGap = 5, minRatio = 0.2, maxRatio = 0.8 },
        minWidth = 240, minHeight = 140,
        scrolling = { presets = {}, swipeSpan = 0 },
    }
    package.loaded["hyprspoon.util"] = { winByID = {}, focusHistory = {}, warpToWindow = noop, native = noop }
    package.loaded["hyprspoon.tree"] = {
        isLeaf = function(n) return n.windowID ~= nil end,
        findByID = function() return nil end,
        keyForScreen = function() return "ws1" end,
        saveTrees = noop,
    }
    package.loaded["hyprspoon.focus"] = { focus = noop }
    package.loaded["hyprspoon.layout"] = { tileNow = noop, applyTree = noop, captureRetile = noop }
    package.loaded["hyprspoon.spaces"] = { isHidden = function() return false end, uuidForKey = noop }
    package.loaded["hyprspoon.border"] = { focusing = noop, ringFor = noop }
    package.loaded["hyprspoon.layouts"] = { is = function() return true end, configured = function() return true end }

    local Scroll = require("hyprspoon.scroll")
    local hs1 = Scroll.heights({ [1] = 0.5 }, 10, 500, 5, 140)
    assert(#hs1 == 10)
    for i = 1, 10 do
        assert(hs1[i] >= 1, "height " .. i .. " must be >= 1, got " .. tostring(hs1[i]))
    end
    assert(hs1[1] > 1, "resized window must not be crushed to 1px when many auto windows compete for least")

    -- Invalid direction and empty presets/zero swipeSpan are safe no-ops.
    assert(Scroll.consumeOrExpel(nil, "up") == false)
    assert(Scroll.consumeOrExpel(nil, nil) == false)
    Scroll.panTo("ws1", 0, 0.5)
end)

-- 5. Slide.stop resets native cleanly (restarting with slide = false does not crash) and retile(nil) returns false.
runIsolated(function()
    clearHyprspoon()
    local noop = function() end
    local stopped, onChangeArg = 0, "unset"
    local nativeMod = {
        onChange = function(fn) onChangeArg = fn end,
        forget = noop,
        wallpaper = noop,
        capture = function() return true end,
        run = noop,
        stop = function() stopped = stopped + 1 end,
    }
    hs = {
        settings = { get = function() return nil end },
        screen = { allScreens = function() return {} end },
        timer = { secondsSinceEpoch = function() return 100 end, doAfter = function() return { stop = noop } end },
    }
    local S = require("hyprspoon.state")
    S.cfg = { slide = { workspaces = "horizontal", scratchpads = "bottom" }, experimental = {} }
    package.loaded["hyprspoon.util"] = { native = function() return nativeMod end }
    package.loaded["hyprspoon.anim"] = { get = function() return {} end }
    package.loaded["hyprspoon.groupbar"] = { suspend = noop }
    package.loaded["hyprspoon.spaces"] = { beneath = function() return {} end }

    local Slide = require("hyprspoon.slide")
    Slide.start()
    assert(Slide.canPan() == true)
    assert(Slide.retile(nil, { { wid = 1 } }, noop) == false, "retile(nil) must return false without crashing")
    Slide.stop()
    assert(stopped == 1, "Slide.stop calls native.stop")
    S.cfg.slide = false
    Slide.start()
    assert(Slide.canPan() == false, "canPan is false after restart with slide = false")
    assert(Slide.switch({ getUUID = function() return "A" end }, 1, 2, { 1 }, { 2 }, 1) == false,
        "switch is safe no-op after restart with slide = false")
end)

-- 6. Border.stop resets native = false so post-stop calls don't touch stopped module.
runIsolated(function()
    clearHyprspoon()
    local noop = function() end
    local calls = 0
    local nativeMod = {
        style = noop,
        set = function() calls = calls + 1 end,
        focus = function() calls = calls + 1 end,
        stop = noop,
    }
    hs = {
        settings = { get = function() return nil end },
        screen = { allScreens = function() return {} end },
        drawing = { color = { asRGB = function() return nil end } },
        timer = { delayed = { new = function() return { start = noop, stop = noop } end } },
    }
    local S = require("hyprspoon.state")
    S.cfg = { border = { active = "#invalid", inactive = false, width = 3, radius = 12, fade = 0 }, experimental = {} }
    S.running = {}
    package.loaded["hyprspoon.util"] = { native = function() return nativeMod end, managedWindows = function() return {} end }
    package.loaded["hyprspoon.spaces"] = { isHidden = function() return false end }
    package.loaded["hyprspoon.tree"] = { behindMaximized = function() return false end, filling = function() return false end }
    package.loaded["hyprspoon.scroll"] = { isAway = function() return false end }

    local Border = require("hyprspoon.border")
    Border.start() -- invalid color string must not crash rgba()
    assert(calls == 1)
    Border.stop()
    calls = 0
    Border.syncNow()
    Border.focused({ id = function() return 1 end })
    assert(calls == 0, "stopped border module must not invoke native calls")
end)

-- 7. Mouse ignores overlapping second button down/up and cleans up active drags on Mouse.stop().
runIsolated(function()
    clearHyprspoon()
    local noop = function() end
    local dragBegins, dragEnds, dropCancels, muted = 0, 0, 0, nil
    hs = {
        settings = { get = function() return nil end },
        geometry = { copy = function(r) return { x = r.x, y = r.y, w = r.w, h = r.h } end },
        timer = { secondsSinceEpoch = function() return 100 end },
        eventtap = {
            new = function() return { start = function(self) return self end, stop = noop } end,
            event = { types = { leftMouseDown = 1, leftMouseUp = 2, leftMouseDragged = 3,
                                rightMouseDown = 4, rightMouseUp = 5, rightMouseDragged = 6 } },
        },
        processInfo = { processID = 1 },
    }
    local S = require("hyprspoon.state")
    S.cfg = { mouse = { move = { "alt" }, resize = { "alt", "cmd" }, rightResize = { "alt" } }, minWidth = 240, minHeight = 140 }
    S.windowInfo, S.applied = {}, {}
    S.running = { events = { mute = function(id) muted = id end } }
    local win = {
        id = function() return 7 end,
        pid = function() return 42 end,
        frame = function() return { x = 0, y = 0, w = 400, h = 300 } end,
        screen = function() return { getUUID = function() return "A" end, currentMode = function() return { freq = 60 } end } end,
    }
    package.loaded["hyprspoon.util"] = {
        focusWindow = noop,
        native = function()
            return {
                dragBegin = function(t) dragBegins = dragBegins + 1 assert(t.button == "left") return true end,
                dragEnd = function() dragEnds = dragEnds + 1 end,
            }
        end,
    }
    package.loaded["hyprspoon.focus"] = { windowUnderPoint = function() return win end }
    package.loaded["hyprspoon.resize"] = { resizeBranches = function() return nil, nil end, beginResize = noop, finishResize = noop }
    package.loaded["hyprspoon.drop"] = {
        beginDrag = noop, updateDrag = noop, wouldStay = function() return false end,
        preview = noop, finishDrag = function() return true end,
        cancelDrag = function() dropCancels = dropCancels + 1 end,
    }
    package.loaded["hyprspoon.border"] = { previewer = noop }
    package.loaded["hyprspoon.discover"] = { windowInfoFor = function() return { uuid = "A" } end }
    package.loaded["hyprspoon.spaces"] = { parkPoint = noop, claim = noop }
    package.loaded["hyprspoon.slide"] = { lifter = noop, land = noop, cancelHome = function() return false end }

    local Mouse = require("hyprspoon.mouse")
    local function ev(kind)
        return {
            getType = function() return hs.eventtap.event.types[kind] end,
            location = function() return { x = 50, y = 50 } end,
            getFlags = function() return { containExactly = function(_, want) return #want == 1 and want[1] == "alt" end } end,
        }
    end

    assert(Mouse.onMouseEvent(ev("leftMouseDown")) == true)
    assert(dragBegins == 1 and muted == 7)
    -- Right-click down and right-click up while left-dragging must NOT start a resize or end the move drag.
    assert(Mouse.onMouseEvent(ev("rightMouseDown")) == false)
    assert(Mouse.onMouseEvent(ev("rightMouseUp")) == false)
    assert(S.dragState ~= nil and dragBegins == 1 and dragEnds == 0,
        "other mouse button must not clobber or end an active drag")
    -- Mouse.stop() must tear down the active drag, unmute events, and cancel Drop.
    Mouse.stop()
    assert(S.dragState == nil and dragEnds == 1 and dropCancels == 1 and muted == nil,
        "Mouse.stop must clean up active native drag, drop state, and event mute")
end)

-- 8. Spaces: loadState tolerates missing info/under, keyForUUID(nil) returns nil,
--    and moveWorkspaceToDisplay never promotes a hidden scratchpad.
runIsolated(function()
    clearHyprspoon()
    local noop = function() end
    local scrA = {
        getUUID = function() return "A" end, name = function() return "A" end, id = function() return 1 end,
        frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
        fullFrame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
    }
    local scrB = {
        getUUID = function() return "B" end, name = function() return "B" end, id = function() return 2 end,
        frame = function() return { x = 1000, y = 0, w = 1000, h = 800 } end,
        fullFrame = function() return { x = 1000, y = 0, w = 1000, h = 800 } end,
    }
    local settings = {
        ["hyprspoon.workspaces"] = {
            boot = 1000,
            active = { A = 1, B = 2 },
            -- Deliberately omit `info` and `under` to verify loadState tolerates partial state.
            home = { ["1"] = "A", ["2"] = "B", ["101"] = "A" },
            of = {},
            parked = {},
        },
    }
    hs = {
        settings = { get = function(k) return settings[k] end, set = function(k, v) settings[k] = v end },
        timer = { doAfter = function() return { stop = noop } end, secondsSinceEpoch = function() return 1000 end },
        screen = { allScreens = function() return { scrA, scrB } end, primaryScreen = function() return scrA end },
        mouse = { getCurrentScreen = function() return scrA end, absolutePosition = noop },
        window = { list = function() return {} end },
        focus = noop,
    }
    package.loaded["hyprspoon.util"] = { focusHistory = {}, winByID = {}, managedWindows = function() return {} end, rulesFor = function() return {} end, native = noop }
    package.loaded["hyprspoon.tree"] = { bootTime = 1000, setOf = noop, rectFor = noop, findByID = noop, membersOf = function() return {} end }
    package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop, focus = noop, currentWindow = noop, noteFocus = noop }
    package.loaded["hyprspoon.discover"] = { cancelLayoutCheck = noop }
    package.loaded["hyprspoon.layout"] = { tileNow = noop, scheduleRetile = noop, BSP_SETTLE = 0 }
    package.loaded["hyprspoon.bar"] = { update = noop }
    package.loaded["hyprspoon.hud"] = { update = noop, switched = noop }
    package.loaded["hyprspoon.border"] = { forget = noop, sync = noop, syncNow = noop, hide = noop }
    package.loaded["hyprspoon.restore"] = { savedActive = function() return {} end, match = noop, forget = noop }
    package.loaded["hyprspoon.slide"] = { reset = noop, forget = noop, switch = function() return false end, hideScratchpad = function() return false end }
    package.loaded["hyprspoon.hooks"] = { fire = noop }

    local S = require("hyprspoon.state")
    S.cfg = { namedWorkspaces = { "A" }, displays = {} }
    S.trees, S.maximized, S.filled, S.untiled, S.layouts, S.windowInfo, S.applied = {}, {}, {}, {}, {}, {}, {}
    S.settleUntil = 0

    local Spaces = require("hyprspoon.spaces")
    assert(Spaces.keyForUUID(nil) == nil, "keyForUUID(nil) must return nil, not 'wsnil'")
    Spaces.start()
    Spaces.moveWorkspaceToDisplay(1)
    assert(Spaces.keyForUUID("A") ~= "ws101", "moveWorkspaceToDisplay must not promote a hidden scratchpad")
end)

-- 9. Restore.rebuild preserves leaf metadata on non-restored leaves.
runIsolated(function()
    clearHyprspoon()
    local now = os.time()
    local settings = {
        ["hyprspoon.restore"] = {
            boot = 1000,
            untilTime = now + 100,
            trees = { ws1 = { windowID = 10 } },
            windows = { ["10"] = { app = "com.test", title = "A", ws = 1 } },
            claimed = { ["10"] = 100 },
            active = {},
        },
    }
    hs = {
        execute = function() return "{ sec = 1000, usec = 0 }" end,
        settings = { get = function(k) return settings[k] end, set = function(k, v) settings[k] = v end },
        json = { encode = function() return "{}" end },
        timer = { doAfter = function() return { stop = function() end } end },
    }
    package.loaded["hyprspoon.util"] = { native = function() end }
    package.loaded["hyprspoon.spaces"] = { keyForUUID = function() return "ws1" end }
    local S = require("hyprspoon.state")
    S.cfg = { tiling = { minRatio = 0.2, maxRatio = 0.8 } }
    local Tree = require("hyprspoon.tree")
    local Restore = require("hyprspoon.restore")
    local cur = Tree.leaf(200)
    cur.pseudo = { w = 400, h = 300 }
    cur.columnWidth = 0.66
    cur.windowHeight = 0.4
    local rebuilt = Restore.rebuild("ws1", cur, { [100] = true, [200] = true })
    local _, leaf200 = Tree.ancestors(rebuilt, 200)
    assert(leaf200 and leaf200.pseudo and leaf200.pseudo.w == 400 and leaf200.columnWidth == 0.66 and leaf200.windowHeight == 0.4,
        "Restore.rebuild must preserve pseudo and scrolling metadata on existing plain leaves")
end)

-- 10. hotkeysFor skips multi-char/numeric namedWorkspaces for auto-binding, and hotkeyActions doesn't clobber numbered ones.
runIsolated(function()
    clearHyprspoon()
    hs = { settings = { get = function() return nil end } }
    for _, name in ipairs({ "actions", "util", "tree", "float", "focus", "discover", "layout",
        "drop", "resize", "mouse", "ffm", "spaces", "swipe", "bar", "hud", "border", "slide", "overview",
        "restore", "group", "groupbar", "hooks", "scroll" }) do
        package.loaded["hyprspoon." .. name] = {}
    end
    local M = dofile("init.lua")
    local S = require("hyprspoon.state")
    S.cfg = { namedWorkspaces = { "Term", "1", "Q" } }
    local map = M.hotkeysFor({ "alt" })
    assert(map.workspaceQ and map.workspaceQ[2] == "q", "single-letter named workspace gets default key")
    assert(map.workspaceTerm == nil, "multi-char named workspace does not generate invalid single-key binding")
    assert(map.workspace1[2] == "1", "numeric named workspace does not break numbered workspace1")
end)

-- 11. Spaces.windowsOf excludes off-Space, full-screen, group-hidden, and scrolled-away windows from slide captures.
runIsolated(function()
    clearHyprspoon()
    local noop = function() end
    local scrA = {
        getUUID = function() return "A" end, name = function() return "A" end, id = function() return 1 end,
        frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
        fullFrame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
    }
    local function fakeWin(id)
        return {
            id = function() return id end,
            frame = function() return { x = 10, y = 10, w = 500, h = 400 } end,
            screen = function() return scrA end,
            application = function() return { bundleID = function() return "com.test" end } end,
            title = function() return "win" .. id end,
        }
    end
    local w1, w2, wFull, wOff, wAway, wHidden = fakeWin(10), fakeWin(20), fakeWin(30), fakeWin(40), fakeWin(50), fakeWin(60)
    -- Window 99 is in saved `of` (on another Space) and live in WindowServer,
    -- but absent from managedWindows().
    local settings = {
        ["hyprspoon.workspaces"] = {
            boot = 1000,
            active = { A = 1 },
            home = { ["1"] = "A", ["2"] = "A" },
            of = { ["10"] = 1, ["20"] = 2, ["30"] = 1, ["40"] = 1, ["50"] = 1, ["60"] = 1, ["99"] = 1 },
            parked = { ["20"] = { x = 10, y = 10, w = 500, h = 400 } },
        },
    }
    local capturedOut, capturedIn
    hs = {
        settings = { get = function(k) return settings[k] end, set = function(k, v) settings[k] = v end },
        timer = { doAfter = function() return { stop = noop } end, secondsSinceEpoch = function() return 1000 end },
        screen = { allScreens = function() return { scrA } end, primaryScreen = function() return scrA end },
        mouse = { getCurrentScreen = function() return scrA end, absolutePosition = noop },
        window = { list = function() return {} end },
        focus = noop,
    }
    package.loaded["hyprspoon.util"] = {
        focusHistory = {}, winByID = { [10] = w1, [20] = w2 },
        managedWindows = function() return { w1, w2, wFull, wOff, wAway, wHidden } end,
        rulesFor = function() return {} end,
        setFrame = noop,
        pointInFrame = function() return true end,
        native = function()
            return { liveIDs = function() return { [10] = true, [20] = true, [30] = true, [40] = true, [50] = true, [60] = true, [99] = true } end }
        end,
    }
    package.loaded["hyprspoon.tree"] = {
        bootTime = 1000,
        setOf = function(id)
            if id == 60 then return { kind = "group", windowID = 10, members = { 10, 60 } }, "ws1" end
        end,
        tabsOf = function() return nil end,
        rectFor = noop, findByID = noop, membersOf = function() return {} end,
    }
    package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop, focus = noop, currentWindow = noop, noteFocus = noop }
    package.loaded["hyprspoon.discover"] = {
        cancelLayoutCheck = noop,
        windowInfoFor = function() return { uuid = "A", full = false } end,
    }
    package.loaded["hyprspoon.layout"] = { tileNow = noop, scheduleRetile = noop, BSP_SETTLE = 0 }
    package.loaded["hyprspoon.bar"] = { update = noop }
    package.loaded["hyprspoon.hud"] = { update = noop, switched = noop }
    package.loaded["hyprspoon.border"] = { forget = noop, sync = noop, syncNow = noop, hide = noop }
    package.loaded["hyprspoon.restore"] = { savedActive = function() return {} end, match = noop, forget = noop }
    package.loaded["hyprspoon.scroll"] = { isAway = function(id) return id == 50 end }
    package.loaded["hyprspoon.slide"] = {
        reset = noop, forget = noop, hideScratchpad = function() return false end,
        switch = function(_, _, _, outIds, inIds)
            capturedOut, capturedIn = outIds, inIds
            return true
        end,
    }
    package.loaded["hyprspoon.hooks"] = { fire = noop }

    local S = require("hyprspoon.state")
    S.cfg = { namedWorkspaces = {}, displays = {} }
    S.trees, S.maximized, S.filled, S.untiled, S.layouts, S.windowInfo, S.applied = {}, {}, {}, {}, {}, {}, {}
    S.fullscreen = { [30] = true }
    S.offSpace = { [40] = true }
    S.settleUntil = 0

    local Spaces = require("hyprspoon.spaces")
    Spaces.start()
    Spaces.gotoWorkspace(2)
    assert(capturedOut and #capturedOut == 1 and capturedOut[1] == 10,
        "only visible on-Space window 10 should slide out of workspace 1")
    assert(capturedIn and #capturedIn == 1 and capturedIn[1] == 20,
        "workspace 2 should slide in with window 20")
end)

print("Cleanup regression tests passed")
